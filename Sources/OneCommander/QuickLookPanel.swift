import Quartz

/// Drives the system Quick Look window (⌘Y). Arrow keys in the window move the pane's
/// selection, so you can flip through files like in Finder.
@MainActor
final class QuickLookPanelController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPanelController()
    private(set) var urls: [URL] = []
    /// Called with -1 / +1 when the user presses ↑/↓ (or ←/→) inside the Quick Look window.
    var onStep: ((Int) -> Void)?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(_ urls: [URL]) {
        self.urls = urls
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        // If nothing in the responder chain claimed the panel, drive it directly.
        if panel.dataSource == nil {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
    }

    func update(_ urls: [URL]) {
        guard isVisible, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let delta: Int
        switch Int(event.keyCode) {
        case 125, 124: delta = 1        // ↓ →
        case 126, 123: delta = -1       // ↑ ←
        default: return false
        }
        MainActor.assumeIsolated { onStep?(delta) }
        return true
    }
}
