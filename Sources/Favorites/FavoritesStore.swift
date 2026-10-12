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

    /// Favourites belonging to one pane, in bar order.
    func favorites(on side: AppState.Side) -> [Favorite] {
        favorites.filter { $0.side == side }
    }

    /// Adding a directory already bookmarked for that pane is a no-op, so ⌘⇧D can be pressed
    /// twice safely. The same folder may still be a favourite of both panes.
    @discardableResult
    func add(_ url: URL, name: String? = nil, side: AppState.Side = .left) -> Favorite? {
        let candidate = Favorite(url: url, name: name, side: side)
        guard !favorites.contains(where: { $0.path == candidate.path && $0.side == side })
        else { return nil }
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

    /// Hands a favourite to the other pane, at the end of that pane's group.
    func setSide(_ favorite: Favorite, to side: AppState.Side) {
        guard let index = favorites.firstIndex(where: { $0.id == favorite.id }),
            favorites[index].side != side
        else { return }
        var item = favorites.remove(at: index)
        item.side = side
        favorites.append(item)
        save()
    }

    /// Moves the favourite with `id` next to `target`, taking `target`'s pane, so a drag can
    /// both reorder within a group and carry a favourite across to the other one.
    func move(id: UUID, onto target: Favorite) {
        guard id != target.id,
            let from = favorites.firstIndex(where: { $0.id == id }),
            let destination = favorites.firstIndex(where: { $0.id == target.id })
        else { return }
        var item = favorites.remove(at: from)
        item.side = target.side
        favorites.insert(item, at: destination)
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

    /// 1-based position within one pane's group, matching ⌃1–⌃9 (left) and ⌘1–⌘9 (right).
    func favorite(number: Int, on side: AppState.Side) -> Favorite? {
        let group = favorites(on: side)
        let index = number - 1
        return group.indices.contains(index) ? group[index] : nil
    }

    /// The shortcut number for `favorite` within its group, or nil past the ninth.
    func number(of favorite: Favorite) -> Int? {
        guard let index = favorites(on: favorite.side).firstIndex(where: { $0.id == favorite.id }),
            index < 9
        else { return nil }
        return index + 1
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
