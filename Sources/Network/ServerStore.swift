import Foundation
import Observation

/// Saved servers, persisted as JSON beside the favourites.
@MainActor
@Observable
final class ServerStore {
    static let shared = ServerStore()

    private(set) var servers: [ServerBookmark] = []

    private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("servers.json")) {
        self.fileURL = fileURL
        load()
    }

    /// Remembers a server, or updates the entry that already points at the same address.
    ///
    /// Matched on address rather than on id: reconnecting is normally done by typing the
    /// address again, and a second entry for one share is noise.
    @discardableResult
    func remember(address: String, username: String, name: String? = nil) -> ServerBookmark {
        if let index = servers.firstIndex(where: { $0.address == address }) {
            servers[index].username = username
            if let name { servers[index].name = name }
            save()
            return servers[index]
        }
        let bookmark = ServerBookmark(address: address, username: username, name: name)
        servers.append(bookmark)
        save()
        return bookmark
    }

    func remove(_ bookmark: ServerBookmark) {
        servers.removeAll { $0.id == bookmark.id }
        // The password goes with it: leaving it behind would silently log the next person in.
        ServerKeychain.remove(host: bookmark.host, account: bookmark.username)
        save()
    }

    func rename(_ bookmark: ServerBookmark, to name: String) {
        guard let index = servers.firstIndex(where: { $0.id == bookmark.id }) else { return }
        servers[index].name = name
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        servers = (try? JSONDecoder().decode([ServerBookmark].self, from: data)) ?? []
    }

    private func save() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(servers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
