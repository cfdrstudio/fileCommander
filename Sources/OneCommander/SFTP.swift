import Foundation

/// A saved SFTP connection. Authentication is by SSH key / ssh-agent / ~/.ssh/config only:
/// the app never asks for or stores passwords.
struct SFTPServer: Codable, Hashable, Sendable, Identifiable {
    var user: String = ""
    var host: String
    var port: Int?
    var path: String = ""            // starting folder; "" = home
    var identityFile: String = ""    // optional private key path
    var extraOptions: [String] = []  // extra `-o` options (advanced / tests)

    var id: String { target }
    /// "user@host:port", the key used in pseudo paths.
    var target: String {
        (user.isEmpty ? "" : user + "@") + host + (port.map { ":\($0)" } ?? "")
    }
    var label: String { (user.isEmpty ? "" : user + "@") + host }
}

/// A location on a server: pseudo path `/sftp:/user@host:22/remote/path`.
struct SFTPRef: Sendable, Equatable {
    let target: String
    let path: String        // absolute remote path, "/" at minimum

    static let prefix = "/sftp:/"

    static func resolve(_ url: URL) -> SFTPRef? {
        let p = url.path
        guard p.hasPrefix(prefix) else { return nil }
        let rest = p.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let target = parts.first, !target.isEmpty else { return nil }
        let remote = parts.count > 1 ? "/" + parts[1] : "/"
        return SFTPRef(target: String(target), path: remote)
    }

    static func url(_ target: String, _ remotePath: String) -> URL {
        let clean = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath
        return URL(fileURLWithPath: prefix + target + (clean == "/" ? "" : clean))
    }

    var url: URL { Self.url(target, path) }
}

enum SFTPClient {
    /// Connection settings by target, registered when the user connects.
    nonisolated(unsafe) private static var servers: [String: SFTPServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: SFTPServer) { lock.withLock { servers[server.target] = server } }
    static func server(_ target: String) -> SFTPServer? { lock.withLock { servers[target] } }

    struct SFTPError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs an sftp batch. One SSH connection is shared between calls (ControlMaster), so
    /// browsing doesn't reconnect for every folder.
    @discardableResult
    static func batch(_ target: String, _ commands: [String]) throws -> String {
        guard let s = server(target) else { throw SFTPError(message: "Not connected to \(target).") }
        let control = FileManager.default.temporaryDirectory.appendingPathComponent("oc-ssh-%C").path
        var args = ["-b", "-", "-q",
                    "-oBatchMode=yes", "-oConnectTimeout=10",
                    "-oControlMaster=auto", "-oControlPath=\(control)", "-oControlPersist=120"]
        if let port = s.port { args += ["-P", String(port)] }
        if !s.identityFile.isEmpty { args += ["-i", (s.identityFile as NSString).expandingTildeInPath] }
        for o in s.extraOptions { args += ["-o", o] }
        args.append((s.user.isEmpty ? "" : s.user + "@") + s.host)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        p.arguments = args
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        try p.run()
        input.fileHandleForWriting.write(Data((commands.joined(separator: "\n") + "\n").utf8))
        try? input.fileHandleForWriting.close()
        // Read both pipes concurrently so a chatty stderr can't block the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            throw SFTPError(message: friendly(stderr, target: target))
        }
        return String(decoding: outData, as: UTF8.self)
    }

    /// Turns ssh's terse failures into something actionable.
    static func friendly(_ stderr: String, target: String) -> String {
        if stderr.contains("Host key verification failed") || stderr.contains("No ED25519 host key is known")
            || stderr.contains("host key is not known") {
            return "\(target)'s host key isn't known yet. Connect once with `ssh \(target)` in Terminal to verify and save it, then try again."
        }
        if stderr.contains("Permission denied") {
            return "Permission denied by \(target). One Commander signs in with SSH keys only (ssh-agent, ~/.ssh/config or the key file you chose) — passwords aren't supported."
        }
        if stderr.contains("Could not resolve hostname") { return "Can't find the server “\(target)”." }
        if stderr.contains("Connection refused") { return "\(target) refused the connection (is SSH/SFTP enabled on it?)." }
        if stderr.contains("timed out") { return "Connecting to \(target) timed out." }
        return stderr.isEmpty ? "sftp failed for \(target)." : stderr
    }

    /// Quotes a path for an sftp batch line.
    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Operations

    static func home(_ target: String) throws -> String {
        let out = try batch(target, ["pwd"])
        for line in out.split(separator: "\n") where line.hasPrefix("Remote working directory: ") {
            return String(line.dropFirst("Remote working directory: ".count))
        }
        return "/"
    }

    static func list(_ ref: SFTPRef, showHidden: Bool) throws -> [FileItem] {
        let out = try batch(ref.target, ["cd \(q(ref.path))", "ls -la"])
        return parseListing(out, ref: ref).filter { showHidden || !$0.isHidden }
    }

    /// Parses `ls -la` long-format lines from sftp.
    static func parseListing(_ text: String, ref: SFTPRef, now: Date = Date()) -> [FileItem] {
        var items: [FileItem] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("sftp>") { continue }
            guard let ls = LsLine(line, now: now) else { continue }
            var name = ls.name
            if ls.perm == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            guard name != ".", name != ".." else { continue }
            let isDir = ls.perm == "d"
            let path = (ref.path as NSString).appendingPathComponent(name)
            items.append(FileItem(url: SFTPRef.url(ref.target, path), name: name, isFolder: isDir,
                                  isHidden: name.hasPrefix("."), size: isDir ? nil : ls.size,
                                  modified: ls.date, isRemote: true))
        }
        return items
    }

    /// Downloads remote items (files or folders) into a local folder. Returns what was created.
    static func download(_ refs: [SFTPRef], to dir: URL) throws -> [URL] {
        guard let target = refs.first?.target else { return [] }
        var commands: [String] = []
        var created: [URL] = []
        for r in refs {
            let dest = FileOps.uniqueURL(dir.appendingPathComponent((r.path as NSString).lastPathComponent))
            commands.append("get -pr \(q(r.path)) \(q(dest.path))")
            created.append(dest)
        }
        try batch(target, commands)
        return created.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Uploads local items into a remote folder. Returns the remote locations.
    static func upload(_ urls: [URL], to dir: SFTPRef) throws -> [URL] {
        let commands = urls.map { "put -pr \(q($0.path)) \(q((dir.path as NSString).appendingPathComponent($0.lastPathComponent)))" }
        try batch(dir.target, commands)
        return urls.map { SFTPRef.url(dir.target, (dir.path as NSString).appendingPathComponent($0.lastPathComponent)) }
    }

    static func makeFolder(_ ref: SFTPRef) throws { try batch(ref.target, ["mkdir \(q(ref.path))"]) }

    static func rename(_ ref: SFTPRef, to newPath: String) throws {
        try batch(ref.target, ["rename \(q(ref.path)) \(q(newPath))"])
    }

    /// Deletes files and *empty* folders (sftp has no recursive delete).
    static func delete(_ refs: [SFTPRef], folders: Set<String>) throws {
        guard let target = refs.first?.target else { return }
        try batch(target, refs.map { folders.contains($0.path) ? "rmdir \(q($0.path))" : "rm \(q($0.path))" })
    }

    /// Fetches one file into a temp cache (for Quick Look / opening).
    static func fetchForViewing(_ ref: SFTPRef) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OneCommander-sftp/\(String(ref.target.hashValue, radix: 36))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((ref.path as NSString).lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try batch(ref.target, ["get -p \(q(ref.path)) \(q(dest.path))"])
        return dest
    }
}

/// One `ls -l`-style line: `perms links owner group size Mon DD HH:MM|YYYY name…`
/// (printed by sftp and by `tar -tv`).
struct LsLine {
    let perm: Character
    let size: Int64
    let date: Date?
    let name: String

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    init?(_ line: String, now: Date = Date()) {
        let f = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard f.count == 9, let perm = f[0].first, "-dlcbpsh".contains(perm), f[0].count >= 10,
              let size = Int64(f[4]), let month = Self.months.firstIndex(of: String(f[5])), let day = Int(f[6])
        else { return nil }
        var c = DateComponents()
        c.month = month + 1
        c.day = day
        if f[7].contains(":") {
            // Recent files show a time instead of a year; a date in the future means last year.
            let hm = f[7].split(separator: ":")
            c.hour = Int(hm[0]); c.minute = Int(hm[1])
            c.year = Calendar.current.component(.year, from: now)
            if let d = Calendar.current.date(from: c), d > now.addingTimeInterval(86_400) { c.year! -= 1 }
        } else {
            c.year = Int(f[7])
        }
        self.perm = perm
        self.size = size
        self.date = Calendar.current.date(from: c)
        self.name = String(f[8])
    }
}
