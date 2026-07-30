import Foundation

/// Where a pane is looking.
///
/// A pane is either on the filesystem or inside an archive. Modelling it as one value keeps the
/// distinction in one place instead of scattering "are we in a zip" checks through the panel.
enum PanelLocation: Hashable, Sendable {
    case directory(URL)
    /// `path` is the directory within the archive; `""` is the archive's own root.
    case archive(archive: URL, path: String)

    /// The real directory this location sits in or under.
    ///
    /// Inside an archive that is the folder holding the archive file, which is what commands
    /// needing somewhere real — Open in Terminal, free space, a copy destination — should use.
    var containingDirectory: URL {
        switch self {
        case .directory(let url): return url
        case .archive(let archive, _): return archive.deletingLastPathComponent()
        }
    }

    var archiveURL: URL? {
        switch self {
        case .directory: return nil
        case .archive(let archive, _): return archive
        }
    }

    var archivePath: String? {
        switch self {
        case .directory: return nil
        case .archive(_, let path): return path
        }
    }

    var isInsideArchive: Bool { archiveURL != nil }

    /// What the path bar shows. Inside an archive the archive's own path continues into the
    /// member path, so one line reads as a single location.
    var displayPath: String {
        switch self {
        case .directory(let url):
            return url.path
        case .archive(let archive, let path):
            return path.isEmpty ? archive.path : archive.path + "/" + path
        }
    }

    /// Name for a tab, which is the innermost component either way.
    var title: String {
        switch self {
        case .directory(let url):
            let name = url.lastPathComponent
            return name.isEmpty || name == "/" ? "Root" : name
        case .archive(let archive, let path):
            return path.isEmpty
                ? archive.lastPathComponent
                : (path.components(separatedBy: "/").last ?? archive.lastPathComponent)
        }
    }

    /// Compared by path rather than by URL, because `standardizedFileURL` marks an existing
    /// directory with a trailing slash and two URLs for one folder then differ.
    func isSamePlace(as other: PanelLocation) -> Bool {
        switch (self, other) {
        case (.directory(let a), .directory(let b)):
            return a.path == b.path
        case (.archive(let archiveA, let pathA), .archive(let archiveB, let pathB)):
            // Canonical, so a zip reached as /var/… and as /private/var/… is one place.
            return archiveA.canonicalPath == archiveB.canonicalPath
                && ArchiveIndex.normalise(pathA) == ArchiveIndex.normalise(pathB)
        default:
            return false
        }
    }

    /// One level up. Leaving an archive's root lands back on the archive file's own folder;
    /// `nil` means there is nowhere further up.
    var parent: PanelLocation? {
        switch self {
        case .directory(let url):
            return DirectoryLister.parent(of: url).map { .directory($0) }
        case .archive(let archive, let path):
            let normalised = ArchiveIndex.normalise(path)
            guard !normalised.isEmpty else {
                return .directory(archive.deletingLastPathComponent())
            }
            var components = normalised.components(separatedBy: "/")
            components.removeLast()
            return .archive(archive: archive, path: components.joined(separator: "/"))
        }
    }

    /// The name to put the cursor on after going up, so leaving somewhere selects where you were.
    var nameWithinParent: String? {
        switch self {
        case .directory(let url):
            return url.lastPathComponent
        case .archive(let archive, let path):
            let normalised = ArchiveIndex.normalise(path)
            return normalised.isEmpty
                ? archive.lastPathComponent
                : normalised.components(separatedBy: "/").last
        }
    }
}
