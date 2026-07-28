import Foundation

/// A bookmarked directory.
///
/// Stored as a plain path rather than as bookmark data: the app is not sandboxed, so there is
/// nothing to resolve and a hand-editable file is worth more than opaque blobs.
struct Favorite: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    init(url: URL, name: String? = nil) {
        let path = url.standardizedFileURL.path
        self.init(
            name: name ?? (url.lastPathComponent.isEmpty ? path : url.lastPathComponent),
            path: path
        )
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// False once the folder has been moved or deleted, so the bar can dim it rather than
    /// silently failing when clicked.
    var exists: Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }
}
