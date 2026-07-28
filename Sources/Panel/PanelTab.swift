import Foundation

/// One tab in a pane.
///
/// A tab is a snapshot rather than a second panel: giving every tab its own view model would
/// mean its own FSEvents stream and size cache running in the background. Switching re-points
/// the single panel instead, which costs one listing — fast, and guaranteed current.
struct PanelTab: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var path: String
    var sort: SortOrder
    /// Row to restore the cursor to, by name.
    var cursorName: String?

    init(id: UUID = UUID(), path: String, sort: SortOrder = SortOrder(), cursorName: String? = nil) {
        self.id = id
        self.path = path
        self.sort = sort
        self.cursorName = cursorName
    }

    init(url: URL, sort: SortOrder = SortOrder(), cursorName: String? = nil) {
        self.init(path: url.standardizedFileURL.path, sort: sort, cursorName: cursorName)
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// What the tab strip shows. "/" has no last component, so it gets a name of its own.
    var title: String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "Root" : name
    }
}
