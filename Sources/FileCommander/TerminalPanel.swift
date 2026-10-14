import AppKit
import SwiftTerm
import SwiftUI

/// Owns one shell session for the terminal panel. Lives in the model, so hiding the panel
/// doesn't kill the shell.
@MainActor
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    /// Folder the shell is in, as reported by the shell itself (OSC 7).
    private(set) var directory: String?
    var onDirectoryChange: ((URL) -> Void)?
    var onExit: (() -> Void)?
    private(set) var running = false

    override init() {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        super.init()
        view.processDelegate = self
    }

    static var userShell: String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    func start(in dir: URL) {
        guard !running else { return }
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        // macOS's /etc/zshrc loads /etc/zshrc_Apple_Terminal for this value, which reports the
        // current folder after every command (OSC 7). That's how the pane follows `cd`.
        env.append("TERM_PROGRAM=Apple_Terminal")
        env.append("LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")")
        let shell = Self.userShell
        view.startProcess(executable: shell, args: ["-l"], environment: env,
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir.path)
        directory = dir.path
        running = true
    }

    /// True when the shell itself is in the foreground (not vim, a build, ssh…), so it's
    /// safe to type a `cd` for it.
    var shellIsIdle: Bool {
        guard running, let p = view.process, p.childfd >= 0 else { return false }
        return tcgetpgrp(p.childfd) == p.shellPid
    }

    /// Changes the shell's folder, only when it's idle at its prompt.
    func cd(_ dir: URL) {
        guard dir.path != directory, shellIsIdle, Self.isSafeToType(dir.path) else { return }
        // ^U clears anything half-typed on the prompt line first.
        view.send(txt: "\u{15} cd -- \(Self.shellQuote(dir.path))\r")
        directory = dir.path
    }

    /// The `cd` is typed as keystrokes, so control characters in a folder name (allowed on
    /// APFS) would act as editing keys rather than text: such folders aren't followed.
    static func isSafeToType(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func applyTheme(_ theme: Theme) {
        view.nativeBackgroundColor = theme.terminalBackground
        view.nativeForegroundColor = theme.terminalForeground
        view.caretColor = theme.accentNS
        view.font = NSFont.monospacedSystemFont(ofSize: theme.terminalFontSize, weight: .regular)
    }

    func focus() { view.window?.makeFirstResponder(view) }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        let path = url.path
        MainActor.assumeIsolated {
            guard path != self.directory else { return }
            self.directory = path
            self.onDirectoryChange?(URL(fileURLWithPath: path))
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            running = false
            onExit?()
        }
    }
}

/// Hosts the controller's terminal view in SwiftUI.
struct TerminalHost: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let v = controller.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TerminalPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(model.terminalTitle).lineLimit(1).truncationMode(.head)
                Spacer()
                Toggle("Follow pane", isOn: $model.terminalSync)
                    .toggleStyle(.checkbox)
                    .help("Keep the terminal and the active pane in the same folder (both ways)")
                Button { model.toggleTerminal() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide terminal (⌃`)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
            TerminalHost(controller: model.terminal)
                .background(Color(nsColor: model.theme.terminalBackground))
        }
    }
}
