import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var volumes: [URL] = []

    private var places: [URL] {
        let fm = FileManager.default
        var list = [fm.homeDirectoryForCurrentUser]
        for dir: FileManager.SearchPathDirectory in [.desktopDirectory, .documentDirectory, .downloadsDirectory] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first { list.append(u) }
        }
        list.append(URL(fileURLWithPath: "/Applications"))
        let icloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: icloud.path) { list.append(icloud) }
        return list
    }

    var body: some View {
        List {
            Section("Places") {
                ForEach(places, id: \.path) { row($0) }
            }
            Section("Favorites") {
                if model.favorites.isEmpty {
                    Text("Drop folders here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(model.favorites, id: \.path) { url in
                    row(url).contextMenu {
                        Button("Remove from Favorites") { model.removeFavorite(url) }
                    }
                }
            }
            Section("Locations") {
                ForEach(volumes, id: \.path) { url in
                    HStack {
                        row(url)
                        if isEjectable(url) {
                            Button { model.eject(url) } label: { Image(systemName: "eject.fill").font(.caption) }
                                .buttonStyle(.borderless)
                                .help("Eject \(FileManager.default.displayName(atPath: url.path))")
                        }
                    }
                }
            }
            Section("Servers") {
                ForEach(model.servers) { server in
                    Button {
                        model.connect(server) { if let e = $0 { model.errorMessage = e } }
                    } label: {
                        Label(server.name, systemImage: server.symbol)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove from Sidebar") { model.forget(server) } }
                }
                Button {
                    model.sheet = .connect
                } label: {
                    Label("Connect to Server…", systemImage: "plus.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Section("Tags") {
                ForEach(model.knownTags) { tag in
                    Button {
                        model.showTagged(tag)
                    } label: {
                        Label {
                            Text(tag.name).lineLimit(1)
                        } icon: {
                            Circle()
                                .fill(tag.color == 0 ? Color.clear : tag.swiftUIColor)
                                .overlay(Circle().strokeBorder(.secondary, lineWidth: tag.color == 0 ? 1 : 0))
                                .frame(width: 10, height: 10)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Find files tagged \(tag.name)")
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            folders.forEach(model.addFavorite)
            return !folders.isEmpty
        }
        .onAppear(perform: loadVolumes)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in loadVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in loadVolumes() }
    }

    private func row(_ url: URL) -> some View {
        let isCurrent = model.active.rootURL.path == url.path
        return Button {
            model.go(to: url)
        } label: {
            Label {
                Text(FileManager.default.displayName(atPath: url.path)).lineLimit(1)
            } icon: {
                Image(nsImage: IconCache.icon(for: url.path)).resizable().frame(width: 16, height: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : .regular)
    }

    private func isEjectable(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey])
        if v?.volumeIsRootFileSystem == true { return false }
        return v?.volumeIsEjectable == true || v?.volumeIsRemovable == true || v?.volumeIsLocal == false
    }

    private func loadVolumes() {
        volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
    }
}

// MARK: - Preview

struct PreviewPanel: View {
    let cursor: FileItem?
    let selection: [FileItem]

    var body: some View {
        VStack(spacing: 0) {
            if selection.count > 1 {
                MultiSelectionSummary(items: selection)
            } else if let item = cursor {
                PreviewContent(item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                FileInfo(item: item)
            } else {
                Spacer()
                Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.tertiary)
                Text("No selection").foregroundStyle(.secondary).padding(.top, 4)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Quick Look for real files; zip entries are extracted to a temp copy first.
private struct PreviewContent: View {
    let item: FileItem
    @State private var extracted: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if !item.isVirtual {
                QuickLookView(url: item.url)
            } else if item.isFolder || failed {
                VStack(spacing: 8) {
                    FileIcon(item: item, size: 96)
                    if failed { Text("Can't preview this entry").font(.caption).foregroundStyle(.secondary) }
                }
            } else if let extracted {
                QuickLookView(url: extracted)
            } else {
                ProgressView()
            }
        }
        .task(id: item.path) {
            extracted = nil
            failed = false
            guard item.isVirtual, !item.isFolder else { return }
            let url = item.url
            let result = await Task.detached { () -> URL? in
                if let remote = SFTPRef.resolve(url) { return try? SFTPClient.fetchForViewing(remote) }
                guard let ref = ArchiveRef.resolve(url) else { return nil }
                return try? ZipArchive.extractForViewing(ref.zip, inner: ref.inner)
            }.value
            if let result { extracted = result } else { failed = true }
        }
    }
}

private struct MultiSelectionSummary: View {
    let items: [FileItem]

    var body: some View {
        let folders = items.filter(\.isFolder).count
        let files = items.count - folders
        let bytes = items.compactMap(\.size).reduce(0, +)
        VStack(spacing: 10) {
            Spacer()
            ZStack {
                ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { i, item in
                    Image(nsImage: Thumbnails.cached(item.path) ?? IconCache.icon(for: item.path))
                        .resizable().frame(width: 72, height: 72)
                        .rotationEffect(.degrees(Double(i - 1) * 8))
                        .offset(x: CGFloat(i - 1) * 14)
                }
            }
            .frame(height: 100)
            Text("\(items.count) items selected").font(.headline)
            Group {
                if files > 0 { Text("\(files) file\(files == 1 ? "" : "s") · \(FileOps.formatSize(bytes))") }
                if folders > 0 { Text("\(folders) folder\(folders == 1 ? "" : "s") (sizes not counted)") }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct FileInfo: View {
    @Environment(AppModel.self) private var model
    let item: FileItem
    @State private var folderCount: Int?

    var body: some View {
        let v = try? item.url.resourceValues(forKeys: [
            .localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .totalFileSizeKey,
        ])
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(.headline).lineLimit(2).textSelection(.enabled)
            if item.isVirtual {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    info("Kind", item.isFolder ? "Folder" : item.kind)
                    if let size = item.size { info("Size", FileOps.formatSize(size)) }
                    info("Modified", item.modified?.formatted(date: .abbreviated, time: .shortened))
                    info("In", SFTPRef.resolve(item.url).map { "SFTP · \($0.target)" }
                         ?? ArchiveRef.resolve(item.url).map { $0.zip.lastPathComponent + " (read-only)" })
                }
                .font(.caption)
            } else {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                info("Kind", v?.localizedTypeDescription)
                if !item.tags.isEmpty {
                    GridRow {
                        Text("Tags").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            ForEach(item.tags) { tag in
                                HStack(spacing: 3) {
                                    Circle().fill(tag.swiftUIColor).frame(width: 7, height: 7)
                                    Text(tag.name)
                                }
                            }
                        }
                    }
                }
                if item.isFolder {
                    info("Contains", folderCount.map { "\($0) items" } ?? "…")
                    if let size = model.sizes.size(item.path) {
                        info("Size", FileOps.formatSize(size))
                    } else {
                        GridRow {
                            Text("Size").foregroundStyle(.secondary)
                            if model.sizes.computing.contains(item.path) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Button("Calculate") { model.sizes.request([item.url]) }
                                    .controlSize(.mini)
                            }
                        }
                    }
                } else if let size = v?.totalFileSize {
                    info("Size", FileOps.formatSize(Int64(size)))
                }
                info("Created", v?.creationDate?.formatted(date: .abbreviated, time: .shortened))
                info("Modified", v?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened))
                info("Where", (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
            }
            .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: item.path) {
            folderCount = nil
            guard item.isFolder, !item.isVirtual else { return }
            let path = item.path
            folderCount = await Task.detached {
                (try? FileManager.default.contentsOfDirectory(atPath: path).count) ?? 0
            }.value
        }
    }

    @ViewBuilder
    private func info(_ label: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).lineLimit(3).textSelection(.enabled)
            }
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
