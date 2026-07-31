import AppKit
import Testing

@testable import ShlCommander

/// A filter session runs from the first typed character until Escape or a directory change.
/// Backspace belongs to it for that whole time, so clearing a filter can never walk the user
/// out of the directory they are in.
@MainActor
@Suite("Quick filter session")
struct QuickFilterSessionTests {
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.directory("sub")
        try tree.file("alpha.txt", bytes: 10)
        try tree.file("beta.txt", bytes: 10)
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    @Test("typing opens a session and filters as it goes")
    func typingOpensSession() async throws {
        let tree = try TempTree("session-type")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.isFiltering == false)
        panel.appendToFilter("b")
        #expect(panel.isFiltering)
        #expect(panel.filter == "b")
        // A substring match, so "sub" counts too.
        #expect(panel.entries.map(\.name) == ["..", "sub", "beta.txt"])

        panel.appendToFilter("e")
        #expect(panel.filter == "be")
        #expect(panel.entries.map(\.name) == ["..", "beta.txt"])
    }

    @Test("backspacing to empty keeps the session open")
    func backspaceToEmptyKeepsSession() async throws {
        let tree = try TempTree("session-backspace")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.appendToFilter("b")
        panel.appendToFilter("e")
        panel.deleteFilterCharacter()
        #expect(panel.filter == "b")

        panel.deleteFilterCharacter()
        #expect(panel.filter.isEmpty)
        // The session staying open is what stops the next Backspace from leaving the folder.
        #expect(panel.isFiltering)
        #expect(panel.entries.count == 4, "everything is visible again")
    }

    @Test("backspace on an empty filter does nothing at all")
    func backspaceOnEmptyIsNoOp() async throws {
        let tree = try TempTree("session-empty-backspace")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.appendToFilter("b")
        panel.deleteFilterCharacter()
        let directory = panel.directory

        panel.deleteFilterCharacter()
        panel.deleteFilterCharacter()

        #expect(panel.filter.isEmpty)
        #expect(panel.isFiltering)
        #expect(panel.directory == directory, "the panel did not move")
    }

    @Test("Escape ends the session")
    func escapeEndsSession() async throws {
        let tree = try TempTree("session-escape")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.appendToFilter("b")
        panel.stopFiltering()

        #expect(panel.isFiltering == false)
        #expect(panel.filter.isEmpty)
        #expect(panel.entries.count == 4)
    }

    @Test("a directory change ends the session")
    func navigationEndsSession() async throws {
        let tree = try TempTree("session-navigate")
        defer { tree.remove() }
        try tree.file("sub/inner.txt", bytes: 1)
        let panel = try await panel(in: tree)

        panel.appendToFilter("s")
        panel.navigate(to: tree.root.appendingPathComponent("sub"))
        await panel.settle()

        #expect(panel.isFiltering == false)
        #expect(panel.filter.isEmpty)
    }

    @Test("setFilter opens a session, and clearing through it does not")
    func setFilterSemantics() async throws {
        let tree = try TempTree("session-set")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.setFilter("beta")
        #expect(panel.isFiltering)

        panel.setFilter("")
        #expect(panel.isFiltering, "emptying the text is not the same as ending the session")
        panel.stopFiltering()
        #expect(panel.isFiltering == false)
    }

    @Test("Clear Filter is offered exactly while a session is open")
    func clearFilterEnablement() async throws {
        let tree = try TempTree("session-enable")
        defer { tree.remove() }
        let left = try TempTree("session-enable-right")
        defer { left.remove() }

        let state = AppState(
            left: tree.root, right: left.root, keymap: .defaults,
            settings: isolatedSettings()
        )
        state.start()
        await state.left.settle()
        let dispatcher = CommandDispatcher(state: state)

        #expect(dispatcher.isEnabled(.clearFilter) == false)

        state.left.appendToFilter("a")
        #expect(dispatcher.isEnabled(.clearFilter))

        // Still offered with the text emptied, because Backspace is still captive.
        state.left.deleteFilterCharacter()
        #expect(dispatcher.isEnabled(.clearFilter))

        dispatcher.perform(.clearFilter)
        #expect(state.left.isFiltering == false)
        #expect(dispatcher.isEnabled(.clearFilter) == false)
    }

    @Test("filtering to nothing still leaves the parent row and no crash")
    func filterMatchingNothing() async throws {
        let tree = try TempTree("session-nomatch")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        for character in "zzzz" { panel.appendToFilter(character) }
        #expect(panel.entries.map(\.name) == [".."])
        #expect(panel.cursor == 0)

        panel.deleteFilterCharacter()
        panel.deleteFilterCharacter()
        panel.deleteFilterCharacter()
        panel.deleteFilterCharacter()
        #expect(panel.entries.count == 4)
    }
}

@MainActor
@Suite("Delete confirmation summary")
struct DeleteSummaryTests {
    private func entry(_ name: String, directory: Bool = false, size: Int64 = 0) -> FileEntry {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        return FileEntry(
            url: url,
            name: name,
            baseName: url.deletingPathExtension().lastPathComponent,
            ext: directory ? "" : url.pathExtension.lowercased(),
            isDirectory: directory,
            isSymlink: false,
            isHidden: false,
            isPackage: false,
            size: size,
            modified: Date(timeIntervalSince1970: 0),
            isParent: false
        )
    }

    @Test("one file names itself in the headline")
    func singleFileHeadline() {
        let summary = OperationPrompts.deleteSummary(
            [entry("report.txt", size: 100)], toTrash: true)
        #expect(summary.headline.contains("report.txt"))
        #expect(summary.headline.contains("Trash"))
    }

    @Test("permanent deletion says so and never mentions the Trash as a way back")
    func permanentWording() {
        let summary = OperationPrompts.deleteSummary(
            [entry("report.txt", size: 100)], toTrash: false)
        #expect(summary.headline.contains("Permanently"))
        #expect(summary.detail.contains("cannot be undone"))
        #expect(summary.detail.contains("put back") == false)
    }

    @Test("a trash move says the items can be put back")
    func trashWording() {
        let summary = OperationPrompts.deleteSummary([entry("a.txt", size: 1)], toTrash: true)
        #expect(summary.detail.contains("put back"))
    }

    @Test("counts and total size are reported, folders flagged as recursive")
    func countsAndSize() {
        let summary = OperationPrompts.deleteSummary(
            [
                entry("a.txt", size: 1_000),
                entry("b.txt", size: 2_000),
                entry("folder", directory: true),
            ],
            toTrash: true
        )
        #expect(summary.headline.contains("3 items"))
        #expect(summary.detail.contains("2 files"))
        #expect(summary.detail.contains("1 folder"))
        #expect(summary.detail.contains("folder contents included"))
        // 3 kB of files; a folder's own size is not measured behind a dialog.
        #expect(summary.detail.contains("3 KB") || summary.detail.contains("3,000"))
    }

    @Test("full paths are listed, with folders marked by a trailing slash")
    func listsFullPaths() {
        // Names alone do not answer "which file"; the dialog is wide enough for the whole path.
        let summary = OperationPrompts.deleteSummary(
            [entry("keep.txt", size: 1), entry("stuff", directory: true)], toTrash: true)

        #expect(summary.paths == ["/tmp/keep.txt", "/tmp/stuff/"])
        // The prose stays prose: counts and consequence, no file list.
        #expect(summary.detail.contains("keep.txt") == false)
    }

    @Test("every item is listed, however many there are")
    func listsEverything() {
        // The list scrolls rather than the dialog growing, so nothing is truncated: an
        // "and 28 more" tail would hide exactly the items worth checking.
        let many = (1...40).map { entry("file-\($0).txt", size: 10) }
        let summary = OperationPrompts.deleteSummary(many, toTrash: true)

        #expect(summary.paths.count == 40)
        #expect(summary.paths.first == "/tmp/file-1.txt")
        #expect(summary.paths.last == "/tmp/file-40.txt")
        #expect(summary.detail.contains("more") == false)
    }

    @Test("the dialog is built wide enough for a path to be readable")
    func dialogIsWide() {
        // NSAlert sizes itself around its accessory view; the stock width fits about a folder
        // name, which is useless for confirming which file is about to go.
        #expect(OperationPrompts.dialogWidth >= 600)
    }

    @Test("a permanent delete needs typing for folders or for more than ten items")
    func typingRules() {
        let oneFile = [entry("a.txt", size: 1)]
        #expect(OperationPrompts.deleteNeedsTypedConfirmation(oneFile, toTrash: false) == false)
        #expect(
            OperationPrompts.deleteNeedsTypedConfirmation(
                [entry("folder", directory: true)], toTrash: false)
        )
        let eleven = (1...11).map { entry("f\($0).txt", size: 1) }
        #expect(OperationPrompts.deleteNeedsTypedConfirmation(eleven, toTrash: false))

        // A trash move never demands typing, however much is going.
        #expect(OperationPrompts.deleteNeedsTypedConfirmation(eleven, toTrash: true) == false)
    }
}
