import Foundation

/// A saved server, the way Finder's "Connect to Server" keeps its favourites.
///
/// The password is deliberately not here: the file is plain JSON in Application Support, and a
/// password belongs in the Keychain. See `ServerKeychain`.
struct ServerBookmark: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Normalised, with any `user@` stripped out — that half lives in `username`.
    var address: String
    var username: String
    var name: String

    init(id: UUID = UUID(), address: String, username: String = "", name: String? = nil) {
        self.id = id
        self.address = address
        self.username = username
        self.name = name ?? Self.defaultName(for: address)
    }

    var url: URL? { URL(string: address) }

    /// The host, which is what a Keychain internet-password entry is keyed on.
    var host: String { url?.host ?? address }

    /// `smb://nas.local/media` → `nas.local/media`, which reads better in a list than the
    /// scheme repeated on every row.
    static func defaultName(for address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }
}
