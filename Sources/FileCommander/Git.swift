import Foundation
import Observation
import SwiftUI

enum GitCode: String, Sendable {
    case modified = "M", added = "A", untracked = "?", renamed = "R", deleted = "D", conflict = "U"

    var color: Color {
        switch self {
        case .modified: return .orange
        case .added: return .green
        case .untracked: return .teal
        case .renamed: return .blue
        case .deleted: return .red
        case .conflict: return .red
        }
    }

    var label: String {
        switch self {
        case .modified: return "Modified"
        case .added: return "Added"
        case .untracked: return "Untracked"
        case .renamed: return "Renamed"
        case .deleted: return "Deleted"
        case .conflict: return "Conflict"
        }
    }
}

struct RepoState: Sendable, Equatable {
    let root: String
    var branch: String?
    var ahead = 0
    var behind = 0
    var files: [String: GitCode] = [:]       // absolute path → status
    var dirtyDirs: Set<String> = []          // folders containing changes (absolute)

    var changeCount: Int { files.count }

    /// Status for a row: the file's own code, or a "contains changes" mark for folders.
    func code(for path: String) -> GitCode? {
        if let c = files[path] { return c }
        return dirtyDirs.contains(path) ? .modified : nil
    }

    /// Parses `git status --porcelain=v1 -z --branch` output.
    static func parse(_ data: Data, root: String) -> RepoState {
        var state = RepoState(root: root)
        let records = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < records.count {
            let r = records[i]
            i += 1
            if r.hasPrefix("## ") {
                state.parseBranch(String(r.dropFirst(3)))
                continue
            }
            guard r.count > 3 else { continue }
            let x = r[r.startIndex], y = r[r.index(after: r.startIndex)]
            var rel = String(r.dropFirst(3))
            if x == "R" || x == "C" { i += 1 }        // the next record is the original name
            if rel.hasSuffix("/") { rel.removeLast() }  // untracked folder
            let code: GitCode
            switch (x, y) {
            case ("?", "?"): code = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): code = .conflict
            case ("A", _): code = .added
            case ("R", _), ("C", _): code = .renamed
            case ("D", _), (_, "D"): code = .deleted
            default: code = .modified
            }
            let abs = (root as NSString).appendingPathComponent(rel)
            state.files[abs] = code
            var dir = (abs as NSString).deletingLastPathComponent
            while dir.count >= root.count && dir.hasPrefix(root) {
                if !state.dirtyDirs.insert(dir).inserted { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return state
    }

    private mutating func parseBranch(_ s: String) {
        // "main...origin/main [ahead 1, behind 2]" or "No commits yet on main" or "HEAD (no branch)"
        var head = s
        if let bracket = s.range(of: " [") {
            let info = s[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if words.count == 2, let n = Int(words[1]) {
                    if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
                }
            }
            head = String(s[..<bracket.lowerBound])
        }
        if head.hasPrefix("No commits yet on ") { head = String(head.dropFirst("No commits yet on ".count)) }
        branch = head.components(separatedBy: "...").first
    }
}

/// Runs `git status` for repositories the user is looking at, at most every couple of seconds.
@MainActor @Observable
final class GitService {
    private(set) var repos: [String: RepoState] = [:]
    @ObservationIgnored private var roots: [String: String] = [:]      // dir → repo root ("" = none)
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var lastRun: [String: Date] = [:]
    @ObservationIgnored private var dirty: Set<String> = []
    nonisolated static let gitPath = "/usr/bin/git"
    static var available: Bool { FileManager.default.isExecutableFile(atPath: gitPath) }

    /// Nearest ancestor containing `.git` (a folder, or a file for worktrees/submodules).
    func root(for dir: String) -> String? {
        if let r = roots[dir] { return r.isEmpty ? nil : r }
        var p = dir
        var found: String?
        while !p.isEmpty {
            if FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".git")) { found = p; break }
            if p == "/" { break }
            p = (p as NSString).deletingLastPathComponent
        }
        roots[dir] = found ?? ""
        return found
    }

    func state(for dir: String) -> RepoState? {
        guard let r = root(for: dir) else { return nil }
        return repos[r]
    }

    func refresh(_ dir: String, force: Bool = false) {
        guard Self.available, let root = root(for: dir) else { return }
        if running.contains(root) { dirty.insert(root); return }
        if !force, let last = lastRun[root], Date().timeIntervalSince(last) < 2, repos[root] != nil { return }
        running.insert(root)
        lastRun[root] = Date()
        Task.detached(priority: .utility) { [weak self] in
            let data = try? ZipArchive.run(Self.gitPath, ["-C", root, "status", "--porcelain=v1", "-z", "--branch",
                                                         "--untracked-files=normal"])
            let state = data.map { RepoState.parse($0, root: root) }
            await self?.finished(root, state)
        }
    }

    private func finished(_ root: String, _ state: RepoState?) {
        running.remove(root)
        if let state, repos[root] != state { repos[root] = state }
        if dirty.remove(root) != nil { refresh(root, force: true) }
    }

    func invalidateAll() {
        lastRun.removeAll()
        roots.removeAll()
    }
}

/// The small coloured letter shown on a row.
struct GitBadge: View {
    let code: GitCode
    let isFolder: Bool

    var body: some View {
        Group {
            if isFolder {
                Circle().fill(code.color).frame(width: 6, height: 6)
            } else {
                Text(code.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(code.color)
            }
        }
        .help(isFolder ? "Contains changes" : code.label)
    }
}
