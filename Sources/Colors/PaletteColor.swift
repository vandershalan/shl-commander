import AppKit
import SwiftUI

/// A colour from the fixed palette, stored by name (`blue-500`, `neutral-300`, `black`) so a
/// hand-edited file reads as itself.
///
/// The palette follows the Tailwind CSS scale: 12 hues ordered around the colour wheel
/// (columns) × shades 200–800 (rows), plus a neutral row from white to black — the same one
/// shl-todo offers.
struct PaletteColor: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    /// An unknown name falls back to a neutral grey rather than failing the whole file.
    init(rawValue: String) {
        self.rawValue = Self.hexByName[rawValue] != nil ? rawValue : "neutral-500"
    }

    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// sRGB hex value.
    var hex: UInt32 { Self.hexByName[rawValue] ?? 0x737373 }

    /// "Blue 500", "Black".
    var label: String {
        rawValue.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var color: Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    // MARK: - Palette

    static let hues = [
        "red", "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "blue", "indigo",
        "purple", "pink",
    ]
    static let shades = [200, 300, 400, 500, 600, 700, 800]

    private static let neutralRow: [(String, UInt32)] = [
        ("white", 0xFFFFFF), ("neutral-100", 0xF5F5F5), ("neutral-200", 0xE5E5E5),
        ("neutral-300", 0xD4D4D4), ("neutral-400", 0xA3A3A3), ("neutral-500", 0x737373),
        ("neutral-600", 0x525252), ("neutral-700", 0x404040), ("neutral-800", 0x262626),
        ("neutral-900", 0x171717), ("neutral-950", 0x0A0A0A), ("black", 0x000000),
    ]

    /// Tailwind CSS v3 values, shades 200...800 per hue.
    private static let hueHex: [String: [UInt32]] = [
        "red": [0xFECACA, 0xFCA5A5, 0xF87171, 0xEF4444, 0xDC2626, 0xB91C1C, 0x991B1B],
        "orange": [0xFED7AA, 0xFDBA74, 0xFB923C, 0xF97316, 0xEA580C, 0xC2410C, 0x9A3412],
        "amber": [0xFDE68A, 0xFCD34D, 0xFBBF24, 0xF59E0B, 0xD97706, 0xB45309, 0x92400E],
        "yellow": [0xFEF08A, 0xFDE047, 0xFACC15, 0xEAB308, 0xCA8A04, 0xA16207, 0x854D0E],
        "lime": [0xD9F99D, 0xBEF264, 0xA3E635, 0x84CC16, 0x65A30D, 0x4D7C0F, 0x3F6212],
        "green": [0xBBF7D0, 0x86EFAC, 0x4ADE80, 0x22C55E, 0x16A34A, 0x15803D, 0x166534],
        "teal": [0x99F6E4, 0x5EEAD4, 0x2DD4BF, 0x14B8A6, 0x0D9488, 0x0F766E, 0x115E59],
        "cyan": [0xA5F3FC, 0x67E8F9, 0x22D3EE, 0x06B6D4, 0x0891B2, 0x0E7490, 0x155E75],
        "blue": [0xBFDBFE, 0x93C5FD, 0x60A5FA, 0x3B82F6, 0x2563EB, 0x1D4ED8, 0x1E40AF],
        "indigo": [0xC7D2FE, 0xA5B4FC, 0x818CF8, 0x6366F1, 0x4F46E5, 0x4338CA, 0x3730A3],
        "purple": [0xE9D5FF, 0xD8B4FE, 0xC084FC, 0xA855F7, 0x9333EA, 0x7E22CE, 0x6B21A8],
        "pink": [0xFBCFE8, 0xF9A8D4, 0xF472B6, 0xEC4899, 0xDB2777, 0xBE185D, 0x9D174D],
    ]

    /// Picker layout: first row neutrals (white → black), then one row per shade (light → dark).
    static let grid: [[PaletteColor]] =
        [neutralRow.map { PaletteColor(rawValue: $0.0) }]
        + shades.map { shade in hues.map { PaletteColor(rawValue: "\($0)-\(shade)") } }

    /// Colours handed out to new rules in turn: mid shades, spread around the wheel so
    /// neighbours in the list do not look alike.
    static let rotation: [PaletteColor] = [0, 8, 5, 1, 10, 6, 3, 9, 11, 2, 7, 4].map {
        PaletteColor(rawValue: "\(hues[$0])-400")
    }

    private static let hexByName: [String: UInt32] = {
        var map = Dictionary(uniqueKeysWithValues: neutralRow)
        for (hue, values) in hueHex {
            for (shade, hex) in zip(shades, values) { map["\(hue)-\(shade)"] = hex }
        }
        return map
    }()
}
