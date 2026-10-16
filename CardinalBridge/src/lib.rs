//! C API over Cardinal's file name index (`Vendor/cardinal/search-cache`), used by
//! fileCommander's search sheet. See `Sources/CCardinal/cardinal_bridge.h` for the contract.
//!
//! One index = one worker thread that owns a `SearchCache`: it walks the root (or loads a
//! persisted snapshot), then serves searches and applies FSEvents so the index stays current.

use cardinal_sdk::EventWatcher;
use crossbeam_channel::{Receiver, Sender, bounded, select, unbounded};
use memchr::memmem;
use rayon::prelude::*;
use search_cache::{HandleFSEError, SearchCache, SearchOptions, WalkData};
use search_cancel::CancellationToken;
use unicode_normalization::UnicodeNormalization;
use std::{
    collections::HashSet,
    ffi::{CStr, c_char},
    fs::{File, OpenOptions},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    os::unix::ffi::OsStrExt,
    panic::{AssertUnwindSafe, catch_unwind},
    path::{Component, Path, PathBuf},
    ptr,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering},
    },
    thread,
    time::Duration,
};

const STATE_INDEXING: u8 = 0;
const STATE_READY: u8 = 1;
const STATE_CLOSED: u8 = 2;

/// FSEvents latency, in seconds.
const EVENT_LATENCY: f64 = 0.1;

/// Per-search cancellation: a ticket names a slot and the version it holds; bumping the slot
/// cancels that search only. Slots are reused round-robin, far more than run at once.
const SLOTS: u64 = 64;
static CANCEL_SLOTS: [AtomicU64; SLOTS as usize] = [const { AtomicU64::new(0) }; SLOTS as usize];
static NEXT_SLOT: AtomicU64 = AtomicU64::new(0);

fn ticket_token(ticket: u64) -> CancellationToken {
    CancellationToken::with_counter(&CANCEL_SLOTS[(ticket % SLOTS) as usize], ticket / SLOTS)
}

struct Shared {
    state: AtomicU8,
    /// Items seen so far while indexing, then the number of indexed items.
    items: AtomicU64,
}

enum Command {
    Search {
        request: Request,
        token: CancellationToken,
        reply: Sender<Reply>,
    },
    Save {
        path: PathBuf,
        reply: Sender<bool>,
    },
}

struct Request {
    query: String,
    scope: PathBuf,
    case_insensitive: bool,
    include_hidden: bool,
    /// Text the files must contain (bytes, ASCII case folding like Cardinal's `content:`).
    content: Option<String>,
    /// Files up to this size whose first `BINARY_SNIFF_BYTES` hold a NUL are skipped.
    max_file_size: u64,
    limit: usize,
}

enum Reply {
    Hits { paths: Vec<PathBuf>, truncated: bool },
    Cancelled,
    Error(String),
}

pub struct CardinalIndex {
    root: PathBuf,
    ignore: Vec<PathBuf>,
    shared: Arc<Shared>,
    commands: Sender<Command>,
    stop: &'static AtomicBool,
}

#[repr(C)]
pub struct CardinalSearchResult {
    /// `count` NUL-terminated UTF-8 paths, back to back; null when there are none.
    pub paths: *mut c_char,
    pub paths_len: usize,
    pub count: usize,
    /// More than `limit` items matched; only the first `limit` are in `paths`.
    pub truncated: bool,
    pub cancelled: bool,
    /// NUL-terminated message when the query could not run (e.g. a syntax error); else null.
    pub error: *mut c_char,
}

impl CardinalSearchResult {
    fn empty() -> Self {
        Self {
            paths: ptr::null_mut(),
            paths_len: 0,
            count: 0,
            truncated: false,
            cancelled: false,
            error: ptr::null_mut(),
        }
    }

    fn error(message: &str) -> Self {
        let mut bytes = message.replace('\0', " ").into_bytes();
        bytes.push(0);
        let (ptr, _) = leak(bytes);
        Self {
            error: ptr,
            ..Self::empty()
        }
    }
}

fn leak(bytes: Vec<u8>) -> (*mut c_char, usize) {
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    (Box::into_raw(boxed) as *mut u8 as *mut c_char, len)
}

unsafe fn free_leaked(ptr: *mut c_char, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(ptr as *mut u8, len)) });
    }
}

unsafe fn path_arg(s: *const c_char) -> Option<PathBuf> {
    if s.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(s) }.to_bytes();
    (!bytes.is_empty()).then(|| PathBuf::from(std::ffi::OsStr::from_bytes(bytes)))
}

/// Directories never worth indexing under `root`: the firmlinked duplicate of the data
/// volume (as Cardinal does); other apps' sandbox containers, which make macOS ask the user
/// whether fileCommander may "access data from other apps"; and folders that are slow or
/// costly to walk because they live elsewhere: other volumes and network shares (/Volumes),
/// automounts, and cloud storage (File Provider folders list their contents from the
/// network, and walking them can stall for minutes). Searching inside one of these indexes
/// that folder on its own (see `cardinal_index_covers`).
fn ignore_paths(root: &Path) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = ["/System/Volumes/Data", "/Volumes", "/net", "/home"]
        .into_iter()
        .map(PathBuf::from)
        .collect();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        for dir in [
            "Library/Containers",
            "Library/Group Containers",
            "Library/Daemon Containers",
            "Library/CloudStorage",
        ] {
            paths.push(home.join(dir));
        }
    }
    // An ignored root would leave the index empty, so only ignore what lies strictly below it.
    paths.retain(|p| p.starts_with(root) && p != root);
    paths
}

fn is_hidden_below(path: &Path, scope: &Path) -> bool {
    path.strip_prefix(scope).is_ok_and(|rest| {
        rest.components()
            .any(|c| matches!(c, Component::Normal(n) if n.as_bytes().first() == Some(&b'.')))
    })
}

fn build(
    root: &Path,
    ignore: &[PathBuf],
    cache_file: Option<&Path>,
    shared: &Shared,
    stop: &'static AtomicBool,
) -> Option<SearchCache> {
    if let Some(file) = cache_file {
        if let Ok(cache) =
            SearchCache::try_read_persistent_cache(root, file, &ignore.to_vec(), &Vec::new(), stop)
        {
            return Some(cache);
        }
    }
    let walk_data = WalkData::new(root, ignore, &[], false, || stop.load(Ordering::Relaxed));
    let walking = AtomicBool::new(true);
    thread::scope(|s| {
        s.spawn(|| {
            while walking.load(Ordering::Relaxed) {
                let n = walk_data.num_files.load(Ordering::Relaxed)
                    + walk_data.num_dirs.load(Ordering::Relaxed);
                shared.items.store(n as u64, Ordering::Relaxed);
                thread::sleep(Duration::from_millis(100));
            }
        });
        let cache = SearchCache::walk_fs_with_walk_data(&walk_data, stop);
        walking.store(false, Ordering::Relaxed);
        cache
    })
}

fn watch(cache: &mut SearchCache, root: &Path) -> EventWatcher {
    EventWatcher::spawn(
        root.to_string_lossy().into_owned(),
        cache.last_event_id(),
        EVENT_LATENCY,
        cache.ignore_paths(),
        cache.include_paths(),
    )
    .1
}

/// The app shows no binary files below its size limit (a NUL in the first 8 KB), so their
/// contents are not worth reading past that point.
const BINARY_SNIFF_BYTES: usize = 8192;
const CONTENT_CHUNK_BYTES: usize = 64 * 1024;

fn search(cache: &mut SearchCache, request: &Request, token: CancellationToken) -> Reply {
    let options = SearchOptions {
        case_insensitive: request.case_insensitive,
    };
    let nodes = if request.query.trim().is_empty() {
        cache.search_empty(token)
    } else {
        match cache.search_with_options(&request.query, options, token) {
            Ok(outcome) => outcome.nodes,
            Err(e) => return Reply::Error(format!("{e:#}")),
        }
    };
    let Some(mut nodes) = nodes else {
        return Reply::Cancelled;
    };
    if request.content.is_some() {
        // Drop folders using the index, without touching the disk. Not `file:`: a symlink
        // is typed File when the initial walk found it (no metadata) but Symlink when an
        // FSEvent added it, so that would match symlinks only some of the time. Whatever
        // is left is checked with fstat before it is read.
        let folders = match cache.search_with_options("folder:", options, token) {
            Ok(outcome) => outcome.nodes,
            Err(e) => return Reply::Error(format!("{e:#}")),
        };
        let Some(folders) = folders else {
            return Reply::Cancelled;
        };
        let folders: HashSet<_> = folders.into_iter().collect();
        nodes.retain(|node| !folders.contains(node));
    }
    let mut paths = Vec::new();
    for (i, node) in nodes.into_iter().enumerate() {
        if i % 4096 == 0 && token.is_cancelled().is_none() {
            return Reply::Cancelled;
        }
        let Some(path) = cache.node_path(node) else {
            continue;
        };
        if path == request.scope || !path.starts_with(&request.scope) {
            continue;
        }
        if !request.include_hidden && is_hidden_below(&path, &request.scope) {
            continue;
        }
        if request.content.is_none() && paths.len() == request.limit {
            return Reply::Hits {
                paths,
                truncated: true,
            };
        }
        paths.push(path);
    }
    // Contents are read only for what survived the name, scope and hidden filters, unlike a
    // `content:` term, which reads every file in the query's base set (hidden folders too).
    if let Some(text) = &request.content {
        let Some(matched) = filter_contents(paths, text, request, token) else {
            return Reply::Cancelled;
        };
        paths = matched;
        if paths.len() > request.limit {
            paths.truncate(request.limit);
            return Reply::Hits {
                paths,
                truncated: true,
            };
        }
    }
    Reply::Hits {
        paths,
        truncated: false,
    }
}

/// The files among `paths` (or symlinks to files) containing `text`, in order; None when cancelled.
/// Matches the bytes the way Cardinal's `content:` filter does, including its second pass
/// with the other Unicode normalization form (NFC/NFD) of the text.
fn filter_contents(
    paths: Vec<PathBuf>,
    text: &str,
    request: &Request,
    token: CancellationToken,
) -> Option<Vec<PathBuf>> {
    let fold = |s: String| {
        if request.case_insensitive {
            s.to_ascii_lowercase()
        } else {
            s
        }
    };
    let mut needles = vec![fold(text.to_owned())];
    for alt in [text.nfc().collect::<String>(), text.nfd().collect::<String>()] {
        let alt = fold(alt);
        if !needles.contains(&alt) {
            needles.push(alt);
        }
    }
    let finders: Vec<_> = needles
        .iter()
        .filter(|n| !n.is_empty())
        .map(|n| memmem::Finder::new(n.as_bytes()).into_owned())
        .collect();
    if finders.is_empty() {
        return Some(Vec::new());
    }
    let matched: Vec<PathBuf> = paths
        .into_par_iter()
        .filter(|path| {
            token.is_cancelled().is_some()
                && file_contains(path, &finders, request, token) == Some(true)
        })
        .collect();
    token.is_cancelled().map(|()| matched)
}

/// None when cancelled.
fn file_contains(
    path: &Path,
    finders: &[memmem::Finder<'static>],
    request: &Request,
    token: CancellationToken,
) -> Option<bool> {
    // Like Cardinal's `content:`, read through symlinks to files; skip pipes and sockets
    // (non-blocking, so opening a pipe can't hang the search) and folders a symlink points to.
    let Ok(mut file) = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
    else {
        return Some(false);
    };
    let Ok(meta) = file.metadata() else {
        return Some(false);
    };
    if !meta.is_file() {
        return Some(false);
    }
    #[cfg(test)]
    tests::OPENED.lock().unwrap().push(path.to_owned());
    let sniff_binary = meta.len() <= request.max_file_size;
    let overlap = finders.iter().map(|f| f.needle().len()).max().unwrap_or(1) - 1;
    thread_local! {
        static BUFFER: std::cell::RefCell<Vec<u8>> = const { std::cell::RefCell::new(Vec::new()) };
    }
    BUFFER.with_borrow_mut(|buffer| {
        buffer.resize(CONTENT_CHUNK_BYTES + overlap, 0);
        // The first read is just enough to tell binary files, which most are skipped after.
        let mut want = BINARY_SNIFF_BYTES;
        let mut carry = 0;
        loop {
            token.is_cancelled()?;
            let read = read_full(&mut file, &mut buffer[carry..carry + want]);
            if read == 0 {
                return Some(false);
            }
            let chunk = &mut buffer[..carry + read];
            if want == BINARY_SNIFF_BYTES && sniff_binary && chunk.contains(&0) {
                return Some(false);
            }
            if request.case_insensitive {
                chunk[carry..].make_ascii_lowercase();
            }
            if finders.iter().any(|f| f.find(chunk).is_some()) {
                return Some(true);
            }
            let keep = overlap.min(chunk.len());
            let len = chunk.len();
            chunk.copy_within(len - keep.., 0);
            carry = keep;
            want = CONTENT_CHUNK_BYTES;
        }
    })
}

/// Reads until `buf` is full or the file ends; a read error counts as the end.
fn read_full(file: &mut File, buf: &mut [u8]) -> usize {
    let mut filled = 0;
    while filled < buf.len() {
        match file.read(&mut buf[filled..]) {
            Ok(0) | Err(_) => break,
            Ok(n) => filled += n,
        }
    }
    filled
}

fn run(
    root: PathBuf,
    cache_file: Option<PathBuf>,
    shared: Arc<Shared>,
    stop: &'static AtomicBool,
    commands: Receiver<Command>,
) {
    let ignore = ignore_paths(&root);
    let Some(mut cache) = build(&root, &ignore, cache_file.as_deref(), &shared, stop) else {
        shared.state.store(STATE_CLOSED, Ordering::SeqCst);
        return;
    };
    shared
        .items
        .store(cache.get_total_files() as u64, Ordering::Relaxed);
    shared.state.store(STATE_READY, Ordering::SeqCst);
    let mut watcher = watch(&mut cache, &root);
    loop {
        select! {
            recv(commands) -> command => match command {
                Ok(Command::Search { request, token, reply }) => {
                    let _ = reply.send(search(&mut cache, &request, token));
                }
                Ok(Command::Save { path, reply }) => {
                    let _ = reply.send(cache.flush_snapshot_to_file(&path).is_ok());
                }
                Err(_) => break, // closed
            },
            recv(watcher) -> events => match events {
                Ok(events) => {
                    if let Err(HandleFSEError::Rescan) = cache.handle_fs_events(events) {
                        // Stop listening while rescanning (it can take a while), then resume
                        // from the rescan's event id.
                        drop(std::mem::replace(&mut watcher, EventWatcher::noop()));
                        cache.rescan();
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        shared.items.store(cache.get_total_files() as u64, Ordering::Relaxed);
                        watcher = watch(&mut cache, &root);
                    }
                }
                Err(_) => watcher = EventWatcher::noop(),
            },
        }
    }
    shared.state.store(STATE_CLOSED, Ordering::SeqCst);
}

/// Starts indexing `root` (an absolute path with symlinks resolved) on a background thread
/// and returns at once. `cache_file` (nullable) is a snapshot written by
/// `cardinal_index_save` for the same root; when it loads, the index is ready almost
/// immediately and catches up on changes since the snapshot via FSEvents.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_open(
    root: *const c_char,
    cache_file: *const c_char,
) -> *mut CardinalIndex {
    let Some(root) = (unsafe { path_arg(root) }) else {
        return ptr::null_mut();
    };
    let cache_file = unsafe { path_arg(cache_file) };
    let shared = Arc::new(Shared {
        state: AtomicU8::new(STATE_INDEXING),
        items: AtomicU64::new(0),
    });
    // SearchCache wants a 'static stop flag; one bool per index is a fine price.
    let stop: &'static AtomicBool = Box::leak(Box::new(AtomicBool::new(false)));
    let (tx, rx) = unbounded();
    let worker_shared = shared.clone();
    let (index_root, ignore) = (root.clone(), ignore_paths(&root));
    let spawned = thread::Builder::new()
        .name("cardinal-index".into())
        .spawn(move || {
            let result = catch_unwind(AssertUnwindSafe(|| {
                run(root, cache_file, worker_shared.clone(), stop, rx)
            }));
            if result.is_err() {
                worker_shared.state.store(STATE_CLOSED, Ordering::SeqCst);
            }
        });
    if spawned.is_err() {
        return ptr::null_mut();
    }
    Box::into_raw(Box::new(CardinalIndex {
        root: index_root,
        ignore,
        shared,
        commands: tx,
        stop,
    }))
}

/// 0 = indexing, 1 = ready, 2 = closed or failed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_state(index: *const CardinalIndex) -> u8 {
    unsafe { index.as_ref() }.map_or(STATE_CLOSED, |i| i.shared.state.load(Ordering::SeqCst))
}

/// Items found so far while indexing; once ready, the number of indexed items.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_item_count(index: *const CardinalIndex) -> u64 {
    unsafe { index.as_ref() }.map_or(0, |i| i.shared.items.load(Ordering::Relaxed))
}

/// Whether the index holds `path` (absolute, symlinks resolved) and everything below it: it
/// is the root or below it, and not in a folder the index skips (see `ignore_paths`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_covers(index: *const CardinalIndex, path: *const c_char) -> bool {
    let (Some(index), Some(path)) = (unsafe { index.as_ref() }, unsafe { path_arg(path) }) else {
        return false;
    };
    covers(&index.root, &index.ignore, &path)
}

fn covers(root: &Path, ignore: &[PathBuf], path: &Path) -> bool {
    path.starts_with(root) && !ignore.iter().any(|i| path.starts_with(i))
}

/// Returns a ticket for one search: pass it to `cardinal_index_search`, and to
/// `cardinal_cancel_search` to cancel that search (even before it starts).
#[unsafe(no_mangle)]
pub extern "C" fn cardinal_search_ticket() -> u64 {
    let slot = NEXT_SLOT.fetch_add(1, Ordering::Relaxed) % SLOTS;
    let version = CANCEL_SLOTS[slot as usize].fetch_add(1, Ordering::SeqCst) + 1;
    version * SLOTS + slot
}

/// Runs a Cardinal query (Everything-like syntax) and returns matches at or below `scope`,
/// excluding `scope` itself. `content` (nullable; empty = none) keeps only files (or symlinks to files)
/// containing that text; files up to `max_file_size` bytes with a NUL in their first 8 KB
/// count as binary and never match it. Blocks until the index is ready and the search
/// finishes; `cardinal_cancel_search(ticket)` from another thread makes it return `cancelled`.
/// Free the result with `cardinal_search_result_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_search(
    index: *const CardinalIndex,
    query: *const c_char,
    scope: *const c_char,
    content: *const c_char,
    case_insensitive: bool,
    include_hidden: bool,
    max_file_size: u64,
    limit: usize,
    ticket: u64,
) -> CardinalSearchResult {
    let Some(index) = (unsafe { index.as_ref() }) else {
        return CardinalSearchResult::error("No index");
    };
    if query.is_null() {
        return CardinalSearchResult::error("No query");
    }
    let query = unsafe { CStr::from_ptr(query) }.to_string_lossy().into_owned();
    let Some(scope) = (unsafe { path_arg(scope) }) else {
        return CardinalSearchResult::error("No search folder");
    };
    let content = (!content.is_null())
        .then(|| unsafe { CStr::from_ptr(content) }.to_string_lossy().into_owned())
        .filter(|c| !c.is_empty());
    let token = ticket_token(ticket);
    let (reply_tx, reply_rx) = bounded(1);
    let request = Request {
        query,
        scope,
        case_insensitive,
        include_hidden,
        content,
        max_file_size,
        limit,
    };
    let sent = index.commands.send(Command::Search {
        request,
        token,
        reply: reply_tx,
    });
    if sent.is_err() {
        return CardinalSearchResult::error("The search index is closed");
    }
    match reply_rx.recv() {
        Ok(Reply::Hits { paths, truncated }) => {
            let mut bytes = Vec::with_capacity(paths.iter().map(|p| p.as_os_str().len() + 1).sum());
            for path in &paths {
                bytes.extend_from_slice(path.as_os_str().as_bytes());
                bytes.push(0);
            }
            let (ptr, len) = if bytes.is_empty() {
                (ptr::null_mut(), 0)
            } else {
                leak(bytes)
            };
            CardinalSearchResult {
                paths: ptr,
                paths_len: len,
                count: paths.len(),
                truncated,
                ..CardinalSearchResult::empty()
            }
        }
        Ok(Reply::Cancelled) => CardinalSearchResult {
            cancelled: true,
            ..CardinalSearchResult::empty()
        },
        Ok(Reply::Error(message)) => CardinalSearchResult::error(&message),
        Err(_) => CardinalSearchResult::error("The search index is closed"),
    }
}

/// Cancels the search holding `ticket`, if it is still that slot's current search.
#[unsafe(no_mangle)]
pub extern "C" fn cardinal_cancel_search(ticket: u64) {
    let slot = &CANCEL_SLOTS[(ticket % SLOTS) as usize];
    let version = ticket / SLOTS;
    let _ = slot.compare_exchange(version, version + 1, Ordering::SeqCst, Ordering::SeqCst);
}

/// Writes a snapshot of a ready index to `path` (blocking). Returns false if the index is
/// not ready or the write failed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_save(
    index: *const CardinalIndex,
    path: *const c_char,
) -> bool {
    let (Some(index), Some(path)) = (unsafe { index.as_ref() }, unsafe { path_arg(path) }) else {
        return false;
    };
    if index.shared.state.load(Ordering::SeqCst) != STATE_READY {
        return false;
    }
    let (reply_tx, reply_rx) = bounded(1);
    if index
        .commands
        .send(Command::Save {
            path,
            reply: reply_tx,
        })
        .is_err()
    {
        return false;
    }
    reply_rx.recv().unwrap_or(false)
}

/// Stops indexing/watching and releases the index once its worker finishes. Returns at once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_index_close(index: *mut CardinalIndex) {
    if index.is_null() {
        return;
    }
    let index = unsafe { Box::from_raw(index) };
    index.stop.store(true, Ordering::Relaxed);
    // Dropping the command sender ends the worker loop.
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cardinal_search_result_free(result: CardinalSearchResult) {
    unsafe {
        free_leaked(result.paths, result.paths_len);
        if !result.error.is_null() {
            let len = CStr::from_ptr(result.error).to_bytes_with_nul().len();
            free_leaked(result.error, len);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::Mutex;
    use std::time::Instant;

    /// Every file the content scan opened (tests run in parallel, so filter by your own root).
    pub(super) static OPENED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

    fn open(root: &Path, cache: Option<&Path>) -> *mut CardinalIndex {
        let root = CString::new(root.as_os_str().as_bytes()).unwrap();
        let cache = cache.map(|c| CString::new(c.as_os_str().as_bytes()).unwrap());
        unsafe {
            cardinal_index_open(root.as_ptr(), cache.as_ref().map_or(ptr::null(), |c| c.as_ptr()))
        }
    }

    fn wait_ready(index: *mut CardinalIndex) {
        let start = Instant::now();
        while unsafe { cardinal_index_state(index) } != STATE_READY {
            assert!(start.elapsed() < Duration::from_secs(30), "index never got ready");
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn find(index: *mut CardinalIndex, query: &str, scope: &Path, hidden: bool) -> Vec<String> {
        find_text(index, query, "", scope, hidden)
    }

    fn find_text(index: *mut CardinalIndex, query: &str, text: &str, scope: &Path, hidden: bool) -> Vec<String> {
        let (q, t) = (CString::new(query).unwrap(), CString::new(text).unwrap());
        let s = CString::new(scope.as_os_str().as_bytes()).unwrap();
        let r = unsafe {
            cardinal_index_search(index, q.as_ptr(), s.as_ptr(), t.as_ptr(), true, hidden, 1000, 100, cardinal_search_ticket())
        };
        assert!(r.error.is_null(), "{:?}", unsafe { CStr::from_ptr(r.error) });
        let mut out = Vec::new();
        if !r.paths.is_null() {
            let bytes = unsafe { std::slice::from_raw_parts(r.paths as *const u8, r.paths_len) };
            for p in bytes.split(|&b| b == 0).filter(|p| !p.is_empty()) {
                let p = Path::new(std::ffi::OsStr::from_bytes(p));
                out.push(p.strip_prefix(scope).unwrap().to_string_lossy().into_owned());
            }
        }
        unsafe { cardinal_search_result_free(r) };
        out.sort();
        out
    }

    #[test]
    fn searches_scope_hidden_saves_and_follows_changes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join("docs/.hidden")).unwrap();
        std::fs::write(root.join("docs/report.pdf"), "x").unwrap();
        std::fs::write(root.join("docs/.hidden/report2.pdf"), "x").unwrap();
        std::fs::write(root.join("notes.md"), "the needle").unwrap();

        let index = open(&root, None);
        wait_ready(index);
        assert_eq!(find(index, "*.pdf", &root, false), ["docs/report.pdf"]);
        assert_eq!(
            find(index, "*.pdf", &root, true),
            ["docs/.hidden/report2.pdf", "docs/report.pdf"]
        );
        assert_eq!(find(index, "REPORT", &root.join("docs"), false), ["report.pdf"]);
        assert_eq!(find(index, "content:needle", &root, false), ["notes.md"]);
        assert_eq!(find_text(index, "", "NEEDLE", &root, false), ["notes.md"]);
        assert_eq!(find_text(index, "*.pdf", "needle", &root, false), Vec::<String>::new());

        let cache = root.join("index.zstd");
        let c = CString::new(cache.as_os_str().as_bytes()).unwrap();
        assert!(unsafe { cardinal_index_save(index, c.as_ptr()) });

        // FSEvents keeps the index current.
        std::fs::write(root.join("docs/later.pdf"), "x").unwrap();
        let start = Instant::now();
        while find(index, "later", &root, false).is_empty() {
            assert!(start.elapsed() < Duration::from_secs(20), "new file never indexed");
            thread::sleep(Duration::from_millis(100));
        }
        unsafe { cardinal_index_close(index) };

        // A snapshot for the same root loads instead of walking.
        let reloaded = open(&root, Some(&cache));
        wait_ready(reloaded);
        assert!(find(reloaded, "report", &root, false).contains(&"docs/report.pdf".to_string()));
        unsafe { cardinal_index_close(reloaded) };
    }

    /// fileCommander quotes folder paths and content text, escaping `\` and `"` with `\`.
    #[test]
    fn quoted_arguments_unescape() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join("my \"odd\" dir")).unwrap();
        std::fs::write(root.join("my \"odd\" dir/a.txt"), r#"say "hi" \o/"#).unwrap();
        std::fs::write(root.join("b.txt"), r#"say "hi" \o/"#).unwrap();
        let index = open(&root, None);
        wait_ready(index);
        assert_eq!(
            find(index, r#"content:"say \"hi\" \\o/""#, &root, false),
            ["b.txt", "my \"odd\" dir/a.txt"]
        );
        let scoped = format!(r#"in:"{}/my \"odd\" dir" *.txt"#, root.display());
        assert_eq!(find(index, &scoped, &root, false), ["my \"odd\" dir/a.txt"]);
        unsafe { cardinal_index_close(index) };
    }

    /// Content search never opens files in hidden folders unless asked to, skips small binary
    /// files, and still reads (and matches) binary files over the size limit.
    #[test]
    fn content_search_skips_hidden_folders_and_small_binaries() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::create_dir_all(root.join(".git/objects")).unwrap();
        std::fs::create_dir_all(root.join("src/.cache")).unwrap();
        std::fs::write(root.join("src/main.rs"), "// the Needle\n").unwrap();
        std::fs::write(root.join(".git/objects/pack"), "needle").unwrap();
        std::fs::write(root.join("src/.cache/blob"), "needle").unwrap();
        std::fs::write(root.join("src/small.bin"), b"needle\0needle").unwrap();
        let mut big = vec![0u8; 2000]; // over the 1000-byte limit `find_text` passes
        big.extend_from_slice(b"needle");
        std::fs::write(root.join("src/big.bin"), &big).unwrap();
        // Spans two read chunks, so the match crosses a chunk boundary.
        let mut across = vec![b'x'; CONTENT_CHUNK_BYTES - 3];
        across.extend_from_slice(b"needle");
        std::fs::write(root.join("src/across.txt"), &across).unwrap();
        std::os::unix::fs::symlink(root.join("src/main.rs"), root.join("src/link.rs")).unwrap();

        let index = open(&root, None);
        wait_ready(index);
        let opened_hidden = || {
            OPENED.lock().unwrap().iter().filter(|p| p.starts_with(&root) && is_hidden_below(p, &root)).count()
        };
        assert_eq!(
            find_text(index, "", "needle", &root, false),
            ["src/across.txt", "src/big.bin", "src/link.rs", "src/main.rs"]
        );
        assert_eq!(opened_hidden(), 0);
        assert_eq!(find_text(index, "", "needle", &root.join("src"), false), ["across.txt", "big.bin", "link.rs", "main.rs"]);
        assert_eq!(opened_hidden(), 0);
        assert_eq!(
            find_text(index, "", "needle", &root, true),
            [".git/objects/pack", "src/.cache/blob", "src/across.txt", "src/big.bin", "src/link.rs", "src/main.rs"]
        );
        assert_eq!(opened_hidden(), 2);
        assert_eq!(find_text(index, "main", "needle", &root, false), ["src/main.rs"]);
        // A symlink FSEvents adds is typed Symlink in the index (the walk typed the first one
        // File); it must match all the same.
        std::os::unix::fs::symlink(root.join("src/main.rs"), root.join("src/late.rs")).unwrap();
        let start = Instant::now();
        while !find_text(index, "late", "needle", &root, false).contains(&"src/late.rs".to_string()) {
            assert!(find(index, "late", &root, false).is_empty(), "late.rs indexed but not matched");
            assert!(start.elapsed() < Duration::from_secs(20), "late.rs never indexed");
            thread::sleep(Duration::from_millis(100));
        }
        unsafe { cardinal_index_close(index) };
    }

    #[test]
    fn broad_index_skips_other_volumes_and_cloud_storage() {
        let home = PathBuf::from(std::env::var_os("HOME").unwrap());
        let ignore = ignore_paths(Path::new("/"));
        let cloud = home.join("Library/CloudStorage");
        for skipped in [Path::new("/Volumes"), Path::new("/System/Volumes/Data"), &cloud] {
            assert!(ignore.iter().any(|i| i == skipped), "{skipped:?} not skipped");
        }
        let covered = |p: &str| covers(Path::new("/"), &ignore, Path::new(p));
        assert!(covered("/") && covered("/Applications") && covered(&home.join("Documents").to_string_lossy()));
        assert!(!covered("/Volumes/Storage/photos") && !covered(&cloud.join("OneDrive").to_string_lossy()));
        // Searching inside a skipped folder indexes it on its own, all of it.
        assert!(ignore_paths(Path::new("/Volumes/Storage")).is_empty());
        assert!(ignore_paths(&cloud.join("OneDrive")).is_empty());
    }

    #[test]
    fn cancelled_ticket_cancels_only_its_search() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::write(root.join("a.txt"), "x").unwrap();
        let index = open(&root, None);
        wait_ready(index);
        let (q, s) = (CString::new("a").unwrap(), CString::new(root.as_os_str().as_bytes()).unwrap());
        let cancelled = cardinal_search_ticket();
        let other = cardinal_search_ticket();
        cardinal_cancel_search(cancelled);
        let r = unsafe { cardinal_index_search(index, q.as_ptr(), s.as_ptr(), ptr::null(), true, false, 0, 10, cancelled) };
        assert!(r.cancelled && r.count == 0);
        unsafe { cardinal_search_result_free(r) };
        let r = unsafe { cardinal_index_search(index, q.as_ptr(), s.as_ptr(), ptr::null(), true, false, 0, 10, other) };
        assert!(!r.cancelled && r.count == 1);
        unsafe { cardinal_search_result_free(r) };
        unsafe { cardinal_index_close(index) };
    }

    #[test]
    fn bad_queries_report_errors() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let index = open(&root, None);
        wait_ready(index);
        let q = CString::new("\"unterminated").unwrap();
        let s = CString::new(root.as_os_str().as_bytes()).unwrap();
        let r = unsafe { cardinal_index_search(index, q.as_ptr(), s.as_ptr(), ptr::null(), true, false, 0, 10, cardinal_search_ticket()) };
        assert!(!r.error.is_null());
        unsafe { cardinal_search_result_free(r) };
        unsafe { cardinal_index_close(index) };
    }
}

#[cfg(test)]
mod bench {
    use super::*;
    use std::ffi::CString;
    use std::time::Instant;

    fn timed(index: *mut CardinalIndex, root: &CString, query: &str, text: &str, hidden: bool) -> (Vec<PathBuf>, Duration) {
        let (q, t) = (CString::new(query).unwrap(), CString::new(text).unwrap());
        let start = Instant::now();
        let r = unsafe {
            cardinal_index_search(index, q.as_ptr(), root.as_ptr(), t.as_ptr(), true, hidden, MAX, 1_000_000, cardinal_search_ticket())
        };
        let elapsed = start.elapsed();
        let mut out = Vec::new();
        if !r.paths.is_null() {
            let bytes = unsafe { std::slice::from_raw_parts(r.paths as *const u8, r.paths_len) };
            out = bytes.split(|&b| b == 0).filter(|p| !p.is_empty())
                .map(|p| PathBuf::from(std::ffi::OsStr::from_bytes(p))).collect();
        }
        unsafe { cardinal_search_result_free(r) };
        out.sort();
        (out, elapsed)
    }

    const MAX: u64 = 20 * 1024 * 1024;

    /// What the app keeps from a `content:` query: small binary files are dropped.
    fn app_visible(paths: Vec<PathBuf>) -> Vec<PathBuf> {
        paths.into_iter().filter(|p| {
            let len = std::fs::metadata(p).map_or(0, |m| m.len());
            len > MAX || !std::fs::read(p).is_ok_and(|d| d[..d.len().min(BINARY_SNIFF_BYTES)].contains(&0))
        }).collect()
    }

    /// `CARDINAL_BENCH_ROOT=/ CARDINAL_BENCH_QUERY=miet cargo test --release name_search -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn name_search_timing() {
        let root = PathBuf::from(std::env::var("CARDINAL_BENCH_ROOT").expect("CARDINAL_BENCH_ROOT"));
        let query = std::env::var("CARDINAL_BENCH_QUERY").expect("CARDINAL_BENCH_QUERY");
        let r = CString::new(root.as_os_str().as_bytes()).unwrap();
        let start = Instant::now();
        let index = unsafe { cardinal_index_open(r.as_ptr(), ptr::null()) };
        while unsafe { cardinal_index_state(index) } != STATE_READY {
            thread::sleep(Duration::from_millis(10));
        }
        println!("{} items indexed in {:.2?}", unsafe { cardinal_index_item_count(index) }, start.elapsed());
        for hidden in [false, true] {
            let (hits, t) = timed(index, &r, &query, "", hidden);
            println!("{query} hidden={hidden}: {} hits in {t:.2?}; first {:?}", hits.len(), &hits[..hits.len().min(3)]);
        }
        // With CARDINAL_BENCH_SNAPSHOT=<file>: save, then time a reload from the snapshot.
        if let Some(file) = std::env::var_os("CARDINAL_BENCH_SNAPSHOT") {
            let f = CString::new(file.as_bytes()).unwrap();
            let t = Instant::now();
            assert!(unsafe { cardinal_index_save(index, f.as_ptr()) });
            let size = std::fs::metadata(&file).unwrap().len();
            println!("saved {} MB in {:.2?}", size / 1_000_000, t.elapsed());
            unsafe { cardinal_index_close(index) };
            let t = Instant::now();
            let index = unsafe { cardinal_index_open(r.as_ptr(), f.as_ptr()) };
            while unsafe { cardinal_index_state(index) } != STATE_READY {
                thread::sleep(Duration::from_millis(10));
            }
            println!("reloaded {} items in {:.2?}", unsafe { cardinal_index_item_count(index) }, t.elapsed());
            let (hits, t) = timed(index, &r, &query, "", false);
            println!("{query} after reload: {} hits in {t:.2?}", hits.len());
            unsafe { cardinal_index_close(index) };
            let _ = std::fs::remove_file(&file);
            return;
        }
        unsafe { cardinal_index_close(index) };
    }

    /// Before (`content:` query term) versus after (`content` argument), same index:
    /// `CARDINAL_BENCH_ROOT=~/some/tree cargo test --release bench -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn content_search_timing() {
        let root = PathBuf::from(std::env::var("CARDINAL_BENCH_ROOT").expect("CARDINAL_BENCH_ROOT"));
        let r = CString::new(root.as_os_str().as_bytes()).unwrap();
        let index = unsafe { cardinal_index_open(r.as_ptr(), ptr::null()) };
        while unsafe { cardinal_index_state(index) } != STATE_READY {
            thread::sleep(Duration::from_millis(10));
        }
        println!("{} items", unsafe { cardinal_index_item_count(index) });
        let (all, t) = timed(index, &r, "", "", false);
        println!("listing {} paths (no content) {t:.2?}", all.len());
        for text in ["zzqx_never_found_qq", "needle", "TODO", "func"] {
            for hidden in [false, true] {
                let (old, old_t) = timed(index, &r, &format!("content:\"{text}\""), "", hidden);
                let (new, new_t) = timed(index, &r, "", text, hidden);
                let old = app_visible(old);
                assert_eq!(old, new, "{text} hidden={hidden}");
                println!("{text:>20} hidden={hidden:<5} {:>6} hits  before {old_t:>8.2?}  after {new_t:>8.2?}", new.len());
            }
        }
        unsafe { cardinal_index_close(index) };
    }
}
