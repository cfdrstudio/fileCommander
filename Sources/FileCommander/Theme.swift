import AppKit
import SwiftUI

/// A colour theme. `appearance` nil follows the system light/dark setting.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let appearance: NSAppearance.Name?
    let paneBackgroundNS: NSColor?      // nil = system text background
    let accentNS: NSColor
    let selectionTextNS: NSColor
    let terminalBackground: NSColor
    let terminalForeground: NSColor
    var terminalFontSize: CGFloat = 12

    var paneBackground: Color { paneBackgroundNS.map(Color.init(nsColor:)) ?? Color(nsColor: .textBackgroundColor) }
    var accent: Color { Color(nsColor: accentNS) }
    var selectionText: Color { Color(nsColor: selectionTextNS) }
    var colorScheme: ColorScheme? {
        switch appearance {
        case .darkAqua?: return .dark
        case .aqua?: return .light
        default: return nil
        }
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let all: [Theme] = [
        Theme(id: "system", name: "System", appearance: nil, paneBackgroundNS: nil,
              accentNS: .controlAccentColor, selectionTextNS: .white,
              terminalBackground: .textBackgroundColor, terminalForeground: .textColor),
        Theme(id: "graphite", name: "Graphite", appearance: .darkAqua, paneBackgroundNS: hex(0x1E1F22),
              accentNS: hex(0x6B7280), selectionTextNS: .white,
              terminalBackground: hex(0x17181A), terminalForeground: hex(0xD6D6D6)),
        Theme(id: "midnight", name: "Midnight", appearance: .darkAqua, paneBackgroundNS: hex(0x0F172A),
              accentNS: hex(0x3B82F6), selectionTextNS: .white,
              terminalBackground: hex(0x0B1222), terminalForeground: hex(0xCBD5E1)),
        Theme(id: "nord", name: "Nord", appearance: .darkAqua, paneBackgroundNS: hex(0x2E3440),
              accentNS: hex(0x5E81AC), selectionTextNS: hex(0xECEFF4),
              terminalBackground: hex(0x2E3440), terminalForeground: hex(0xD8DEE9)),
        Theme(id: "dracula", name: "Dracula", appearance: .darkAqua, paneBackgroundNS: hex(0x282A36),
              accentNS: hex(0x8B6FD1), selectionTextNS: .white,
              terminalBackground: hex(0x21222C), terminalForeground: hex(0xF8F8F2)),
        Theme(id: "solarized", name: "Solarized Light", appearance: .aqua, paneBackgroundNS: hex(0xFDF6E3),
              accentNS: hex(0x268BD2), selectionTextNS: .white,
              terminalBackground: hex(0xFDF6E3), terminalForeground: hex(0x586E75)),
        Theme(id: "paper", name: "Paper", appearance: .aqua, paneBackgroundNS: hex(0xFAF8F3),
              accentNS: hex(0xD97706), selectionTextNS: .white,
              terminalBackground: hex(0xFFFFFF), terminalForeground: hex(0x1F2937)),
    ]

    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? all[0] }
}

enum Density: String, CaseIterable, Identifiable {
    case compact = "Compact", regular = "Regular", roomy = "Roomy"
    var id: String { rawValue }
    var rowPadding: CGFloat {
        switch self {
        case .compact: return 1.5
        case .regular: return 3
        case .roomy: return 5.5
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section("Theme") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                        ForEach(Theme.all) { theme in
                            ThemeSwatch(theme: theme, selected: model.themeID == theme.id)
                                .onTapGesture { model.themeID = theme.id }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Lists") {
                    Picker("Density", selection: $model.density) {
                        ForEach(Density.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Slider(value: $model.fontSize, in: 11...16, step: 0.5) {
                        Text("Text size")
                    } minimumValueLabel: {
                        Text("A").font(.system(size: 10))
                    } maximumValueLabel: {
                        Text("A").font(.system(size: 15))
                    }
                    Text("Sample row — Quarterly Report.pdf")
                        .font(.system(size: model.fontSize))
                        .padding(.vertical, model.density.rowPadding)
                        .padding(.horizontal, 7)
                        .background(RoundedRectangle(cornerRadius: 5).fill(model.theme.accent))
                        .foregroundStyle(model.theme.selectionText)
                }
                Section("Terminal") {
                    Slider(value: $model.terminalFontSize, in: 10...18, step: 1) { Text("Font size \(Int(model.terminalFontSize))") }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 520, height: 520)
    }
}

private struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == 1 ? theme.accent : Color(nsColor: theme.terminalForeground).opacity(0.25))
                        .frame(height: 7)
                        .frame(maxWidth: i == 2 ? 50 : .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: theme.paneBackgroundNS ?? .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                                                    lineWidth: selected ? 2.5 : 1))
            Text(theme.name).font(.caption)
        }
        .contentShape(Rectangle())
    }
}
