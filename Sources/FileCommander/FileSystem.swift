import AppKit
import Foundation
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isFolder: Bool      // a directory you can browse into (not a package like .app)
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    var tags: [FileTag] = []
    /// A read-only entry inside a zip (its `url` is a pseudo path through the archive).
    var inArchive = false
    /// An entry on an SFTP server (its `url` is a pseudo path `/sftp:/user@host/…`).
    var isRemote = false
    /// iCloud / cloud-provider status, for files that live in the cloud.
    var cloud: CloudState?

    var id: String { url.path }
    /// Not a real local file: inside a zip or on a server.
    var isVirtual: Bool { inArchive || isRemote }
    var path: String { url.path }

    /// A zip on disk that can be browsed like a folder.
    var isBrowsableArchive: Bool { !isFolder && !isVirtual && ZipArchive.isArchive(url) }
    /// Selecting it shows a column to its right.
    var opensColumn: Bool { isFolder || isBrowsableArchive }
    var kind: String { isFolder ? "Folder" : (url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased()) }
    var sortSize: Int64 { size ?? -1 }
    var sortDate: Date { modified ?? .distantPast }
}

/// How a column orders its items. Folders always come first, like Finder.
struct SortSpec: Equatable, Codable, Sendable {
    enum Key: String, Codable, CaseIterable, Sendable { case name = "Name", size = "Size", modified = "Date Modified", kind = "Kind" }
    var key: Key = .name
    var ascending = true

    /// `sizeOf` lets folder sizes (computed separately) take part in size sorting.
    func sorted(_ items: [FileItem], sizeOf: (FileItem) -> Int64 = { $0.sortSize }) -> [FileItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            let byName = a.name.localizedStandardCompare(b.name)
            let r: ComparisonResult
            switch key {
            case .name: r = byName
            case .size: r = sizeOf(a) == sizeOf(b) ? .orderedSame : (sizeOf(a) < sizeOf(b) ? .orderedAscending : .orderedDescending)
            case .modified: r = a.sortDate == b.sortDate ? .orderedSame : (a.sortDate < b.sortDate ? .orderedAscending : .orderedDescending)
            case .kind: r = a.kind.localizedStandardCompare(b.kind)
            }
            // Ties (e.g. folders when sorting by size) always read A→Z, whatever the direction.
            if r == .orderedSame { return byName == .orderedAscending }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
    }
}

/// Name filter: wildcards (`*.pdf`, `IMG_??`) when present, otherwise a case-insensitive substring.
func filterMatches(_ filter: String, _ name: String) -> Bool {
    let f = filter.trimmingCharacters(in: .whitespaces)
    if f.isEmpty { return true }
    if f.contains("*") || f.contains("?") { return globMatch(f, name) }
    return name.range(of: f, options: [.caseInsensitive, .diacriticInsensitive]) != nil
}

enum FileLister {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .isSymbolicLinkKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey,
    ]

    /// Blocking; call from a background task.
    static func list(_ dir: URL, showHidden: Bool) -> [FileItem] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: options)
        else { return [] }
        return urls.map(item(for:)).sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Folders macOS guards with a permission prompt. Reading even their own tags counts as
    /// access, so listing the home folder would prompt (and wait) for each one; they show no tags.
    static let privacyProtected: Set<String> = {
        let fm = FileManager.default
        return Set([FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first?.standardizedFileURL.path })
    }()

    static func item(for url: URL) -> FileItem {
        let v = try? url.resourceValues(forKeys: Set(keys))
        var isDir = v?.isDirectory ?? false
        if v?.isSymbolicLink == true {
            isDir = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        let isPackage = v?.isPackage ?? false
        return FileItem(
            url: url.standardizedFileURL,
            name: url.lastPathComponent,
            isFolder: isDir && !isPackage,
            isHidden: v?.isHidden ?? url.lastPathComponent.hasPrefix("."),
            size: isDir ? nil : v?.fileSize.map(Int64.init),
            modified: v?.contentModificationDate,
            tags: privacyProtected.contains(url.standardizedFileURL.path) ? [] : TagStore.read(url),
            cloud: isDir ? nil : CloudState(
                isUbiquitous: v?.isUbiquitousItem, status: v?.ubiquitousItemDownloadingStatus,
                downloading: v?.ubiquitousItemIsDownloading, uploading: v?.ubiquitousItemIsUploading))
    }
}

/// Synchronous icons for the handful of fixed places (sidebar, path bar).
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let img = cache[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

/// Async icons/thumbnails for file rows: images and PDFs get a real thumbnail, everything
/// else gets its Finder icon. Generated off the main thread and cached.
@MainActor
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]
    static let folder = NSWorkspace.shared.icon(for: .folder)
    static let file = NSWorkspace.shared.icon(for: .data)

    static func cached(_ path: String) -> NSImage? { cache[path] }

    static func load(_ url: URL) async -> NSImage {
        if let img = cache[url.path] { return img }
        if !FileManager.default.fileExists(atPath: url.path) {
            // An entry inside a zip: icon by file type.
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let img = NSWorkspace.shared.icon(for: type)
            cache[url.path] = img
            return img
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 32, height: 32), scale: 2, representationTypes: .all)
        request.iconMode = true
        let img: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            img = rep.nsImage
        } else {
            img = NSWorkspace.shared.icon(forFile: url.path)
        }
        if cache.count > 5000 { cache.removeAll() }
        cache[url.path] = img
        return img
    }

    static func invalidate(_ path: String) { cache[path] = nil }
}

/// Watches a directory and calls `onChange` (on the main queue) when its contents change.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    /// Takes ownership of `fd`, opened with O_EVTONLY. Open it off the main thread: for
    /// privacy-protected folders (Desktop, Downloads…) `open` blocks on the permission prompt.
    init(fd: Int32, onChange: @escaping () -> Void) {
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}

enum FileOps {
    /// "name.txt" -> "name copy.txt" -> "name copy 2.txt" ... until free.
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = n == 1 ? "\(base) copy" : "\(base) copy \(n)"
            let candidate = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let ka = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let kb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let ka, let kb else { return false }
        return ka.isEqual(kb)
    }

    static func freeSpace(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func exists(_ url: URL) -> Bool {
        // lstat semantics: a dangling symlink still "exists" as an obstacle.
        (try? url.checkResourceIsReachable()) == true
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

/// Shell-style wildcard match (`*.pdf`, `IMG_??.jpg`), case-insensitive.
func globMatch(_ pattern: String, _ name: String) -> Bool {
    fnmatch(pattern.lowercased(), name.lowercased(), 0) == 0
}

/// Subsequence fuzzy match. Returns nil when `query` isn't a subsequence of `text`.
/// Scores consecutive runs, word starts (after space/punctuation or a camelCase hump) and
/// prefix matches; when a letter appears both mid-word and at a later word start, the word
/// start is preferred as long as the rest of the query still fits after it.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased())
    let orig = Array(text)
    let t = Array(text.lowercased())
    guard t.count == orig.count else { return nil }   // case mapping changed length; skip
    func isBoundary(_ i: Int) -> Bool {
        i == 0 || " /_-.".contains(t[i - 1]) || (orig[i].isUppercase && orig[i - 1].isLowercase)
    }
    func fits(_ qi: Int, from ti: Int) -> Bool {
        var qi = qi, ti = ti
        while qi < q.count && ti < t.count {
            if q[qi] == t[ti] { qi += 1 }
            ti += 1
        }
        return qi == q.count
    }
    var score = 0, run = 0, prev = -2, ti = 0
    for qi in q.indices {
        guard var pos = (ti..<t.count).first(where: { t[$0] == q[qi] }) else { return nil }
        if pos != prev + 1 && !isBoundary(pos),
           let b = ((pos + 1)..<t.count).first(where: { t[$0] == q[qi] && isBoundary($0) }),
           fits(qi + 1, from: b + 1) {
            pos = b
        }
        run = pos == prev + 1 ? run + 1 : 1
        score += 1 + (run - 1) * 3
        if isBoundary(pos) { score += 6 }
        if pos == 0 { score += 8 }
        prev = pos
        ti = pos + 1
    }
    return score - t.count / 8
}

/// Where a cloud-backed file's content is.
enum CloudState: Sendable, Equatable {
    case notDownloaded, downloading, downloaded, uploading

    init?(isUbiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?, downloading: Bool?, uploading: Bool?) {
        guard isUbiquitous == true else { return nil }
        if downloading == true { self = .downloading; return }
        if uploading == true { self = .uploading; return }
        switch status {
        case .notDownloaded?: self = .notDownloaded
        default: self = .downloaded
        }
    }

    var symbol: String? {
        switch self {
        case .notDownloaded: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle"
        case .uploading: return "icloud.and.arrow.up"
        case .downloaded: return nil
        }
    }

    var help: String {
        switch self {
        case .notDownloaded: return "In the cloud only — opening or Download Now fetches it"
        case .downloading: return "Downloading…"
        case .uploading: return "Uploading…"
        case .downloaded: return "Downloaded"
        }
    }
}
