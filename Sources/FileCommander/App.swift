import Quartz
import SwiftUI

@main
struct FileCommanderApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    init() {
        // Folder arguments are parsed by AppModel; stop AppKit from also treating them as
        // documents to open, which can stop SwiftUI creating the window.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        Window("fileCommander", id: "main") {
            ContentView()
                .environment(model)
        }
        .defaultSize(width: 1400, height: 800)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Searches are instant from the start when an earlier session built the index.
        MainActor.assumeIsolated { SearchIndex.warmUp() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Quick Look asks the responder chain (which ends at the app delegate) who controls it.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookPanelController.shared
            panel.delegate = QuickLookPanelController.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focusedPane: Int?
    @AppStorage("previewWidth") private var previewWidth: Double = 300
    @AppStorage("terminalHeight") private var terminalHeight: Double = 220

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 280)
        } detail: {
            VStack(spacing: 0) {
            HStack(spacing: 0) {
                PaneView(side: model.sides[0], index: 0, focus: $focusedPane)
                if model.dualPane {
                    Divider()
                    PaneView(side: model.sides[1], index: 1, focus: $focusedPane)
                }
                if model.showPreview {
                    ResizeHandle(width: $previewWidth)
                    PreviewPanel(cursor: model.active.cursorItem, selection: model.active.current.selectedItems)
                        .frame(width: previewWidth)
                }
            }
            if model.showTerminal {
                ResizeHandle(width: $terminalHeight, axis: .vertical, range: 100...700)
                TerminalPanel()
                    .frame(height: terminalHeight)
            }
            }
        }
        .tint(model.theme.accent)
        .onChange(of: model.active.currentDirectory) { model.paneDirectoryChanged() }
        .onChange(of: model.activePane) { model.paneDirectoryChanged() }
        .onChange(of: model.active.cursorItem?.path) { model.updateQuickLook() }
        .onAppear { model.applyTheme() }
        .alert("Delete from server?", isPresented: remoteDeleteShown) {
            Button("Delete", role: .destructive) {
                if let urls = model.confirmRemoteDelete { model.deleteRemote(urls) }
                model.confirmRemoteDelete = nil
            }
            Button("Cancel", role: .cancel) { model.confirmRemoteDelete = nil }
        } message: {
            let n = model.confirmRemoteDelete?.count ?? 0
            Text("\(n == 1 ? "“\(model.confirmRemoteDelete?.first?.lastPathComponent ?? "")”" : "\(n) items") will be deleted permanently — servers have no Trash and this can't be undone. Folders must be empty.")
        }
        .navigationTitle(model.active.title)
        .toolbar { toolbar }
        .overlay(alignment: .top) { palette }
        .onAppear { focusedPane = 0 }
        .onChange(of: focusedPane) { _, pane in
            if let pane { model.activePane = pane }
        }
        .onChange(of: model.activePane) { _, pane in
            if focusedPane != nil || model.palette == nil { focusedPane = pane }
        }
        .onChange(of: model.palette == nil) { _, closed in
            if closed { focusedPane = model.activePane }
        }
        .alert(promptTitle, isPresented: promptShown) {
            TextField(promptPlaceholder, text: $model.promptText)
            Button(promptAction) { model.commitPrompt(); focusedPane = model.activePane }
            Button("Cancel", role: .cancel) { model.prompt = nil; focusedPane = model.activePane }
        } message: {
            if case .selectMatching = model.prompt {
                Text("Wildcards: * and ?. Separate several patterns with ;")
            }
        }
        .alert("Something went wrong", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: conflictJob) { job in
            ConflictSheet(job: job)
        }
        .background {
            // A second presenter, so tool sheets and transfer-conflict sheets can coexist.
            Color.clear.sheet(item: $model.sheet, onDismiss: { focusedPane = model.activePane }) { sheet in
                switch sheet {
                case .batchRename(let urls): BatchRenameView(urls: urls)
                case .tags(let urls): TagEditor(urls: urls)
                case .tagResults(let tag): TagResultsView(tag: tag)
                case .compare(let session): CompareView(session: session)
                case .search(let session): SearchView(session: session)
                case .connect: ConnectSheet()
                case .info(let urls): InfoView(urls: urls)
                }
            }
        }
    }

    @ViewBuilder
    private var palette: some View {
        if let mode = model.palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { model.palette = nil }
                CommandPalette(mode: mode)
                    .padding(.top, 40)
                    .id(mode == .goTo ? "goto" : "commands")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .primaryAction) {
            JobsButton(center: model.jobs)
            Button { model.beginNewFolder() } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New Folder (⇧⌘N)")
            Button { model.sendToOtherPane(move: false) } label: {
                Label("Copy to Other Pane", systemImage: "doc.on.doc")
            }
            .help("Copy to other pane (F5)")
            .disabled(!model.dualPane || !model.hasSelection)
            Button { model.sendToOtherPane(move: true) } label: {
                Label("Move to Other Pane", systemImage: "arrow.right.doc.on.clipboard")
            }
            .help("Move to other pane (F6)")
            .disabled(!model.dualPane || !model.hasSelection)
            Button { model.trash() } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move to Trash (⌘⌫)")
            .disabled(!model.hasSelection)

            Divider()

            Picker("View", selection: Binding(get: { model.active.viewMode }, set: { model.setViewMode($0) })) {
                Label("Columns", systemImage: "rectangle.split.3x1").tag(Pane.ViewMode.columns)
                Label("List", systemImage: "list.bullet").tag(Pane.ViewMode.details)
            }
            .pickerStyle(.segmented)
            .help("View as columns (⌘3) or list (⌘2)")
            Button { model.beginSearch() } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search in files (⇧⌘F) · Filter this folder (⌘F)")
            Button { model.palette = .commands } label: {
                Label("Command Palette", systemImage: "command")
            }
            .help("Command Palette (⇧⌘P) · Go to Folder (⌘P)")
            Toggle(isOn: $model.showHidden) {
                Label("Hidden Files", systemImage: model.showHidden ? "eye" : "eye.slash")
            }
            .help("Show hidden files (⇧⌘.)")
            Button { model.swapPanes() } label: {
                Label("Swap Panes", systemImage: "arrow.left.arrow.right")
            }
            .help("Swap panes (⌥⌘U)")
            .disabled(!model.dualPane)
            Toggle(isOn: $model.dualPane) {
                Label("Dual Pane", systemImage: "rectangle.split.2x1")
            }
            .help("Dual pane (⌥⌘D)")
            Toggle(isOn: $model.showPreview) {
                Label("Preview", systemImage: "sidebar.right")
            }
            .help("Preview panel (⌥⌘P)")
        }
    }

    private var conflictJob: Binding<FileJob?> {
        Binding(get: { model.jobs.conflictJob }, set: { _ in })
    }

    private var remoteDeleteShown: Binding<Bool> {
        Binding(get: { model.confirmRemoteDelete != nil }, set: { if !$0 { model.confirmRemoteDelete = nil } })
    }

    private var promptShown: Binding<Bool> {
        Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var promptTitle: String {
        switch model.prompt {
        case .rename: return "Rename"
        case .newFolder: return "New Folder"
        case .selectMatching(let add): return add ? "Select Matching" : "Deselect Matching"
        case .saveWorkspace: return "Save Workspace"
        case nil: return ""
        }
    }

    private var promptPlaceholder: String {
        switch model.prompt {
        case .selectMatching: return "*.pdf; *.docx"
        case .saveWorkspace: return "Workspace name"
        default: return "Name"
        }
    }

    private var promptAction: String {
        switch model.prompt {
        case .rename: return "Rename"
        case .newFolder: return "Create"
        case .selectMatching(let add): return add ? "Select" : "Deselect"
        case .saveWorkspace: return "Save"
        case nil: return "OK"
        }
    }
}

/// Draggable vertical divider that resizes the panel to its right.
struct ResizeHandle: View {
    @Binding var width: Double          // or height, for .vertical
    var axis: Axis = .horizontal
    var range: ClosedRange<Double> = 200...700
    @State private var start: Double?

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                if start == nil { start = width }
                                let delta = axis == .horizontal ? g.translation.width : g.translation.height
                                width = min(max((start ?? width) - delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in start = nil }))
    }
}
