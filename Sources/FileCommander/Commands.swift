import SwiftTerm
import SwiftUI

/// One user-invokable action. The same list builds the menu bar and the command palette,
/// so every command is reachable both ways and shows the same shortcut.
struct CommandSpec: Identifiable {
    enum Menu: String { case file = "File", edit = "Edit", go = "Go", commander = "Commander", tag = "Tag", view = "View", sort = "Sort", tabs = "Tabs" }

    let id: String
    let title: String
    let menu: Menu
    var key: KeyEquivalent?
    var modifiers: EventModifiers = .command
    var dividerBefore = false
    /// When a text field has focus, send this editing action instead (e.g. ⌘⌫ deletes text,
    /// it must not trash files while you type a filter or path).
    var textAction: Selector?
    var enabled: @MainActor (AppModel) -> Bool = { _ in true }
    let run: @MainActor (AppModel) -> Void

    var shortcut: KeyboardShortcut? { key.map { KeyboardShortcut($0, modifiers: modifiers) } }

    var shortcutLabel: String {
        guard let key else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .delete: s += "⌫"
        case .tab: s += "⇥"
        case .return: s += "↩"
        default:
            let scalar = key.character.unicodeScalars.first!.value
            if (0xF704...0xF70F).contains(scalar) {
                s += "F\(scalar - 0xF703)"
            } else {
                s += String(key.character).uppercased()
            }
        }
        return s
    }
}

private func fkey(_ n: Int) -> KeyEquivalent {
    KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey + n - 1)!))
}

private func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

private func userDir(_ d: FileManager.SearchPathDirectory) -> URL {
    FileManager.default.urls(for: d, in: .userDomainMask).first ?? home()
}

@MainActor
enum CommandRegistry {
    static let all: [CommandSpec] = [
        // File
        CommandSpec(id: "newFolder", title: "New Folder", menu: .file, key: "n", modifiers: [.command, .shift],
                    run: { $0.beginNewFolder() }),
        CommandSpec(id: "newTab", title: "New Tab", menu: .file, key: "t", run: { $0.newTab() }),
        CommandSpec(id: "closeTab", title: "Close Tab", menu: .file, key: "w",
                    run: { model in
                        // Like Finder: ⌘W closes the tab, or the window when it's the last one.
                        if model.activeSide.tabs.count > 1 { model.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
                    }),
        CommandSpec(id: "open", title: "Open", menu: .file, key: .downArrow, dividerBefore: true,
                    textAction: #selector(NSResponder.moveToEndOfDocument(_:)),
                    enabled: { $0.hasSelection }, run: { $0.openSelection() }),
        CommandSpec(id: "search", title: "Search in Files…", menu: .file, key: "f", modifiers: [.command, .shift],
                    run: { $0.beginSearch() }),
        CommandSpec(id: "filter", title: "Filter Folder…", menu: .file, key: "f", run: { $0.beginFilter() }),
        CommandSpec(id: "compress", title: "Compress", menu: .file, dividerBefore: true,
                    enabled: { $0.hasSelection }, run: { $0.compress() }),
        CommandSpec(id: "extractHere", title: "Extract Here", menu: .file,
                    enabled: { $0.active.cursorItem?.isBrowsableArchive == true }, run: { $0.extractHere() }),
        CommandSpec(id: "quickLook", title: "Quick Look", menu: .file, key: "y",
                    enabled: { $0.hasSelection }, run: { $0.quickLook() }),
        CommandSpec(id: "getInfo", title: "Get Info", menu: .file, key: "i",
                    enabled: { $0.hasSelection }, run: { $0.getInfo() }),
        CommandSpec(id: "connect", title: "Connect to Server…", menu: .go, key: "k", dividerBefore: true,
                    run: { m in if !m.isPrompting { m.sheet = .connect } }),
        CommandSpec(id: "revealFinder", title: "Reveal in Finder", menu: .file, key: "r", modifiers: [.command, .shift],
                    enabled: { $0.hasSelection }, run: { $0.revealInFinder($0.selectedURLs) }),
        CommandSpec(id: "terminalPanel", title: "Toggle Terminal Panel", menu: .view, key: "`", modifiers: .control,
                    run: { $0.toggleTerminal() }),
        CommandSpec(id: "terminal", title: "Open in Terminal App", menu: .file, key: "t", modifiers: [.command, .option],
                    run: { $0.openTerminal(at: $0.active.currentDirectory) }),

        // Edit (selection)
        CommandSpec(id: "selectMatching", title: "Select Matching…", menu: .edit, key: "=", dividerBefore: true,
                    run: { $0.beginSelectMatching(add: true) }),
        CommandSpec(id: "deselectMatching", title: "Deselect Matching…", menu: .edit, key: "-",
                    run: { $0.beginSelectMatching(add: false) }),
        CommandSpec(id: "invertSelection", title: "Invert Selection", menu: .edit, key: "i", modifiers: [.command, .shift],
                    run: { $0.active.invertSelection() }),
        CommandSpec(id: "copyPath", title: "Copy Path", menu: .edit, key: "c", modifiers: [.command, .option],
                    enabled: { $0.hasSelection }, run: { $0.copyPaths($0.selectedURLs) }),

        // Go
        CommandSpec(id: "goTo", title: "Go to Folder…", menu: .go, key: "p", run: { $0.palette = .goTo }),
        CommandSpec(id: "back", title: "Back", menu: .go, key: "[", dividerBefore: true,
                    enabled: { $0.active.canGoBack }, run: { $0.active.goBack() }),
        CommandSpec(id: "forward", title: "Forward", menu: .go, key: "]",
                    enabled: { $0.active.canGoForward }, run: { $0.active.goForward() }),
        CommandSpec(id: "up", title: "Enclosing Folder", menu: .go, key: .upArrow,
                    textAction: #selector(NSResponder.moveToBeginningOfDocument(_:)), run: { $0.active.goUp() }),
        CommandSpec(id: "home", title: "Home", menu: .go, key: "h", modifiers: [.command, .shift], dividerBefore: true,
                    run: { $0.go(to: home()) }),
        CommandSpec(id: "desktop", title: "Desktop", menu: .go, key: "d", modifiers: [.command, .shift],
                    run: { $0.go(to: userDir(.desktopDirectory)) }),
        CommandSpec(id: "documents", title: "Documents", menu: .go, key: "o", modifiers: [.command, .shift],
                    run: { $0.go(to: userDir(.documentDirectory)) }),
        CommandSpec(id: "downloads", title: "Downloads", menu: .go, key: "l", modifiers: [.command, .option],
                    run: { $0.go(to: userDir(.downloadsDirectory)) }),
        CommandSpec(id: "applications", title: "Applications", menu: .go, key: "a", modifiers: [.command, .shift],
                    run: { $0.go(to: URL(fileURLWithPath: "/Applications")) }),

        // Commander (file operations)
        CommandSpec(id: "rename", title: "Rename…", menu: .commander, key: fkey(2), modifiers: [],
                    enabled: { $0.hasSelection }, run: { $0.beginBatchRename() }),
        CommandSpec(id: "batchRename", title: "Batch Rename…", menu: .commander, key: "m", modifiers: [.command, .control],
                    enabled: { $0.hasSelection }, run: { m in m.sheet = .batchRename(m.selectedURLs) }),
        CommandSpec(id: "copyOther", title: "Copy to Other Pane", menu: .commander, key: fkey(5), modifiers: [],
                    enabled: { $0.hasSelection && $0.dualPane }, run: { $0.sendToOtherPane(move: false) }),
        CommandSpec(id: "moveOther", title: "Move to Other Pane", menu: .commander, key: fkey(6), modifiers: [],
                    enabled: { $0.hasSelection && $0.dualPane }, run: { $0.sendToOtherPane(move: true) }),
        CommandSpec(id: "duplicate", title: "Duplicate", menu: .commander, key: "d",
                    enabled: { $0.hasSelection }, run: { $0.duplicate() }),
        CommandSpec(id: "trash", title: "Move to Trash", menu: .commander, key: .delete,
                    textAction: #selector(NSResponder.deleteToBeginningOfLine(_:)),
                    enabled: { $0.hasSelection }, run: { $0.trash() }),
        CommandSpec(id: "editTags", title: "Edit Tags…", menu: .commander, key: "g", modifiers: [.command, .option],
                    dividerBefore: true, enabled: { $0.hasSelection }, run: { $0.editTags() }),
        CommandSpec(id: "calcSizes", title: "Calculate Folder Sizes", menu: .commander, key: "s", modifiers: [.command, .shift],
                    run: { $0.calculateSelectedSizes() }),
        CommandSpec(id: "compare", title: "Compare & Sync Folders…", menu: .commander, key: "c", modifiers: [.command, .shift],
                    enabled: { $0.dualPane }, run: { $0.compareFolders() }),
        CommandSpec(id: "favorite", title: "Add Folder to Favorites", menu: .commander, key: "t", modifiers: [.command, .control],
                    dividerBefore: true, run: { $0.addFavorite($0.active.currentDirectory) }),
        CommandSpec(id: "refresh", title: "Refresh", menu: .commander, key: "r",
                    run: { $0.sizes.clear(); $0.refreshAll() }),

        // View
        CommandSpec(id: "palette", title: "Command Palette…", menu: .view, key: "p", modifiers: [.command, .shift],
                    run: { $0.palette = .commands }),
        CommandSpec(id: "hidden", title: "Toggle Hidden Files", menu: .view, key: ".", modifiers: [.command, .shift],
                    dividerBefore: true, run: { $0.showHidden.toggle() }),
        CommandSpec(id: "asColumns", title: "as Columns", menu: .view, key: "3", run: { $0.setViewMode(.columns) }),
        CommandSpec(id: "asList", title: "as List (Details)", menu: .view, key: "2", run: { $0.setViewMode(.details) }),
        CommandSpec(id: "folderSizes", title: "Toggle Folder Sizes", menu: .view, key: "s", modifiers: [.command, .option],
                    dividerBefore: true, run: { $0.showFolderSizes.toggle() }),
        CommandSpec(id: "dual", title: "Toggle Dual Pane", menu: .view, key: "d", modifiers: [.command, .option],
                    run: { $0.dualPane.toggle() }),
        CommandSpec(id: "preview", title: "Toggle Preview", menu: .view, key: "p", modifiers: [.command, .option],
                    run: { $0.showPreview.toggle() }),
        CommandSpec(id: "swap", title: "Swap Panes", menu: .view, key: "u", modifiers: [.command, .option],
                    enabled: { $0.dualPane }, run: { $0.swapPanes() }),
        CommandSpec(id: "otherPane", title: "Switch to Other Pane", menu: .view,
                    enabled: { $0.dualPane }, run: { $0.focusPane(1 - $0.activePane) }),

        // Tabs
        CommandSpec(id: "nextTab", title: "Next Tab", menu: .tabs, key: .tab, modifiers: .control,
                    run: { $0.cycleTab(1) }),
        CommandSpec(id: "prevTab", title: "Previous Tab", menu: .tabs, key: .tab, modifiers: [.control, .shift],
                    run: { $0.cycleTab(-1) }),
        CommandSpec(id: "saveWorkspace", title: "Save Workspace…", menu: .tabs, dividerBefore: true,
                    run: { $0.beginSaveWorkspace() }),
    ]

    static let tagToggles: [CommandSpec] = FileTag.standard.enumerated().map { i, tag in
        CommandSpec(id: "tag-\(tag.color)", title: "Tag \(tag.name)", menu: .tag,
                    key: KeyEquivalent(Character("\(i + 1)")), modifiers: .control,
                    enabled: { $0.hasSelection }, run: { $0.toggleStandardTag(tag.color) })
    }

    static let sortCommands: [CommandSpec] = SortSpec.Key.allCases.enumerated().map { i, key in
        CommandSpec(id: "sort-\(key.rawValue)", title: "Sort by \(key.rawValue)", menu: .sort,
                    key: KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option, .control],
                    run: { $0.sortBy(key) })
    }

    static func specs(_ menu: CommandSpec.Menu) -> [CommandSpec] {
        (all + tagToggles + sortCommands).filter { $0.menu == menu }
    }

    /// Extra palette-only entries that depend on state (undo, workspaces).
    static func dynamic(_ model: AppModel) -> [CommandSpec] {
        var list: [CommandSpec] = []
        if let name = model.undoName {
            list.append(CommandSpec(id: "undo", title: "Undo \(name)", menu: .edit, key: "z", run: { $0.undo() }))
        }
        if let name = model.redoName {
            list.append(CommandSpec(id: "redo", title: "Redo \(name)", menu: .edit, key: "z", modifiers: [.command, .shift],
                                    run: { $0.redo() }))
        }
        for ws in model.workspaces {
            list.append(CommandSpec(id: "ws-\(ws.name)", title: "Open Workspace: \(ws.name)", menu: .tabs,
                                    run: { $0.apply(ws) }))
        }
        for tag in model.knownTags {
            list.append(CommandSpec(id: "find-tag-\(tag.name)", title: "Find Files Tagged \(tag.name)", menu: .tag,
                                    run: { $0.showTagged(tag) }))
        }
        return list + tagToggles + sortCommands
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { menuItems(.file) }
        CommandGroup(replacing: .saveItem) {}     // drop the system Close (⌘W is Close Tab)

        CommandGroup(replacing: .undoRedo) {
            Button(model.undoName.map { "Undo \($0)" } ?? "Undo") {
                if textEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undo() }
            }
            .keyboardShortcut("z")
            Button(model.redoName.map { "Redo \($0)" } ?? "Redo") {
                if textEditing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) { menuItems(.edit) }
        CommandMenu("Go") { menuItems(.go) }
        CommandMenu("Commander") {
            menuItems(.commander)
            Menu("Tag") { menuItems(.tag) }
        }
        CommandGroup(after: .toolbar) {
            menuItems(.view)
            Menu("Sort By") { menuItems(.sort) }
        }
        CommandMenu("Tabs") {
            menuItems(.tabs)
            if !model.workspaces.isEmpty {
                Menu("Open Workspace") {
                    ForEach(model.workspaces) { ws in Button(ws.name) { model.apply(ws) } }
                }
                Menu("Delete Workspace") {
                    ForEach(model.workspaces) { ws in Button(ws.name) { model.deleteWorkspace(ws) } }
                }
            }
        }
    }

    /// True when typing goes somewhere other than the file lists: a text field (rename prompt,
    /// palette, path bar, filter) or the terminal panel.
    private var textEditing: Bool {
        let r = NSApp.keyWindow?.firstResponder
        return r is NSTextView || r is TerminalView
    }

    @ViewBuilder
    private func menuItems(_ menu: CommandSpec.Menu) -> some View {
        ForEach(CommandRegistry.specs(menu)) { spec in
            if spec.dividerBefore { Divider() }
            Button(spec.title) {
                if textEditing, let action = spec.textAction {
                    NSApp.sendAction(action, to: nil, from: nil)
                } else {
                    spec.run(model)
                }
            }
                .keyboardShortcut(spec.shortcut)
                .disabled(model.isPrompting || !spec.enabled(model))
        }
    }
}
