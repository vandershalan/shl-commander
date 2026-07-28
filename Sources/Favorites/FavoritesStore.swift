import Foundation
import Observation

/// Favourites, persisted as JSON in the app's support directory.
@MainActor
@Observable
final class FavoritesStore {
    private(set) var favorites: [Favorite] = []

    /// Overridable so tests do not touch the real file.
    private let fileURL: URL

    init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("favorites.json")) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Mutation

    /// Adding a directory already bookmarked is a no-op, so ⌘⇧D can be pressed twice safely.
    @discardableResult
    func add(_ url: URL, name: String? = nil) -> Favorite? {
        let candidate = Favorite(url: url, name: name)
        guard !favorites.contains(where: { $0.path == candidate.path }) else { return nil }
        favorites.append(candidate)
        save()
        return candidate
    }

    func remove(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        save()
    }

    func rename(_ favorite: Favorite, to name: String) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }) else { return }
        favorites[index].name = name
        save()
    }

    /// Moves the favourite with `id` so it sits at `destination` in the current ordering.
    func move(id: UUID, to destination: Int) {
        guard let from = favorites.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(0, destination), favorites.count - 1)
        guard from != clamped else { return }
        let item = favorites.remove(at: from)
        favorites.insert(item, at: clamped)
        save()
    }

    /// 1-based, matching the ⌘1–⌘9 shortcuts.
    func favorite(number: Int) -> Favorite? {
        let index = number - 1
        return favorites.indices.contains(index) ? favorites[index] : nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        favorites = (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
    }

    private func save() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(favorites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
