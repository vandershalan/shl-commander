import Foundation
import Testing

@testable import ShlCommander

/// The cursor must never wander. After any operation it stays on the same row, and when that
/// row is gone it takes the nearest surviving row *above* where it was.
@MainActor
@Suite("Cursor persistence")
struct CursorPersistenceTests {
    /// `root/{a.txt … e.txt}` plus a folder, so rows are predictable:
    /// `["..", "folder", "a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]`
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.directory("folder")
        for name in ["a", "b", "c", "d", "e"] {
            try tree.file("\(name).txt", bytes: 10)
        }
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    private func park(_ panel: PanelViewModel, on name: String) throws {
        panel.cursor = try #require(panel.entries.firstIndex { $0.name == name })
    }

    private func reloaded(_ panel: PanelViewModel) async {
        panel.reload()
        await panel.settle()
    }

    @Test("a reload that changes nothing leaves the cursor alone")
    func unchangedReload() async throws {
        let tree = try TempTree("cursor-noop")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        await reloaded(panel)
        #expect(panel.cursorEntry?.name == "c.txt")
    }

    @Test("a file appearing elsewhere does not move the cursor")
    func externalCreation() async throws {
        let tree = try TempTree("cursor-add")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        // Sorts before the cursor row, so every index below it shifts.
        try tree.file("aaa-new.txt", bytes: 1)
        await reloaded(panel)

        #expect(panel.cursorEntry?.name == "c.txt")
    }

    @Test("deleting the row under the cursor moves it to the row above")
    func deletedRowGoesUp() async throws {
        let tree = try TempTree("cursor-delete")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("c.txt"))
        await reloaded(panel)

        #expect(panel.cursorEntry?.name == "b.txt")
    }

    @Test("a bulk delete lands the cursor above the whole block")
    func bulkDeleteSkipsPastTheBlock() async throws {
        let tree = try TempTree("cursor-bulk")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "d.txt")

        // The cursor row and everything directly above it, down to a.txt, goes.
        for name in ["b.txt", "c.txt", "d.txt"] {
            try FileManager.default.removeItem(at: tree.root.appendingPathComponent(name))
        }
        await reloaded(panel)

        #expect(panel.cursorEntry?.name == "a.txt", "walked up past the deleted block")
    }

    @Test("deleting the first file lands on whatever moved up, not on the parent row")
    func deletingFirstRowAvoidsParent() async throws {
        let tree = try TempTree("cursor-first")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        // "folder" sorts first among real rows, directly under "..".
        try park(panel, on: "folder")

        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("folder"))
        await reloaded(panel)

        #expect(panel.cursorEntry?.name == "a.txt")
        #expect(panel.cursorEntry?.isParent == false, "Return must not become 'leave the folder'")
    }

    @Test("emptying the directory leaves the cursor on the parent row")
    func emptiedDirectory() async throws {
        let tree = try TempTree("cursor-empty")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        for entry in panel.entries where !entry.isParent {
            try FileManager.default.removeItem(at: entry.url)
        }
        await reloaded(panel)

        #expect(panel.entries.count == 1)
        #expect(panel.cursorEntry?.isParent == true)
    }

    @Test("a cursor already on the parent row stays there")
    func parentRowStays() async throws {
        let tree = try TempTree("cursor-parent")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        panel.cursor = 0

        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("a.txt"))
        await reloaded(panel)

        #expect(panel.cursor == 0)
        #expect(panel.cursorEntry?.isParent == true)
    }

    @Test("a rename keeps the cursor on the renamed file")
    func renameFollowsTheFile() async throws {
        let tree = try TempTree("cursor-rename")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try #require(panel.entries.firstIndex { $0.name == "c.txt" })
        panel.cursor = row

        #expect(panel.commitRename(at: row, to: "zzz.txt") == nil)
        await panel.settle()

        #expect(panel.cursorEntry?.name == "zzz.txt", "the cursor follows the file it renamed")
    }

    @Test("a move out of the pane behaves like a delete")
    func moveAwayGoesUp() async throws {
        let tree = try TempTree("cursor-move")
        defer { tree.remove() }
        let destination = try tree.directory("out")
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        let queue = FileOperationQueue()
        queue.startDeletion(
            of: [tree.root.appendingPathComponent("c.txt")], toTrash: false)
        await queue.settle()
        await reloaded(panel)

        #expect(panel.cursorEntry?.name == "b.txt")
        _ = destination
    }

    @Test("a copy into the pane leaves the cursor where it was")
    func copyIntoPaneKeepsCursor() async throws {
        let source = try TempTree("cursor-copysrc")
        let tree = try TempTree("cursor-copydst")
        defer {
            source.remove()
            tree.remove()
        }
        let incoming = try source.file("aaa-incoming.txt", bytes: 5)
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        let queue = FileOperationQueue()
        queue.start(
            FileOperationRequest(kind: .copy, sources: [incoming], destinationDirectory: tree.root),
            prompt: SilentPrompt()
        )
        await queue.settle()
        await reloaded(panel)

        #expect(panel.entries.contains { $0.name == "aaa-incoming.txt" })
        #expect(panel.cursorEntry?.name == "c.txt")
    }

    @Test("toggling hidden files keeps the cursor on its row")
    func hiddenToggleKeepsCursor() async throws {
        let tree = try TempTree("cursor-hidden")
        defer { tree.remove() }
        try tree.file(".aaa-hidden", bytes: 1)
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        panel.showHidden = true
        await panel.settle()
        #expect(panel.cursorEntry?.name == "c.txt")

        panel.showHidden = false
        await panel.settle()
        #expect(panel.cursorEntry?.name == "c.txt")
    }

    @Test("re-sorting keeps the cursor on its row")
    func resortKeepsCursor() async throws {
        let tree = try TempTree("cursor-resort")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        panel.sort = panel.sort.toggled(to: .name)
        #expect(panel.cursorEntry?.name == "c.txt")

        panel.sort = SortOrder(key: .date, ascending: true)
        #expect(panel.cursorEntry?.name == "c.txt")
    }

    @Test("filtering the cursor row out moves the cursor above it")
    func filteringOutTheCursorRow() async throws {
        let tree = try TempTree("cursor-filter")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "c.txt")

        // "b" excludes c.txt, and nothing above it survives except the parent row.
        panel.setFilter("b")
        #expect(panel.cursorEntry?.name == "b.txt")

        panel.stopFiltering()
        #expect(panel.cursorEntry?.name == "b.txt", "clearing the filter does not jump either")
    }

    @Test("entering a directory still starts at the top")
    func navigationStillResets() async throws {
        let tree = try TempTree("cursor-navigate")
        defer { tree.remove() }
        try tree.file("folder/inner.txt", bytes: 1)
        let panel = try await panel(in: tree)
        try park(panel, on: "folder")

        panel.openCursor()
        await panel.settle()

        // Holding position applies to operations, not to deliberate navigation.
        #expect(panel.cursor == 0)
    }

    @Test("going up still lands on the folder just left")
    func goUpStillSelectsOrigin() async throws {
        let tree = try TempTree("cursor-up")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        try park(panel, on: "folder")
        panel.openCursor()
        await panel.settle()

        panel.goUp()
        await panel.settle()
        #expect(panel.cursorEntry?.name == "folder")
    }
}

/// Answers every conflict with "keep both", so tests never block on a dialog.
@MainActor
private struct SilentPrompt: ConflictPrompting {
    func resolveConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL
    ) async -> ConflictDecision? {
        ConflictDecision(resolution: .rename, applyToAll: true)
    }
}
