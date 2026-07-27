import Foundation

/// One row in a panel. Immutable snapshot taken at listing time — directory sizes
/// and marks live outside it so a reload never has to recompute them.
struct FileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    /// Full file name including the extension. `".."` for the parent row.
    let name: String
    /// Name without the extension. Equal to `name` for directories and the parent row.
    let baseName: String
    /// Lowercased extension without the dot. Empty for directories and extensionless files.
    let ext: String
    let isDirectory: Bool
    let isSymlink: Bool
    let isHidden: Bool
    /// `.app`, `.rtfd`, … — a directory that Finder presents as a single file. Panels still
    /// descend into these; the flag only affects which icon is drawn.
    let isPackage: Bool
    /// Byte size of the file. Always 0 for directories; `DirectorySizer` supplies those later.
    let size: Int64
    let modified: Date
    /// The synthetic `..` row, always sorted first and never markable.
    let isParent: Bool

    var id: URL { url }

    /// Panels navigate into anything directory-shaped, packages included.
    var isNavigable: Bool { isDirectory }
}

extension FileEntry {
    /// Builds the synthetic `..` row pointing at `parent`.
    static func parent(_ parent: URL) -> FileEntry {
        FileEntry(
            url: parent,
            name: "..",
            baseName: "..",
            ext: "",
            isDirectory: true,
            isSymlink: false,
            isHidden: false,
            isPackage: false,
            size: 0,
            modified: .distantPast,
            isParent: true
        )
    }
}
