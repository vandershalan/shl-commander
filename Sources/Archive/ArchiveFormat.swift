import Foundation

/// Archive kinds the app will open.
///
/// Two families: containers, which hold many members and are listed by bsdtar, and single
/// compressed streams, which hold exactly one payload and are handled by a decompressor.
enum ArchiveFormat: String, CaseIterable, Sendable {
    // Containers
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXZ
    case tarZstd
    case sevenZip
    case rar
    case cpio
    case iso

    // Single compressed streams
    case gzipStream
    case bzip2Stream
    case xzStream
    case zstdStream
    case compressStream

    /// True for a format holding exactly one payload rather than a table of contents.
    ///
    /// These still open: the pane shows one row — the payload — which can be previewed and
    /// copied out decompressed. That is more useful than refusing to open the file at all.
    var isSingleStream: Bool {
        switch self {
        case .gzipStream, .bzip2Stream, .xzStream, .zstdStream, .compressStream: return true
        default: return false
        }
    }

    /// Suffix stripped from the archive's name to name the payload inside a single stream.
    var streamSuffix: String? {
        switch self {
        case .gzipStream: return ".gz"
        case .bzip2Stream: return ".bz2"
        case .xzStream: return ".xz"
        case .zstdStream: return ".zst"
        case .compressStream: return ".Z"
        default: return nil
        }
    }

    /// Longest suffixes first, so `.tar.gz` is never mistaken for a plain `.gz`.
    private static let suffixes: [(String, ArchiveFormat)] = [
        (".tar.gz", .tarGzip), (".tgz", .tarGzip),
        (".tar.bz2", .tarBzip2), (".tbz", .tarBzip2), (".tbz2", .tarBzip2),
        (".tar.xz", .tarXZ), (".txz", .tarXZ),
        (".tar.zst", .tarZstd), (".tzst", .tarZstd),
        (".tar.z", .tar),
        (".tar", .tar),
        // Zip containers under other names. `.ipa`, `.jar` and the comic-book formats are all
        // ordinary zips, and being able to look inside them is the point.
        (".zip", .zip), (".jar", .zip), (".war", .zip), (".ipa", .zip), (".cbz", .zip),
        (".7z", .sevenZip),
        (".rar", .rar), (".cbr", .rar),
        (".cpio", .cpio),
        (".iso", .iso),
        // Single streams, checked after every compound form above.
        (".gz", .gzipStream),
        (".bz2", .bzip2Stream),
        (".xz", .xzStream),
        (".zst", .zstdStream),
        (".z", .compressStream),
    ]

    /// The format suggested by `name`.
    ///
    /// A hint only: names are wrong often enough that anything actually opening a file checks
    /// its content instead. This is what decides whether a row offers `Return`, because sniffing
    /// every row of a large directory would mean opening every file in it.
    static func detect(name: String) -> ArchiveFormat? {
        let lowered = name.lowercased()
        return suffixes.first { lowered.hasSuffix($0.0) }?.1
    }

    static func detect(url: URL) -> ArchiveFormat? {
        detect(name: url.lastPathComponent)
    }

    static func isArchive(_ url: URL) -> Bool {
        detect(url: url) != nil
    }
}
