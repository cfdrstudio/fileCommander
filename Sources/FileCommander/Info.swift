import SwiftUI
import UniformTypeIdentifiers

/// "Open With" submenu: the default app first, then every other app that can open all the items.
struct OpenWithMenu: View {
    @Environment(AppModel.self) private var model
    let urls: [URL]

    var body: some View {
        Menu("Open With") {
            let apps = Self.apps(for: urls)
            if let first = apps.first {
                appButton(first, isDefault: true)
                if apps.count > 1 { Divider() }
            }
            ForEach(apps.dropFirst(), id: \.self) { appButton($0, isDefault: false) }
            Divider()
            Button("Other…", action: chooseOther)
        }
    }

    /// Apps that can open every item, default app of the first item first.
    static func apps(for urls: [URL]) -> [URL] {
        guard let first = urls.first else { return [] }
        var common = NSWorkspace.shared.urlsForApplications(toOpen: first)
        for u in urls.dropFirst() {
            let set = Set(NSWorkspace.shared.urlsForApplications(toOpen: u))
            common = common.filter(set.contains)
        }
        var seen = Set<String>()
        common = common.filter { seen.insert($0.lastPathComponent).inserted }   // one entry per app name
        if let def = NSWorkspace.shared.urlForApplication(toOpen: first), let i = common.firstIndex(of: def) {
            common.remove(at: i)
            common.insert(def, at: 0)
        }
        return common.prefix(30).map { $0 }
    }

    private func appButton(_ app: URL, isDefault: Bool) -> some View {
        Button {
            model.open(urls, with: app)
        } label: {
            let name = FileManager.default.displayName(atPath: app.path)
            Label {
                Text(isDefault ? "\(name) (default)" : name)
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
            }
        }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        if panel.runModal() == .OK, let app = panel.url { model.open(urls, with: app) }
    }
}

/// fileCommander's Get Info: general facts, permissions, default app and tags.
struct InfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(urls.prefix(20), id: \.self) { url in
                        InfoCard(url: url)
                        if url != urls.prefix(20).last { Divider() }
                    }
                    if urls.count > 20 {
                        Text("…and \(urls.count - 20) more").foregroundStyle(.secondary)
                    }
                }
                .padding(2)
            }
            HStack {
                Button("Show in Finder") { model.revealInFinder(urls) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460, height: min(160 + CGFloat(urls.count) * 260, 640))
    }
}

private struct InfoCard: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        let keys: Set<URLResourceKey> = [
            .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .contentAccessDateKey,
            .totalFileSizeKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .contentTypeKey,
        ]
        let v = try? url.resourceValues(forKeys: keys)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let isDir = v?.isDirectory == true
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.headline).textSelection(.enabled)
                    Text(v?.localizedTypeDescription ?? "").foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if isDir && v?.isPackage != true {
                    row("Size", model.sizes.size(url.path).map(FileOps.formatSize) ?? "Calculating…")
                } else if let size = v?.totalFileSize {
                    row("Size", "\(FileOps.formatSize(Int64(size))) (\(size.formatted()) bytes)")
                }
                row("Where", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                row("Created", v?.creationDate?.formatted(date: .long, time: .shortened))
                row("Modified", v?.contentModificationDate?.formatted(date: .long, time: .shortened))
                row("Last opened", v?.contentAccessDate?.formatted(date: .long, time: .shortened))
                if v?.isSymbolicLink == true,
                   let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                    row("Points to", dest)
                }
                if let perms = attrs?[.posixPermissions] as? Int {
                    row("Permissions", "\(Self.permissionString(perms, isDir: isDir))  (\(String(perms, radix: 8)))")
                }
                row("Owner", [attrs?[.ownerAccountName] as? String, attrs?[.groupOwnerAccountName] as? String]
                        .compactMap { $0 }.joined(separator: " : "))
                if !isDir, let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
                    row("Opens with", FileManager.default.displayName(atPath: app.path))
                }
                if let type = v?.contentType { row("Type", type.identifier) }
                let tags = TagStore.read(url)
                if !tags.isEmpty {
                    GridRow {
                        Text("Tags").foregroundStyle(.secondary)
                        TagDots(tags: tags)
                    }
                }
                if v?.isHidden == true { row("Hidden", "Yes") }
            }
            .font(.callout)
        }
        .onAppear { if isDir && v?.isPackage != true { model.sizes.request([url]) } }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled).lineLimit(3)
            }
        }
    }

    /// 0o755 → "drwxr-xr-x"
    static func permissionString(_ p: Int, isDir: Bool) -> String {
        var s = isDir ? "d" : "-"
        for shift in [6, 3, 0] {
            let bits = (p >> shift) & 7
            s += (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
        }
        return s
    }
}

/// Lets tests reach the permission formatter.
enum InfoCardTestHook {
    static func permissions(_ p: Int, dir: Bool) -> String { InfoCard.permissionString(p, isDir: dir) }
}
