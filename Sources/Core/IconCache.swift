import AppKit
import UniformTypeIdentifiers

/// Icons are expensive to fetch and highly repetitive in a file list, so they are cached
/// by *kind* rather than by path. Only bundles get a per-path entry, since each app
/// carries its own artwork.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage] = [:]
    private let side: CGFloat = 16

    private init() {}

    func icon(for entry: FileEntry) -> NSImage {
        let key = Self.key(for: entry)
        if let hit = cache[key] { return hit }
        // Copy before resizing: named and symbol images come back shared, and mutating
        // `size` on those would resize them for the whole process.
        let image = resolve(entry).copy() as? NSImage ?? resolve(entry)
        image.size = NSSize(width: side, height: side)
        cache[key] = image
        return image
    }

    private static func key(for entry: FileEntry) -> String {
        if entry.isParent { return "\u{1}parent" }
        // Bundles are visually unique; everything else collapses to its kind.
        if entry.isPackage { return "\u{1}pkg:" + entry.url.path }
        if entry.isDirectory { return "\u{1}dir" }
        return entry.ext.isEmpty ? "\u{1}file" : "ext:" + entry.ext
    }

    private func resolve(_ entry: FileEntry) -> NSImage {
        // The parent row uses a plain folder icon rather than a symbol: NSTableCellView
        // installs its own constraints on the `imageView` outlet, and a symbol's taller
        // intrinsic height wins against a 16pt height constraint. The `..` name and the
        // `<UP>` size column already identify the row.
        if entry.isParent { return NSWorkspace.shared.icon(for: .folder) }
        // Covers packages too — they are directories with their own artwork.
        if entry.isDirectory { return NSWorkspace.shared.icon(forFile: entry.url.path) }
        if !entry.ext.isEmpty, let type = UTType(filenameExtension: entry.ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
