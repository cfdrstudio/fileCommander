import Foundation

/// One entry from a zip's central directory.
struct ZipEntry: Sendable, Equatable {
    let path: String        // inner path without a trailing slash (and without a leading "./")
    let isDir: Bool
    let size: Int64
    let modified: Date?
    /// The name exactly as stored in the archive (tar often stores "./name"); used to extract.
    var member: String = ""
}

/// Read-only zip browsing: parses the central directory directly (fast, no extraction)
/// and extracts with the system `unzip`/`ditto` when files are actually needed.
enum ZipArchive {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Date?, [ZipEntry])] = [:]

    static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    /// Archive types One Commander can open like folders. Zip is read natively; the others
    /// through macOS's built-in `tar` (libarchive).
    static let tarSuffixes = [".tar", ".tgz", ".tar.gz", ".tbz", ".tbz2", ".tar.bz2", ".txz", ".tar.xz",
                              ".7z", ".rar", ".iso", ".cpio", ".xar"]

    static func isArchiveName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".zip") || tarSuffixes.contains { n.hasSuffix($0) }
    }

    static func isArchive(_ url: URL) -> Bool { isArchiveName(url.lastPathComponent) }

    /// Entries of an archive, cached until the file's modification date changes.
    static func entries(_ archive: URL) throws -> [ZipEntry] {
        let mtime = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let hit = lock.withLock({ cache[archive.path] }), hit.0 == mtime { return hit.1 }
        let parsed = isZip(archive)
            ? try parse(Data(contentsOf: archive, options: .alwaysMapped))
            : try listWithTar(archive)
        lock.withLock { cache[archive.path] = (mtime, parsed) }
        return parsed
    }

    /// `tar -tv` prints `ls -l`-style lines: perms links owner group size Mon DD time|year name.
    static func listWithTar(_ archive: URL) throws -> [ZipEntry] {
        let out = String(decoding: try run("/usr/bin/tar", ["-tvf", archive.path], env: utf8Env), as: UTF8.self)
        return parseTarListing(out)
    }

    static func parseTarListing(_ text: String, now: Date = Date()) -> [ZipEntry] {
        var entries: [ZipEntry] = []
        for line in text.split(separator: "\n") {
            guard let ls = LsLine(String(line), now: now) else { continue }
            var member = ls.name
            if ls.perm == "l", let arrow = member.range(of: " -> ") { member = String(member[..<arrow.lowerBound]) }
            if ls.perm == "h", let link = member.range(of: " link to ") { member = String(member[..<link.lowerBound]) }
            var path = member
            while path.hasPrefix("./") { path.removeFirst(2) }
            let isDir = ls.perm == "d" || path.hasSuffix("/")
            while path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, path != ".", !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { continue }
            if path.hasPrefix("__MACOSX/") || (path as NSString).lastPathComponent.hasPrefix("._") { continue }
            entries.append(ZipEntry(path: path, isDir: isDir, size: isDir ? 0 : ls.size, modified: ls.date, member: member))
        }
        return entries
    }

    static let utf8Env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["LC_ALL"] = "en_US.UTF-8"
        return e
    }()

    struct FormatError: LocalizedError {
        var errorDescription: String? { "Not a readable zip archive." }
    }

    static func parse(_ data: Data) throws -> [ZipEntry] {
        func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func u64(_ o: Int) -> Int { u32(o) | u32(o + 4) << 32 }

        // End of central directory: scan back over a possible comment (max 64 KB).
        let n = data.count
        guard n >= 22 else { throw FormatError() }
        var eocd = -1
        var i = n - 22
        while i >= max(0, n - 22 - 65_535) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw FormatError() }
        var count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        // Zip64: the real values live in the zip64 end record.
        if (count == 0xFFFF || offset == 0xFFFF_FFFF), eocd >= 20, u32(eocd - 20) == 0x0706_4b50 {
            let z = u64(eocd - 20 + 8)
            guard z + 56 <= n, u32(z) == 0x0606_4b50 else { throw FormatError() }
            count = u64(z + 32)
            offset = u64(z + 48)
        }

        var entries: [ZipEntry] = []
        var p = offset
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4b50 else { throw FormatError() }
            let flags = u16(p + 8)
            let time = u16(p + 12), date = u16(p + 14)
            var size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            guard p + 46 + nameLen + extraLen <= n else { throw FormatError() }
            let nameData = data.subdata(in: data.startIndex + p + 46 ..< data.startIndex + p + 46 + nameLen)
            if size == 0xFFFF_FFFF {
                // Zip64 extended info: the uncompressed size is the first field.
                var e = p + 46 + nameLen
                while e + 4 <= p + 46 + nameLen + extraLen {
                    let id = u16(e), len = u16(e + 2)
                    if id == 0x0001, len >= 8 { size = u64(e + 4); break }
                    e += 4 + len
                }
            }
            p += 46 + nameLen + extraLen + commentLen

            var name = (flags & 0x800) != 0
                ? String(decoding: nameData, as: UTF8.self)
                : (String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: dosLatin) ?? "?")
            // Skip macOS resource-fork sidecars that `ditto` and Finder add.
            if name.hasPrefix("__MACOSX/") || (name as NSString).lastPathComponent.hasPrefix("._") { continue }
            let isDir = name.hasSuffix("/")
            while name.hasSuffix("/") { name.removeLast() }
            guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { continue }
            entries.append(ZipEntry(path: name, isDir: isDir, size: Int64(isDir ? 0 : size), modified: dosDate(date, time)))
        }
        return entries
    }

    private static let dosLatin = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    private static func dosDate(_ d: Int, _ t: Int) -> Date? {
        var c = DateComponents()
        c.year = (d >> 9) + 1980
        c.month = (d >> 5) & 15
        c.day = d & 31
        c.hour = t >> 11
        c.minute = (t >> 5) & 63
        c.second = (t & 31) * 2
        return Calendar.current.date(from: c)
    }

    /// Immediate children of `inner` ("" = archive root) as file items with pseudo URLs
    /// (`/path/a.zip/inner/name`). Folders that only exist implicitly are synthesized.
    static func list(_ zip: URL, inner: String) throws -> [FileItem] {
        let prefix = inner.isEmpty ? "" : inner + "/"
        var dirNames: [String] = []
        var dirDates: [String: Date] = [:]
        var files: [FileItem] = []
        for e in try entries(zip) where e.path.hasPrefix(prefix) && e.path != inner {
            let rest = e.path.dropFirst(prefix.count)
            let parts = rest.split(separator: "/", maxSplits: 1)
            guard let first = parts.first.map(String.init) else { continue }
            if parts.count > 1 || e.isDir {
                if !dirNames.contains(first) { dirNames.append(first) }
                if e.isDir && parts.count == 1 { dirDates[first] = e.modified }
            } else {
                files.append(FileItem(url: zip.appendingPathComponent(prefix + first), name: first, isFolder: false,
                                      isHidden: first.hasPrefix("."), size: e.size, modified: e.modified, inArchive: true))
            }
        }
        let folders = dirNames.map { name in
            FileItem(url: zip.appendingPathComponent(prefix + name), name: name, isFolder: true,
                     isHidden: name.hasPrefix("."), size: nil, modified: dirDates[name], inArchive: true)
        }
        return folders + files
    }

    static func isDirectory(_ zip: URL, inner: String) -> Bool {
        guard !inner.isEmpty, let all = try? entries(zip) else { return true }
        return all.contains { $0.path == inner && $0.isDir } || all.contains { $0.path.hasPrefix(inner + "/") }
    }

    // MARK: Extraction

    struct ToolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil, env: [String: String]? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ToolError(message: msg.isEmpty ? "\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus))" : msg)
        }
        return data
    }

    /// unzip treats these as wildcards; escape them to match literal names.
    private static func literal(_ s: String) -> String {
        var out = ""
        for c in s { if "[]*?\\".contains(c) { out.append("\\") }; out.append(c) }
        return out
    }

    /// Extracts entries (files or whole folders, given as inner paths) into `dest`, each landing
    /// directly in `dest` under its own name (made unique if needed). Returns what was created.
    static func extract(_ zip: URL, inner paths: [String], to dest: URL) throws -> [URL] {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
        defer { try? fm.removeItem(at: staging) }
        if !isZip(zip) {
            // tar extracts a folder's contents when given the folder's stored name.
            let all = try entries(zip)
            var members: [String] = []
            for p in paths {
                if let e = all.first(where: { $0.path == p }) {
                    members.append(literal(e.member))
                } else if all.contains(where: { $0.path.hasPrefix(p + "/") }) {
                    // Folder implied by its contents only: name each member.
                    members += all.filter { $0.path.hasPrefix(p + "/") && !$0.isDir }.map { literal($0.member) }
                }
            }
            guard !members.isEmpty else { return [] }
            try run("/usr/bin/tar", ["-xf", zip.path, "-C", staging.path, "--"] + members, env: utf8Env)
            return try moveOut(paths, from: staging, to: dest)
        }
        // unzip fails if any pattern matches nothing, so build patterns from the real entries:
        // a folder (explicit or implied by its contents) becomes "folder/*", a file its exact name.
        let all = try entries(zip)
        var patterns: [String] = []
        for p in paths {
            if all.contains(where: { $0.path.hasPrefix(p + "/") }) {
                patterns.append(literal(p) + "/*")
            } else if all.contains(where: { $0.path == p }) {
                patterns.append(literal(p))
            }
        }
        guard !patterns.isEmpty else { return [] }
        try run("/usr/bin/unzip", ["-qq", "-o", zip.path] + patterns + ["-d", staging.path])
        // Empty folders exist only as directory entries; make sure they appear.
        for p in paths where all.contains(where: { $0.path == p && $0.isDir }) {
            try? fm.createDirectory(at: staging.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        return try moveOut(paths, from: staging, to: dest)
    }

    private static func moveOut(_ paths: [String], from staging: URL, to dest: URL) throws -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        for p in paths {
            let src = staging.appendingPathComponent(p)
            guard fm.fileExists(atPath: src.path) else { continue }
            let target = FileOps.uniqueURL(dest.appendingPathComponent((p as NSString).lastPathComponent))
            try fm.moveItem(at: src, to: target)
            created.append(target)
        }
        return created
    }

    /// Extracts a whole archive into `dest` (which must exist).
    static func extractAll(_ archive: URL, to dest: URL) throws {
        if isZip(archive) {
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, dest.path])
        } else {
            try run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path], env: utf8Env)
        }
    }

    /// Extracts one file to a per-archive temp cache (for Quick Look / opening) and returns it.
    static func extractForViewing(_ zip: URL, inner: String) throws -> URL {
        let fm = FileManager.default
        let key = String(zip.path.hashValue, radix: 36)
        let dir = fm.temporaryDirectory.appendingPathComponent("OneCommander-zip/\(key)")
        let target = dir.appendingPathComponent(inner)
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if isZip(zip) {
            try run("/usr/bin/unzip", ["-qq", "-o", zip.path, literal(inner), "-d", dir.path])
        } else {
            let member = (try entries(zip)).first { $0.path == inner }?.member ?? inner
            try run("/usr/bin/tar", ["-xf", zip.path, "-C", dir.path, "--", literal(member)], env: utf8Env)
            if member != inner, !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: dir.appendingPathComponent(member), to: target)
            }
        }
        return target
    }

    /// Creates a zip like Finder's Compress: one item → "name.zip", several → "Archive.zip".
    static func compress(_ urls: [URL]) throws -> URL {
        guard let first = urls.first else { throw ToolError(message: "Nothing to compress") }
        let parent = first.deletingLastPathComponent()
        if urls.count == 1 {
            let dest = FileOps.uniqueURL(parent.appendingPathComponent(first.lastPathComponent + ".zip"))
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, dest.path])
            return dest
        }
        let dest = FileOps.uniqueURL(parent.appendingPathComponent("Archive.zip"))
        try run("/usr/bin/zip", ["-q", "-r", "-y", dest.lastPathComponent] + urls.map(\.lastPathComponent)
                + ["-x", "*.DS_Store"], in: parent)
        return dest
    }
}

/// A location inside a zip: `/path/a.zip/sub/file` → (zip: /path/a.zip, inner: "sub/file").
struct ArchiveRef: Sendable, Equatable {
    let zip: URL
    let inner: String

    /// Recognizes pseudo paths that go "through" an existing zip file.
    static func resolve(_ url: URL) -> ArchiveRef? {
        let comps = url.standardizedFileURL.pathComponents
        var path = ""
        for (i, c) in comps.enumerated() {
            path = (path as NSString).appendingPathComponent(c)
            guard ZipArchive.isArchiveName(c) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                let inner = comps[(i + 1)...].joined(separator: "/")
                return ArchiveRef(zip: URL(fileURLWithPath: path), inner: inner)
            }
        }
        return nil
    }
}
