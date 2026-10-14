import AppKit
import Observation

/// A reversible file-system change. Performing one returns its inverse, which gives redo for free.
struct TagChange: Sendable {
    let url: URL
    let old: [FileTag]
    let new: [FileTag]
}

indirect enum FileAction: Sendable {
    case move([MovePair])
    /// Renames that may swap or chain names (a→b, b→a), done via temporary names.
    case renameBatch([MovePair])
    case trash([URL])
    case setTags([TagChange])
    case group([FileAction])

    /// Blocking; call off the main thread.
    func perform() throws -> FileAction {
        let fm = FileManager.default
        switch self {
        case .move(let pairs):
            var done: [MovePair] = []
            for p in pairs {
                if FileOps.exists(p.to) {
                    throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: p.to.path])
                }
                try fm.moveItem(at: p.from, to: p.to)
                done.append(p)
            }
            return .move(done.reversed().map(\.reversed))
        case .renameBatch(let pairs):
            // Phase 1: everything to a unique temporary name; phase 2: temp to final.
            var temps: [(MovePair, URL)] = []
            do {
                for p in pairs {
                    let tmp = p.from.deletingLastPathComponent()
                        .appendingPathComponent(".oc-rename-\(UUID().uuidString)")
                    try fm.moveItem(at: p.from, to: tmp)
                    temps.append((p, tmp))
                }
                for (p, tmp) in temps {
                    if FileOps.exists(p.to) {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: p.to.path])
                    }
                    try fm.moveItem(at: tmp, to: p.to)
                }
            } catch {
                // Put anything still under a temporary name back where it came from.
                for (p, tmp) in temps where FileOps.exists(tmp) { try? fm.moveItem(at: tmp, to: p.from) }
                throw error
            }
            return .renameBatch(pairs.map(\.reversed))
        case .setTags(let changes):
            for c in changes { try TagStore.write(c.new, to: c.url) }
            return .setTags(changes.map { TagChange(url: $0.url, old: $0.new, new: $0.old) })
        case .trash(let urls):
            var pairs: [MovePair] = []
            for u in urls where FileOps.exists(u) {
                var trashed: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &trashed)
                if let t = trashed as URL? { pairs.append(MovePair(from: t, to: u)) }
            }
            return .move(pairs)
        case .group(let actions):
            var inverses: [FileAction] = []
            for a in actions { inverses.append(try a.perform()) }
            return .group(inverses.reversed())
        }
    }

    /// Every path this action touches, for revealing the result.
    var targets: [URL] {
        switch self {
        case .move(let pairs), .renameBatch(let pairs): return pairs.map(\.to)
        case .setTags(let changes): return changes.map(\.url)
        case .trash: return []
        case .group(let actions): return actions.flatMap(\.targets)
        }
    }
}

struct UndoEntry {
    let name: String
    let action: FileAction
}

struct Workspace: Codable, Identifiable, Equatable {
    var name: String
    var left: [String]
    var right: [String]
    var leftSelected: Int
    var rightSelected: Int
    var dualPane: Bool
    var id: String { name }
}

enum PaletteMode { case commands, goTo }

enum Sheet: Identifiable {
    case batchRename([URL])
    case tags([URL])
    case tagResults(FileTag)
    case compare(CompareSession)
    case search(SearchSession)
    case connect
    case info([URL])

    var id: String {
        switch self {
        case .connect: return "connect"
        case .info: return "info"
        case .search(let s): return "search-\(s.id)"
        case .batchRename: return "rename"
        case .tags: return "tags"
        case .tagResults(let t): return "tag-\(t.name)"
        case .compare(let c): return "compare-\(c.id)"
        }
    }
}

@MainActor @Observable
final class AppModel {
    enum Prompt { case rename(URL), newFolder(URL), selectMatching(add: Bool), saveWorkspace }

    var sides: [PaneSide] = []
    var activePane = 0
    var dualPane = true { didSet { if !dualPane { activePane = 0 } } }
    var showPreview = true
    var showHidden = false {
        didSet { sides.flatMap(\.tabs).forEach { $0.showHidden = showHidden } }
    }
    var favorites: [URL] { didSet { defaults.set(favorites.map(\.path), forKey: "favorites") } }
    private(set) var recentFolders: [String]
    var workspaces: [Workspace] { didSet { saveWorkspaces() } }
    var errorMessage: String?
    /// Items waiting for "Delete from server permanently?" confirmation.
    var confirmRemoteDelete: [URL]?
    var prompt: Prompt?
    var promptText = ""
    var palette: PaletteMode?
    var sheet: Sheet?
    var showFolderSizes: Bool {
        didSet { defaults.set(showFolderSizes, forKey: "showFolderSizes"); if !showFolderSizes { sizes.clear() } }
    }
    private(set) var knownTags: [FileTag]
    let jobs = JobCenter()
    let sizes = FolderSizes()
    let git = GitService()

    // Appearance
    var themeID: String { didSet { defaults.set(themeID, forKey: "theme"); applyTheme() } }
    var density: Density { didSet { defaults.set(density.rawValue, forKey: "density") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize"); applyTheme() } }
    var theme: Theme {
        var t = Theme.named(themeID)
        t.terminalFontSize = terminalFontSize
        return t
    }

    // Terminal panel
    var showTerminal = false
    var terminalSync: Bool { didSet { defaults.set(terminalSync, forKey: "terminalSync") } }
    private(set) var terminalTitle = ""
    @ObservationIgnored private var terminalController: TerminalController?
    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        if Bundle.main.bundleIdentifier == "local.filecommander.mac" {
            Self.migrateSettings(from: defaults.persistentDomain(forName: "local.onecommander.mac"), to: defaults)
        }
        favorites = (defaults.stringArray(forKey: "favorites") ?? []).map { URL(fileURLWithPath: $0) }
        recentFolders = defaults.stringArray(forKey: "recentFolders") ?? []
        showFolderSizes = defaults.bool(forKey: "showFolderSizes")
        themeID = defaults.string(forKey: "theme") ?? "system"
        density = Density(rawValue: defaults.string(forKey: "density") ?? "") ?? .regular
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 12.5
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 12
        terminalSync = defaults.object(forKey: "terminalSync") as? Bool ?? true
        let savedServers = defaults.data(forKey: "servers").flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) } ?? []
        servers = savedServers
        for case .sftp(let s) in savedServers.map(\.kind) { SFTPClient.register(s) }
        let savedTags = defaults.data(forKey: "knownTags").flatMap { try? JSONDecoder().decode([FileTag].self, from: $0) } ?? []
        knownTags = FileTag.standard + savedTags.filter { t in !FileTag.standard.contains { $0.name == t.name } }
        workspaces = (defaults.data(forKey: "workspaces"))
            .flatMap { try? JSONDecoder().decode([Workspace].self, from: $0) } ?? []

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
        // Optional start folders: fileCommander [left-path] [right-path]. Otherwise restore last session.
        // Only real paths count: AppKit flags like `-NSFoo YES` also arrive in argv.
        let args = CommandLine.arguments.dropFirst()
            .filter { $0.hasPrefix("/") || $0.hasPrefix("~") }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !args.isEmpty {
            sides = [
                PaneSide(tabs: [makePane(args[0])]),
                PaneSide(tabs: [makePane(args.count > 1 ? args[1] : downloads)]),
            ]
        } else if let data = defaults.data(forKey: "session"),
                  let ws = try? JSONDecoder().decode(Workspace.self, from: data) {
            sides = [PaneSide(tabs: [makePane(home)]), PaneSide(tabs: [makePane(downloads)])]
            apply(ws)
        } else {
            sides = [PaneSide(tabs: [makePane(home)]), PaneSide(tabs: [makePane(downloads)])]
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    /// Settings the app stores. Used to carry them over from the app's previous identifier
    /// ("One Commander", local.onecommander.mac) the first time fileCommander launches.
    static let settingKeys = [
        "favorites", "recentFolders", "workspaces", "session", "showFolderSizes", "knownTags", "servers",
        "theme", "density", "fontSize", "terminalFontSize", "terminalSync", "previewWidth", "terminalHeight",
    ]

    /// Copies settings once; never overwrites anything already set in the new domain.
    static func migrateSettings(from old: [String: Any]?, to new: UserDefaults) {
        guard let old, !new.bool(forKey: "migratedLegacySettings") else { return }
        new.set(true, forKey: "migratedLegacySettings")
        for key in settingKeys where new.object(forKey: key) == nil {
            if let value = old[key] { new.set(value, forKey: key) }
        }
    }

    func makePane(_ url: URL) -> Pane {
        Pane(url: url, showHidden: showHidden) { [weak self] url in self?.visited(url) }
    }

    var panes: [Pane] { sides.map(\.current) }
    var activeSide: PaneSide { sides[activePane] }
    var active: Pane { activeSide.current }
    var inactive: Pane? { dualPane ? sides[1 - activePane].current : nil }
    var isPrompting: Bool { prompt != nil || palette != nil || sheet != nil }
    var selectedURLs: [URL] { active.selectedURLs }
    var hasSelection: Bool { !active.selectedItems.isEmpty }

    func refreshAll() { sides.flatMap(\.tabs).forEach { $0.refresh() } }
    func go(to url: URL) { active.navigate(to: url) }
    /// Focus moves with the folder, so the pane you were working in stays the active one.
    func swapPanes() {
        sides.swapAt(0, 1)
        if dualPane { activePane = 1 - activePane }
    }

    func focusPane(_ index: Int) {
        guard index == 0 || dualPane else { return }
        activePane = index
    }

    // MARK: Tabs

    func newTab() { activeSide.add(makePane(active.currentDirectory)) }
    func closeTab() { activeSide.close(activeSide.selected) }
    func cycleTab(_ delta: Int) { activeSide.cycle(delta) }

    // MARK: Recent folders & workspaces

    private func visited(_ url: URL) {
        let p = url.path
        recentFolders.removeAll { $0 == p }
        recentFolders.insert(p, at: 0)
        if recentFolders.count > 300 { recentFolders.removeLast(recentFolders.count - 300) }
        defaults.set(recentFolders, forKey: "recentFolders")
    }

    func captureWorkspace(named name: String) -> Workspace {
        Workspace(
            name: name,
            left: sides[0].tabs.map(\.rootURL.path), right: sides[1].tabs.map(\.rootURL.path),
            leftSelected: sides[0].selected, rightSelected: sides[1].selected,
            dualPane: dualPane)
    }

    func apply(_ ws: Workspace) {
        func side(_ paths: [String], _ selected: Int) -> PaneSide? {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            return urls.isEmpty ? nil : PaneSide(tabs: urls.map(makePane), selected: selected)
        }
        if let l = side(ws.left, ws.leftSelected) { sides[0] = l }
        if let r = side(ws.right, ws.rightSelected) { sides[1] = r }
        dualPane = ws.dualPane
        activePane = 0
    }

    func saveSession() {
        if let data = try? JSONEncoder().encode(captureWorkspace(named: "session")) {
            defaults.set(data, forKey: "session")
        }
    }

    private func saveWorkspaces() {
        if let data = try? JSONEncoder().encode(workspaces) { defaults.set(data, forKey: "workspaces") }
    }

    func deleteWorkspace(_ ws: Workspace) { workspaces.removeAll { $0.name == ws.name } }

    // MARK: Favorites

    func addFavorite(_ url: URL) {
        guard !favorites.contains(where: { $0.path == url.path }) else { return }
        favorites.append(url)
    }

    func removeFavorite(_ url: URL) { favorites.removeAll { $0.path == url.path } }

    // MARK: Open / reveal

    func openSelection() {
        let items = active.selectedItems
        if items.count == 1, items[0].opensColumn {
            active.moveRight()
        } else {
            items.filter { !$0.isFolder }.forEach { open($0.url) }
        }
    }

    func open(_ url: URL) {
        if let remote = SFTPRef.resolve(url) {
            Task.detached {
                let result = Result { try SFTPClient.fetchForViewing(remote) }
                await MainActor.run {
                    switch result {
                    case .success(let tmp): NSWorkspace.shared.open(tmp)
                    case .failure(let e): self.errorMessage = e.localizedDescription
                    }
                }
            }
            return
        }
        guard let ref = archiveRef(url) else { NSWorkspace.shared.open(url); return }
        // Inside a zip: extract to a temp copy first.
        Task.detached {
            let result = Result { try ZipArchive.extractForViewing(ref.zip, inner: ref.inner) }
            await MainActor.run {
                switch result {
                case .success(let tmp): NSWorkspace.shared.open(tmp)
                case .failure(let e): self.errorMessage = e.localizedDescription
                }
            }
        }
    }

    /// Non-nil for pseudo paths inside a zip.
    func archiveRef(_ url: URL) -> ArchiveRef? {
        FileManager.default.fileExists(atPath: url.path) ? nil : ArchiveRef.resolve(url)
    }

    /// Server items support browsing, transfer, rename, new folder and delete — nothing else.
    private func rejectRemote(_ urls: [URL], _ action: String) -> Bool {
        guard urls.contains(where: { SFTPRef.resolve($0) != nil }) else { return false }
        errorMessage = "Items on a server can't be \(action). Download them first (F5)."
        return true
    }

    /// Runs a server operation off the main thread, then refreshes the affected columns.
    func remoteTask(_ work: @escaping @Sendable () throws -> Void, refresh urls: [URL], then: (@MainActor () -> Void)? = nil) {
        Task.detached {
            let result = Result { try work() }
            await MainActor.run {
                if case .failure(let e) = result { self.errorMessage = e.localizedDescription }
                self.refreshColumns(containing: urls)
                then?()
            }
        }
    }

    /// Items inside zips are read-only; returns true (and explains) if any are.
    private func rejectArchive(_ urls: [URL], _ action: String) -> Bool {
        guard urls.contains(where: { archiveRef($0) != nil }) else { return false }
        errorMessage = "Items inside an archive are read-only, so they can't be \(action). Copy them out first (F5 extracts)."
        return true
    }

    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openTerminal(at dir: URL) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: Prompts

    func beginRename(_ url: URL? = nil) {
        guard !isPrompting, let url = url ?? active.cursorItem?.url else { return }
        if rejectArchive([url], "renamed") { return }
        promptText = url.lastPathComponent
        prompt = .rename(url)
    }

    func beginNewFolder(in dir: URL? = nil) {
        guard !isPrompting else { return }
        let target = dir ?? active.currentDirectory
        if SFTPRef.resolve(target) == nil, rejectArchive([target], "changed") { return }
        promptText = "untitled folder"
        prompt = .newFolder(dir ?? active.currentDirectory)
    }

    func beginSelectMatching(add: Bool) {
        guard !isPrompting else { return }
        promptText = add ? "*.*" : "*"
        prompt = .selectMatching(add: add)
    }

    func beginSaveWorkspace() {
        guard !isPrompting else { return }
        promptText = "Workspace \(workspaces.count + 1)"
        prompt = .saveWorkspace
    }

    func commitPrompt() {
        guard let p = prompt else { return }
        prompt = nil
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch p {
        case .selectMatching(let add):
            active.selectMatching(text, add: add)
            return
        case .saveWorkspace:
            let ws = captureWorkspace(named: text)
            workspaces.removeAll { $0.name == text }
            workspaces.append(ws)
            return
        case .rename, .newFolder:
            break
        }
        guard !text.contains("/"), !text.contains(":") else {
            errorMessage = "“\(text)” isn't a valid name."
            return
        }
        do {
            switch p {
            case .rename(let url) where SFTPRef.resolve(url) != nil:
                let ref = SFTPRef.resolve(url)!
                let newPath = ((ref.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(text)
                remoteTask({ try SFTPClient.rename(ref, to: newPath) }, refresh: [url])
            case .newFolder(let dir) where SFTPRef.resolve(dir) != nil:
                let ref = SFTPRef.resolve(dir)!
                let path = (ref.path as NSString).appendingPathComponent(text)
                let newURL = SFTPRef.url(ref.target, path)
                remoteTask({ try SFTPClient.makeFolder(SFTPRef(target: ref.target, path: path)) }, refresh: [newURL]) { [weak self] in
                    self?.active.reveal(newURL)
                }
            case .rename(let url):
                let dest = url.deletingLastPathComponent().appendingPathComponent(text)
                guard dest.path != url.path else { return }
                if FileOps.exists(dest) && dest.path.lowercased() != url.path.lowercased() {
                    errorMessage = "“\(text)” already exists."
                    return
                }
                try FileManager.default.moveItem(at: url, to: dest)
                Thumbnails.invalidate(url.path)
                record("Rename", undo: .move([MovePair(from: dest, to: url)]))
                active.reveal(dest)
            case .newFolder(let dir):
                let dest = FileOps.uniqueURL(dir.appendingPathComponent(text))
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                record("New Folder", undo: .trash([dest]))
                active.reveal(dest)
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: File operations

    func trash(_ urls: [URL]? = nil) {
        guard !isPrompting else { return }
        let urls = urls ?? selectedURLs
        guard !urls.isEmpty, !rejectArchive(urls, "moved to the Trash") else { return }
        if urls.contains(where: { SFTPRef.resolve($0) != nil }) {
            confirmRemoteDelete = urls          // no Trash on a server: ask first
            return
        }
        // Remember position so the next item gets selected afterwards.
        let pane = active
        let col = pane.current
        let first = col.items.firstIndex { urls.map(\.standardizedFileURL.path).contains($0.path) }
        do {
            let inverse = try FileAction.trash(urls).perform()
            record("Move to Trash", undo: inverse)
        } catch {
            errorMessage = error.localizedDescription
        }
        col.reload { col in
            guard let first, !col.items.isEmpty, let ci = pane.columns.firstIndex(where: { $0 === col }) else { return }
            pane.select(col.items[min(first, col.items.count - 1)], in: ci)
        }
    }

    func duplicate(_ urls: [URL]? = nil) {
        guard !isPrompting else { return }
        let urls = urls ?? selectedURLs
        guard let parent = urls.first?.deletingLastPathComponent(), !rejectArchive(urls, "duplicated"),
              !rejectRemote(urls, "duplicated") else { return }
        transfer(urls, to: parent, move: false)
    }

    func sendToOtherPane(move: Bool) {
        guard !isPrompting, hasSelection else { return }
        guard let target = inactive?.currentDirectory else {
            errorMessage = "Turn on dual pane to copy or move between panes."
            return
        }
        transfer(selectedURLs, to: target, move: move)
    }

    /// Queues a copy/move job. `move: nil` means Finder semantics: move within a volume,
    /// copy across volumes.
    func transfer(_ urls: [URL], to dir: URL, move: Bool? = nil) {
        let dir = dir.standardizedFileURL
        guard !urls.isEmpty else { return }
        if archiveRef(dir) != nil {
            errorMessage = "Can't add files inside a zip. Extract it first, or copy into a regular folder."
            return
        }
        let remoteSources = urls.compactMap(SFTPRef.resolve)
        if let remoteDir = SFTPRef.resolve(dir) {
            guard remoteSources.isEmpty, !urls.contains(where: { archiveRef($0) != nil }) else {
                errorMessage = "Copy between servers or from a zip to a server isn't supported. Copy to a local folder first."
                return
            }
            if move == true { errorMessage = "Uploads are copies; delete the originals yourself if needed."; return }
            let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
            jobs.runTask("Uploading \(what) to \(remoteDir.target)") {
                try SFTPClient.upload(urls, to: remoteDir)
            } completion: { [weak self] result in
                if case .failure(let e) = result { self?.errorMessage = e.localizedDescription }
                self?.refreshColumns(containing: urls.map { remoteDir.url.appendingPathComponent($0.lastPathComponent) })
            }
            return
        }
        if !remoteSources.isEmpty {
            guard remoteSources.count == urls.count, move != true else {
                errorMessage = "Items on a server can only be copied (downloaded), not moved."
                return
            }
            let what = urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"
            jobs.runTask("Downloading \(what) from \(remoteSources[0].target)") {
                try SFTPClient.download(remoteSources, to: dir)
            } completion: { [weak self] result in
                self?.finishTask(result, name: "Download", reveal: dir)
            }
            return
        }
        // Copying out of a zip = extracting.
        let fromZip = urls.compactMap(archiveRef)
        if !fromZip.isEmpty {
            if move == true || fromZip.count != urls.count {
                errorMessage = "Items inside a zip can only be copied out (F5), not moved."
                return
            }
            extract(fromZip, to: dir)
            return
        }
        for u in urls {
            let p = u.standardizedFileURL.path
            if dir.path == p || dir.path.hasPrefix(p + "/") {
                errorMessage = "Can't put “\(u.lastPathComponent)” inside itself."
                return
            }
        }
        let shouldMove = move ?? urls.allSatisfy { FileOps.sameVolume($0, dir) }
        jobs.start(shouldMove ? .move : .copy, sources: urls, to: dir) { [weak self] result in
            self?.finish(result, kind: shouldMove ? .move : .copy, dir: dir)
        }
    }

    private func finish(_ r: JobResult, kind: FileJob.Kind, dir: URL?) {
        var undo: [FileAction] = []
        // Copies inside a folder we created go with that folder.
        let loose = r.created.filter { c in !r.createdDirs.contains { c.path.hasPrefix($0.path + "/") } }
        if !loose.isEmpty || !r.createdDirs.isEmpty { undo.append(.trash(loose + r.createdDirs)) }
        if !r.moved.isEmpty { undo.append(.move(r.moved.reversed().map(\.reversed))) }
        if !r.replaced.isEmpty { undo.append(.move(r.replaced)) }
        if !undo.isEmpty { record(kind == .copy ? "Copy" : "Move", undo: .group(undo)) }
        if r.errors.count > 0 { errorMessage = r.errors.joined(separator: "\n") }
        let results = r.created + r.moved.map(\.to)
        if let dir, !results.isEmpty, let pane = panes.first(where: { p in p.columns.contains { $0.url.path == dir.path } }) {
            pane.reveal(results)
        }
    }

    func paste(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        transfer(urls, to: active.currentDirectory, move: false)
    }

    // MARK: Batch rename

    func beginBatchRename() {
        guard !isPrompting else { return }
        let urls = selectedURLs
        guard !urls.isEmpty, !rejectArchive(urls, "renamed") else { return }
        if urls.count == 1 { beginRename(urls[0]); return }
        if rejectRemote(urls, "batch renamed") { return }
        sheet = .batchRename(urls)
    }

    func batchRename(_ rows: [RenameRow]) {
        let pairs = rows.filter { $0.changed && $0.problem == nil }.map {
            MovePair(from: $0.url, to: $0.url.deletingLastPathComponent().appendingPathComponent($0.newName))
        }
        guard !pairs.isEmpty else { return }
        do {
            let inverse = try FileAction.renameBatch(pairs).perform()
            pairs.forEach { Thumbnails.invalidate($0.from.path) }
            record(pairs.count == 1 ? "Rename" : "Rename \(pairs.count) Items", undo: inverse)
            active.reveal(pairs.map(\.to))
        } catch {
            errorMessage = error.localizedDescription
            refreshAll()
        }
    }

    // MARK: Tags

    func editTags() {
        guard !isPrompting, hasSelection, !rejectArchive(selectedURLs, "tagged"), !rejectRemote(selectedURLs, "tagged") else { return }
        sheet = .tags(selectedURLs)
    }

    func showTagged(_ tag: FileTag) {
        guard !isPrompting else { return }
        sheet = .tagResults(tag)
    }

    func rememberTag(_ tag: FileTag) {
        guard !knownTags.contains(where: { $0.name == tag.name }) else { return }
        knownTags.append(tag)
        let custom = knownTags.filter { t in !FileTag.standard.contains { $0.name == t.name } }
        if let data = try? JSONEncoder().encode(custom) { defaults.set(data, forKey: "knownTags") }
    }

    /// Adds `tag` to every item, or removes it from all of them if they all have it already.
    func toggleTag(_ tag: FileTag, on urls: [URL]? = nil) {
        let urls = urls ?? selectedURLs
        guard !urls.isEmpty, !rejectArchive(urls, "tagged"), !rejectRemote(urls, "tagged") else { return }
        let current = urls.map { ($0, TagStore.read($0)) }
        let allHave = current.allSatisfy { $0.1.contains { $0.name == tag.name } }
        let changes = current.map { url, tags in
            TagChange(url: url, old: tags,
                      new: allHave ? tags.filter { $0.name != tag.name }
                                   : (tags.contains { $0.name == tag.name } ? tags : tags + [tag]))
        }
        do {
            let inverse = try FileAction.setTags(changes).perform()
            record(allHave ? "Remove Tag" : "Add Tag", undo: inverse)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshColumns(containing: urls)
    }

    func toggleStandardTag(_ color: Int) {
        guard !isPrompting, let tag = FileTag.standard.first(where: { $0.color == color }) else { return }
        toggleTag(tag)
    }

    func refreshColumns(containing urls: [URL]) {
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        for pane in sides.flatMap(\.tabs) {
            for col in pane.columns where parents.contains(col.url.path) { col.reload() }
        }
    }

    // MARK: Folder sizes

    func calculateSelectedSizes() {
        let folders = active.selectedItems.filter(\.isFolder).map(\.url)
        sizes.request(folders.isEmpty ? [active.currentDirectory] : folders)
    }

    // MARK: Zip

    /// Extracts entries from inside zips into `dir`.
    func extract(_ refs: [ArchiveRef], to dir: URL) {
        let byZip = Dictionary(grouping: refs, by: \.zip)
        let what = refs.count == 1 ? "“\((refs[0].inner as NSString).lastPathComponent)”" : "\(refs.count) items"
        jobs.runTask("Extracting \(what) to “\(dir.lastPathComponent)”") {
            try byZip.flatMap { zip, refs in try ZipArchive.extract(zip, inner: refs.map(\.inner), to: dir) }
        } completion: { [weak self] result in
            self?.finishTask(result, name: "Extract", reveal: dir)
        }
    }

    /// Extracts a whole zip next to it, into a folder named after it.
    func extractHere(_ zip: URL? = nil) {
        guard let zip = zip ?? active.cursorItem?.url, ZipArchive.isArchive(zip), archiveRef(zip) == nil else { return }
        // "photos.tar.gz" → "photos"
        var base = zip.lastPathComponent
        for suffix in [".zip"] + ZipArchive.tarSuffixes where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        let dest = FileOps.uniqueURL(zip.deletingLastPathComponent().appendingPathComponent(base.isEmpty ? "Archive" : base))
        jobs.runTask("Extracting “\(zip.lastPathComponent)”") {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
            try ZipArchive.extractAll(zip, to: dest)
            return [dest]
        } completion: { [weak self] result in
            self?.finishTask(result, name: "Extract", reveal: zip.deletingLastPathComponent())
        }
    }

    func compress(_ urls: [URL]? = nil) {
        let urls = urls ?? selectedURLs
        guard !urls.isEmpty, !rejectArchive(urls, "compressed"), !rejectRemote(urls, "compressed") else { return }
        let parent = urls[0].deletingLastPathComponent()
        jobs.runTask("Compressing \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items")") {
            [try ZipArchive.compress(urls)]
        } completion: { [weak self] result in
            self?.finishTask(result, name: "Compress", reveal: parent)
        }
    }

    private func finishTask(_ result: Result<[URL], Error>, name: String, reveal dir: URL) {
        switch result {
        case .success(let created) where !created.isEmpty:
            record(name, undo: .trash(created))
            panes.first { p in p.columns.contains { $0.url.path == dir.standardizedFileURL.path } }?.reveal(created)
        case .failure(let e):
            errorMessage = e.localizedDescription
        default:
            break
        }
    }

    // MARK: Search, filter, view

    func beginSearch() {
        guard !isPrompting else { return }
        if active.current.remote != nil { errorMessage = "Searching on servers isn't supported."; return }
        var dir = active.currentDirectory
        if let ref = archiveRef(dir) { dir = ref.zip.deletingLastPathComponent() }
        sheet = .search(SearchSession(root: dir))
    }

    func beginFilter() {
        guard !isPrompting else { return }
        active.filterEditing = true
    }

    func clearFilter() {
        active.current.filter = ""
        active.filterEditing = false
    }

    func setViewMode(_ mode: Pane.ViewMode) { active.viewMode = mode }

    /// Choosing the current key again flips the direction, like clicking a column header.
    func sortBy(_ key: SortSpec.Key) {
        var s = active.sort
        if s.key == key { s.ascending.toggle() } else { s = SortSpec(key: key, ascending: key == .name || key == .kind) }
        active.sort = s
    }

    // MARK: Compare & sync

    func compareFolders() {
        guard !isPrompting else { return }
        guard dualPane else {
            errorMessage = "Turn on dual pane: Compare uses the folders open in the two panes."
            return
        }
        let l = sides[0].current.current, r = sides[1].current.current
        if l.isVirtual || r.isVirtual {
            errorMessage = "Compare works on local folders (not zips or servers)."
            return
        }
        sheet = .compare(CompareSession(left: l.url, right: r.url))
    }

    func runSync(_ items: [TransferItem], title: String, completion: @escaping @MainActor () -> Void) {
        jobs.start(.copy, items: items, policy: .replace, title: title) { [weak self] result in
            self?.finish(result, kind: .copy, dir: nil)
            self?.refreshAll()
            completion()
        }
    }

    // MARK: Appearance

    func applyTheme() {
        NSApp?.appearance = theme.appearance.flatMap { NSAppearance(named: $0) }
        terminalController?.applyTheme(theme)
    }

    // MARK: Terminal

    /// The shell session, created on first use and kept while the panel is hidden.
    var terminal: TerminalController {
        if let t = terminalController { return t }
        let t = TerminalController()
        t.applyTheme(theme)
        t.onDirectoryChange = { [weak self] url in self?.terminalMoved(to: url) }
        t.onExit = { [weak self] in
            self?.terminalController = nil
            self?.showTerminal = false
        }
        terminalController = t
        return t
    }

    func toggleTerminal() {
        showTerminal.toggle()
        if showTerminal {
            let dir = terminalDirectory(for: active)
            terminal.start(in: dir)
            terminalTitle = (dir.path as NSString).abbreviatingWithTildeInPath
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.terminalController?.focus() }
        }
    }

    /// Zips and servers aren't real folders a shell can enter: use the nearest real one.
    private func terminalDirectory(for pane: Pane) -> URL {
        let col = pane.current
        if let ref = col.archive { return ref.zip.deletingLastPathComponent() }
        if col.remote != nil { return FileManager.default.homeDirectoryForCurrentUser }
        return col.url
    }

    /// The active pane moved: take the shell along (only if it's idle at its prompt).
    func paneDirectoryChanged() {
        guard showTerminal, terminalSync, let t = terminalController, active.current.isVirtual == false else { return }
        t.cd(active.currentDirectory)
        terminalTitle = (active.currentDirectory.path as NSString).abbreviatingWithTildeInPath
    }

    /// The shell changed folder (`cd`): take the active pane along.
    private func terminalMoved(to url: URL) {
        terminalTitle = (url.path as NSString).abbreviatingWithTildeInPath
        guard terminalSync, url.standardizedFileURL.path != active.currentDirectory.path else { return }
        active.navigate(to: url)
    }

    // MARK: Quick Look window & cloud files

    /// Local files Quick Look can show directly (archive/server entries use the preview panel).
    private var quickLookURLs: [URL] {
        selectedURLs.filter { SFTPRef.resolve($0) == nil && archiveRef($0) == nil }
    }

    func quickLook() {
        let urls = quickLookURLs
        guard !urls.isEmpty else {
            if hasSelection { errorMessage = "Quick Look shows local files. Items in archives or on servers appear in the preview panel (Space)." }
            return
        }
        QuickLookPanelController.shared.onStep = { [weak self] delta in
            self?.active.moveSelection(delta)
        }
        QuickLookPanelController.shared.show(urls)
    }

    func updateQuickLook() {
        QuickLookPanelController.shared.update(quickLookURLs)
    }

    func downloadNow(_ urls: [URL]) {
        cloudAction(urls) { try FileManager.default.startDownloadingUbiquitousItem(at: $0) }
    }

    func removeDownload(_ urls: [URL]) {
        cloudAction(urls) { try FileManager.default.evictUbiquitousItem(at: $0) }
    }

    /// Cloud status changes don't touch the folder, so refresh the column a few times after.
    private func cloudAction(_ urls: [URL], _ action: @escaping @Sendable (URL) throws -> Void) {
        Task.detached {
            var failure: String?
            for u in urls {
                do { try action(u) } catch { failure = error.localizedDescription }
            }
            await MainActor.run { [failure] in
                if let failure { self.errorMessage = failure }
                for delay in [0.5, 2.0, 5.0, 15.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.refreshColumns(containing: urls) }
                }
            }
        }
    }

    // MARK: Open With / Info

    func open(_ urls: [URL], with app: URL) {
        let local = urls.filter { SFTPRef.resolve($0) == nil && archiveRef($0) == nil }
        guard local.count == urls.count else {
            errorMessage = "Open With works on local files. Copy items out of zips or servers first."
            return
        }
        NSWorkspace.shared.open(local, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }

    func getInfo(_ urls: [URL]? = nil) {
        guard !isPrompting else { return }
        let urls = urls ?? selectedURLs
        guard !urls.isEmpty, !rejectArchive(urls, "inspected"), !rejectRemote(urls, "inspected") else { return }
        sheet = .info(urls)
    }

    // MARK: Servers

    /// Deletes server items after the user confirmed (files, and folders only if empty).
    func deleteRemote(_ urls: [URL]) {
        let refs = urls.compactMap(SFTPRef.resolve)
        let folders = Set(active.current.items.filter { $0.isFolder && urls.contains($0.url) }.compactMap { SFTPRef.resolve($0.url)?.path })
        remoteTask({ try SFTPClient.delete(refs, folders: folders) }, refresh: urls)
    }

    var servers: [SavedServer] {
        didSet { if let d = try? JSONEncoder().encode(servers) { defaults.set(d, forKey: "servers") } }
    }

    func remember(_ server: SavedServer) {
        servers.removeAll { $0.id == server.id }
        servers.insert(server, at: 0)
    }

    func forget(_ server: SavedServer) { servers.removeAll { $0.id == server.id } }

    /// Connects (mounting via macOS, or checking SFTP access) and opens it in the active pane.
    func connect(_ server: SavedServer, completion: ((String?) -> Void)? = nil) {
        switch server.kind {
        case .mount(let urlString):
            ServerMounter.mount(urlString) { [weak self] result in
                switch result {
                case .success(let mountPoint):
                    self?.remember(server)
                    self?.go(to: mountPoint)
                    completion?(nil)
                case .failure(let e):
                    completion?(e.localizedDescription)
                }
            }
        case .sftp(let s):
            SFTPClient.register(s)
            Task.detached {
                let result = Result { () throws -> String in
                    s.path.isEmpty ? try SFTPClient.home(s.target) : s.path
                }
                await MainActor.run {
                    switch result {
                    case .success(let start):
                        self.remember(server)
                        self.go(to: SFTPRef.url(s.target, start))
                        completion?(nil)
                    case .failure(let e):
                        completion?(e.localizedDescription)
                    }
                }
            }
        }
    }

    func eject(_ volume: URL) {
        Task.detached {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    // MARK: Undo / redo

    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    private func record(_ name: String, undo action: FileAction) {
        undoStack.append(UndoEntry(name: name, action: action))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() { replay(from: \.undoStack, to: \.redoStack) }
    func redo() { replay(from: \.redoStack, to: \.undoStack) }

    private func replay(from: ReferenceWritableKeyPath<AppModel, [UndoEntry]>,
                        to: ReferenceWritableKeyPath<AppModel, [UndoEntry]>) {
        guard let entry = self[keyPath: from].popLast() else { return }
        let action = entry.action
        Task.detached {
            let outcome = Result { try action.perform() }
            await MainActor.run {
                switch outcome {
                case .success(let inverse):
                    self[keyPath: to].append(UndoEntry(name: entry.name, action: inverse))
                    let targets = action.targets
                    if !targets.isEmpty {
                        let parent = targets[0].deletingLastPathComponent().standardizedFileURL.path
                        let same = targets.filter { $0.deletingLastPathComponent().standardizedFileURL.path == parent }
                        let pane = ([self.active] + self.panes).first { p in p.columns.contains { $0.url.path == parent } }
                        pane?.reveal(same)
                    }
                case .failure(let error):
                    self.errorMessage = "Couldn't \(from == \AppModel.undoStack ? "undo" : "redo") \(entry.name): \(error.localizedDescription)"
                }
                self.refreshAll()
            }
        }
    }
}
