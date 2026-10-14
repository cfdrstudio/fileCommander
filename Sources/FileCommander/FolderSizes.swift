import Foundation
import Observation

/// Background folder-size calculator with a cache. Most recently requested folders are
/// computed first (they're what's on screen), two at a time.
@MainActor @Observable
final class FolderSizes {
    private(set) var sizes: [String: Int64] = [:]
    private(set) var computing: Set<String> = []
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private let maxConcurrent = 2

    func size(_ path: String) -> Int64? { sizes[path] }

    func request(_ urls: [URL]) {
        for url in urls {
            let path = url.standardizedFileURL.path
            guard sizes[path] == nil, !computing.contains(path) else { continue }
            queue.removeAll { $0.path == path }
            queue.append(url.standardizedFileURL)
        }
        pump()
    }

    /// Forget `path` and every ancestor, since all their totals include it.
    func invalidate(_ path: String) {
        var p = path
        while true {
            sizes[p] = nil
            if p == "/" || p.isEmpty { break }
            p = (p as NSString).deletingLastPathComponent
        }
    }

    func clear() {
        sizes.removeAll()
        queue.removeAll()
    }

    private func pump() {
        while running < maxConcurrent, let url = queue.popLast() {
            running += 1
            computing.insert(url.path)
            Task.detached(priority: .utility) { [weak self] in
                let total = FolderSizes.compute(url)
                await self?.finished(url.path, total)
            }
        }
    }

    private func finished(_ path: String, _ total: Int64) {
        running -= 1
        computing.remove(path)
        sizes[path] = total
        pump()
    }

    /// Sum of file sizes below `url` (including hidden files and package contents).
    nonisolated static func compute(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: Int64 = 0
        while let child = e.nextObject() as? URL {
            if let v = try? child.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}
