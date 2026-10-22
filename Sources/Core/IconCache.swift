import AppKit
import UniformTypeIdentifiers

/// Icons are expensive to fetch and highly repetitive in a file list, so they are cached
/// by *kind* rather than by path. Only bundles get a per-path entry, since each app
/// carries its own artwork.
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var cache: [String: NSImage] = [:]

    private init() {}

    /// `side` is in points; the zoom level decides it, so each size is cached on its own.
    func icon(for entry: FileEntry, side: CGFloat = 16) -> NSImage {
        let key = "\(Self.key(for: entry))@\(side)"
        if let hit = cache[key] { return hit }
        let image = Self.rasterize(resolve(entry), side: side)
        cache[key] = image
        return image
    }

    /// Workspace icons are lazy, multi-resolution images: drawn as they come, every new
    /// image view decodes the artwork again and converts it to the display's colour space,
    /// which was the largest single cost of showing a listing. Drawing each icon once into a
    /// bitmap already in the screen's colour space and pixel format leaves Core Animation
    /// nothing to do but upload it.
    private static func rasterize(_ source: NSImage, side: CGFloat) -> NSImage {
        let screens = NSScreen.screens
        let backing = screens.map(\.backingScaleFactor).max() ?? 2
        let pixels = Int((side * backing).rounded(.up))
        let space =
            NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return source }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        guard let bitmap = context.makeImage() else { return source }
        return NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
    }

    private static func key(for entry: FileEntry) -> String {
        if entry.isParent { return "\u{1}parent" }
        // An archive member's URL is synthetic, so it can only ever be keyed by kind.
        if entry.isArchiveMember {
            if entry.isDirectory { return "\u{1}dir" }
            return entry.ext.isEmpty ? "\u{1}file" : "ext:" + entry.ext
        }
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
        // An archive member has no file on disk to ask about, so its icon comes from the name.
        if entry.isArchiveMember {
            guard !entry.isDirectory else { return NSWorkspace.shared.icon(for: .folder) }
            if !entry.ext.isEmpty, let type = UTType(filenameExtension: entry.ext) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: .data)
        }
        // Covers packages too — they are directories with their own artwork.
        if entry.isDirectory { return NSWorkspace.shared.icon(forFile: entry.url.path) }
        if !entry.ext.isEmpty, let type = UTType(filenameExtension: entry.ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
