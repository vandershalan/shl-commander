import Foundation

/// Archive kinds the app will open, recognised by name.
///
/// Recognition is by extension rather than by sniffing magic bytes: the panel has to decide
/// whether `Return` enters a file or opens it, and it has to decide that for every row in a
/// listing without reading any of them.
enum ArchiveFormat: String, CaseIterable, Sendable {
    case zip
    case tar
    case tarGzip
    case tarBzip2
    case tarXZ
    case sevenZip
    case rar
    case cpio
    case iso

    /// Longest suffixes first, so `.tar.gz` is not mistaken for a plain `.gz`.
    private static let suffixes: [(String, ArchiveFormat)] = [
        (".tar.gz", .tarGzip), (".tgz", .tarGzip),
        (".tar.bz2", .tarBzip2), (".tbz", .tarBzip2), (".tbz2", .tarBzip2),
        (".tar.xz", .tarXZ), (".txz", .tarXZ),
        (".tar.zst", .tarGzip), (".tzst", .tarGzip),
        (".tar", .tar),
        // Zip containers under other names. `.ipa`, `.jar` and the comic-book formats are all
        // ordinary zips, and being able to look inside them is the point.
        (".zip", .zip), (".jar", .zip), (".war", .zip), (".ipa", .zip), (".cbz", .zip),
        (".7z", .sevenZip),
        (".rar", .rar), (".cbr", .rar),
        (".cpio", .cpio),
        (".iso", .iso),
    ]

    /// The format of `name`, or nil when it is not an archive this app opens.
    ///
    /// A bare `.gz`, `.bz2` or `.xz` is deliberately excluded: those are single compressed
    /// streams, not containers, so there is nothing to navigate inside.
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
