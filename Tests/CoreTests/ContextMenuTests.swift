import AppKit
import Testing

@testable import ShlCommander

@MainActor
@Suite("Open With")
struct OpenWithStoreTests {
    /// Seeded from nowhere, so a test never depends on what is installed on the machine.
    private func store(_ label: String) -> (OpenWithStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shl-openwith-\(label)-\(UUID().uuidString).json")
        return (OpenWithStore(fileURL: url, seedingFrom: []), url)
    }

    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    private let missing = URL(fileURLWithPath: "/Applications/Not Installed.app")

    @Test("a chosen application is remembered and survives a reload")
    func persistence() {
        let (store, url) = store("persist")
        defer { try? FileManager.default.removeItem(at: url) }

        let app = store.remember(textEdit)
        #expect(app.name == "TextEdit")
        #expect(OpenWithStore(fileURL: url, seedingFrom: []).apps.map(\.path) == [textEdit.path])
    }

    @Test("choosing the same application again moves it to the front")
    func mostRecentFirst() {
        let (store, url) = store("order")
        defer { try? FileManager.default.removeItem(at: url) }

        store.remember(textEdit)
        store.remember(missing)
        #expect(store.apps.first?.path == missing.path)

        store.remember(textEdit)
        #expect(store.apps.map(\.path) == [textEdit.path, missing.path])
    }

    @Test("the list is capped, oldest choices falling off")
    func capped() {
        let (store, url) = store("cap")
        defer { try? FileManager.default.removeItem(at: url) }

        for index in 1...20 {
            store.remember(URL(fileURLWithPath: "/Applications/App\(index).app"))
        }
        #expect(store.apps.count == 12)
        #expect(store.apps.first?.name == "App20")
    }

    @Test("an uninstalled application is not offered, but is not forgotten either")
    func availability() {
        let (store, url) = store("available")
        defer { try? FileManager.default.removeItem(at: url) }

        store.remember(textEdit)
        store.remember(missing)
        #expect(store.available.map(\.name) == ["TextEdit"])
        // Kept in the file: reinstalling the app should bring the entry back.
        #expect(store.apps.count == 2)
    }

    @Test("removing takes it out for good")
    func removal() {
        let (store, url) = store("remove")
        defer { try? FileManager.default.removeItem(at: url) }

        let app = store.remember(textEdit)
        store.remove(app)
        #expect(store.apps.isEmpty)
        #expect(OpenWithStore(fileURL: url, seedingFrom: []).apps.isEmpty)
    }

    @Test("remembered applications join the system's suggestions, without duplicates")
    func candidates() throws {
        let tree = try TempTree("openwith-candidates")
        defer { tree.remove() }
        let file = try tree.file("notes.txt", bytes: 4)

        let remembered = [OpenWithApp(url: textEdit)]
        let candidates = AppOpener.candidates(for: [file], remembered: remembered)

        #expect(candidates.contains { $0.path == textEdit.path })
        #expect(Set(candidates.map(\.path)).count == candidates.count)
    }

    @Test("a folder still offers the remembered applications")
    func folderCandidates() throws {
        let tree = try TempTree("openwith-folder")
        defer { tree.remove() }
        let folder = try tree.directory("project")

        // Nothing claims public.folder except the Finder, which is the whole reason the
        // remembered list exists — an editor has to be offered from somewhere.
        let candidates = AppOpener.candidates(
            for: [folder], remembered: [OpenWithApp(url: textEdit)])
        #expect(candidates.contains { $0.name == "TextEdit" })
    }
}

@MainActor
@Suite("Open With seeding")
struct OpenWithSeedingTests {
    @Test("a first run picks up the editors and terminals that are installed")
    func seeding() throws {
        let tree = try TempTree("openwith-seed")
        defer { tree.remove() }
        // A stand-in /Applications holding two of the names worth seeding and one that is not.
        try tree.directory("Applications/Cursor.app")
        try tree.directory("Applications/iTerm.app")
        try tree.directory("Applications/Chess.app")

        let file = tree.root.appendingPathComponent("openwith.json")
        let store = OpenWithStore(
            fileURL: file, seedingFrom: [tree.root.appendingPathComponent("Applications")])

        #expect(store.apps.map(\.name) == ["Cursor", "iTerm"])
        // Written straight away, so a list the user then empties is not seeded again.
        #expect(FileManager.default.fileExists(atPath: file.path))
        let reopened = OpenWithStore(fileURL: file, seedingFrom: [])
        #expect(reopened.apps.map(\.name) == ["Cursor", "iTerm"])
    }

    @Test("an emptied list stays empty across launches")
    func emptiedListIsNotReseeded() throws {
        let tree = try TempTree("openwith-empty")
        defer { tree.remove() }
        try tree.directory("Applications/Cursor.app")
        let folders = [tree.root.appendingPathComponent("Applications")]
        let file = tree.root.appendingPathComponent("openwith.json")

        let store = OpenWithStore(fileURL: file, seedingFrom: folders)
        for app in store.apps { store.remove(app) }

        #expect(OpenWithStore(fileURL: file, seedingFrom: folders).apps.isEmpty)
    }
}

@MainActor
@Suite("Row context menu")
struct RowContextMenuTests {
    private func state(_ tree: TempTree) async throws -> AppState {
        try tree.directory("sub")
        try tree.file("alpha.txt", bytes: 10)
        try tree.file("beta.txt", bytes: 10)
        let state = AppState(
            left: tree.root, right: tree.root, keymap: .defaults, settings: isolatedSettings())
        state.start()
        await state.left.settle()
        return state
    }

    private func row(_ panel: PanelViewModel, named name: String) throws -> Int {
        try #require(panel.entries.firstIndex { $0.name == name })
    }

    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test("a file row offers the file commands and Open With")
    func fileRow() async throws {
        let tree = try TempTree("menu-file")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        let menu = RowContextMenu.build(
            row: try row(panel, named: "alpha.txt"), panel: panel, state: state)
        let items = titles(menu)

        #expect(items.contains("Open With"))
        #expect(items.contains(Command.copyToOtherPane.title))
        #expect(items.contains(Command.moveToTrash.title))
        #expect(items.contains(Command.renameInPlace.title))
        // Text and editor items belong to files only.
        #expect(items.contains(Command.viewInternal.title))
        #expect(items.contains("Mark"))
    }

    @Test("a folder row offers the folder-only items instead")
    func folderRow() async throws {
        let tree = try TempTree("menu-folder")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        let items = titles(
            RowContextMenu.build(row: try row(panel, named: "sub"), panel: panel, state: state))
        #expect(items.contains("New Terminal at Folder"))
        #expect(items.contains("Add to Favourites"))
        #expect(items.contains(Command.viewInternal.title) == false)
    }

    @Test("a click on nothing is about the pane's own folder")
    func backgroundMenu() async throws {
        let tree = try TempTree("menu-background")
        defer { tree.remove() }
        let state = try await state(tree)

        let items = titles(RowContextMenu.build(row: nil, panel: state.left, state: state))
        #expect(items.contains(Command.newFolder.title))
        #expect(items.contains("Open This Folder With"))
        #expect(items.contains(Command.addFavorite.title))
        // Nothing was clicked, so nothing is copied or deleted.
        #expect(items.contains(Command.moveToTrash.title) == false)
    }

    @Test("the parent row has no file menu of its own")
    func parentRow() async throws {
        let tree = try TempTree("menu-parent")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        let items = titles(
            RowContextMenu.build(row: try row(panel, named: ".."), panel: panel, state: state))
        #expect(items.contains(Command.newFolder.title), "it falls back to the folder menu")
    }

    @Test("items carry the command's own ⌘ key")
    func keyEquivalents() async throws {
        let tree = try TempTree("menu-keys")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        let menu = RowContextMenu.build(
            row: try row(panel, named: "alpha.txt"), panel: panel, state: state)
        let copy = try #require(menu.items.first { $0.title == Command.copyToOtherPane.title })
        #expect(copy.keyEquivalent == "c")
        #expect(copy.keyEquivalentModifierMask == .command)
    }

    @Test("Open With lists something, and always offers Other…")
    func openWithSubmenu() async throws {
        let tree = try TempTree("menu-openwith")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        let menu = RowContextMenu.build(
            row: try row(panel, named: "alpha.txt"), panel: panel, state: state)
        let submenu = try #require(menu.items.first { $0.title == "Open With" }?.submenu)
        #expect(titles(submenu).last == "Other…")
    }

    @Test("right-clicking an unmarked row acts on that row, marks elsewhere or not")
    func targetsFollowTheClick() async throws {
        let tree = try TempTree("menu-targets")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        panel.cursor = try row(panel, named: "beta.txt")
        panel.toggleMarkAtCursor(advance: false)

        // The clicked row is not the marked one, so it alone is the target.
        let clicked = panel.contextMenuTargets(at: try row(panel, named: "alpha.txt"))
        #expect(clicked.map(\.name) == ["alpha.txt"])

        // While the override is in force, that is what the commands would act on.
        panel.contextTargets = clicked
        #expect(panel.actionTargets.map(\.name) == ["alpha.txt"])
        panel.contextTargets = nil
        #expect(panel.actionTargets.map(\.name) == ["beta.txt"], "the marks are untouched")
    }

    @Test("right-clicking a marked row acts on every mark")
    func markedRowTakesTheSet() async throws {
        let tree = try TempTree("menu-marked")
        defer { tree.remove() }
        let state = try await state(tree)
        let panel = state.left

        for name in ["alpha.txt", "beta.txt"] {
            panel.cursor = try row(panel, named: name)
            panel.toggleMarkAtCursor(advance: false)
        }

        let targets = panel.contextMenuTargets(at: try row(panel, named: "alpha.txt"))
        #expect(Set(targets.map(\.name)) == ["alpha.txt", "beta.txt"])
    }
}

@Suite("Menu key equivalents")
struct KeyEquivalentStringTests {
    @Test("letters and punctuation carry over")
    func printableKeys() throws {
        #expect(try #require(KeyChord(parsing: "cmd+c")).keyEquivalentString == "c")
        #expect(try #require(KeyChord(parsing: "cmd+shift+period")).keyEquivalentString == ".")
    }

    @Test("Return and Backspace get their control characters")
    func specialKeys() throws {
        #expect(try #require(KeyChord(parsing: "cmd+return")).keyEquivalentString == "\r")
        #expect(
            try #require(KeyChord(parsing: "cmd+backspace")).keyEquivalentString
                == String(UnicodeScalar(NSBackspaceCharacter)!))
    }

    @Test("keys a menu cannot draw report nothing")
    func unprintableKeys() throws {
        #expect(try #require(KeyChord(parsing: "f5")).keyEquivalentString == nil)
        #expect(try #require(KeyChord(parsing: "cmd+up")).keyEquivalentString == nil)
    }
}
