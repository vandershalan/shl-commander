import Foundation

/// Identifies an archive by what is in it rather than by what it is called.
///
/// Names lie. Export pipelines and download servers hand out files whose extension says one
/// thing and whose bytes say another — a gzipped CSV named `.zip` is a real and common example —
/// and refusing to open one because its name is wrong is a poor answer when the first few bytes
/// settle the question outright.
enum ArchiveProbe {
    /// Bytes needed to recognise every signature below, including `ustar` at offset 257.
    private static let headerLength = 264

    /// The format of the file, decided by content where possible and by name otherwise.
    ///
    /// Content wins: a mismatch means the name is wrong, not the bytes.
    static func format(of url: URL) -> ArchiveFormat? {
        guard let header = readHeader(url) else {
            return ArchiveFormat.detect(url: url)
        }
        if let sniffed = signature(of: header) {
            // A container that the name spells more precisely keeps the name's answer, since
            // `.tar.gz` and a bare `.gz` share a gzip signature and mean different things.
            if sniffed == .gzipStream, let named = ArchiveFormat.detect(url: url),
                named == .tarGzip
            {
                return .tarGzip
            }
            if sniffed == .bzip2Stream, ArchiveFormat.detect(url: url) == .tarBzip2 {
                return .tarBzip2
            }
            if sniffed == .xzStream, ArchiveFormat.detect(url: url) == .tarXZ { return .tarXZ }
            if sniffed == .zstdStream, ArchiveFormat.detect(url: url) == .tarZstd {
                return .tarZstd
            }
            return sniffed
        }
        return ArchiveFormat.detect(url: url)
    }

    /// Recognises a signature, or nil when nothing matches.
    static func signature(of header: Data) -> ArchiveFormat? {
        func matches(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard header.count >= offset + bytes.count else { return false }
            return Array(header[offset..<(offset + bytes.count)]) == bytes
        }

        // Local file header, empty archive, and spanned archive.
        if matches([0x50, 0x4B, 0x03, 0x04]) || matches([0x50, 0x4B, 0x05, 0x06])
            || matches([0x50, 0x4B, 0x07, 0x08])
        {
            return .zip
        }
        if matches([0x1F, 0x8B]) { return .gzipStream }
        if matches([0x42, 0x5A, 0x68]) { return .bzip2Stream }  // "BZh"
        if matches([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xzStream }
        if matches([0x28, 0xB5, 0x2F, 0xFD]) { return .zstdStream }
        if matches([0x1F, 0x9D]) { return .compressStream }
        if matches([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if matches([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }  // "Rar!\u{1a}\u{7}"
        // tar records "ustar" in the header of its first entry, 257 bytes in.
        if matches([0x75, 0x73, 0x74, 0x61, 0x72], at: 257) { return .tar }
        if matches([0x30, 0x37, 0x30, 0x37, 0x30]) { return .cpio }  // "07070"
        return nil
    }

    /// True when the name claims one format and the bytes say another, which is worth saying out
    /// loud rather than silently working around.
    static func nameDisagreesWithContent(_ url: URL) -> Bool {
        guard let header = readHeader(url), let sniffed = signature(of: header) else { return false }
        guard let named = ArchiveFormat.detect(url: url) else { return true }
        if named == sniffed { return false }
        // A tar inside a compressed stream is not a disagreement.
        switch (named, sniffed) {
        case (.tarGzip, .gzipStream), (.tarBzip2, .bzip2Stream), (.tarXZ, .xzStream),
            (.tarZstd, .zstdStream), (.tar, .tar):
            return false
        default:
            return true
        }
    }

    private static func readHeader(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: headerLength)
    }
}
