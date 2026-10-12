import Foundation

/// A bookmarked directory.
///
/// Stored as a plain path rather than as bookmark data: the app is not sandboxed, so there is
/// nothing to resolve and a hand-editable file is worth more than opaque blobs.
struct Favorite: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String
    /// The pane this favourite opens in, whichever pane has focus.
    var side: AppState.Side

    init(id: UUID = UUID(), name: String, path: String, side: AppState.Side = .left) {
        self.id = id
        self.name = name
        self.path = path
        self.side = side
    }

    init(url: URL, name: String? = nil, side: AppState.Side = .left) {
        let path = url.standardizedFileURL.path
        self.init(
            name: name ?? (url.lastPathComponent.isEmpty ? path : url.lastPathComponent),
            path: path,
            side: side
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, side
    }

    /// Files written before favourites had a side load them all onto the left.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        side = try container.decodeIfPresent(AppState.Side.self, forKey: .side) ?? .left
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
