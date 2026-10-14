import AppKit
import Observation

// MARK: - Column

/// One Miller column: the contents of a single directory plus what's selected in it.
/// Listing happens off the main thread, so slow volumes never block the UI.
@MainActor @Observable
final class Column: Identifiable {
    let id = UUID()
    let url: URL
    /// Set when this column shows the inside of a zip (read-only).
    let archive: ArchiveRef?
    /// Set when this column shows a folder on an SFTP server.
    let remote: SFTPRef?
    /// Everything in the folder, as listed.
    private(set) var allItems: [FileItem] = []
    /// What's shown: `allItems` sorted and filtered.
    private(set) var items: [FileItem] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    var sort = SortSpec() { didSet { if sort != oldValue { rebuild() } } }
    var filter = "" { didSet { if filter != oldValue { rebuild() } } }
    private(set) var freeSpace: Int64?
    var selection: Set<String> = []
    var cursor: String?     // focused item: drives preview and the column to the right
    var anchor: String?     // start of a shift-extended range
    var showHidden: Bool
    @ObservationIgnored var onLoad: (() -> Void)?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var waiters: [(Column) -> Void] = []

    init(url: URL, showHidden: Bool, sort: SortSpec = SortSpec()) {
        self.url = url.standardizedFileURL
        self.showHidden = showHidden
        self.sort = sort
        // A zip file itself, or a pseudo path inside one.
        remote = SFTPRef.resolve(self.url)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: self.url.path, isDirectory: &isDir)
        if remote != nil {
            archive = nil
        } else if exists && !isDir.boolValue && ZipArchive.isArchive(self.url) {
            archive = ArchiveRef(zip: self.url, inner: "")
        } else if !exists {
            archive = ArchiveRef.resolve(self.url)
        } else {
            archive = nil
        }
        reload()
    }

    var isVirtual: Bool { archive != nil || remote != nil }

    private func rebuild() {
        let filtered = filter.isEmpty ? allItems : allItems.filter { filterMatches(filter, $0.name) }
        items = sort.sorted(filtered)
    }

    var cursorItem: FileItem? { items.first { $0.path == cursor } }
    var selectedItems: [FileItem] { items.filter { selection.contains($0.path) } }

    func reload(then completion: ((Column) -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        generation += 1
        let gen = generation, url = url, hidden = showHidden, archive = archive, remote = remote
        let needsWatcher = watcher == nil && archive == nil && remote == nil
        // Everything that touches the disk happens here, never on the main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            var items: [FileItem] = []
            var failure: String?
            if let remote {
                do {
                    items = try SFTPClient.list(remote, showHidden: hidden)
                } catch {
                    failure = error.localizedDescription
                }
            } else if let archive {
                do {
                    items = try ZipArchive.list(archive.zip, inner: archive.inner).filter { hidden || !$0.isHidden }
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                items = FileLister.list(url, showHidden: hidden)
            }
            let free = archive == nil && remote == nil ? FileOps.freeSpace(url) : nil
            let fd = needsWatcher ? open(url.path, O_EVTONLY) : -1
            if let self {
                await self.finishLoad(items, free: free, error: failure, generation: gen, watchFD: fd)
            } else if fd >= 0 {
                close(fd)
            }
        }
    }

    /// Runs `body` now if loaded, otherwise once the in-flight load finishes.
    func whenLoaded(_ body: @escaping (Column) -> Void) {
        if isLoading { waiters.append(body) } else { body(self) }
    }

    private func finishLoad(_ items: [FileItem], free: Int64?, error: String?, generation gen: Int, watchFD fd: Int32) {
        loadError = error
        if fd >= 0 {
            if watcher == nil {
                watcher = DirectoryWatcher(fd: fd) { [weak self] in
                    MainActor.assumeIsolated { self?.reload() }
                }
            } else {
                close(fd)
            }
        }
        guard gen == generation else { return }     // a newer reload is in flight
        apply(items, free: free)
    }

    private func apply(_ newItems: [FileItem], free: Int64?) {
        allItems = newItems
        rebuild()
        freeSpace = free
        isLoading = false
        let paths = Set(newItems.map(\.path))
        if !selection.isSubset(of: paths) { selection.formIntersection(paths) }
        if let c = cursor, !paths.contains(c) { cursor = nil }
        if let a = anchor, !paths.contains(a) { anchor = nil }
        let pending = waiters
        waiters = []
        pending.forEach { $0(self) }
        onLoad?()
    }
}

// MARK: - Pane

/// A pane is a horizontal strip of Miller columns with its own history.
@MainActor @Observable
final class Pane: Identifiable {
    let id = UUID()
    private(set) var columns: [Column] = []
    var activeColumn = 0
    enum ViewMode: String, Codable { case columns, details }

    var showHidden: Bool {
        didSet { columns.forEach { $0.showHidden = showHidden; $0.reload() } }
    }
    var sort = SortSpec() { didSet { columns.forEach { $0.sort = sort } } }
    var viewMode: ViewMode = .columns
    /// The filter field is open (it filters the active column).
    var filterEditing = false
    private var back: [URL] = []
    private var forward: [URL] = []
    @ObservationIgnored private var typeBuffer = ""
    @ObservationIgnored private var lastTyped = Date.distantPast
    @ObservationIgnored var onVisit: ((URL) -> Void)?

    init(url: URL, showHidden: Bool, onVisit: ((URL) -> Void)? = nil) {
        self.showHidden = showHidden
        self.onVisit = onVisit
        setRoot(url)
    }

    var rootURL: URL { columns[0].url }
    var current: Column { columns[min(activeColumn, columns.count - 1)] }
    var currentDirectory: URL { current.url }
    var cursorItem: FileItem? { current.cursorItem }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var title: String { FileManager.default.displayName(atPath: currentDirectory.path) }

    /// What file operations act on: the selection, or the cursor item if nothing is selected.
    var selectedItems: [FileItem] {
        let s = current.selectedItems
        if !s.isEmpty { return s }
        return cursorItem.map { [$0] } ?? []
    }

    var selectedURLs: [URL] { selectedItems.map(\.url) }

    /// True for a second after type-to-select, so Space continues a name instead of toggling preview.
    var isTyping: Bool { Date().timeIntervalSince(lastTyped) < 1 }

    private func makeColumn(_ url: URL) -> Column {
        let col = Column(url: url, showHidden: showHidden, sort: sort)
        col.onLoad = { [weak self] in self?.reconcile() }
        return col
    }

    // MARK: Navigation

    private func setRoot(_ url: URL, selecting target: URL? = nil) {
        let col = makeColumn(url)
        columns = [col]
        activeColumn = 0
        onVisit?(col.url)
        if let target {
            let path = target.standardizedFileURL.path
            col.whenLoaded { [weak self] col in
                if let item = col.items.first(where: { $0.path == path }) { self?.select(item, in: 0) }
            }
        }
    }

    /// Show `url` as the first column (or its parent, with it selected, if it's a file).
    private func show(_ url: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && !isDir.boolValue {
            setRoot(url.deletingLastPathComponent(), selecting: url)
        } else if !exists, let ref = ArchiveRef.resolve(url), !ZipArchive.isDirectory(ref.zip, inner: ref.inner) {
            setRoot(url.deletingLastPathComponent(), selecting: url)     // a file inside a zip
        } else {
            setRoot(url)
        }
    }

    /// `enteringArchive`: a zip opens as a folder instead of being selected in its parent.
    func navigate(to url: URL, enteringArchive: Bool = false) {
        let url = url.standardizedFileURL
        if url.path == rootURL.path && columns.count == 1 { return }
        back.append(rootURL)
        forward.removeAll()
        if enteringArchive && ZipArchive.isArchive(url) { setRoot(url) } else { show(url) }
    }

    func goBack() {
        guard let url = back.popLast() else { return }
        forward.append(rootURL)
        show(url)
    }

    func goForward() {
        guard let url = forward.popLast() else { return }
        back.append(rootURL)
        show(url)
    }

    /// Prepend the parent of the first column, keeping the existing columns to its right.
    var canGoUp: Bool {
        if let ref = SFTPRef.resolve(rootURL) { return ref.path != "/" }
        return rootURL.path != "/"
    }

    func goUp() {
        let root = rootURL
        guard canGoUp else { return }
        back.append(root)
        forward.removeAll()
        let parent = makeColumn(root.deletingLastPathComponent())
        parent.selection = [root.path]
        parent.cursor = root.path
        parent.anchor = root.path
        columns.insert(parent, at: 0)
        activeColumn = 0
    }

    // MARK: Selection

    /// Plain click / arrow key: select exactly this item.
    func select(_ item: FileItem, in index: Int) {
        guard columns.indices.contains(index) else { return }
        let col = columns[index]
        activeColumn = index
        col.selection = [item.path]
        col.cursor = item.path
        col.anchor = item.path
        openChild(of: index)
    }

    /// ⌘-click: add or remove one item.
    func toggle(_ item: FileItem, in index: Int) {
        guard columns.indices.contains(index) else { return }
        let col = columns[index]
        activeColumn = index
        if col.selection.contains(item.path) {
            col.selection.remove(item.path)
        } else {
            col.selection.insert(item.path)
        }
        col.cursor = item.path
        col.anchor = item.path
        openChild(of: index)
    }

    /// ⇧-click: select the range from the anchor to this item.
    func extend(to item: FileItem, in index: Int) {
        guard columns.indices.contains(index) else { return }
        let col = columns[index]
        activeColumn = index
        let anchor = col.anchor ?? col.cursor ?? item.path
        guard let a = col.items.firstIndex(where: { $0.path == anchor }),
              let b = col.items.firstIndex(where: { $0.path == item.path })
        else { select(item, in: index); return }
        col.selection = Set(col.items[min(a, b)...max(a, b)].map(\.path))
        col.anchor = anchor
        col.cursor = item.path
        openChild(of: index)
    }

    /// Shows the folder under the cursor as the next column, but only for a single selection.
    private func openChild(of index: Int) {
        let col = columns[index]
        var wanted: URL?
        if col.selection.count <= 1, let item = col.cursorItem, item.opensColumn { wanted = item.url }
        if let wanted, columns.count > index + 1, columns[index + 1].url.path == wanted.path {
            if columns.count > index + 2, columns[index + 1].cursor == nil {
                columns.removeSubrange((index + 2)...)
            }
            return
        }
        if columns.count > index + 1 { columns.removeSubrange((index + 1)...) }
        if let wanted {
            columns.append(makeColumn(wanted))
            onVisit?(wanted)
        }
    }

    /// After a reload, drop columns whose parent no longer selects them (e.g. folder deleted).
    private func reconcile() {
        for i in columns.indices.dropLast() {
            let col = columns[i]
            if col.isLoading { return }
            let next = columns[i + 1]
            let ok = col.selection.count <= 1 && col.cursorItem?.opensColumn == true && col.cursor == next.url.path
            if !ok {
                columns.removeSubrange((i + 1)...)
                activeColumn = min(activeColumn, i)
                return
            }
        }
    }

    /// Applies a selection made by the details table, keeping cursor/anchor sensible.
    func setSelection(_ paths: Set<String>, in index: Int) {
        guard columns.indices.contains(index) else { return }
        let col = columns[index]
        let added = paths.subtracting(col.selection)
        col.selection = paths
        if let new = added.first ?? (paths.contains(col.cursor ?? "") ? col.cursor : paths.first) {
            col.cursor = new
            if added.count == 1 || paths.count == 1 { col.anchor = new }
        }
        activeColumn = index
        openChild(of: index)
    }

    func activate(column index: Int) {
        guard columns.indices.contains(index) else { return }
        activeColumn = index
    }

    func moveSelection(_ delta: Int, extending: Bool = false) {
        let col = current
        guard !col.items.isEmpty else { return }
        let next: Int
        if let i = col.items.firstIndex(where: { $0.path == col.cursor }) {
            next = min(max(i + delta, 0), col.items.count - 1)
        } else {
            next = delta > 0 ? 0 : col.items.count - 1
        }
        let item = col.items[next]
        extending ? extend(to: item, in: activeColumn) : select(item, in: activeColumn)
    }

    func selectEdge(last: Bool, extending: Bool = false) {
        guard let item = last ? current.items.last : current.items.first else { return }
        extending ? extend(to: item, in: activeColumn) : select(item, in: activeColumn)
    }

    func selectAll() {
        let col = current
        col.selection = Set(col.items.map(\.path))
        if col.cursor == nil { col.cursor = col.items.first?.path }
        openChild(of: activeColumn)
    }

    func invertSelection() {
        let col = current
        col.selection = Set(col.items.map(\.path)).subtracting(col.selection)
        openChild(of: activeColumn)
    }

    /// Total Commander-style "select group": add (or remove) everything matching a wildcard.
    func selectMatching(_ pattern: String, add: Bool) {
        let col = current
        let patterns = pattern.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let matches = col.items.filter { item in patterns.contains { globMatch($0, item.name) } }.map(\.path)
        if add {
            col.selection.formUnion(matches)
            if col.cursor == nil { col.cursor = matches.first }
        } else {
            col.selection.subtract(matches)
        }
        openChild(of: activeColumn)
    }

    func moveRight() {
        let next = activeColumn + 1
        guard columns.indices.contains(next), let item = columns[next].cursorItem ?? columns[next].items.first
        else { return }
        select(item, in: next)
    }

    func moveLeft() {
        guard activeColumn > 0 else { goUp(); return }
        let idx = activeColumn - 1
        activeColumn = idx
        let child = columns[idx + 1]
        child.selection = []
        child.cursor = nil
        if columns.count > idx + 2 { columns.removeSubrange((idx + 2)...) }
    }

    /// Finder-style type-to-select within the active column.
    func typeSelect(_ chars: String) {
        let now = Date()
        if now.timeIntervalSince(lastTyped) > 1 { typeBuffer = "" }
        lastTyped = now
        typeBuffer += chars.lowercased()
        if let item = current.items.first(where: { $0.name.lowercased().hasPrefix(typeBuffer) }) {
            select(item, in: activeColumn)
        }
    }

    /// Select `urls` (all in one folder) if that folder is one of the columns, otherwise navigate there.
    func reveal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent().standardizedFileURL.path
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        if let i = columns.firstIndex(where: { $0.url.path == parent }) {
            columns[i].reload { [weak self] col in
                guard let self, let idx = self.columns.firstIndex(where: { $0 === col }) else { return }
                let found = col.items.filter { paths.contains($0.path) }
                guard let head = found.first else { return }
                self.select(head, in: idx)
                if found.count > 1 {
                    col.selection = Set(found.map(\.path))
                    self.openChild(of: idx)
                }
            }
        } else {
            navigate(to: first)
        }
    }

    func reveal(_ url: URL) { reveal([url]) }

    func refresh() { columns.forEach { $0.reload() } }
}

// MARK: - Tabs

/// One side of the window (left or right): a set of tabs, each its own pane.
@MainActor @Observable
final class PaneSide {
    var tabs: [Pane]
    var selected = 0

    init(tabs: [Pane], selected: Int = 0) {
        self.tabs = tabs
        self.selected = min(max(selected, 0), tabs.count - 1)
    }

    var current: Pane { tabs[min(selected, tabs.count - 1)] }

    func add(_ pane: Pane) {
        tabs.insert(pane, at: selected + 1)
        selected += 1
    }

    func close(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if selected > index || selected >= tabs.count { selected -= 1 }
    }

    func cycle(_ delta: Int) {
        selected = (selected + delta + tabs.count) % tabs.count
    }
}
