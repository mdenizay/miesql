import AppKit
import SwiftUI
import MieSQLCore

/// Colours and fonts shared by the whole app. Everything resolves against the system
/// appearance, so light and dark come for free and follow the user's accent colour.
enum Theme {

    /// Accent per engine, used on sidebar icons and connection badges.
    static func color(for kind: DatabaseKind) -> Color {
        switch kind {
        case .postgres: return Color(red: 0.20, green: 0.45, blue: 0.72)
        case .mysql: return Color(red: 0.87, green: 0.55, blue: 0.13)
        case .mariadb: return Color(red: 0.47, green: 0.31, blue: 0.55)
        case .sqlite: return Color(red: 0.24, green: 0.58, blue: 0.45)
        }
    }

    /// A user-chosen connection colour, parsed from `#RRGGBB`.
    static func color(hex: String?) -> Color? {
        guard var hex, !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// The presets offered in the connection editor's colour picker.
    static let connectionColors: [(name: String, hex: String)] = [
        ("Graphite", "8E8E93"),
        ("Blue", "3B82F6"),
        ("Teal", "14B8A6"),
        ("Green", "22C55E"),
        ("Yellow", "EAB308"),
        ("Orange", "F97316"),
        ("Red", "EF4444"),
        ("Purple", "A855F7")
    ]

    static func editorFont(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func gridFont(size: Double) -> NSFont {
        NSFont.systemFont(ofSize: size)
    }

    // MARK: - Syntax colours

    /// Resolved against the effective appearance so the editor recolours on a theme switch.
    static func syntaxColor(for kind: SQLTokenKind, appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch kind {
        case .keyword:
            return isDark ? NSColor(srgbRed: 0.98, green: 0.47, blue: 0.65, alpha: 1)
                          : NSColor(srgbRed: 0.68, green: 0.13, blue: 0.42, alpha: 1)
        case .type:
            return isDark ? NSColor(srgbRed: 0.51, green: 0.78, blue: 0.96, alpha: 1)
                          : NSColor(srgbRed: 0.12, green: 0.38, blue: 0.64, alpha: 1)
        case .function:
            return isDark ? NSColor(srgbRed: 0.72, green: 0.65, blue: 0.98, alpha: 1)
                          : NSColor(srgbRed: 0.40, green: 0.29, blue: 0.72, alpha: 1)
        case .string:
            return isDark ? NSColor(srgbRed: 0.60, green: 0.85, blue: 0.55, alpha: 1)
                          : NSColor(srgbRed: 0.16, green: 0.49, blue: 0.20, alpha: 1)
        case .number:
            return isDark ? NSColor(srgbRed: 0.98, green: 0.76, blue: 0.45, alpha: 1)
                          : NSColor(srgbRed: 0.66, green: 0.36, blue: 0.04, alpha: 1)
        case .comment:
            return isDark ? NSColor(srgbRed: 0.53, green: 0.57, blue: 0.62, alpha: 1)
                          : NSColor(srgbRed: 0.45, green: 0.49, blue: 0.54, alpha: 1)
        case .parameter:
            return isDark ? NSColor(srgbRed: 0.95, green: 0.62, blue: 0.36, alpha: 1)
                          : NSColor(srgbRed: 0.72, green: 0.35, blue: 0.08, alpha: 1)
        case .quotedIdentifier:
            return isDark ? NSColor(srgbRed: 0.76, green: 0.88, blue: 0.98, alpha: 1)
                          : NSColor(srgbRed: 0.20, green: 0.32, blue: 0.45, alpha: 1)
        case .identifier, .punctuation, .whitespace:
            return NSColor.labelColor
        }
    }
}

extension View {
    /// Matches the small, dense control metrics used through the inspector panes.
    func denseFormStyle() -> some View {
        self.controlSize(.small)
            .textFieldStyle(.roundedBorder)
    }
}
