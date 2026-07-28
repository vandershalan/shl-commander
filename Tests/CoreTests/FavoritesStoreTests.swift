import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("FavoritesStore")
struct FavoritesStoreTests {
    /// A store backed by a throwaway file, so tests never touch the real favourites.
    private func store(in tree: TempTree) -> FavoritesStore {
        FavoritesStore(fileURL: tree.root.appendingPathComponent("favorites.json"))
    }

    @Test("adding keeps the folder name by default")
    func addUsesFolderName() throws {
        let tree = try TempTree("fav-add")
        defer { tree.remove() }
        let folder = try tree.directory("Projects")
        let store = store(in: tree)

        let added = try #require(store.add(folder))
        #expect(added.name == "Projects")
        #expect(added.path == folder.standardizedFileURL.path)
        #expect(store.favorites.count == 1)
    }

    @Test("adding the same folder twice is a no-op")
    func addIsIdempotent() throws {
        let tree = try TempTree("fav-dup")
        defer { tree.remove() }
        let folder = try tree.directory("Projects")
        let store = store(in: tree)

        #expect(store.add(folder) != nil)
        #expect(store.add(folder) == nil, "⌘⇧D twice should not duplicate")
        #expect(store.favorites.count == 1)
    }

    @Test("a custom name overrides the folder name")
    func customName() throws {
        let tree = try TempTree("fav-name")
        defer { tree.remove() }
        let folder = try tree.directory("very-long-folder-name")
        let store = store(in: tree)

        let added = try #require(store.add(folder, name: "Work"))
        #expect(added.name == "Work")
    }

    @Test("favourites are numbered from one, matching ⌘1–⌘9")
    func numbering() throws {
        let tree = try TempTree("fav-number")
        defer { tree.remove() }
        let store = store(in: tree)
        for name in ["A", "B", "C"] {
            store.add(try tree.directory(name))
        }

        #expect(store.favorite(number: 1)?.name == "A")
        #expect(store.favorite(number: 3)?.name == "C")
        #expect(store.favorite(number: 0) == nil)
        #expect(store.favorite(number: 4) == nil)
    }

    @Test("reordering moves an entry to the requested position")
    func reorder() throws {
        let tree = try TempTree("fav-order")
        defer { tree.remove() }
        let store = store(in: tree)
        for name in ["A", "B", "C"] {
            store.add(try tree.directory(name))
        }
        let c = try #require(store.favorite(number: 3))

        store.move(id: c.id, to: 0)
        #expect(store.favorites.map(\.name) == ["C", "A", "B"])

        store.move(id: c.id, to: 99)  // clamped to the end
        #expect(store.favorites.map(\.name) == ["A", "B", "C"])
    }

    @Test("rename and remove take effect")
    func renameAndRemove() throws {
        let tree = try TempTree("fav-edit")
        defer { tree.remove() }
        let store = store(in: tree)
        let favorite = try #require(store.add(try tree.directory("A")))

        store.rename(favorite, to: "Alpha")
        #expect(store.favorites.first?.name == "Alpha")

        store.remove(favorite)
        #expect(store.favorites.isEmpty)
    }

    @Test("favourites survive a reload from disk")
    func persistence() throws {
        let tree = try TempTree("fav-persist")
        defer { tree.remove() }
        let url = tree.root.appendingPathComponent("favorites.json")

        let first = FavoritesStore(fileURL: url)
        first.add(try tree.directory("Kept"), name: "Kept")

        let second = FavoritesStore(fileURL: url)
        #expect(second.favorites.map(\.name) == ["Kept"])
    }

    @Test("a favourite pointing at a deleted folder reports that it is gone")
    func detectsMissingFolder() throws {
        let tree = try TempTree("fav-missing")
        defer { tree.remove() }
        let folder = try tree.directory("Temporary")
        let store = store(in: tree)
        let favorite = try #require(store.add(folder))
        #expect(favorite.exists)

        try FileManager.default.removeItem(at: folder)
        #expect(store.favorites[0].exists == false)
    }

    @Test("a file is not a valid favourite target")
    func fileIsNotAFolder() throws {
        let tree = try TempTree("fav-file")
        defer { tree.remove() }
        let file = try tree.file("notes.txt", bytes: 3)
        #expect(Favorite(url: file).exists == false)
    }

    @Test("a corrupt favourites file degrades to an empty list")
    func corruptFile() throws {
        let tree = try TempTree("fav-corrupt")
        defer { tree.remove() }
        let url = tree.root.appendingPathComponent("favorites.json")
        try Data("this is not json".utf8).write(to: url)

        #expect(FavoritesStore(fileURL: url).favorites.isEmpty)
    }
}
