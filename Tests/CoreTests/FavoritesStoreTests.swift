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

    @Test("tab names prefer the pane's own favourite for a shared folder")
    func namesPreferSide() throws {
        let tree = try TempTree("fav-names")
        defer { tree.remove() }
        let shared = try tree.directory("com~apple~CloudDocs")
        let other = try tree.directory("Other")
        let store = store(in: tree)
        store.add(shared, name: "Right iCloud", side: .right)
        store.add(shared, name: "iCloud", side: .left)
        store.add(other, name: "Elsewhere", side: .right)

        let names = store.names(preferring: .left)
        #expect(names[shared.standardizedFileURL.path] == "iCloud")
        #expect(names[other.standardizedFileURL.path] == "Elsewhere")
        #expect(store.names(preferring: .right)[shared.standardizedFileURL.path] == "Right iCloud")

        let tab = PanelTab(url: shared)
        #expect(tab.title(favoriteNames: names) == "iCloud")
        #expect(tab.title(favoriteNames: [:]) == "com~apple~CloudDocs")
    }

    @Test("favourites are numbered from one within their group")
    func numbering() throws {
        let tree = try TempTree("fav-number")
        defer { tree.remove() }
        let store = store(in: tree)
        for name in ["A", "B", "C"] {
            store.add(try tree.directory(name))
        }

        #expect(store.favorite(number: 1, on: .left)?.name == "A")
        #expect(store.favorite(number: 3, on: .left)?.name == "C")
        #expect(store.favorite(number: 0, on: .left) == nil)
        #expect(store.favorite(number: 4, on: .left) == nil)
        #expect(store.favorite(number: 1, on: .right) == nil)
    }

    @Test("reordering moves an entry to the requested position")
    func reorder() throws {
        let tree = try TempTree("fav-order")
        defer { tree.remove() }
        let store = store(in: tree)
        for name in ["A", "B", "C"] {
            store.add(try tree.directory(name))
        }
        let c = try #require(store.favorite(number: 3, on: .left))

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

    @Test("each pane's group is numbered on its own: ⌃1–⌃9 left, ⌘1–⌘9 right")
    func numberingPerSide() throws {
        let tree = try TempTree("fav-sides")
        defer { tree.remove() }
        let store = store(in: tree)
        store.add(try tree.directory("R1"), side: .right)
        store.add(try tree.directory("L1"), side: .left)
        store.add(try tree.directory("R2"), side: .right)

        #expect(store.favorite(number: 1, on: .left)?.name == "L1")
        #expect(store.favorite(number: 1, on: .right)?.name == "R1")
        #expect(store.favorite(number: 2, on: .right)?.name == "R2")
        #expect(store.favorites(on: .right).map(\.name) == ["R1", "R2"])
    }

    @Test("only the first nine favourites of a group get a shortcut number")
    func numbersStopAtNine() throws {
        let tree = try TempTree("fav-nine")
        defer { tree.remove() }
        let store = store(in: tree)
        for index in 1...10 {
            store.add(try tree.directory("F\(index)"), side: .right)
        }
        let left = try #require(store.add(try tree.directory("L"), side: .left))

        let numbers = store.favorites(on: .right).map { store.number(of: $0) }
        #expect(numbers == [1, 2, 3, 4, 5, 6, 7, 8, 9, nil])
        #expect(store.number(of: left) == 1)
    }

    @Test("the same folder may be a favourite of both panes")
    func sameFolderBothSides() throws {
        let tree = try TempTree("fav-both")
        defer { tree.remove() }
        let folder = try tree.directory("Shared")
        let store = store(in: tree)

        #expect(store.add(folder, side: .left) != nil)
        #expect(store.add(folder, side: .right) != nil)
        #expect(store.add(folder, side: .right) == nil)
    }

    @Test("a favourite can be moved to the other pane, by menu or by drag")
    func changeSide() throws {
        let tree = try TempTree("fav-move-side")
        defer { tree.remove() }
        let store = store(in: tree)
        let a = try #require(store.add(try tree.directory("A"), side: .left))
        let b = try #require(store.add(try tree.directory("B"), side: .right))

        store.setSide(a, to: .right)
        #expect(store.favorites(on: .right).map(\.name) == ["B", "A"])

        store.move(id: a.id, onto: b)
        #expect(store.favorites(on: .right).map(\.name) == ["A", "B"])

        store.setSide(b, to: .left)
        #expect(store.favorites(on: .left).map(\.name) == ["B"])
    }

    @Test("favourites saved before panes had their own load onto the left")
    func legacyFileLoadsLeft() throws {
        let tree = try TempTree("fav-legacy")
        defer { tree.remove() }
        let url = tree.root.appendingPathComponent("favorites.json")
        let json = #"[{"id":"\#(UUID().uuidString)","name":"Old","path":"/tmp"}]"#
        try Data(json.utf8).write(to: url)

        let store = FavoritesStore(fileURL: url)
        #expect(store.favorites.map(\.side) == [.left])
    }

    @Test("numbered favourite commands name their pane and position")
    func commandSlots() {
        #expect(Command.leftFavorite1.favoriteSlot! == (AppState.Side.left, 1))
        #expect(Command.rightFavorite9.favoriteSlot! == (AppState.Side.right, 9))
        #expect(Command.addFavorite.favoriteSlot == nil)
    }
}
