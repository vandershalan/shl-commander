import Foundation

/// Human-readable note about the archive a pane has open.
///
/// Carried through a main-actor slot rather than threaded back through `ListingOutcome`, which
/// exists to be `Sendable` and describes rows, not commentary about the container.
@MainActor
enum ArchiveNote {
    /// Set by the most recent archive listing, read by the panel applying it.
    static var latest: String?

    static func describe(index: ArchiveIndex, archive: URL) -> String {
        let kind = label(for: index.format)
        guard ArchiveProbe.nameDisagreesWithContent(archive) else {
            return "Inside a \(kind) — read-only"
        }
        let claimed = ArchiveFormat.detect(url: archive).map(label(for:)) ?? "an archive"
        // Says plainly why a file named .zip holds a single row.
        return "Inside a \(kind) — read-only. The name says \(claimed), but the contents are not."
    }

    private static func label(for format: ArchiveFormat) -> String {
        switch format {
        case .zip: return "zip"
        case .tar: return "tar"
        case .tarGzip: return "gzipped tar"
        case .tarBzip2: return "bzip2 tar"
        case .tarXZ: return "xz tar"
        case .tarZstd: return "zstd tar"
        case .sevenZip: return "7-Zip archive"
        case .rar: return "RAR archive"
        case .cpio: return "cpio archive"
        case .iso: return "disc image"
        case .gzipStream: return "gzip stream"
        case .bzip2Stream: return "bzip2 stream"
        case .xzStream: return "xz stream"
        case .zstdStream: return "zstd stream"
        case .compressStream: return "compress stream"
        }
    }
}
