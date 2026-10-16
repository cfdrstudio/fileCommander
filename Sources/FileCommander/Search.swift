import CCardinal
import SwiftUI

struct SearchOptions: Equatable, Sendable {
    var name = ""               // Cardinal query: substring, wildcards, ext:, size:, …; empty = any
    var text = ""               // file contents must contain this; empty = don't look inside
    var caseSensitive = false
    var includeHidden = false
    var useSpotlight = false
    var maxFileSize: Int64 = 20 * 1024 * 1024

    var isEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty && text.isEmpty }
}

struct SearchHit: Identifiable, Sendable, Equatable {
    let url: URL
    var line: Int?
    var snippet: String?
    var id: String { url.path }
}

/// In-memory file name index for one folder tree (Cardinal, in Vendor/cardinal, linked through
/// CardinalBridge). It walks the tree once, or loads a saved snapshot, then FSEvents keep it
/// current, so searches don't touch the disk.
final class CardinalIndex: @unchecked Sendable {
    let root: String
    private let handle: OpaquePointer

    enum Outcome: Sendable {
        case hits([String], truncated: Bool)
        case cancelled
        case failed(String)
    }

    /// Started from a saved snapshot (ready within moments) rather than a walk.
    let fromSnapshot: Bool

    init?(root: String, cacheFile: URL?) {
        guard let handle = cardinal_index_open(root, cacheFile?.path) else { return nil }
        self.root = root
        self.handle = handle
        fromSnapshot = cacheFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    deinit { cardinal_index_close(handle) }

    var isReady: Bool { cardinal_index_state(handle) == 1 }
    var isClosed: Bool { cardinal_index_state(handle) == 2 }
    /// Items found so far while indexing; once ready, the number of indexed items.
    var itemCount: Int { Int(cardinal_index_item_count(handle)) }

    /// Holds `path` (a real path) and everything below it.
    func covers(_ path: String) -> Bool { cardinal_index_covers(handle, path) }

    /// Blocks until the index is ready and the query has run. `scope` must be inside `root`.
    /// Non-empty `text` keeps files containing it, read after the scope and hidden filters;
    /// files up to `maxFileSize` that look binary (a NUL in the first 8 KB) never match.
    func search(_ query: String, text: String = "", scope: String, caseSensitive: Bool,
                includeHidden: Bool, maxFileSize: Int64 = 0, limit: Int, ticket: UInt64) -> Outcome {
        let r = cardinal_index_search(handle, query, scope, text, !caseSensitive, includeHidden,
                                      UInt64(max(0, maxFileSize)), limit, ticket)
        defer { cardinal_search_result_free(r) }
        if let error = r.error { return .failed(String(cString: error)) }
        if r.cancelled { return .cancelled }
        var paths: [String] = []
        paths.reserveCapacity(r.count)
        if let base = r.paths {
            var p = base
            for _ in 0..<r.count {
                let s = String(cString: p)
                paths.append(s)
                p += strlen(p) + 1
            }
        }
        return .hits(paths, truncated: r.truncated)
    }

    func save(to url: URL) -> Bool { cardinal_index_save(handle, url.path) }

    static func ticket() -> UInt64 { cardinal_search_ticket() }
    static func cancel(_ ticket: UInt64) { cardinal_cancel_search(ticket) }

    /// Cardinal's query syntax for `options`' name part, searching below `scope`. The text is
    /// passed to `search` separately: a `content:` term would read every file in the folder,
    /// hidden ones included, before the hidden filter drops them.
    static func query(_ o: SearchOptions, scope: String, indexRoot: String) -> String {
        var parts: [String] = []
        if scope != indexRoot { parts.append("in:" + quoted(scope)) }
        let name = o.name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " ")
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The app keeps one index of the whole startup disk (`broadRoot`) for its lifetime: built
/// the first time someone searches, saved as soon as it is ready, and loaded at the next launch
/// (then kept current by FSEvents), so changing folders or starting a new search never
/// re-indexes. Until it is first built, a search in a smaller folder gets a quick index of
/// just that folder. Folders the broad index skips (other volumes, cloud storage) get their
/// own index while they are being searched.
@MainActor
enum SearchIndex {
    /// nil indexes each searched folder on its own (tests use that).
    static var broadRoot: String? = "/"
    private static var broad: CardinalIndex?
    /// For folders the broad index doesn't cover, or until it is ready.
    private static var other: CardinalIndex?

    static func covering(_ folder: String) -> CardinalIndex? {
        let broad = broadIndex()
        if let broad, broad.isReady, broad.covers(folder) {
            other = nil
            return broad
        }
        if let o = other, !o.isClosed, o.covers(folder) { return o }
        // The broad index loading from its snapshot is ready in moments, and walking a
        // folder this broad would take nearly as long as the broad index itself.
        if let broad, broad.covers(folder),
           broad.fromSnapshot || folder.split(separator: "/").count < 3 { return broad }
        other = CardinalIndex(root: folder, cacheFile: nil)
        return other
    }

    /// Loads the broad index at launch if an earlier session built it.
    static func warmUp() {
        if let root = broadRoot, let file = cacheFile(for: root),
           FileManager.default.fileExists(atPath: file.path) { _ = broadIndex() }
    }

    private static func broadIndex() -> CardinalIndex? {
        if let b = broad, !b.isClosed { return b }
        guard let root = broadRoot, let file = cacheFile(for: root) else { return nil }
        let index = CardinalIndex(root: root, cacheFile: file)
        broad = index
        if let index { saveWhenReady(index, to: file) }
        return index
    }

    /// Saves a newly walked index right away, so a crash or force quit doesn't lose it.
    private static func saveWhenReady(_ index: CardinalIndex, to file: URL) {
        Task.detached(priority: .utility) {
            while !index.isReady && !index.isClosed { try? await Task.sleep(for: .seconds(1)) }
            guard index.isReady, !index.fromSnapshot else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            _ = index.save(to: file)
        }
    }

    /// Saves the broad index so the next launch skips the walk and catches up through FSEvents.
    static func saveForNextLaunch() {
        guard let b = broad, b.isReady, let file = cacheFile(for: b.root) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Only the broad index's snapshot is kept.
        for old in (try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),
                                                                 includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("index-") && old != file {
            try? FileManager.default.removeItem(at: old)
        }
        _ = b.save(to: file)
    }

    /// The real path (symlinks resolved, e.g. /tmp → /private/tmp), as FSEvents reports it.
    nonisolated static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    private static var cacheDir: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.filecommander.mac")
            .appendingPathComponent("SearchIndex")
    }

    /// One snapshot file per root (the bridge loads it only if it exists and matches).
    private static func cacheFile(for root: String) -> URL? {
        guard let dir = cacheDir else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a: stable across launches, unlike hashValue
        for byte in root.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return dir.appendingPathComponent("index-\(String(hash, radix: 16)).zstd")
    }
}

enum SearchEngine {
    /// Runs `options` against `index` below `scope` and adds the matching line for content
    /// searches. Blocking; run off the main thread.
    static func run(_ index: CardinalIndex, scope: String, _ o: SearchOptions, limit: Int,
                    ticket: UInt64) -> (hits: [SearchHit], truncated: Bool, error: String?)? {
        let query = CardinalIndex.query(o, scope: scope, indexRoot: index.root)
        switch index.search(query, text: o.text, scope: scope, caseSensitive: o.caseSensitive,
                            includeHidden: o.includeHidden, maxFileSize: o.maxFileSize,
                            limit: limit, ticket: ticket) {
        case .cancelled:
            return nil
        case .failed(let message):
            return ([], false, message)
        case .hits(let paths, let truncated):
            let sorted = paths.sorted()
            guard !o.text.isEmpty else {
                return (sorted.map { SearchHit(url: URL(fileURLWithPath: $0)) }, truncated, nil)
            }
            // The bridge matched the bytes; find the line to show, skipping binary files as before.
            var found = [SearchHit?](repeating: nil, count: sorted.count)
            found.withUnsafeMutableBufferPointer { out in
                let out = UnsafeSendableBuffer(out)
                DispatchQueue.concurrentPerform(iterations: sorted.count) { i in
                    let url = URL(fileURLWithPath: sorted[i])
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    out[i] = Int64(size) > o.maxFileSize ? SearchHit(url: url) : matchContents(url, o)
                }
            }
            return (found.compactMap { $0 }, truncated, nil)
        }
    }

    /// First matching line in a text file; binary files (a NUL in the first 8 KB) are skipped.
    static func matchContents(_ url: URL, _ o: SearchOptions) -> SearchHit? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: o.text, options: o.caseSensitive ? [] : [.caseInsensitive]) else { return nil }
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let lineNumber = text[..<r.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var snippet = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
        if snippet.count > 160 {
            // Keep the match visible in long lines.
            let matchOffset = text.distance(from: lineStart, to: r.lowerBound)
            let start = snippet.index(snippet.startIndex, offsetBy: max(0, min(matchOffset - 40, snippet.count - 160)))
            snippet = "…" + String(snippet[start...].prefix(160)) + "…"
        }
        return SearchHit(url: url, line: lineNumber, snippet: snippet)
    }
}

/// Each concurrentPerform iteration writes only its own slot.
private struct UnsafeSendableBuffer<T>: @unchecked Sendable {
    let base: UnsafeMutableBufferPointer<T>
    init(_ base: UnsafeMutableBufferPointer<T>) { self.base = base }
    subscript(i: Int) -> T {
        get { base[i] }
        nonmutating set { base[i] = newValue }
    }
}

@MainActor @Observable
final class SearchSession: Identifiable {
    let id = UUID()
    let root: URL
    var options = SearchOptions()
    private(set) var hits: [SearchHit] = []
    private(set) var running = false
    /// Building the index (first search below this folder since launch, without a snapshot).
    private(set) var indexing = false
    /// Items found while indexing, then items in the index that answered the last search.
    private(set) var indexedItems = 0
    private(set) var searched = false
    private(set) var error: String?
    /// More matches exist than `maxHits`; only the first ones are listed.
    private(set) var truncated = false
    @ObservationIgnored private var control = JobControl()
    @ObservationIgnored private var ticket: UInt64?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0

    /// A broad name in a big folder can match ~1M files; past this the list is no help anyway.
    nonisolated static let maxHits = 5_000

    init(root: URL) { self.root = root }

    /// Starts building the index while the user types.
    func prepare() {
        if !options.useSpotlight { _ = SearchIndex.covering(SearchIndex.realPath(root.path)) }
    }

    func start() {
        stop()
        guard !options.isEmpty else {
            hits = []
            truncated = false
            error = nil
            searched = false
            return
        }
        generation += 1
        running = true
        searched = true
        if options.useSpotlight { startSpotlight(); return }
        let scope = SearchIndex.realPath(root.path)
        guard let index = SearchIndex.covering(scope) else {
            hits = []
            error = "Couldn't start the search index"
            running = false
            return
        }
        let control = JobControl(), ticket = CardinalIndex.ticket()
        self.control = control
        self.ticket = ticket
        let gen = generation, o = options, me = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            while !index.isReady && !index.isClosed && !control.cancelled {
                let n = index.itemCount
                await me.value?.indexingProgress(n, gen)
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !control.cancelled else { return }
            let result = index.isClosed
                ? ([], false, "The search index stopped (is the folder still there?)")
                : SearchEngine.run(index, scope: scope, o, limit: Self.maxHits, ticket: ticket)
            let count = index.itemCount
            await me.value?.finish(result, items: count, gen)
        }
    }

    func stop() {
        control.cancelled = true
        if let t = ticket { CardinalIndex.cancel(t) }
        ticket = nil
        if let q = query { q.operationQueue?.addOperation { q.stop() } }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
        running = false
        indexing = false
    }

    private func indexingProgress(_ n: Int, _ gen: Int) {
        guard gen == generation else { return }
        indexing = true
        indexedItems = n
    }

    private func finish(_ result: (hits: [SearchHit], truncated: Bool, error: String?)?, items: Int, _ gen: Int) {
        guard gen == generation else { return }
        indexing = false
        running = false
        indexedItems = items
        guard let result else { return } // cancelled
        hits = result.hits
        truncated = result.truncated
        error = result.error
    }

    private func startSpotlight() {
        let q = NSMetadataQuery()
        var parts: [NSPredicate] = []
        let name = options.name.trimmingCharacters(in: .whitespaces)
        let flags = options.caseSensitive ? "" : "c"
        if !name.isEmpty {
            let pattern = name.contains("*") || name.contains("?") ? name : "*\(name)*"
            parts.append(NSPredicate(format: "%K LIKE[\(flags)] %@", NSMetadataItemFSNameKey, pattern))
        }
        if !options.text.isEmpty {
            parts.append(NSPredicate(format: "%K CONTAINS[\(flags)d] %@", "kMDItemTextContent", options.text))
        }
        // NSMetadataQuery rejects (throws on) an AND with a single subpredicate.
        q.predicate = parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        q.searchScopes = [root]
        // Gathering and reading results happen on a private queue: a broad query can take
        // tens of seconds and return ~1M items, which used to freeze the app on the main thread.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        q.operationQueue = queue
        let gen = generation, me = WeakRef(self), limit = Self.maxHits
        for name in [Notification.Name.NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: queue) { note in
                let finished = note.name == .NSMetadataQueryDidFinishGathering
                guard !q.isStopped, finished || q.resultCount >= limit else { return }
                q.stop()
                let count = q.resultCount
                let paths = (0..<min(count, limit)).compactMap {
                    (q.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String
                }
                let truncated = !finished || count > limit
                Task { @MainActor in me.value?.finishSpotlight(paths, truncated: truncated, gen) }
            })
        }
        query = q
        queue.addOperation { q.start() }
    }

    private func finishSpotlight(_ paths: [String], truncated: Bool, _ gen: Int) {
        guard gen == generation else { return }
        hits = paths.map { SearchHit(url: URL(fileURLWithPath: $0)) }
        self.truncated = truncated
        error = nil
        running = false
    }

    /// Searches shortly after the user stops typing; a newer change restarts the wait.
    func scheduleSearch() {
        generation += 1
        let gen = generation
        // Name searches answer in milliseconds; reading file contents or asking Spotlight
        // is worth a slightly longer pause.
        let delay = options.text.isEmpty && !options.useSpotlight ? 120 : 400
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, gen == self.generation else { return }
            self.start()
        }
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: SearchSession
    @State private var selection: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Search in “\(session.root.lastPathComponent)”").font(.headline)
                HStack {
                    TextField("Name or query (report, *.pdf, ext:png size:>1mb)", text: $session.options.name)
                        .focused($nameFocused)
                    TextField("Containing text (plain-text files)", text: $session.options.text)
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.start() }
                .onChange(of: session.options) { session.scheduleSearch() }
                HStack(spacing: 14) {
                    Toggle("Match case", isOn: $session.options.caseSensitive)
                    Toggle("Hidden files", isOn: $session.options.includeHidden)
                    Toggle("Use Spotlight (content of PDFs and documents)", isOn: $session.options.useSpotlight)
                    Spacer()
                    if session.running {
                        ProgressView().controlSize(.small)
                        Button("Stop") { session.stop() }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(14)
            Divider()
            List(session.hits, selection: $selection) { hit in
                HStack(alignment: .top, spacing: 8) {
                    Image(nsImage: IconCache.icon(for: hit.url.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.url.lastPathComponent)
                        Text(relative(hit.url)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let snippet = hit.snippet {
                            Text("\(hit.line.map { "\($0): " } ?? "")\(snippet)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .tag(hit.id)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Show in Pane") { reveal(id) }
                    Button("Open") { model.open(URL(fileURLWithPath: id)) }
                    Button("Copy Path") { model.copyPaths([URL(fileURLWithPath: id)]) }
                }
            } primaryAction: { ids in
                if let id = ids.first { reveal(id) }
            }
            .overlay {
                if !session.running && session.hits.isEmpty && session.searched && session.error == nil {
                    ContentUnavailableView.search
                }
            }
            Divider()
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open") { selection.map { model.open(URL(fileURLWithPath: $0)) } }.disabled(selection == nil)
                Button("Show in Pane") { selection.map(reveal) }.disabled(selection == nil)
                Button("Close") { session.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 560)
        .onAppear { nameFocused = true; session.prepare() }
        .onDisappear { session.stop() }
    }

    private var status: String {
        let found = session.truncated
            ? "Showing the first \(SearchSession.maxHits.formatted()) matches. Narrow the search to see the rest"
            : "\(session.hits.count) found"
        if session.truncated { return found }
        if let error = session.error { return "Query error: \(error)" }
        if session.options.useSpotlight { return session.running ? "Asking Spotlight…" : found }
        let items = session.indexedItems.formatted()
        if session.indexing { return "Indexing for fast search (only the first time)… \(items) items" }
        if session.running { return "Searching…" }
        return session.searched ? "\(found) among \(items) indexed items" : "Type a name (report, *.pdf, ext:png size:>1mb) and/or text to find"
    }

    private func relative(_ url: URL) -> String {
        // Hits carry real paths (/private/tmp, not /tmp); Spotlight's may not, so try both.
        var base = SearchIndex.realPath(session.root.path)
        let p = url.deletingLastPathComponent().path
        if !p.hasPrefix(base) { base = session.root.resolvingSymlinksInPath().path }
        if base == "/" { return p } // "." + "Users/…" would read as a hidden folder
        return p.hasPrefix(base) ? "." + p.dropFirst(base.count) : p
    }

    private func reveal(_ path: String) {
        model.active.navigate(to: URL(fileURLWithPath: path))
        session.stop()
        dismiss()
    }
}

/// Lets background callbacks reach a main-actor object without keeping it alive.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
