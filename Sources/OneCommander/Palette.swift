import SwiftUI

/// Background index of folder paths for "Go to Folder" fuzzy search.
@MainActor
enum FolderIndex {
    private static var folders: [String] = []
    private static var builtAt = Date.distantPast
    private static var building = false

    static var current: [String] { folders }

    /// Rebuilds at most once a minute: home to depth 4 plus the given roots to depth 3.
    static func refresh(roots: [URL], onUpdate: @escaping @MainActor () -> Void) {
        guard !building, Date().timeIntervalSince(builtAt) > 60 else { return }
        building = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task.detached(priority: .utility) {
            var seen = Set<String>()
            var result: [String] = []
            for (root, depth) in [(home, 4)] + roots.map({ ($0, 3) }) {
                scan(root, depth: depth, into: &result, seen: &seen)
            }
            let found = result
            await MainActor.run {
                folders = found
                builtAt = Date()
                building = false
                onUpdate()
            }
        }
    }

    nonisolated private static func scan(_ root: URL, depth: Int, into result: inout [String], seen: inout Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
        else { return }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        while let url = e.nextObject() as? URL {
            if result.count > 40000 { return }
            if e.level >= depth { e.skipDescendants() }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isDirectory == true, v?.isPackage != true, v?.isSymbolicLink != true else { continue }
            let path = url.path
            if path == library || path.hasPrefix(library + "/") { e.skipDescendants(); continue }
            if path.hasSuffix("/node_modules") || path.hasSuffix("/.git") { e.skipDescendants(); continue }
            if seen.insert(path).inserted { result.append(path) }
        }
    }
}

private struct PaletteRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let shortcut: String
    let icon: NSImage?
    let symbol: String?
    let run: () -> Void
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    let mode: PaletteMode
    @State private var query = ""
    @State private var selected = 0
    @State private var indexVersion = 0
    @FocusState private var focused: Bool

    var body: some View {
        let rows = results
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: mode == .goTo ? "folder" : "command")
                    .foregroundStyle(.secondary)
                TextField(mode == .goTo ? "Go to folder… (fuzzy, or type a path)" : "Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(rows) }
                    .onKeyPress(.downArrow) { move(1, rows.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, rows.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onChange(of: query) { selected = 0 }
            }
            .padding(12)
            Divider()
            if rows.isEmpty {
                Text(mode == .goTo && FolderIndex.current.isEmpty ? "Indexing folders…" : "No matches")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                rowView(row, highlighted: i == selected)
                                    .onTapGesture { selected = i; run(rows) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selected) { _, i in
                        if rows.indices.contains(i) { proxy.scrollTo(rows[i].id) }
                    }
                }
            }
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onAppear {
            focused = true
            if mode == .goTo {
                let roots = model.panes.map(\.rootURL)
                FolderIndex.refresh(roots: roots) { indexVersion += 1 }
            }
        }
    }

    private func rowView(_ row: PaletteRow, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon = row.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else if let symbol = row.symbol {
                Image(systemName: symbol).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.caption).foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            Text(row.shortcut).font(.callout.monospaced()).foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
        }
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func run(_ rows: [PaletteRow]) {
        guard rows.indices.contains(selected) else { return }
        let row = rows[selected]
        close()
        row.run()
    }

    private func close() { model.palette = nil }

    // MARK: Results

    private var results: [PaletteRow] {
        _ = indexVersion
        return mode == .commands ? commandRows : folderRows
    }

    private var commandRows: [PaletteRow] {
        let specs = (CommandRegistry.dynamic(model) + CommandRegistry.all).filter { $0.enabled(model) }
        let scored: [(CommandSpec, Int)] = specs.compactMap { spec in
            fuzzyScore(query, spec.title).map { (spec, $0) }
        }
        let sorted = query.isEmpty ? scored : scored.sorted { $0.1 > $1.1 }
        return sorted.prefix(60).map { spec, _ in
            PaletteRow(id: spec.id, title: spec.title, subtitle: spec.menu.rawValue, shortcut: spec.shortcutLabel,
                       icon: nil, symbol: "chevron.right.2") { [model] in spec.run(model) }
        }
    }

    private var folderRows: [PaletteRow] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func row(_ path: String) -> PaletteRow {
            PaletteRow(id: path, title: (path as NSString).lastPathComponent,
                       subtitle: path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path,
                       shortcut: "", icon: IconCache.icon(for: path), symbol: nil) { [model] in
                model.go(to: URL(fileURLWithPath: path))
            }
        }

        // Typed paths: complete against the folder's children.
        if query.hasPrefix("/") || query.hasPrefix("~") {
            let expanded = (query as NSString).expandingTildeInPath
            let parent = query.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
            let partial = query.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent
            let children = ((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? [])
                .filter { !$0.hasPrefix(".") || partial.hasPrefix(".") }
                .map { (parent as NSString).appendingPathComponent($0) }
                .filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
                .compactMap { p in fuzzyScore(partial, (p as NSString).lastPathComponent).map { (p, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            var paths = children
            if FileManager.default.fileExists(atPath: expanded) && !children.contains(expanded) {
                paths.insert(expanded, at: 0)
            }
            return paths.prefix(60).map(row)
        }

        // Fuzzy: recent folders and favorites first, then the background index.
        let places = [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/Applications"]
        var seen = Set<String>()
        var candidates: [(String, Int)] = []    // path, bonus
        let recents = model.recentFolders.filter { FileManager.default.fileExists(atPath: $0) }
        for (i, p) in recents.enumerated() where seen.insert(p).inserted {
            candidates.append((p, max(40 - i, 10)))
        }
        for p in model.favorites.map(\.path) + places where seen.insert(p).inserted { candidates.append((p, 20)) }
        for p in FolderIndex.current where seen.insert(p).inserted { candidates.append((p, 0)) }

        if query.isEmpty {
            return candidates.prefix(40).map { row($0.0) }
        }
        var scored: [(String, Int)] = []
        for (path, bonus) in candidates {
            let name = (path as NSString).lastPathComponent
            let byName = fuzzyScore(query, name).map { $0 * 2 }
            let byPath = fuzzyScore(query, path)
            guard let best = [byName, byPath].compactMap({ $0 }).max() else { continue }
            scored.append((path, best + bonus))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(60).map { row($0.0) }
    }
}
