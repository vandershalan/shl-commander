import CryptoKit
import Foundation

/// Caches archive listings and the temporary copies pulled out of them.
///
/// Listing an archive costs a subprocess and a full pass over its table of contents, so the
/// result is kept until the archive file itself changes. Previewing or opening a member needs a
/// real file on disk, so members are extracted once into a scratch directory and reused.
@MainActor
final class ArchiveStore {
    static let shared = ArchiveStore()

    /// Identifies a particular state of an archive file. A rebuilt archive gets a new stamp and
    /// so a fresh listing, rather than a stale one that no longer matches.
    private struct Stamp: Hashable {
        let path: String
        let modified: Date
        let size: Int64
    }

    private var indexes: [Stamp: ArchiveIndex] = [:]
    /// Members already extracted, so a second preview of the same file is free.
    private var materialised: [Stamp: Set<String>] = [:]

    private init() {}

    // MARK: - Listing

    func index(for archive: URL) async throws -> ArchiveIndex {
        let stamp = Self.stamp(for: archive)
        if let cached = indexes[stamp] { return cached }

        let index = try await Self.read(archive)
        // Drop any older listing of the same file, so the cache does not grow with every save.
        indexes = indexes.filter { $0.key.path != stamp.path }
        indexes[stamp] = index
        return index
    }

    /// `nonisolated async` so the subprocess and parsing run off the main actor.
    private nonisolated static func read(_ archive: URL) async throws -> ArchiveIndex {
        try ArchiveReader.index(of: archive)
    }

    func invalidate(_ archive: URL) {
        let path = archive.canonicalPath
        indexes = indexes.filter { $0.key.path != path }
        materialised = materialised.filter { $0.key.path != path }
    }

    // MARK: - Extraction for preview and opening

    /// Extracts one member into the scratch area and returns the file on disk.
    ///
    /// The copy is read-only in spirit: edits to it are never written back, because writing into
    /// an archive is not supported.
    func materialise(member: String, from archive: URL) async throws -> URL {
        let stamp = Self.stamp(for: archive)
        let directory = Self.scratchDirectory(for: stamp)
        let destination = directory.appendingPathComponent(ArchiveIndex.normalise(member))

        if materialised[stamp]?.contains(member) == true,
            FileManager.default.fileExists(atPath: destination.path)
        {
            return destination
        }

        try await Self.extract(member: member, from: archive, to: directory)
        materialised[stamp, default: []].insert(member)
        return destination
    }

    private nonisolated static func extract(
        member: String,
        from archive: URL,
        to directory: URL
    ) async throws {
        try ArchiveReader.extract(members: [member], from: archive, to: directory)
    }

    // MARK: - Scratch area

    /// `…/TemporaryItems/shl-commander-archives/<digest>` — one directory per archive state, so
    /// two versions of the same file cannot mix their contents.
    private static func scratchDirectory(for stamp: Stamp) -> URL {
        let seed = "\(stamp.path)|\(stamp.modified.timeIntervalSince1970)|\(stamp.size)"
        let digest = SHA256.hash(data: Data(seed.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    static var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shl-commander-archives", isDirectory: true)
    }

    /// Removes every extracted copy. Called on quit; the scratch area is disposable by design.
    static func removeScratch() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func stamp(for archive: URL) -> Stamp {
        let values = try? archive.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
        return Stamp(
            // Canonical, so two spellings of one archive do not cache it twice.
            path: archive.canonicalPath,
            modified: values?.contentModificationDate ?? .distantPast,
            size: Int64(values?.fileSize ?? 0)
        )
    }
}
