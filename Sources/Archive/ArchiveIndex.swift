import Foundation

/// One member of an archive.
struct ArchiveMember: Hashable, Sendable {
    /// Normalised: no leading `./`, no trailing slash, never absolute, never containing `..`.
    let path: String
    let isDirectory: Bool
    let isSymlink: Bool
    /// Uncompressed size. Zero for directories.
    let size: Int64
    let modified: Date

    var name: String {
        path.components(separatedBy: "/").last ?? path
    }

    /// Parent path, `""` for a member at the archive root.
    var parent: String {
        var components = path.components(separatedBy: "/")
        components.removeLast()
        return components.joined(separator: "/")
    }
}

/// A listing of an archive, arranged so a panel can walk it like a directory tree.
struct ArchiveIndex: Sendable {
    let archive: URL
    let format: ArchiveFormat
    /// Every member, including directories synthesised for paths that only appear as prefixes.
    let members: [ArchiveMember]

    /// Members grouped by parent path, so listing one level is a dictionary lookup rather than
    /// a scan of the whole archive.
    private let childrenByParent: [String: [ArchiveMember]]
    /// Recursive uncompressed size per directory, totalled once here because the archive has
    /// already told us every size — there is nothing left to walk.
    private let directorySizes: [String: Int64]

    init(archive: URL, format: ArchiveFormat, members: [ArchiveMember]) {
        self.archive = archive
        self.format = format

        let completed = Self.addingMissingDirectories(members)
        self.members = completed
        self.childrenByParent = Dictionary(grouping: completed, by: \.parent)

        var sizes: [String: Int64] = [:]
        for member in completed where !member.isDirectory {
            // Credit the size to every ancestor, which is what a recursive total means.
            var parent = member.parent
            while true {
                sizes[parent, default: 0] += member.size
                if parent.isEmpty { break }
                var components = parent.components(separatedBy: "/")
                components.removeLast()
                parent = components.joined(separator: "/")
            }
        }
        self.directorySizes = sizes
    }

    /// Members directly inside `path`, sorted the way the panel will re-sort them anyway.
    func children(of path: String) -> [ArchiveMember] {
        childrenByParent[Self.normalise(path)] ?? []
    }

    /// Recursive uncompressed size of a directory inside the archive.
    func size(ofDirectory path: String) -> Int64 {
        directorySizes[Self.normalise(path)] ?? 0
    }

    func member(at path: String) -> ArchiveMember? {
        let wanted = Self.normalise(path)
        return members.first { $0.path == wanted }
    }

    func isDirectory(_ path: String) -> Bool {
        let wanted = Self.normalise(path)
        if wanted.isEmpty { return true }
        return member(at: wanted)?.isDirectory ?? false
    }

    var totalSize: Int64 { members.reduce(0) { $0 + $1.size } }
    var fileCount: Int { members.count(where: { !$0.isDirectory }) }

    // MARK: - Path handling

    /// Strips the spellings archivers vary on, so `./a/b/`, `a/b` and `/a/b` are one path.
    static func normalise(_ path: String) -> String {
        var value = path
        while value.hasPrefix("./") { value.removeFirst(2) }
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value == "." ? "" : value
    }

    /// True for a member path that must never be shown or extracted.
    ///
    /// An entry that escapes the archive root — `../../etc/passwd` — is the zip-slip attack.
    /// bsdtar refuses these on extraction, but they are dropped here as well so they are never
    /// listed, never counted, and never passed to it in the first place.
    static func isUnsafe(_ path: String) -> Bool {
        let normalised = normalise(path)
        if normalised.isEmpty { return true }
        return normalised.components(separatedBy: "/").contains("..")
    }

    /// Adds directory entries for paths that appear only as a prefix of some file.
    ///
    /// Plenty of archivers omit directory records entirely — `zip -D` does, and so do many
    /// language tool-chains — which would leave a listing with files whose folders do not exist.
    private static func addingMissingDirectories(_ members: [ArchiveMember]) -> [ArchiveMember] {
        var known = Set(members.map(\.path))
        var result = members

        for member in members {
            var parent = member.parent
            while !parent.isEmpty, !known.contains(parent) {
                known.insert(parent)
                result.append(
                    ArchiveMember(
                        path: parent,
                        isDirectory: true,
                        isSymlink: false,
                        size: 0,
                        // Nothing in the archive records this directory, so it inherits the
                        // timestamp of a file inside it rather than inventing "now".
                        modified: member.modified
                    )
                )
                var components = parent.components(separatedBy: "/")
                components.removeLast()
                parent = components.joined(separator: "/")
            }
        }
        return result
    }
}
