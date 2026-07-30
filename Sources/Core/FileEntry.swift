import Foundation

/// Where an entry came from, when it is not a file on disk.
struct ArchiveOrigin: Hashable, Sendable {
    let archive: URL
    /// Path of this entry within the archive.
    let member: String
}

/// One row in a panel. Immutable snapshot taken at listing time — directory sizes and marks
/// live outside it so a reload never has to recompute them.
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
    /// Byte size of the file. For a directory inside an archive this is the recursive total,
    /// which the archive already knows; for one on disk it is 0 until measured.
    let size: Int64
    let modified: Date
    /// The synthetic `..` row, always sorted first and never markable.
    let isParent: Bool
    /// Set when this entry is a member of an archive rather than a file on disk. Its `url` is
    /// then synthetic — unique and stable for marks and selection, but not something to stat.
    let archive: ArchiveOrigin?

    init(
        url: URL,
        name: String,
        baseName: String,
        ext: String,
        isDirectory: Bool,
        isSymlink: Bool,
        isHidden: Bool,
        isPackage: Bool,
        size: Int64,
        modified: Date,
        isParent: Bool,
        archive: ArchiveOrigin? = nil
    ) {
        self.url = url
        self.name = name
        self.baseName = baseName
        self.ext = ext
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.isParent = isParent
        self.archive = archive
    }

    var id: URL { url }

    /// True when this entry is inside an archive, so it cannot be written to or stat'd.
    var isArchiveMember: Bool { archive != nil }

    /// A file the panel can open and walk into, like `report.zip`.
    var isBrowsableArchive: Bool {
        !isDirectory && ArchiveFormat.detect(name: name) != nil
    }

    /// Panels navigate into anything directory-shaped, packages included — and into archives,
    /// which behave like directories once opened.
    var isNavigable: Bool { isDirectory || isBrowsableArchive }
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

    /// The `..` row while inside an archive. Its URL only has to be unique and stable.
    static func archiveParent(archive: URL, path: String) -> FileEntry {
        FileEntry(
            url: archive.appendingPathComponent(path.isEmpty ? ".." : path + "/.."),
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

    /// Turns an archive member into a row.
    init(member: ArchiveMember, in archive: URL, directorySize: Int64) {
        let name = member.name
        let isDirectory = member.isDirectory
        self.init(
            // Synthetic but unique: marks and the cursor are keyed by URL, and this reads
            // naturally in the path bar. Nothing stats it.
            url: archive.appendingPathComponent(member.path),
            name: name,
            baseName: isDirectory
                ? name : (name as NSString).deletingPathExtension,
            ext: isDirectory ? "" : (name as NSString).pathExtension.lowercased(),
            isDirectory: isDirectory,
            isSymlink: member.isSymlink,
            // Dotfiles inside an archive are hidden by the same rule as on disk.
            isHidden: name.hasPrefix("."),
            isPackage: false,
            size: isDirectory ? directorySize : member.size,
            modified: member.modified,
            isParent: false,
            archive: ArchiveOrigin(archive: archive, member: member.path)
        )
    }
}
