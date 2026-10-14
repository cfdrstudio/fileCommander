import SwiftUI

/// Total Commander-style multi-rename: a name/extension mask with placeholders, then
/// find & replace, then case conversion.
struct RenameOptions: Equatable, Sendable {
    enum Case: String, CaseIterable, Sendable {
        case unchanged = "Unchanged", lower = "lowercase", upper = "UPPERCASE"
        case title = "Title Case", sentence = "First letter upper"
    }

    var nameMask = "[N]"
    var extMask = "[E]"
    var find = ""
    var replace = ""
    var regex = false
    var caseSensitive = false
    var textCase: Case = .unchanged
    var counterStart = 1
    var counterStep = 1
    var counterDigits = 1
}

struct RenameRow: Identifiable, Sendable {
    let url: URL
    let newName: String
    var problem: String?
    var id: String { url.path }
    var changed: Bool { newName != url.lastPathComponent }
}

enum RenamePlan {
    /// Placeholders: [N] name, [N2-5] / [N3-] / [N-2] characters of the name (1-based,
    /// negative counts from the end), [E] extension, [C] counter, [P] parent folder,
    /// [YMD] and [hms] modification date/time.
    static func compute(_ urls: [URL], _ o: RenameOptions) -> [RenameRow] {
        let regex: NSRegularExpression? = {
            guard o.regex, !o.find.isEmpty else { return nil }
            return try? NSRegularExpression(pattern: o.find, options: o.caseSensitive ? [] : [.caseInsensitive])
        }()
        let regexError = o.regex && !o.find.isEmpty && regex == nil

        var rows: [RenameRow] = urls.enumerated().map { i, url in
            let counter = o.counterStart + i * o.counterStep
            var name = apply(o.nameMask, url: url, counter: counter, o: o)
            let ext = apply(o.extMask, url: url, counter: counter, o: o)
            if !ext.isEmpty { name += "." + ext }
            if !o.find.isEmpty {
                if let regex {
                    name = regex.stringByReplacingMatches(
                        in: name, range: NSRange(name.startIndex..., in: name), withTemplate: o.replace)
                } else if !o.regex {
                    name = name.replacingOccurrences(
                        of: o.find, with: o.replace, options: o.caseSensitive ? [] : [.caseInsensitive])
                }
            }
            name = convertCase(name, o.textCase)
            return RenameRow(url: url, newName: name, problem: regexError ? "Invalid regular expression" : nil)
        }

        // Validate: names, clashes within the batch, and clashes with other files on disk.
        // Comparisons are case-insensitive, like the default APFS volume.
        let renamedPaths = Set(urls.map { $0.standardizedFileURL.path.lowercased() })
        var seen: [String: Int] = [:]
        var listings: [String: Set<String>] = [:]
        for i in rows.indices where rows[i].problem == nil {
            let row = rows[i]
            let name = row.newName
            if name.isEmpty || name == "." || name == ".." {
                rows[i].problem = "Empty name"
            } else if name.contains("/") || name.contains(":") {
                rows[i].problem = "Contains / or :"
            } else if name.utf8.count > 255 {
                rows[i].problem = "Name too long"
            }
            if rows[i].problem != nil { continue }
            let dir = row.url.deletingLastPathComponent().standardizedFileURL.path
            let key = dir.lowercased() + "/" + name.lowercased()
            if let other = seen[key] {
                rows[i].problem = "Same name as “\(rows[other].url.lastPathComponent)”"
                if rows[other].problem == nil { rows[other].problem = "Same name as “\(row.url.lastPathComponent)”" }
                continue
            }
            seen[key] = i
            guard row.changed else { continue }
            if listings[dir] == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                listings[dir] = Set(names.map { $0.lowercased() })
            }
            if listings[dir]!.contains(name.lowercased()) && !renamedPaths.contains(key) {
                rows[i].problem = "Already exists"
            }
        }
        return rows
    }

    private static let token = try! NSRegularExpression(pattern: #"\[(N(-?\d+)?(-(-?\d*))?|E|C|P|YMD|hms)\]"#)

    static func apply(_ mask: String, url: URL, counter: Int, o: RenameOptions) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let ns = mask as NSString
        var out = ""
        var last = 0
        for m in token.matches(in: mask, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            last = m.range.location + m.range.length
            let body = ns.substring(with: m.range(at: 1))
            switch body {
            case "E": out += ext
            case "P": out += url.deletingLastPathComponent().lastPathComponent
            case "C":
                let s = String(abs(counter))
                out += (counter < 0 ? "-" : "") + String(repeating: "0", count: max(0, o.counterDigits - s.count)) + s
            case "YMD", "hms":
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = body == "YMD" ? "yyyy-MM-dd" : "HH-mm-ss"
                out += f.string(from: date)
            default:   // N, N2, N2-5, N3-, N-2
                out += substring(base, from: m.range(at: 2), ns, rangeEnd: m.range(at: 3), m.range(at: 4))
            }
        }
        out += ns.substring(from: last)
        return out
    }

    /// Resolves [Na], [Na-b], [Na-] against `base` (1-based, negative = from the end).
    private static func substring(_ base: String, from startR: NSRange, _ ns: NSString,
                                  rangeEnd: NSRange, _ endR: NSRange) -> String {
        guard startR.location != NSNotFound, let a = Int(ns.substring(with: startR)) else { return base }
        let chars = Array(base)
        func index(_ n: Int) -> Int { n < 0 ? chars.count + n : n - 1 }
        let start = max(index(a), 0)
        var end = start          // single character by default
        if rangeEnd.location != NSNotFound {
            let e = endR.location != NSNotFound ? ns.substring(with: endR) : ""
            end = e.isEmpty ? chars.count - 1 : min(index(Int(e) ?? chars.count), chars.count - 1)
        }
        guard start < chars.count, end >= start else { return "" }
        return String(chars[start...end])
    }

    static func convertCase(_ name: String, _ c: RenameOptions.Case) -> String {
        switch c {
        case .unchanged: return name
        case .lower: return name.lowercased()
        case .upper: return name.uppercased()
        case .title: return name.capitalized
        case .sentence: return name.prefix(1).uppercased() + name.dropFirst().lowercased()
        }
    }
}

// MARK: - View

struct BatchRenameView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    @State private var o = RenameOptions()
    @State private var rows: [RenameRow] = []

    static let placeholders: [(String, String)] = [
        ("[N]", "name without extension"),
        ("[N1-3]", "characters 1 to 3 of the name"),
        ("[N-4-]", "last 4 characters of the name"),
        ("[E]", "extension"),
        ("[C]", "counter (see right)"),
        ("[P]", "parent folder name"),
        ("[YMD]", "modified date, 2026-10-14"),
        ("[hms]", "modified time, 16-30-05"),
    ]

    private var problems: Int { rows.filter { $0.problem != nil }.count }
    private var changes: Int { rows.filter { $0.changed && $0.problem == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename \(urls.count) Items").font(.title3.bold())
            HStack(alignment: .top, spacing: 20) {
                Form {
                    Section {
                        TextField("Name", text: $o.nameMask)
                        TextField("Extension", text: $o.extMask)
                        Menu("Insert placeholder") {
                            ForEach(Self.placeholders, id: \.0) { token, help in
                                Button("\(token)  —  \(help)") { o.nameMask += token }
                            }
                        }
                    }
                    Section {
                        TextField("Find", text: $o.find)
                        TextField("Replace with", text: $o.replace)
                        HStack {
                            Toggle("Regex", isOn: $o.regex)
                            Toggle("Match case", isOn: $o.caseSensitive)
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(width: 340, height: 300)
                Form {
                    Section {
                        Picker("Case", selection: $o.textCase) {
                            ForEach(RenameOptions.Case.allCases, id: \.self) { Text($0.rawValue) }
                        }
                    }
                    Section("Counter [C]") {
                        Stepper("Start at \(o.counterStart)", value: $o.counterStart, in: 0...999_999)
                        Stepper("Step \(o.counterStep)", value: $o.counterStep, in: -100...100)
                        Stepper("Digits \(o.counterDigits)", value: $o.counterDigits, in: 1...10)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(width: 290, height: 300)
            }
            Table(rows) {
                TableColumn("Current name") { Text($0.url.lastPathComponent).lineLimit(1) }
                TableColumn("New name") { row in
                    Text(row.newName)
                        .lineLimit(1)
                        .foregroundStyle(row.problem != nil ? Color.red : row.changed ? Color.primary : Color.secondary)
                }
                TableColumn("") { row in
                    if let p = row.problem {
                        Label(p, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.caption).lineLimit(1)
                    }
                }
                .width(min: 120, ideal: 160)
            }
            .frame(minHeight: 220)
            HStack {
                Text(problems > 0 ? "\(problems) problem\(problems == 1 ? "" : "s") to fix" :
                        "\(changes) of \(urls.count) will change · Undo with ⌘Z")
                    .foregroundStyle(problems > 0 ? .red : .secondary)
                Spacer()
                Button("Reset") { o = RenameOptions() }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.batchRename(rows)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problems > 0 || changes == 0)
            }
        }
        .padding(18)
        .frame(width: 700, height: 720)
        .onAppear { rows = RenamePlan.compute(urls, o) }
        .onChange(of: o) { _, new in rows = RenamePlan.compute(urls, new) }
    }
}
