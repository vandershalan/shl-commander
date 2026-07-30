import Foundation

/// One tab in a pane.
///
/// A tab is a snapshot rather than a second panel: giving every tab its own view model would
/// mean its own FSEvents stream and size cache running in the background. Switching re-points
/// the single panel instead, which costs one listing — fast, and guaranteed current.
struct PanelTab: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// A directory on disk, or the archive file when the tab is inside an archive.
    var path: String
    /// Path within the archive, or nil when the tab is an ordinary directory.
    ///
    /// Optional so a `session.json` written before archive support still decodes: a missing key
    /// leaves it nil, which is exactly "an ordinary directory".
    var archivePath: String?
    var sort: SortOrder
    /// Row to restore the cursor to, by name.
    var cursorName: String?

    init(
        id: UUID = UUID(),
        path: String,
        archivePath: String? = nil,
        sort: SortOrder = SortOrder(),
        cursorName: String? = nil
    ) {
        self.id = id
        self.path = path
        self.archivePath = archivePath
        self.sort = sort
        self.cursorName = cursorName
    }

    init(location: PanelLocation, sort: SortOrder = SortOrder(), cursorName: String? = nil) {
        switch location {
        case .directory(let url):
            self.init(
                path: url.standardizedFileURL.path, archivePath: nil, sort: sort,
                cursorName: cursorName)
        case .archive(let archive, let inner):
            self.init(
                path: archive.standardizedFileURL.path, archivePath: inner, sort: sort,
                cursorName: cursorName)
        }
    }

    /// Convenience for the common case of a plain directory.
    init(url: URL, sort: SortOrder = SortOrder(), cursorName: String? = nil) {
        self.init(location: .directory(url.standardizedFileURL), sort: sort, cursorName: cursorName)
    }

    var url: URL { URL(fileURLWithPath: path) }

    var location: PanelLocation {
        if let archivePath {
            return .archive(archive: url, path: archivePath)
        }
        return .directory(url)
    }

    mutating func setLocation(_ location: PanelLocation) {
        switch location {
        case .directory(let url):
            path = url.standardizedFileURL.path
            archivePath = nil
        case .archive(let archive, let inner):
            path = archive.standardizedFileURL.path
            archivePath = inner
        }
    }

    /// What the tab strip shows.
    var title: String { location.title }
}
