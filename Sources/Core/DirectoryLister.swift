import Foundation

/// Reads a directory into `FileEntry` values. Pure and off-actor so panels can call it
/// from a detached task.
enum DirectoryLister {
    /// Prefetched in one pass by `contentsOfDirectory` so the per-URL reads below are
    /// cache hits rather than extra stat calls.
    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isHiddenKey,
        .isPackageKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    /// Lists the immediate children of `url`. Does not include a `..` row — panels add
    /// that themselves, since only they know whether they are at a volume root.
    static func list(_ url: URL, includeHidden: Bool) throws -> [FileEntry] {
        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]

        let urls = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: options
        )

        var entries: [FileEntry] = []
        entries.reserveCapacity(urls.count)

        for child in urls {
            // A child that vanished between the listing and this read is skipped rather
            // than failing the whole directory.
            let values = try? child.resourceValues(forKeys: Set(resourceKeys))
            let name = child.lastPathComponent
            let isDirectory = values?.isDirectory ?? false
            let ext = isDirectory ? "" : child.pathExtension.lowercased()

            entries.append(
                FileEntry(
                    url: child,
                    name: name,
                    baseName: isDirectory ? name : (child.deletingPathExtension().lastPathComponent),
                    ext: ext,
                    isDirectory: isDirectory,
                    isSymlink: values?.isSymbolicLink ?? false,
                    isHidden: values?.isHidden ?? false,
                    isPackage: values?.isPackage ?? false,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast,
                    isParent: false
                )
            )
        }

        return entries
    }

    /// The parent directory, or nil at a volume root (where `deletingLastPathComponent`
    /// would just hand back `/` again).
    static func parent(of url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let up = standardized.deletingLastPathComponent().standardizedFileURL
        guard up.path != standardized.path else { return nil }
        return up
    }
}
