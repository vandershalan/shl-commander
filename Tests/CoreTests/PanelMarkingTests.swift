import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Panel marking and filtering")
struct PanelMarkingTests {
    /// `root/{sub/,alpha.txt,beta.txt,notes.md}` on a settled panel.
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.directory("sub")
        try tree.file("alpha.txt", bytes: 100)
        try tree.file("beta.txt", bytes: 200)
        try tree.file("notes.md", bytes: 30)
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    @Test("Space toggles the cursor row and leaves the cursor put")
    func spaceMarks() async throws {
        let tree = try TempTree("space")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 2  // "alpha.txt"
        panel.toggleMarkAtCursor(advance: false)
        #expect(panel.cursor == 2)
        #expect(panel.markedCount == 1)
        #expect(panel.markedBytes == 100)

        panel.toggleMarkAtCursor(advance: false)
        #expect(panel.markedCount == 0)
    }

    @Test("Insert marks and steps down so a run can be marked by holding the key")
    func insertAdvances() async throws {
        let tree = try TempTree("insert")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 2
        panel.toggleMarkAtCursor(advance: true)
        panel.toggleMarkAtCursor(advance: true)

        #expect(panel.cursor == 4)
        #expect(Set(panel.markedEntries.map(\.name)) == ["alpha.txt", "beta.txt"])
    }

    @Test("the parent row can never be marked")
    func parentUnmarkable() async throws {
        let tree = try TempTree("parentmark")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 0
        panel.toggleMarkAtCursor(advance: false)
        #expect(panel.markedCount == 0)

        panel.markAll()
        #expect(panel.markedEntries.contains { $0.isParent } == false)
        #expect(panel.markedCount == 4)  // sub + three files
    }

    @Test("invert flips marks and still skips the parent row")
    func invert() async throws {
        let tree = try TempTree("invert")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 2
        panel.toggleMarkAtCursor(advance: false)  // alpha.txt
        panel.invertMarks()

        #expect(Set(panel.markedEntries.map(\.name)) == ["sub", "beta.txt", "notes.md"])
    }

    @Test("glob patterns mark and unmark, case-insensitively")
    func globMarking() async throws {
        let tree = try TempTree("glob")
        defer { tree.remove() }
        try tree.file("REPORT.TXT", bytes: 5)
        let panel = try await panel(in: tree)

        panel.mark(matching: "*.txt", marked: true)
        #expect(Set(panel.markedEntries.map(\.name)) == ["alpha.txt", "beta.txt", "REPORT.TXT"])

        panel.mark(matching: "beta.*", marked: false)
        #expect(Set(panel.markedEntries.map(\.name)) == ["alpha.txt", "REPORT.TXT"])

        panel.mark(matching: "", marked: true)  // no pattern is a no-op, not a match-all
        #expect(panel.markedCount == 2)
    }

    @Test("actionTargets prefers marks and falls back to the cursor row")
    func actionTargets() async throws {
        let tree = try TempTree("targets")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 3  // "beta.txt"
        #expect(panel.actionTargets.map(\.name) == ["beta.txt"])

        panel.cursor = 2
        panel.toggleMarkAtCursor(advance: false)  // mark alpha.txt
        panel.cursor = 3  // cursor elsewhere, but marks win
        #expect(panel.actionTargets.map(\.name) == ["alpha.txt"])

        panel.clearMarks()
        panel.cursor = 0  // the parent row is never a target
        #expect(panel.actionTargets.isEmpty)
    }

    @Test("the filter narrows rows but always keeps a way back up")
    func filtering() async throws {
        let tree = try TempTree("filter")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.setFilter("ta")
        #expect(panel.entries.map(\.name) == ["..", "beta.txt"])

        panel.setFilter("TA")  // case-insensitive
        #expect(panel.entries.map(\.name) == ["..", "beta.txt"])

        panel.setFilter("zzz")
        #expect(panel.entries.map(\.name) == [".."])

        panel.stopFiltering()
        #expect(panel.entries.count == 5)
    }

    @Test("marks survive filtering but tallies only count visible rows")
    func filterHidesMarksFromTallies() async throws {
        let tree = try TempTree("filtermarks")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.markAll()
        #expect(panel.markedCount == 4)

        panel.setFilter("alpha")
        #expect(panel.markedCount == 1)  // only the visible one is actionable
        #expect(panel.marks.count == 4)  // but the marks themselves are intact

        panel.stopFiltering()
        #expect(panel.markedCount == 4)
    }

    @Test("navigating clears the filter so the next directory is not silently narrowed")
    func navigationClearsFilter() async throws {
        let tree = try TempTree("navfilter")
        defer { tree.remove() }
        try tree.file("sub/inner.txt", bytes: 1)
        let panel = try await panel(in: tree)

        panel.setFilter("sub")
        panel.cursor = 1
        panel.openCursor()
        await panel.settle()

        #expect(panel.filter.isEmpty)
        #expect(panel.entries.map(\.name) == ["..", "inner.txt"])
    }

    @Test("marks are dropped for files that disappear between reloads")
    func staleMarksPruned() async throws {
        let tree = try TempTree("stale")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.markAll()
        #expect(panel.marks.count == 4)

        try FileManager.default.removeItem(at: tree.root.appendingPathComponent("beta.txt"))
        panel.reload()
        await panel.settle()

        #expect(panel.marks.count == 3)
        #expect(panel.markedEntries.contains { $0.name == "beta.txt" } == false)
    }

    @Test("cursor moves clamp at both ends and page by the given row count")
    func cursorMoves() async throws {
        let tree = try TempTree("moves")
        defer { tree.remove() }
        let panel = try await panel(in: tree)  // 5 rows

        panel.move(.bottom)
        #expect(panel.cursor == 4)
        panel.move(.down)  // already at the end
        #expect(panel.cursor == 4)

        panel.move(.pageUp(rows: 2))
        #expect(panel.cursor == 2)
        panel.move(.pageUp(rows: 99))
        #expect(panel.cursor == 0)

        panel.move(.up)
        #expect(panel.cursor == 0)
        panel.move(.pageDown(rows: 3))
        #expect(panel.cursor == 3)
        panel.move(.top)
        #expect(panel.cursor == 0)
    }
}
