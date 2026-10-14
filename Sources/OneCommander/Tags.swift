import AppKit
import SwiftUI

/// A Finder tag. `color` is Finder's label index: 0 none, 1 gray, 2 green, 3 purple,
/// 4 blue, 5 yellow, 6 red, 7 orange.
struct FileTag: Hashable, Sendable, Codable, Identifiable {
    let name: String
    let color: Int
    var id: String { name }

    /// Finder's seven colour tags, in Finder's menu order.
    static let standard: [FileTag] = [6, 7, 5, 2, 4, 3, 1].map { FileTag(name: TagStore.labelName($0), color: $0) }

    var swiftUIColor: Color {
        switch color {
        case 1: return .gray
        case 2: return .green
        case 3: return .purple
        case 4: return .blue
        case 5: return .yellow
        case 6: return .red
        case 7: return .orange
        default: return .secondary
        }
    }
}

/// Reads and writes tags in the same extended attribute Finder uses, so colours of custom
/// tags survive and Finder/Spotlight see the change.
enum TagStore {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    private static let englishLabels = ["", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]
    private static let localizedLabels: [String] = {
        let names = NSWorkspace.shared.fileLabels
        return names.count == 8 ? names : englishLabels
    }()

    static func labelName(_ index: Int) -> String {
        localizedLabels.indices.contains(index) ? localizedLabels[index] : ""
    }

    /// Colour for a tag stored without one: Finder's colour names map to their colour.
    static func defaultColor(for name: String) -> Int {
        if let i = localizedLabels.firstIndex(of: name), i > 0 { return i }
        if let i = englishLabels.firstIndex(of: name), i > 0 { return i }
        return 0
    }

    static func read(_ url: URL) -> [FileTag] {
        url.withUnsafeFileSystemRepresentation { path -> [FileTag] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read == size,
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
            else { return [] }
            return list.compactMap(parse)
        }
    }

    static func parse(_ raw: String) -> FileTag? {
        let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, !first.isEmpty else { return nil }
        let name = String(first)
        let color = parts.count > 1 ? Int(parts[1]) ?? 0 : defaultColor(for: name)
        return FileTag(name: name, color: color)
    }

    static func write(_ tags: [FileTag], to url: URL) throws {
        let status: Int32 = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            if tags.isEmpty {
                let rc = removexattr(path, attribute, XATTR_NOFOLLOW)
                return rc == 0 || errno == ENOATTR ? 0 : rc
            }
            let list = tags.map { $0.color > 0 ? "\($0.name)\n\($0.color)" : $0.name }
            let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
            return data.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
        }
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

// MARK: - Views

/// Small coloured dots shown after a file name.
struct TagDots: View {
    let tags: [FileTag]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags.prefix(3)) { tag in
                Circle()
                    .fill(tag.color == 0 ? Color.clear : tag.swiftUIColor)
                    .overlay(Circle().strokeBorder(tag.color == 0 ? Color.secondary : Color.black.opacity(0.15), lineWidth: 1))
                    .frame(width: 8, height: 8)
            }
        }
        .help(tags.map(\.name).joined(separator: ", "))
    }
}

/// Popover/sheet for toggling tags on the selection and creating new ones.
struct TagEditor: View {
    @Environment(AppModel.self) private var model
    let urls: [URL]
    @State private var current: [URL: [FileTag]] = [:]
    @State private var newName = ""
    @State private var newColor = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(urls.count == 1 ? "Tags for “\(urls[0].lastPathComponent)”" : "Tags for \(urls.count) items")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.knownTags) { tag in
                        Button {
                            model.toggleTag(tag, on: urls)
                            reload()
                        } label: {
                            HStack {
                                Image(systemName: stateSymbol(tag))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 16)
                                Circle().fill(tag.color == 0 ? Color.clear : tag.swiftUIColor)
                                    .overlay(Circle().strokeBorder(.secondary, lineWidth: tag.color == 0 ? 1 : 0))
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
            Divider()
            HStack(spacing: 6) {
                TextField("New tag", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNew)
                ForEach(0..<8) { c in
                    let tag = FileTag(name: "", color: c)
                    Circle()
                        .fill(c == 0 ? Color.clear : tag.swiftUIColor)
                        .overlay(Circle().strokeBorder(newColor == c ? Color.primary : .secondary.opacity(0.5),
                                                       lineWidth: newColor == c ? 2 : 1))
                        .frame(width: 14, height: 14)
                        .onTapGesture { newColor = c }
                }
                Button("Add", action: addNew).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear(perform: reload)
    }

    private func reload() {
        current = Dictionary(uniqueKeysWithValues: urls.map { ($0, TagStore.read($0)) })
    }

    /// All selected items have it / some do / none do.
    private func stateSymbol(_ tag: FileTag) -> String {
        let count = urls.filter { current[$0]?.contains { $0.name == tag.name } == true }.count
        if count == 0 { return "square" }
        return count == urls.count ? "checkmark.square.fill" : "minus.square.fill"
    }

    private func addNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let tag = FileTag(name: name, color: newColor == 0 ? TagStore.defaultColor(for: name) : newColor)
        model.rememberTag(tag)
        if !urls.allSatisfy({ current[$0]?.contains { $0.name == name } == true }) {
            model.toggleTag(tag, on: urls)
        }
        newName = ""
        newColor = 0
        reload()
    }
}

/// Files carrying a tag, found with Spotlight.
@MainActor @Observable
final class TagSearch {
    let tag: FileTag
    private(set) var results: [URL] = []
    private(set) var searching = true
    @ObservationIgnored private let query = NSMetadataQuery()
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(tag: FileTag) {
        self.tag = tag
        query.predicate = NSPredicate(format: "%K == %@", "kMDItemUserTags", tag.name)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        query.start()
    }

    private func finish() {
        query.stop()
        results = (query.results as? [NSMetadataItem] ?? [])
            .compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            .map { URL(fileURLWithPath: $0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        searching = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

struct TagResultsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search: TagSearch
    @State private var selection: URL?

    init(tag: FileTag) { _search = State(initialValue: TagSearch(tag: tag)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(search.tag.swiftUIColor).frame(width: 12, height: 12)
                Text("Tagged “\(search.tag.name)”").font(.headline)
                Spacer()
                if search.searching { ProgressView().controlSize(.small) } else {
                    Text("\(search.results.count) items").foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            List(search.results, id: \.self, selection: $selection) { url in
                HStack {
                    Image(nsImage: IconCache.icon(for: url.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent)
                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .contextMenu {
                    Button("Show in Pane") { reveal(url) }
                    Button("Open") { model.open(url) }
                }
            }
            .contextMenu(forSelectionType: URL.self) { _ in } primaryAction: { urls in
                if let url = urls.first { reveal(url) }
            }
            Divider()
            HStack {
                Text("Double-click to show in the active pane").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open") { selection.map(model.open) }.disabled(selection == nil)
                Button("Show in Pane") { selection.map(reveal) }.disabled(selection == nil)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
    }

    private func reveal(_ url: URL) {
        model.active.navigate(to: url)
        dismiss()
    }
}
