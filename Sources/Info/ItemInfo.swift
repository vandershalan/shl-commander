import AppKit

/// Everything the info panel reports about one item.
///
/// A value type gathered off the main actor: reading a dozen resource values and an owner name
/// touches the disk, and a folder's recursive size can take seconds.
struct ItemInfo: Sendable {
    var url: URL
    var name: String
    /// What the Finder calls "Kind": "Folder", "Plain Text Document", "Application".
    var kind: String
    var typeIdentifier: String
    var isDirectory: Bool
    var isPackage: Bool
    var isHidden: Bool
    /// Where the link points, unresolved. Nil for anything that is not a symlink.
    var symlinkTarget: String?
    /// Logical size. For a folder this stays nil until the tree has been walked.
    var size: Int64?
    var sizeOnDisk: Int64?
    var created: Date?
    var modified: Date?
    var accessed: Date?
    var owner: String
    var group: String
    /// `drwxr-xr-x`, the way `ls -l` writes it.
    var mode: String
    var volumeName: String?
    /// Immediate children, for a folder.
    var childCount: Int?

    /// The folder holding it, which is the Finder's "Where".
    var location: String { url.deletingLastPathComponent().path }

    static func gather(_ url: URL) -> ItemInfo {
        let keys: Set<URLResourceKey> = [
            .localizedNameKey, .localizedTypeDescriptionKey, .contentTypeKey, .isDirectoryKey,
            .isPackageKey, .isHiddenKey, .isSymbolicLinkKey, .fileSizeKey,
            .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey,
            .contentAccessDateKey, .volumeNameKey,
        ]
        let values = try? url.resourceValues(forKeys: keys)
        let isDirectory = values?.isDirectory ?? false
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        return ItemInfo(
            url: url,
            name: values?.localizedName ?? url.lastPathComponent,
            kind: values?.localizedTypeDescription ?? (isDirectory ? "Folder" : "Document"),
            typeIdentifier: values?.contentType?.identifier ?? "—",
            isDirectory: isDirectory,
            isPackage: values?.isPackage ?? false,
            isHidden: values?.isHidden ?? false,
            symlinkTarget: values?.isSymbolicLink == true
                ? (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) : nil,
            // A folder's size means walking it, which the panel asks for separately.
            size: isDirectory ? nil : Int64(values?.fileSize ?? 0),
            sizeOnDisk: isDirectory ? nil : values?.totalFileAllocatedSize.map(Int64.init),
            created: values?.creationDate,
            modified: values?.contentModificationDate,
            accessed: values?.contentAccessDate,
            owner: attributes?[.ownerAccountName] as? String ?? "—",
            group: attributes?[.groupOwnerAccountName] as? String ?? "—",
            mode: Self.modeString(
                attributes?[.posixPermissions] as? NSNumber,
                isDirectory: isDirectory,
                isSymlink: values?.isSymbolicLink == true
            ),
            volumeName: values?.volumeName,
            childCount: isDirectory
                ? (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count : nil
        )
    }

    /// `rwxr-x---` with the type letter in front, which is how anyone reading permissions on a
    /// Mac expects to see them — the octal alone is not.
    static func modeString(_ permissions: NSNumber?, isDirectory: Bool, isSymlink: Bool) -> String {
        guard let permissions else { return "—" }
        let bits = permissions.intValue
        let type = isSymlink ? "l" : (isDirectory ? "d" : "-")
        var result = type
        for shift in [6, 3, 0] {
            let triple = (bits >> shift) & 0o7
            result += triple & 0o4 != 0 ? "r" : "-"
            result += triple & 0o2 != 0 ? "w" : "-"
            result += triple & 0o1 != 0 ? "x" : "-"
        }
        return result + String(format: "  (%03o)", bits & 0o777)
    }
}

/// The totals shown when several items are selected, and the recursive size of a folder.
struct TreeTotals: Sendable {
    var bytes: Int64
    var sizeOnDisk: Int64
    var files: Int
    var directories: Int

    /// Walks the trees. Slow by nature, so it runs off the main actor and can be abandoned.
    static func measure(_ urls: [URL], isCancelled: @escaping () -> Bool = { false }) -> TreeTotals {
        let stats = FileTreeScanner.stats(of: urls)
        let allocated = urls.reduce(Int64(0)) {
            $0 + FileTreeScanner.allocatedSize(of: $1, isCancelled: isCancelled)
        }
        return TreeTotals(
            bytes: stats.bytes,
            sizeOnDisk: allocated,
            files: stats.files,
            directories: stats.directories
        )
    }
}
