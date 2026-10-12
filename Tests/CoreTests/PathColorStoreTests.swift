import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("PathColorStore")
struct PathColorStoreTests {
    private func store(in tree: TempTree, seeding favorites: [Favorite] = []) -> PathColorStore {
        PathColorStore(
            fileURL: tree.root.appendingPathComponent("pathcolors.json"),
            seedingFrom: favorites
        )
    }

    @Test("with no file, favourites seed the list deepest first")
    func seedsFromFavorites() throws {
        let tree = try TempTree("colors-seed")
        defer { tree.remove() }
        let store = store(
            in: tree,
            seeding: [
                Favorite(name: "Home", path: "/Users/me"),
                Favorite(name: "Drive", path: "/Users/me/OneDrive"),
            ]
        )

        #expect(store.rules.map(\.pattern) == ["/Users/me/OneDrive", "/Users/me"])
        #expect(store.rules[0].color != store.rules[1].color)
    }

    @Test("the first matching rule from the top wins, ignoring case")
    func firstMatchWins() throws {
        let tree = try TempTree("colors-match")
        defer { tree.remove() }
        let store = store(in: tree)
        let drive = store.add(pattern: "onedrive")
        let home = store.add(pattern: "/Users/me")

        #expect(store.color(for: "/Users/me/OneDrive/Docs") == drive.color)
        #expect(store.color(for: "/Users/me/Desktop") == home.color)
        #expect(store.color(for: "/Volumes/Backup") == nil)

        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.color(for: "/Users/me/OneDrive/Docs") == home.color)
    }

    @Test("an empty fragment matches nothing")
    func emptyPatternIgnored() throws {
        let tree = try TempTree("colors-empty")
        defer { tree.remove() }
        let store = store(in: tree)
        store.add(pattern: "  ")

        #expect(store.color(for: "/anything") == nil)
    }

    @Test("~ stands for the home folder")
    func tildeExpands() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rule = PathColorRule(pattern: "~/Qsync", color: PaletteColor(rawValue: "red-500"))

        #expect(rule.matches(home + "/Qsync/Photos"))
        #expect(!rule.matches("/Qsync"))
    }

    @Test("edits persist, and a saved list is not reseeded")
    func persists() throws {
        let tree = try TempTree("colors-save")
        defer { tree.remove() }
        var rule = store(in: tree).add(pattern: "Qsync")
        let first = store(in: tree)
        rule.color = PaletteColor(rawValue: "teal-600")
        first.update(rule)

        let reloaded = store(in: tree, seeding: [Favorite(name: "X", path: "/x")])
        #expect(reloaded.rules == [rule])
    }

    @Test("an unknown colour name falls back to grey")
    func unknownColor() {
        #expect(PaletteColor(rawValue: "chartreuse").rawValue == "neutral-500")
        #expect(PaletteColor.grid.count == 8)
        #expect(PaletteColor.grid.allSatisfy { $0.count == 12 })
    }
}
