import SwiftUI

// MARK: - Engine

struct CompareOptions: Equatable, Sendable {
    var recursive = true
    var byContent = false
    var includeHidden = false
}

struct CompareEntry: Identifiable, Sendable, Equatable {
    enum Status: Sendable { case equal, leftNewer, rightNewer, differs, leftOnly, rightOnly }

    struct Side: Sendable, Equatable {
        let size: Int64?
        let modified: Date?
        let isDir: Bool
    }

    let relPath: String
    let left: Side?
    let right: Side?
    let status: Status
    var id: String { relPath }
    var isDir: Bool { (left ?? right)?.isDir ?? false }
}

enum SyncDirection: Sendable { case none, toRight, toLeft }

enum CompareEngine {
    /// Same size and modification times within 2 s (FAT/SMB timestamp slop) count as equal.
    static let dateTolerance: TimeInterval = 2

    static func compare(_ left: URL, _ right: URL, _ o: CompareOptions,
                        isCancelled: () -> Bool = { false }) -> [CompareEntry] {
        var out: [CompareEntry] = []
        walk(left, right, rel: "", o, &out, isCancelled)
        return out.sorted { $0.relPath.localizedStandardCompare($1.relPath) == .orderedAscending }
    }

    private static func listing(_ dir: URL, _ o: CompareOptions) -> [String: (URL, CompareEntry.Side)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: o.includeHidden ? [] : [.skipsHiddenFiles])) ?? []
        var map: [String: (URL, CompareEntry.Side)] = [:]
        for url in urls {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory == true && v?.isPackage != true
            let size: Int64? = v?.isDirectory == true ? nil : Int64(v?.fileSize ?? 0)
            // Case-insensitive key: "Report.pdf" and "report.pdf" are the same file on APFS.
            map[url.lastPathComponent.lowercased()] = (url, .init(size: size, modified: v?.contentModificationDate, isDir: isDir))
        }
        return map
    }

    private static func walk(_ l: URL, _ r: URL, rel: String, _ o: CompareOptions,
                             _ out: inout [CompareEntry], _ isCancelled: () -> Bool) {
        if isCancelled() { return }
        let left = listing(l, o), right = listing(r, o)
        for key in Set(left.keys).union(right.keys) {
            let a = left[key], b = right[key]
            let name = (a?.0 ?? b!.0).lastPathComponent
            let path = rel.isEmpty ? name : rel + "/" + name
            switch (a, b) {
            case let (a?, nil):
                out.append(CompareEntry(relPath: path, left: a.1, right: nil, status: .leftOnly))
            case let (nil, b?):
                out.append(CompareEntry(relPath: path, left: nil, right: b.1, status: .rightOnly))
            case let (a?, b?):
                if a.1.isDir && b.1.isDir {
                    if o.recursive { walk(a.0, b.0, rel: path, o, &out, isCancelled) }
                } else if a.1.isDir != b.1.isDir {
                    out.append(CompareEntry(relPath: path, left: a.1, right: b.1, status: .differs))
                } else {
                    out.append(CompareEntry(relPath: path, left: a.1, right: b.1, status: status(a, b, o)))
                }
            default:
                break
            }
        }
    }

    private static func status(_ a: (URL, CompareEntry.Side), _ b: (URL, CompareEntry.Side),
                               _ o: CompareOptions) -> CompareEntry.Status {
        let ta = a.1.modified ?? .distantPast, tb = b.1.modified ?? .distantPast
        let sameTime = abs(ta.timeIntervalSince(tb)) <= dateTolerance
        if a.1.size == b.1.size {
            if o.byContent {
                if FileManager.default.contentsEqual(atPath: a.0.path, andPath: b.0.path) { return .equal }
            } else if sameTime {
                return .equal
            }
        }
        if sameTime { return .differs }
        return ta > tb ? .leftNewer : .rightNewer
    }

    /// Total Commander's defaults: copy what's missing, and newer over older.
    static func defaultDirection(_ s: CompareEntry.Status) -> SyncDirection {
        switch s {
        case .leftOnly, .leftNewer: return .toRight
        case .rightOnly, .rightNewer: return .toLeft
        case .equal, .differs: return .none
        }
    }

    /// Turns chosen directions into copy jobs' items.
    static func transfers(_ entries: [CompareEntry], _ directions: [String: SyncDirection],
                          left: URL, right: URL) -> [TransferItem] {
        entries.compactMap { e in
            let parent = (e.relPath as NSString).deletingLastPathComponent
            switch directions[e.id] ?? .none {
            case .toRight:
                return TransferItem(source: left.appendingPathComponent(e.relPath),
                                    destinationDir: parent.isEmpty ? right : right.appendingPathComponent(parent))
            case .toLeft:
                return TransferItem(source: right.appendingPathComponent(e.relPath),
                                    destinationDir: parent.isEmpty ? left : left.appendingPathComponent(parent))
            case .none:
                return nil
            }
        }
    }
}

// MARK: - Session

@MainActor @Observable
final class CompareSession: Identifiable {
    let id = UUID()
    let left: URL
    let right: URL
    var options = CompareOptions()
    private(set) var entries: [CompareEntry] = []
    var directions: [String: SyncDirection] = [:]
    private(set) var comparing = false
    private(set) var syncing = false
    var showEqual = false
    var showDifferent = true
    var showLeftOnly = true
    var showRightOnly = true
    @ObservationIgnored private var generation = 0

    init(left: URL, right: URL) {
        self.left = left
        self.right = right
    }

    var visible: [CompareEntry] {
        entries.filter { e in
            switch e.status {
            case .equal: return showEqual
            case .leftNewer, .rightNewer, .differs: return showDifferent
            case .leftOnly: return showLeftOnly
            case .rightOnly: return showRightOnly
            }
        }
    }

    var toRightCount: Int { directions.values.filter { $0 == .toRight }.count }
    var toLeftCount: Int { directions.values.filter { $0 == .toLeft }.count }

    func run() {
        generation += 1
        let gen = generation, l = left, r = right, o = options
        comparing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = CompareEngine.compare(l, r, o)
            await self?.apply(result, generation: gen)
        }
    }

    private func apply(_ result: [CompareEntry], generation gen: Int) {
        guard gen == generation else { return }     // options changed meanwhile
        entries = result
        directions = Dictionary(uniqueKeysWithValues: result.map { ($0.id, CompareEngine.defaultDirection($0.status)) })
        comparing = false
    }

    func set(_ dir: SyncDirection, for ids: Set<String>) {
        for id in ids { directions[id] = dir }
    }

    func cycle(_ id: String) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        let order: [SyncDirection] = [.toRight, .toLeft, .none]
        let cur = directions[id] ?? .none
        var next = order[(order.firstIndex(of: cur)! + 1) % order.count]
        // Can't copy from a side that doesn't have the item.
        if next == .toRight && e.left == nil { next = .toLeft }
        if next == .toLeft && e.right == nil { next = .none }
        directions[id] = next
    }

    func sync(using model: AppModel) {
        let items = CompareEngine.transfers(entries, directions, left: left, right: right)
        guard !items.isEmpty else { return }
        syncing = true
        model.runSync(items, title: "Synchronizing “\(left.lastPathComponent)” ⇄ “\(right.lastPathComponent)”") { [weak self] in
            self?.syncing = false
            self?.run()
        }
    }
}

// MARK: - View

struct CompareView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: CompareSession
    @State private var selection = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            table
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { session.run() }
        .onChange(of: session.options) { session.run() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(session.left.path(percentEncoded: false), systemImage: "rectangle.lefthalf.filled")
                    .lineLimit(1).truncationMode(.head)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Label(session.right.path(percentEncoded: false), systemImage: "rectangle.righthalf.filled")
                    .lineLimit(1).truncationMode(.head)
            }
            .font(.callout)
            HStack(spacing: 14) {
                Toggle("Subfolders", isOn: $session.options.recursive)
                Toggle("Compare contents", isOn: $session.options.byContent)
                    .help("Byte-compare files of equal size instead of trusting dates")
                Toggle("Hidden files", isOn: $session.options.includeHidden)
                Divider().frame(height: 16)
                Text("Show:").foregroundStyle(.secondary)
                Toggle("Equal", isOn: $session.showEqual)
                Toggle("Different", isOn: $session.showDifferent)
                Toggle("Left only", isOn: $session.showLeftOnly)
                Toggle("Right only", isOn: $session.showRightOnly)
                Spacer()
                if session.comparing { ProgressView().controlSize(.small) }
                Button("Compare Again") { session.run() }.disabled(session.comparing)
            }
            .toggleStyle(.checkbox)
        }
        .padding(14)
    }

    private var table: some View {
        Table(session.visible, selection: $selection) {
            TableColumn("Name") { e in
                HStack(spacing: 5) {
                    Image(systemName: e.isDir ? "folder" : "doc").foregroundStyle(.secondary)
                    Text(e.relPath).lineLimit(1).truncationMode(.head)
                }
            }
            .width(min: 200, ideal: 290)
            TableColumn("Left") { e in sideText(e.left) }.width(min: 130, ideal: 150)
            TableColumn("") { e in
                Button { session.cycle(e.id) } label: { directionIcon(e) }
                    .buttonStyle(.borderless)
                    .help("Click to change what happens")
            }
            .width(54)
            TableColumn("Right") { e in sideText(e.right) }.width(min: 130, ideal: 150)
            TableColumn("Status") { e in Text(statusText(e.status)).foregroundStyle(.secondary) }.width(min: 80, ideal: 90)
        }
        .overlay {
            if !session.comparing && session.visible.isEmpty {
                ContentUnavailableView(
                    session.entries.isEmpty ? "Folders are identical" : "Nothing to show",
                    systemImage: "checkmark.circle",
                    description: Text(session.entries.isEmpty ? "No differences found." : "Adjust the Show filters."))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Selected:").foregroundStyle(.secondary)
            Button { session.set(.toRight, for: selection) } label: { Image(systemName: "arrow.right") }
                .help("Copy selected rows to the right")
            Button { session.set(.toLeft, for: selection) } label: { Image(systemName: "arrow.left") }
                .help("Copy selected rows to the left")
            Button("Skip") { session.set(.none, for: selection) }
            Spacer()
            Text("Files that get overwritten go to the Trash · Undo with ⌘Z")
                .font(.caption).foregroundStyle(.secondary)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(syncLabel) { session.sync(using: model) }
                .keyboardShortcut(.defaultAction)
                .disabled(session.syncing || session.comparing || session.toRightCount + session.toLeftCount == 0)
        }
        .padding(12)
    }

    private var syncLabel: String {
        if session.syncing { return "Synchronizing…" }
        return "Synchronize (\(session.toRightCount) →, \(session.toLeftCount) ←)"
    }

    private func sideText(_ s: CompareEntry.Side?) -> some View {
        Group {
            if let s {
                HStack(spacing: 6) {
                    Text(s.isDir ? "Folder" : FileOps.formatSize(s.size ?? 0)).monospacedDigit()
                    Text(s.modified?.formatted(date: .numeric, time: .shortened) ?? "").foregroundStyle(.secondary)
                }
                .font(.caption)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func directionIcon(_ e: CompareEntry) -> some View {
        switch session.directions[e.id] ?? .none {
        case .toRight: Image(systemName: "arrow.right.circle.fill").foregroundStyle(.blue)
        case .toLeft: Image(systemName: "arrow.left.circle.fill").foregroundStyle(.green)
        case .none: Image(systemName: e.status == .equal ? "equal.circle" : "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private func statusText(_ s: CompareEntry.Status) -> String {
        switch s {
        case .equal: return "Equal"
        case .leftNewer: return "Left newer"
        case .rightNewer: return "Right newer"
        case .differs: return "Different"
        case .leftOnly: return "Left only"
        case .rightOnly: return "Right only"
        }
    }
}
