import Foundation
import Observation

// MARK: - Model

enum ConflictChoice: Sendable { case replace, skip, keepBoth }

struct MovePair: Sendable {
    let from: URL
    let to: URL
    var reversed: MovePair { MovePair(from: to, to: from) }
}

/// One thing to copy or move, and the folder it goes into.
struct TransferItem: Sendable {
    let source: URL
    let destinationDir: URL
}

/// What a finished job did, so it can be undone.
struct JobResult: Sendable {
    var created: [URL] = []          // new copies
    var createdDirs: [URL] = []      // destination folders we had to create (sync)
    var moved: [MovePair] = []       // source -> destination
    var replaced: [MovePair] = []    // items we trashed to make room: trash location -> original
    var errors: [String] = []
    var cancelled = false
}

@MainActor @Observable
final class FileJob: Identifiable {
    enum Kind: Sendable { case copy, move }
    enum State: Equatable { case scanning, running, paused, done, cancelled, failed(String) }

    struct Conflict: Equatable {
        let name: String
        let destination: String
    }

    let id = UUID()
    let kind: Kind
    let items: [TransferItem]
    let title: String
    var state: State = .scanning
    var totalBytes: Int64 = 0
    var doneBytes: Int64 = 0
    var totalFiles = 0
    var doneFiles = 0
    var currentName = ""
    var conflict: Conflict?
    let started = Date()
    @ObservationIgnored let control = JobControl()
    @ObservationIgnored private var continuation: CheckedContinuation<(ConflictChoice, Bool), Never>?

    init(kind: Kind, items: [TransferItem], title: String? = nil) {
        self.kind = kind
        self.items = items
        if let title {
            self.title = title
        } else {
            let verb = kind == .copy ? "Copying" : "Moving"
            let what = items.count == 1 ? "“\(items[0].source.lastPathComponent)”" : "\(items.count) items"
            let dest = items.first?.destinationDir.lastPathComponent ?? ""
            self.title = "\(verb) \(what) to “\(dest)”"
        }
    }

    var isActive: Bool { [.scanning, .running, .paused].contains(state) }
    /// No byte/file counts (zip tasks): show an indeterminate bar.
    var isIndeterminate: Bool { items.isEmpty }

    var fraction: Double {
        if totalBytes > 0 { return min(Double(doneBytes) / Double(totalBytes), 1) }
        return totalFiles > 0 ? Double(doneFiles) / Double(totalFiles) : 0
    }

    var bytesPerSecond: Double {
        let t = Date().timeIntervalSince(started)
        return t > 0.5 ? Double(doneBytes) / t : 0
    }

    func pause() { guard state == .running else { return }; control.paused = true; state = .paused }
    func resume() { guard state == .paused else { return }; control.paused = false; state = .running }

    func cancel() {
        control.cancelled = true
        control.paused = false
        if conflict != nil { resolveConflict(.skip, applyToAll: true) }
    }

    /// Called from the worker; suspends it until the user answers the conflict sheet.
    func askConflict(name: String, destination: String) async -> (ConflictChoice, Bool) {
        await withCheckedContinuation { cont in
            continuation = cont
            conflict = Conflict(name: name, destination: destination)
        }
    }

    func resolveConflict(_ choice: ConflictChoice, applyToAll: Bool) {
        conflict = nil
        continuation?.resume(returning: (choice, applyToAll))
        continuation = nil
    }
}

/// Flags shared with the background worker.
final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _paused = false

    var cancelled: Bool {
        get { lock.withLock { _cancelled } }
        set { lock.withLock { _cancelled = newValue } }
    }

    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    /// Blocks the worker thread while paused. Returns false if cancelled.
    func checkpoint() -> Bool {
        while paused && !cancelled { Thread.sleep(forTimeInterval: 0.1) }
        return !cancelled
    }
}

@MainActor @Observable
final class JobCenter {
    var jobs: [FileJob] = []

    var activeJobs: [FileJob] { jobs.filter(\.isActive) }
    var conflictJob: FileJob? { jobs.first { $0.conflict != nil } }

    var overallFraction: Double {
        let active = activeJobs
        guard !active.isEmpty else { return 1 }
        return active.map(\.fraction).reduce(0, +) / Double(active.count)
    }

    func start(_ kind: FileJob.Kind, sources: [URL], to destination: URL,
               completion: @escaping @MainActor (JobResult) -> Void) {
        start(kind, items: sources.map { TransferItem(source: $0, destinationDir: destination) },
              completion: completion)
    }

    /// `policy` pre-answers name clashes (e.g. `.replace` for folder sync) instead of asking.
    func start(_ kind: FileJob.Kind, items: [TransferItem], policy: ConflictChoice? = nil, title: String? = nil,
               completion: @escaping @MainActor (JobResult) -> Void) {
        let job = FileJob(kind: kind, items: items, title: title)
        jobs.insert(job, at: 0)
        let worker = CopyWorker(job: job, kind: kind, items: items, policy: policy)
        Task.detached(priority: .userInitiated) {
            let result = await worker.run()
            await MainActor.run {
                if result.cancelled {
                    job.state = .cancelled
                } else if let err = result.errors.first {
                    job.state = .failed(result.errors.count > 1 ? "\(err) (+\(result.errors.count - 1) more)" : err)
                } else {
                    job.state = .done
                    job.doneBytes = job.totalBytes
                    job.doneFiles = job.totalFiles
                }
                completion(result)
            }
        }
    }

    /// A job without byte progress (zip extract/compress): runs `work` off the main thread and
    /// reports the items it created so they can be revealed and undone.
    func runTask(_ title: String, _ work: @escaping @Sendable () throws -> [URL],
                 completion: @escaping @MainActor (Result<[URL], Error>) -> Void) {
        let job = FileJob(kind: .copy, items: [], title: title)
        job.state = .running
        jobs.insert(job, at: 0)
        Task.detached(priority: .userInitiated) {
            let result = Result { try work() }
            await MainActor.run {
                switch result {
                case .success: job.state = .done
                case .failure(let e): job.state = .failed(e.localizedDescription)
                }
                completion(result)
            }
        }
    }

    func clearFinished() { jobs.removeAll { !$0.isActive } }
}

// MARK: - Worker

/// Does the actual copying on a background thread using `copyfile(3)`: APFS clones when
/// possible, preserves metadata/xattrs/tags/dates, and reports byte-level progress.
final class CopyWorker: @unchecked Sendable {
    private let job: FileJob
    private let control: JobControl
    private let kind: FileJob.Kind
    private let items: [TransferItem]
    private let policy: ConflictChoice?
    private let fm = FileManager.default

    private let lock = NSLock()
    private var doneBytes: Int64 = 0
    private var doneFiles = 0
    private var lastReport = Date.distantPast

    init(job: FileJob, kind: FileJob.Kind, items: [TransferItem], policy: ConflictChoice?) {
        self.job = job
        self.control = MainActor.assumeIsolated { job.control }
        self.kind = kind
        self.items = items.map {
            TransferItem(source: $0.source.standardizedFileURL, destinationDir: $0.destinationDir.standardizedFileURL)
        }
        self.policy = policy
    }

    var isCancelled: Bool { control.cancelled }

    private func isRename(_ item: TransferItem) -> Bool {
        kind == .move && FileOps.sameVolume(item.source, item.destinationDir)
    }

    func run() async -> JobResult {
        var result = JobResult()

        // 1. Measure.
        var totalBytes: Int64 = 0, totalFiles = 0
        for item in items {
            if isRename(item) {
                totalFiles += 1     // a rename: instant
            } else {
                let (b, f) = measure(item.source)
                totalBytes += b
                totalFiles += f
            }
            if isCancelled { result.cancelled = true; return result }
        }
        await MainActor.run { [job, totalBytes, totalFiles] in
            job.totalBytes = totalBytes
            job.totalFiles = totalFiles
            if job.state == .scanning { job.state = .running }
        }

        // 2. Transfer each top-level item.
        var standing = policy
        for item in items {
            guard control.checkpoint() else { result.cancelled = true; break }
            let src = item.source
            let dir = item.destinationDir
            let sameFolder = src.deletingLastPathComponent().path == dir.path
            if kind == .move && sameFolder { continue }

            if !FileOps.exists(dir) {
                do {
                    let top = topmostMissing(dir)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if !result.createdDirs.contains(top) { result.createdDirs.append(top) }
                } catch {
                    result.errors.append("\(dir.lastPathComponent): \(error.localizedDescription)")
                    continue
                }
            }

            var target = dir.appendingPathComponent(src.lastPathComponent)
            if sameFolder {
                target = FileOps.uniqueURL(target)          // duplicate
            } else if FileOps.exists(target) {
                var choice = standing
                if choice == nil {
                    let (c, all) = await job.askConflict(name: src.lastPathComponent, destination: dir.lastPathComponent)
                    choice = c
                    if all { standing = c }
                }
                if isCancelled { result.cancelled = true; break }
                switch choice! {
                case .skip:
                    continue
                case .keepBoth:
                    target = FileOps.uniqueURL(target)
                case .replace:
                    do {
                        var trashed: NSURL?
                        try fm.trashItem(at: target, resultingItemURL: &trashed)
                        if let t = trashed as URL? { result.replaced.append(MovePair(from: t, to: target)) }
                    } catch {
                        result.errors.append(error.localizedDescription)
                        continue
                    }
                }
            }

            report(name: src.lastPathComponent, force: true)
            do {
                if kind == .move && FileOps.sameVolume(src, dir) {
                    try fm.moveItem(at: src, to: target)
                    addFiles(1)
                    result.moved.append(MovePair(from: src, to: target))
                } else {
                    try copyTree(src, to: target)
                    if kind == .move {
                        try fm.removeItem(at: src)
                        result.moved.append(MovePair(from: src, to: target))
                    } else {
                        result.created.append(target)
                    }
                }
            } catch is CancellationError {
                try? fm.removeItem(at: target)      // partial copy only; never user data
                result.cancelled = true
                break
            } catch {
                result.errors.append("\(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        report(name: "", force: true)
        return result
    }

    /// The highest ancestor of `dir` that doesn't exist yet (what creating `dir` will add).
    private func topmostMissing(_ dir: URL) -> URL {
        var top = dir
        var parent = dir.deletingLastPathComponent()
        while parent.path != "/" && !FileOps.exists(parent) {
            top = parent
            parent = parent.deletingLastPathComponent()
        }
        return top
    }

    private func measure(_ url: URL) -> (Int64, Int) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileSizeKey, .fileSizeKey]
        let v = try? url.resourceValues(forKeys: Set(keys))
        guard v?.isDirectory == true, v?.isSymbolicLink != true else {
            return (Int64(v?.fileSize ?? 0), 1)
        }
        var bytes: Int64 = 0, files = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let child = e?.nextObject() as? URL {
            if control.cancelled { break }
            let cv = try? child.resourceValues(forKeys: Set(keys))
            if cv?.isDirectory != true || cv?.isSymbolicLink == true {
                bytes += Int64(cv?.fileSize ?? 0)
                files += 1
            }
        }
        return (bytes, max(files, 1))
    }

    private func copyTree(_ src: URL, to dst: URL) throws {
        guard control.checkpoint() else { throw CancellationError() }
        let v = try? src.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if v?.isDirectory == true && v?.isSymbolicLink != true {
            try fm.createDirectory(at: dst, withIntermediateDirectories: false)
            let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [])
            for child in children {
                try copyTree(child, to: dst.appendingPathComponent(child.lastPathComponent))
            }
            copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        } else {
            try copyFile(src, to: dst)
        }
    }

    private func copyFile(_ src: URL, to dst: URL) throws {
        let box = CallbackBox(worker: self)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(progressCallback, to: UnsafeRawPointer.self))
        report(name: src.lastPathComponent)
        let rc = withExtendedLifetime(box) {
            copyfile(src.path, dst.path, state, copyfile_flags_t(COPYFILE_CLONE))
        }
        if rc != 0 {
            if isCancelled {
                try? fm.removeItem(at: dst)
                throw CancellationError()
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // Clones finish without progress callbacks; account for the remainder.
        let size = Int64((try? src.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        addBytes(max(size - box.copied, 0))
        addFiles(1)
    }

    fileprivate func addBytes(_ n: Int64) {
        lock.withLock { doneBytes += n }
        report(name: nil)
    }

    private func addFiles(_ n: Int) {
        lock.withLock { doneFiles += n }
        report(name: nil)
    }

    /// Pushes counters to the UI at most ~10×/s.
    private func report(name: String?, force: Bool = false) {
        let snapshot: (Int64, Int)? = lock.withLock {
            let now = Date()
            guard force || now.timeIntervalSince(lastReport) > 0.1 else { return nil }
            lastReport = now
            return (doneBytes, doneFiles)
        }
        guard let (bytes, files) = snapshot else { return }
        let job = job
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                job.doneBytes = bytes
                job.doneFiles = files
                if let name { job.currentName = name }
            }
        }
    }

    fileprivate func controlCheckpoint() -> Bool { control.checkpoint() }
}

private final class CallbackBox {
    let worker: CopyWorker
    var copied: Int64 = 0
    init(worker: CopyWorker) { self.worker = worker }
}

private let progressCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        box.worker.addBytes(Int64(copied) - box.copied)
        box.copied = Int64(copied)
    }
    guard box.worker.controlCheckpoint() else { return COPYFILE_QUIT }
    return COPYFILE_CONTINUE
}
