import SwiftUI
import UniformTypeIdentifiers

struct PaneView: View {
    @Environment(AppModel.self) private var model
    let side: PaneSide
    let index: Int
    var focus: FocusState<Int?>.Binding

    private var pane: Pane { side.current }
    private var isActive: Bool { model.activePane == index }

    var body: some View {
        VStack(spacing: 0) {
            TabBar(side: side, isActive: isActive, onActivate: activate)
            PathBar(pane: pane, onActivate: activate)
            if pane.filterEditing || !pane.current.filter.isEmpty {
                FilterBar(pane: pane, onDone: activate)
            }
            Divider()
            if pane.viewMode == .details {
                DetailsView(pane: pane, isActive: isActive, onActivate: activate)
                    .id(pane.current.id)
            } else {
                columns
            }
            Divider()
            statusBar
        }
        .background(model.theme.paneBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(isActive && model.dualPane ? model.theme.accent : .clear).frame(height: 2)
        }
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: index)
        .onKeyPress(phases: .down, action: handleKey)
        .onCommand(#selector(NSResponder.selectAll(_:))) { pane.selectAll() }
        .onCopyCommand {
            pane.selectedURLs.map { NSItemProvider(object: $0 as NSURL) }
        }
        .onPasteCommand(of: [.fileURL]) { providers in
            loadURLs(providers) { model.paste($0) }
        }
        .frame(minWidth: 300, maxWidth: .infinity)
    }

    private var columns: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(pane.columns.enumerated()), id: \.element.id) { i, column in
                        ColumnView(
                            column: column,
                            isActiveColumn: isActive && pane.activeColumn == i,
                            onClick: { item in click(item, column: i) },
                            onOpen: { item in
                                if item.opensColumn { pane.moveRight() } else { model.open(item.url) }
                            },
                            onActivate: { activate(); pane.activate(column: i) })
                        .frame(width: 250)
                        .id(column.id)
                        Divider()
                    }
                }
            }
            .onChange(of: pane.columns.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .trailing) }
            }
        }
        .id(pane.id)    // fresh scroll position per tab
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            let col = pane.current
            let selected = col.selectedItems
            if col.isLoading {
                ProgressView().controlSize(.mini)
                Text("Loading…")
            } else if selected.count > 1 {
                let bytes = selected.compactMap { $0.size ?? model.sizes.size($0.path) }.reduce(0, +)
                Text("\(selected.count) of \(col.items.count) selected")
                if bytes > 0 { Text("· \(FileOps.formatSize(bytes))") }
            } else {
                Text("\(col.items.count) items")
                if let item = pane.cursorItem {
                    Text("·")
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if let size = item.size { Text(FileOps.formatSize(size)) }
                }
            }
            Spacer()
            if let ref = col.remote {
                Label("SFTP · \(ref.target)", systemImage: "lock.shield")
            } else if let ref = col.archive {
                Label("Inside “\(ref.zip.lastPathComponent)” (read-only)", systemImage: "doc.zipper")
            } else if let repo = model.git.state(for: col.url.path) {
                GitSummary(repo: repo)
            }
            if let free = col.freeSpace {
                Text("\(FileOps.formatSize(free)) available")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func activate() {
        model.activePane = index
        focus.wrappedValue = index
    }

    private func click(_ item: FileItem, column i: Int) {
        activate()
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            pane.toggle(item, in: i)
        } else if flags.contains(.shift) {
            pane.extend(to: item, in: i)
        } else {
            pane.select(item, in: i)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard !model.isPrompting else { return .ignored }
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        let shift = press.modifiers.contains(.shift)
        // The details table does its own arrow keys, Return and type-select.
        if pane.viewMode == .details && press.key != .tab && press.key != .escape { return .ignored }
        switch press.key {
        case .upArrow: pane.moveSelection(-1, extending: shift)
        case .downArrow: pane.moveSelection(1, extending: shift)
        case .leftArrow: pane.moveLeft()
        case .rightArrow: pane.moveRight()
        case .pageUp: pane.moveSelection(-15, extending: shift)
        case .pageDown: pane.moveSelection(15, extending: shift)
        case .home: pane.selectEdge(last: false, extending: shift)
        case .end: pane.selectEdge(last: true, extending: shift)
        case .return: model.openSelection()
        case .escape:
            if !pane.current.filter.isEmpty {
                model.clearFilter()
            } else {
                pane.current.selection = Set(pane.cursorItem.map { [$0.path] } ?? [])
            }
        case .tab:
            guard model.dualPane else { return .ignored }
            let other = 1 - index
            model.activePane = other
            focus.wrappedValue = other
        default:
            let chars = press.characters
            guard !chars.isEmpty, press.modifiers.subtracting(.shift).isEmpty,
                  chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return .ignored }
            // Total Commander's numpad-style selection keys.
            switch chars {
            case "+": model.beginSelectMatching(add: true); return .handled
            case "-" where !pane.isTyping: model.beginSelectMatching(add: false); return .handled
            case "*": pane.invertSelection(); return .handled
            default: break
            }
            if chars == " " && !pane.isTyping {
                model.showPreview.toggle()
            } else {
                pane.typeSelect(chars)
            }
        }
        return .handled
    }
}

/// Resolves file URLs from drag/paste item providers, then calls back on the main actor.
func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(urls) }
    }
}

// MARK: - Tabs

struct TabBar: View {
    @Environment(AppModel.self) private var model
    let side: PaneSide
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(side.tabs.enumerated()), id: \.element.id) { i, tab in
                        tabButton(tab, index: i)
                    }
                }
            }
            Button {
                onActivate()
                model.newTab()
            } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ tab: Pane, index i: Int) -> some View {
        let selected = side.selected == i
        return HStack(spacing: 4) {
            Image(nsImage: IconCache.icon(for: tab.currentDirectory.path))
                .resizable().frame(width: 13, height: 13)
            Text(tab.title).lineLimit(1)
            if side.tabs.count > 1 {
                Button {
                    side.close(i)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .opacity(selected ? 0.7 : 0.35)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 170)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected && isActive ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            side.selected = i
            onActivate()
        }
        .contextMenu {
            Button("Close Tab") { side.close(i) }.disabled(side.tabs.count < 2)
            Button("Duplicate Tab") {
                side.selected = i
                onActivate()
                model.newTab()
            }
        }
    }
}

// MARK: - Column

struct ColumnView: View {
    @Environment(AppModel.self) private var model
    let column: Column
    let isActiveColumn: Bool
    let onClick: (FileItem) -> Void
    let onOpen: (FileItem) -> Void
    let onActivate: () -> Void
    @State private var dropTargeted = false

    var body: some View {
        let showSizes = model.showFolderSizes && !column.isVirtual
        let repo = column.isVirtual ? nil : model.git.state(for: column.url.path)
        let sizes = column.items.map { $0.size ?? model.sizes.size($0.path) }
        let largest = max(sizes.compactMap { $0 }.max() ?? 0, 1)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(column.items.enumerated()), id: \.element.id) { i, item in
                        FileRow(
                            item: item,
                            selected: column.selection.contains(item.path),
                            isCursor: column.cursor == item.path && column.selection.count > 1,
                            emphasized: isActiveColumn,
                            folderSize: item.isFolder ? sizes[i] : nil,
                            calculating: item.isFolder && model.sizes.computing.contains(item.path),
                            sizeFraction: showSizes ? sizes[i].map { Double($0) / Double(largest) } : nil,
                            git: repo?.code(for: item.path))
                        .id(item.path)
                        .onTapGesture(count: 2) { onOpen(item) }
                        .simultaneousGesture(TapGesture().onEnded { onClick(item) })
                        .modifier(DragOut(item: item))
                        .contextMenu { ItemMenu(column: column, item: item) }
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .modifier(DragContainer(column: column))
            }
            .overlay {
                if column.isLoading {
                    ProgressView().controlSize(.small)
                } else if let error = column.loadError {
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                } else if column.items.isEmpty {
                    Text(column.filter.isEmpty ? "Empty" : "No matches").font(.callout).foregroundStyle(.tertiary)
                }
            }
            .onChange(of: column.cursor) { _, sel in
                if let sel { proxy.scrollTo(sel) }
            }
        }
        .task(id: "\(column.allItems.count)-\(showSizes)") {
            if showSizes { model.sizes.request(column.items.filter(\.isFolder).map(\.url)) }
            if !column.isVirtual { model.git.refresh(column.url.path) }
        }
        .onChange(of: column.allItems) {
            model.sizes.invalidate(column.url.path)
            if !column.isVirtual { model.git.refresh(column.url.path) }
        }
        .frame(maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .contextMenu {
            if column.remote != nil {
                Button("New Folder") { model.beginNewFolder(in: column.url) }
                Button("Refresh") { column.reload() }
            } else if !column.isVirtual {
                columnMenu
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.transfer(urls, to: column.url)
            return true
        } isTargeted: { dropTargeted = $0 && column.archive == nil }
    }

    @ViewBuilder
    private var columnMenu: some View {
            Button("New Folder") { model.beginNewFolder(in: column.url) }
            Button("Open in Terminal") { model.openTerminal(at: column.url) }
            Button("Reveal in Finder") { model.revealInFinder([column.url]) }
            Button("Add to Favorites") { model.addFavorite(column.url) }
    }

}

/// Right-click menu for an item; acts on the whole selection if the item is part of it.
struct ItemMenu: View {
    @Environment(AppModel.self) private var model
    let column: Column
    let item: FileItem

    var body: some View {
        let urls = column.selection.contains(item.path) && column.selection.count > 1
            ? column.selectedItems.map(\.url) : [item.url]
        let many = urls.count > 1
        Button(many ? "Open \(urls.count) Items" : "Open") { urls.forEach(model.open) }
        if item.isRemote {
            if let other = model.inactive {
                Button("Download to Other Pane") { model.transfer(urls, to: other.currentDirectory, move: false) }
            }
            if !many { Button("Rename…") { model.beginRename(item.url) } }
            Button(many ? "Copy Paths" : "Copy Path") { model.copyPaths(urls) }
            Divider()
            Button(many ? "Delete \(urls.count) Items from Server…" : "Delete from Server…") { model.trash(urls) }
        } else if item.inArchive {
            // Read-only: only ways to get things out.
            if let other = model.inactive {
                Button("Extract to Other Pane") { model.transfer(urls, to: other.currentDirectory, move: false) }
            }
            if let ref = column.archive {
                Button("Extract Next to Zip") { model.transfer(urls, to: ref.zip.deletingLastPathComponent(), move: false) }
            }
            Button(many ? "Copy Paths" : "Copy Path") { model.copyPaths(urls) }
        } else {
            OpenWithMenu(urls: urls)
            Button("Quick Look") { model.quickLook() }
            Button("Reveal in Finder") { model.revealInFinder(urls) }
            let cloudItems = column.items.filter { urls.contains($0.url) }.compactMap(\.cloud)
            if cloudItems.contains(.notDownloaded) {
                Button("Download Now") { model.downloadNow(urls) }
            }
            if cloudItems.contains(.downloaded) {
                Button("Remove Download") { model.removeDownload(urls) }
            }
            Button("Get Info") { model.getInfo(urls) }
            ShareLink(items: urls) { Label("Share…", systemImage: "square.and.arrow.up") }
            if item.opensColumn && !many {
                Button("Open in New Tab") { model.activeSide.add(model.makePane(item.url)) }
            }
            if item.isFolder && !many {
                Button("Open in Terminal App") { model.openTerminal(at: item.url) }
                Button("Add to Favorites") { model.addFavorite(item.url) }
            }
            Divider()
            if many {
                Button("Rename \(urls.count) Items…") { model.sheet = .batchRename(urls) }
            } else {
                Button("Rename…") { model.beginRename(item.url) }
            }
            Button("Tags…") { model.sheet = .tags(urls) }
            Menu("Tag") {
                ForEach(FileTag.standard) { tag in
                    Button(tag.name) { model.toggleTag(tag, on: urls) }
                }
            }
            if item.isFolder {
                Button("Calculate Size") { model.sizes.request(urls) }
            }
            Button("Duplicate") { model.duplicate(urls) }
            Button(many ? "Copy Paths" : "Copy Path") { model.copyPaths(urls) }
            Button(many ? "Compress \(urls.count) Items" : "Compress “\(item.name)”") { model.compress(urls) }
            if item.isBrowsableArchive && !many {
                Button("Extract Here") { model.extractHere(item.url) }
            }
            if let other = model.inactive {
                Divider()
                Button("Copy to Other Pane") { model.transfer(urls, to: other.currentDirectory, move: false) }
                Button("Move to Other Pane") { model.transfer(urls, to: other.currentDirectory, move: true) }
            }
            Divider()
            Button(many ? "Move \(urls.count) Items to Trash" : "Move to Trash") { model.trash(urls) }
        }
    }
}

/// File icon or thumbnail, loaded off the main thread.
struct FileIcon: View {
    let item: FileItem
    var size: CGFloat = 16
    @State private var icon: NSImage?

    var body: some View {
        Image(nsImage: icon ?? Thumbnails.cached(item.path) ?? (item.isFolder ? Thumbnails.folder : Thumbnails.file))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: item.path) {
                // Folders inside a zip have no extension to pick an icon by; they're just folders.
                if item.isVirtual && item.isFolder { icon = Thumbnails.folder; return }
                if Thumbnails.cached(item.path) == nil { icon = await Thumbnails.load(item.url) }
            }
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    let item: FileItem
    let selected: Bool
    let isCursor: Bool
    let emphasized: Bool
    var folderSize: Int64?
    var calculating = false
    var sizeFraction: Double?
    var git: GitCode?
    @State private var dropTargeted = false

    var body: some View {
        let highlighted = selected && emphasized
        HStack(spacing: 6) {
            FileIcon(item: item)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.tags.isEmpty { TagDots(tags: item.tags) }
            if let git { GitBadge(code: git, isFolder: item.isFolder) }
            Spacer(minLength: 4)
            if let cloud = item.cloud, let symbol = cloud.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .opacity(0.7)
                    .help(cloud.help)
            }
            if let folderSize {
                Text(FileOps.formatSize(folderSize))
                    .font(.caption2)
                    .opacity(0.6)
            } else if calculating {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 10)
            }
            if item.isBrowsableArchive {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.5)
                    .help("Zip: browse inside")
            } else if item.isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.5)
            } else if let size = item.size {
                Text(FileOps.formatSize(size))
                    .font(.caption2)
                    .opacity(0.6)
            }
        }
        .font(.system(size: model.fontSize))
        .foregroundStyle(highlighted ? model.theme.selectionText : Color.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, model.density.rowPadding)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background(highlighted: highlighted)))
        .background(alignment: .leading) {
            // Size bar: share of the largest item in this column.
            if let f = sizeFraction, !highlighted, f > 0 {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(model.theme.accent.opacity(0.13))
                        .frame(width: max(g.size.width * f, 3))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(dropTargeted ? Color.accentColor : (isCursor ? Color.primary.opacity(0.5) : .clear),
                              lineWidth: dropTargeted ? 2 : 1))
        .opacity(item.isHidden ? 0.55 : 1)
        .contentShape(Rectangle())
        .modifier(FolderDrop(item: item, targeted: $dropTargeted))
    }

    private func background(highlighted: Bool) -> Color {
        if highlighted { return model.theme.accent }
        if selected { return Color.secondary.opacity(0.22) }
        return .clear
    }
}

/// Folders accept drops directly onto their row.
private struct FolderDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: FileItem
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if item.isFolder {
            content.dropDestination(for: URL.self) { urls, _ in
                model.transfer(urls, to: item.url)
                return true
            } isTargeted: { targeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Path bar

struct PathBar: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let onActivate: () -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", enabled: pane.canGoBack) { pane.goBack() }
            navButton("chevron.right", enabled: pane.canGoForward) { pane.goForward() }
            navButton("arrow.up", enabled: pane.canGoUp) { pane.goUp() }

            if editing {
                TextField("Path", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit(commitPath)
                    .onExitCommand { editing = false }
                    .padding(.leading, 4)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 1) {
                            ForEach(crumbs, id: \.path) { url in
                                Button {
                                    onActivate()
                                    pane.navigate(to: url)
                                } label: {
                                    HStack(spacing: 3) {
                                        if let ref = SFTPRef.resolve(url) {
                                            Image(systemName: ref.path == "/" ? "server.rack" : "folder")
                                                .frame(width: 14, height: 14)
                                            Text(ref.path == "/" ? ref.target : (ref.path as NSString).lastPathComponent)
                                        } else {
                                            Image(nsImage: IconCache.icon(for: url.path))
                                                .resizable().frame(width: 14, height: 14)
                                            Text(FileManager.default.displayName(atPath: url.path))
                                        }
                                    }
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(url.path)
                                .dropDestination(for: URL.self) { urls, _ in
                                    model.transfer(urls, to: url)
                                    return true
                                }
                                if url.path != crumbs.last?.path {
                                    Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .font(.system(size: 12))
                    }
                    .onAppear { proxy.scrollTo(crumbs.last?.path, anchor: .trailing) }
                    .onChange(of: pane.currentDirectory) { _, _ in
                        proxy.scrollTo(crumbs.last?.path, anchor: .trailing)
                    }
                }
                .padding(.leading, 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: startEditing)
            }

            navButton(editing ? "xmark" : "pencil", enabled: true) {
                editing ? (editing = false) : startEditing()
            }
            .help("Type a path")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var crumbs: [URL] {
        // On a server: the server, then its folders.
        if let ref = SFTPRef.resolve(pane.currentDirectory) {
            var result = [SFTPRef.url(ref.target, "/")]
            var path = ""
            for part in ref.path.split(separator: "/") {
                path += "/" + part
                result.append(SFTPRef.url(ref.target, path))
            }
            return result
        }
        var result: [URL] = []
        var u = pane.currentDirectory
        while true {
            result.insert(u, at: 0)
            if u.path == "/" || result.count > 64 { break }
            u = u.deletingLastPathComponent()
        }
        return result
    }

    private func startEditing() {
        text = (pane.currentDirectory.path as NSString).abbreviatingWithTildeInPath
        editing = true
        fieldFocused = true
    }

    private func commitPath() {
        let path = (text as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            pane.navigate(to: URL(fileURLWithPath: path))
            editing = false
            onActivate()
        } else {
            model.errorMessage = "No such file or folder: \(text)"
        }
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
    }
}

/// Files can be dragged out to other panes or apps, except entries inside archives or on servers.
/// On macOS 26+ rows join their column's drag container, so dragging a selected row drags the
/// whole selection; older systems drag one item.
private struct DragOut: ViewModifier {
    let item: FileItem

    func body(content: Content) -> some View {
        if item.isVirtual {
            content
        } else if #available(macOS 26, *) {
            content.draggable(containerItemID: item.path)
        } else {
            content.draggable(item.url) {
                Label(item.name, systemImage: item.isFolder ? "folder" : "doc")
            }
        }
    }
}

/// The column side of multi-item dragging (macOS 26+): resolves dragged row IDs to file URLs.
private struct DragContainer: ViewModifier {
    let column: Column

    func body(content: Content) -> some View {
        if #available(macOS 26, *), !column.isVirtual {
            content
                .dragContainer(for: URL.self, itemID: \URL.path) { ids in ids.map { URL(fileURLWithPath: $0) } }
                .dragContainerSelection(column.selectedItems.map(\.path))
        } else {
            content
        }
    }
}

// MARK: - Filter bar

/// Filters the active column as you type: substring, or wildcards like `*.pdf`.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let col = pane.current
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField("Filter “\(col.url.lastPathComponent)” (e.g. report or *.pdf)",
                      text: Binding(get: { col.filter }, set: { col.filter = $0 }))
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    // Keep the filter, go back to the list with the first match selected.
                    pane.filterEditing = false
                    if col.cursorItem == nil, let first = col.items.first,
                       let i = pane.columns.firstIndex(where: { $0 === col }) {
                        pane.select(first, in: i)
                    }
                    onDone()
                }
                .onExitCommand {
                    model.clearFilter()
                    onDone()
                }
            Text("\(col.items.count) of \(col.allItems.count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Button {
                model.clearFilter()
                onDone()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear filter (Esc)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
        .onAppear { if pane.filterEditing { focused = true } }
        .onChange(of: pane.filterEditing) { _, editing in if editing { focused = true } }
        .onChange(of: focused) { _, f in if !f { pane.filterEditing = false } }
    }
}

// MARK: - Details (list) view

/// The active folder as a sortable table: Name, Size, Date Modified, Kind.
struct DetailsView: View {
    @Environment(AppModel.self) private var model
    let pane: Pane
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        let col = pane.current
        let index = pane.columns.firstIndex { $0 === col } ?? 0
        let repo = col.isVirtual ? nil : model.git.state(for: col.url.path)
        Table(col.items, selection: Binding(
            get: { col.selection },
            set: { onActivate(); pane.setSelection($0, in: index) }
        ), sortOrder: sortOrder) {
            TableColumn("Name", value: \FileItem.name) { item in
                HStack(spacing: 6) {
                    FileIcon(item: item)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if !item.tags.isEmpty { TagDots(tags: item.tags) }
                    if let code = repo?.code(for: item.path) { GitBadge(code: code, isFolder: item.isFolder) }
                    if item.isBrowsableArchive {
                        Image(systemName: "doc.zipper").foregroundStyle(.secondary).help("Zip: double-click to browse")
                    }
                }
                .opacity(item.isHidden ? 0.55 : 1)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Size", value: \FileItem.sortSize) { item in
                Text((item.size ?? model.sizes.size(item.path)).map(FileOps.formatSize) ?? "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Date Modified", value: \FileItem.sortDate) { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Kind", value: \FileItem.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let item = col.items.first(where: { $0.path == id }) {
                ItemMenu(column: col, item: item)
            }
        } primaryAction: { ids in
            guard ids.count == 1, let item = col.items.first(where: { ids.contains($0.path) }) else {
                ids.forEach { model.open(URL(fileURLWithPath: $0)) }
                return
            }
            if item.opensColumn { pane.navigate(to: item.url, enteringArchive: true) } else { model.open(item.url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.transfer(urls, to: col.url)
            return true
        }
        .overlay {
            if col.isLoading {
                ProgressView()
            } else if col.items.isEmpty {
                Text(col.filter.isEmpty ? "Empty" : "No matches").foregroundStyle(.tertiary)
            }
        }
        .task(id: col.allItems.count) {
            if !col.isVirtual { model.git.refresh(col.url.path) }
        }
    }

    /// Table header clicks ↔ the pane's sort (which the column view uses too).
    private var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: {
                let order: SortOrder = pane.sort.ascending ? .forward : .reverse
                switch pane.sort.key {
                case .name: return [KeyPathComparator(\FileItem.name, order: order)]
                case .size: return [KeyPathComparator(\FileItem.sortSize, order: order)]
                case .modified: return [KeyPathComparator(\FileItem.sortDate, order: order)]
                case .kind: return [KeyPathComparator(\FileItem.kind, order: order)]
                }
            },
            set: { comparators in
                guard let c = comparators.first else { return }
                let key: SortSpec.Key
                switch c.keyPath {
                case \FileItem.sortSize: key = .size
                case \FileItem.sortDate: key = .modified
                case \FileItem.kind: key = .kind
                default: key = .name
                }
                pane.sort = SortSpec(key: key, ascending: c.order == .forward)
            })
    }
}

/// "⎇ main ↑1 · 3 changes" for the status bar.
struct GitSummary: View {
    let repo: RepoState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
            Text(repo.branch ?? "detached")
            if repo.ahead > 0 { Text("↑\(repo.ahead)") }
            if repo.behind > 0 { Text("↓\(repo.behind)") }
            if repo.changeCount > 0 {
                Text("· \(repo.changeCount) change\(repo.changeCount == 1 ? "" : "s")").foregroundStyle(.orange)
            }
        }
        .help("Git repository: \(repo.root)")
    }
}
