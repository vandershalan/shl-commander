import Foundation

/// Shared, pre-built formatters. Creating a `DateFormatter` per row is a measurable cost
/// in a 20k-row panel.
///
/// Main-actor isolated because `DateFormatter` and `ByteCountFormatter` are not `Sendable`;
/// every caller is a table cell or a SwiftUI view, so nothing is given up.
@MainActor
enum Formatters {
    /// `2026-07-27 20:31` — fixed width, sorts visually the same way the column sorts.
    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let byteCount: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func size(_ bytes: Int64) -> String {
        byteCount.string(fromByteCount: bytes)
    }

    /// What the Size column shows for a row. A directory reads `<DIR>` until it has been
    /// measured, and `…` while it is being measured.
    static func sizeColumn(for entry: FileEntry, directorySize: Int64?, measuring: Bool) -> String {
        if entry.isParent { return "<UP>" }
        guard entry.isDirectory else { return size(entry.size) }
        if let directorySize { return size(directorySize) }
        return measuring ? "…" : "<DIR>"
    }

    static func dateColumn(for entry: FileEntry) -> String {
        entry.isParent ? "" : timestamp.string(from: entry.modified)
    }
}
