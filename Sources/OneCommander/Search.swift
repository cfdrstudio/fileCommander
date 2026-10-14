import SwiftUI

struct SearchOptions: Equatable, Sendable {
    var name = ""               // wildcard or substring; empty = any
    var text = ""               // file contents must contain this; empty = don't look inside
    var caseSensitive = false
    var includeHidden = false
    var useSpotlight = false
    var maxFileSize: Int64 = 20 * 1024 * 1024

    var isEmpty: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty && text.isEmpty }
}

struct SearchHit: Identifiable, Sendable, Equatable {
    let url: URL
    var line: Int?
    var snippet: String?
    var id: String { url.path }
}

enum SearchEngine {
    /// Walks `root`, calling `emit` with batches of hits. Blocking; run off the main thread.
    static func scan(_ root: URL, _ o: SearchOptions, control: JobControl,
                     progress: @escaping @Sendable (Int) -> Void, emit: @escaping @Sendable ([SearchHit]) -> Void) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !o.includeHidden { options.insert(.skipsHiddenFiles) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options,
                                                     errorHandler: { _, _ in true }) else { return }
        let name = o.name.trimmingCharacters(in: .whitespaces)
        var batch: [SearchHit] = []
        var scanned = 0
        var lastFlush = Date()
        while let url = e.nextObject() as? URL {
            if control.cancelled { break }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if [".git", "node_modules", ".build"].contains(url.lastPathComponent) { e.skipDescendants() }
                if o.text.isEmpty, !name.isEmpty, matchName(name, url.lastPathComponent, o) {
                    batch.append(SearchHit(url: url))
                }
                continue
            }
            guard v?.isRegularFile == true else { continue }
            scanned += 1
            if !name.isEmpty && !matchName(name, url.lastPathComponent, o) { continue }
            if o.text.isEmpty {
                batch.append(SearchHit(url: url))
            } else if Int64(v?.fileSize ?? 0) <= o.maxFileSize, let hit = matchContents(url, o) {
                batch.append(hit)
            }
            if !batch.isEmpty && (batch.count >= 50 || Date().timeIntervalSince(lastFlush) > 0.2) {
                emit(batch)
                batch = []
                lastFlush = Date()
                progress(scanned)
            } else if scanned % 500 == 0 {
                progress(scanned)
            }
        }
        if !batch.isEmpty { emit(batch) }
        progress(scanned)
    }

    static func matchName(_ pattern: String, _ name: String, _ o: SearchOptions) -> Bool {
        if pattern.contains("*") || pattern.contains("?") {
            return fnmatch(o.caseSensitive ? pattern : pattern.lowercased(), o.caseSensitive ? name : name.lowercased(), 0) == 0
        }
        return name.range(of: pattern, options: o.caseSensitive ? [] : [.caseInsensitive]) != nil
    }

    /// First matching line in a text file; binary files (a NUL in the first 8 KB) are skipped.
    static func matchContents(_ url: URL, _ o: SearchOptions) -> SearchHit? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: o.text, options: o.caseSensitive ? [] : [.caseInsensitive]) else { return nil }
        let lineStart = text[..<r.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[r.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let lineNumber = text[..<r.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var snippet = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
        if snippet.count > 160 {
            // Keep the match visible in long lines.
            let matchOffset = text.distance(from: lineStart, to: r.lowerBound)
            let start = snippet.index(snippet.startIndex, offsetBy: max(0, min(matchOffset - 40, snippet.count - 160)))
            snippet = "…" + String(snippet[start...].prefix(160)) + "…"
        }
        return SearchHit(url: url, line: lineNumber, snippet: snippet)
    }
}

@MainActor @Observable
final class SearchSession: Identifiable {
    let id = UUID()
    let root: URL
    var options = SearchOptions()
    private(set) var hits: [SearchHit] = []
    private(set) var running = false
    private(set) var scanned = 0
    @ObservationIgnored private var control = JobControl()
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var generation = 0

    init(root: URL) { self.root = root }

    func start() {
        stop()
        hits = []
        scanned = 0
        guard !options.isEmpty else { return }
        generation += 1
        running = true
        if options.useSpotlight { startSpotlight(); return }
        let control = JobControl()
        self.control = control
        let gen = generation, root = root, o = options
        let me = WeakRef(self)
        Task.detached(priority: .userInitiated) {
            SearchEngine.scan(root, o, control: control,
                progress: { n in Task { @MainActor in me.value?.progress(n, gen) } },
                emit: { batch in Task { @MainActor in me.value?.append(batch, gen) } })
            await me.value?.done(gen)
        }
    }

    func stop() {
        control.cancelled = true
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        query = nil
        running = false
    }

    private func progress(_ n: Int, _ gen: Int) { if gen == generation { scanned = n } }
    private func append(_ batch: [SearchHit], _ gen: Int) { if gen == generation { hits += batch } }
    private func done(_ gen: Int) { if gen == generation { running = false } }

    private func startSpotlight() {
        let q = NSMetadataQuery()
        var parts: [NSPredicate] = []
        let name = options.name.trimmingCharacters(in: .whitespaces)
        let flags = options.caseSensitive ? "" : "c"
        if !name.isEmpty {
            let pattern = name.contains("*") || name.contains("?") ? name : "*\(name)*"
            parts.append(NSPredicate(format: "%K LIKE[\(flags)] %@", NSMetadataItemFSNameKey, pattern))
        }
        if !options.text.isEmpty {
            parts.append(NSPredicate(format: "%K CONTAINS[\(flags)d] %@", "kMDItemTextContent", options.text))
        }
        q.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        q.searchScopes = [root]
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishSpotlight() }
        }
        query = q
        q.start()
    }

    private func finishSpotlight() {
        guard let q = query else { return }
        q.stop()
        hits = (q.results as? [NSMetadataItem] ?? [])
            .compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            .map { SearchHit(url: URL(fileURLWithPath: $0)) }
        scanned = hits.count
        running = false
    }
}

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: SearchSession
    @State private var selection: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Search in “\(session.root.lastPathComponent)”").font(.headline)
                HStack {
                    TextField("File name (e.g. report or *.pdf)", text: $session.options.name)
                        .focused($nameFocused)
                    TextField("Containing text", text: $session.options.text)
                }
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.start() }
                HStack(spacing: 14) {
                    Toggle("Match case", isOn: $session.options.caseSensitive)
                    Toggle("Hidden files", isOn: $session.options.includeHidden)
                    Toggle("Use Spotlight (faster, indexed folders only)", isOn: $session.options.useSpotlight)
                    Spacer()
                    if session.running {
                        ProgressView().controlSize(.small)
                        Button("Stop") { session.stop() }
                    } else {
                        Button("Search") { session.start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(session.options.isEmpty)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(14)
            Divider()
            List(session.hits, selection: $selection) { hit in
                HStack(alignment: .top, spacing: 8) {
                    Image(nsImage: IconCache.icon(for: hit.url.path)).resizable().frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.url.lastPathComponent)
                        Text(relative(hit.url)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let snippet = hit.snippet {
                            Text("\(hit.line.map { "\($0): " } ?? "")\(snippet)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .tag(hit.id)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("Show in Pane") { reveal(id) }
                    Button("Open") { model.open(URL(fileURLWithPath: id)) }
                    Button("Copy Path") { model.copyPaths([URL(fileURLWithPath: id)]) }
                }
            } primaryAction: { ids in
                if let id = ids.first { reveal(id) }
            }
            .overlay {
                if !session.running && session.hits.isEmpty && session.scanned > 0 {
                    ContentUnavailableView.search
                }
            }
            Divider()
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open") { selection.map { model.open(URL(fileURLWithPath: $0)) } }.disabled(selection == nil)
                Button("Show in Pane") { selection.map(reveal) }.disabled(selection == nil)
                Button("Close") { session.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 560)
        .onAppear { nameFocused = true }
        .onDisappear { session.stop() }
    }

    private var status: String {
        let found = "\(session.hits.count) found"
        if session.options.useSpotlight { return session.running ? "Asking Spotlight…" : found }
        return session.running ? "\(found) · \(session.scanned) files scanned…" : "\(found) in \(session.scanned) files"
    }

    private func relative(_ url: URL) -> String {
        // Resolve symlinks on both sides (/tmp vs /private/tmp would otherwise never match).
        let base = session.root.resolvingSymlinksInPath().path
        let p = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return p.hasPrefix(base) ? "." + p.dropFirst(base.count) : p
    }

    private func reveal(_ path: String) {
        model.active.navigate(to: URL(fileURLWithPath: path))
        session.stop()
        dismiss()
    }
}

/// Lets background callbacks reach a main-actor object without keeping it alive.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
