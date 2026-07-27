import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Panel rename")
struct PanelRenameTests {
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.file("report.txt", bytes: 10)
        try tree.file("other.txt", bytes: 10)
        try tree.directory("folder")
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    private func index(of name: String, in panel: PanelViewModel) throws -> Int {
        try #require(panel.entries.firstIndex { $0.name == name })
    }

    @Test("renaming moves the file and lands the cursor on the new name")
    func renameFile() async throws {
        let tree = try TempTree("rename")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "report.txt", in: panel)

        #expect(panel.commitRename(at: row, to: "summary.txt") == nil)
        await panel.settle()

        #expect(panel.entries.contains { $0.name == "summary.txt" })
        #expect(panel.entries.contains { $0.name == "report.txt" } == false)
        #expect(panel.cursorEntry?.name == "summary.txt")
    }

    @Test("renaming a folder works the same way")
    func renameFolder() async throws {
        let tree = try TempTree("renamedir")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "folder", in: panel)

        #expect(panel.commitRename(at: row, to: "archive") == nil)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "archive" })
    }

    @Test("an unchanged or empty name is a no-op, not an error")
    func noOpNames() async throws {
        let tree = try TempTree("renamenoop")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "report.txt", in: panel)

        #expect(panel.commitRename(at: row, to: "report.txt") == nil)
        #expect(panel.commitRename(at: row, to: "   ") == nil)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "report.txt" })
    }

    @Test("surrounding whitespace is trimmed away")
    func trimsWhitespace() async throws {
        let tree = try TempTree("renametrim")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "report.txt", in: panel)

        #expect(panel.commitRename(at: row, to: "  spaced.txt  ") == nil)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "spaced.txt" })
    }

    @Test("colliding with an existing name is refused and changes nothing")
    func refusesCollision() async throws {
        let tree = try TempTree("renamecollide")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "report.txt", in: panel)

        let message = panel.commitRename(at: row, to: "other.txt")
        #expect(message?.contains("already exists") == true)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "report.txt" })
        #expect(try Data(contentsOf: tree.root.appendingPathComponent("other.txt")).count == 10)
    }

    @Test("a case-only change is allowed, not treated as a collision with itself")
    func caseOnlyRename() async throws {
        let tree = try TempTree("renamecase")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "report.txt", in: panel)

        // On a case-insensitive volume the target "exists" — it is the same file.
        #expect(panel.commitRename(at: row, to: "REPORT.txt") == nil)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "REPORT.txt" })
    }

    @Test("path separators are rejected")
    func rejectsSeparators() async throws {
        let tree = try TempTree("renameslash")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let row = try index(of: "report.txt", in: panel)

        #expect(panel.commitRename(at: row, to: "sub/report.txt") != nil)
        #expect(panel.commitRename(at: row, to: "a:b.txt") != nil)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "report.txt" })
    }

    @Test("the parent row cannot be renamed")
    func parentRowNotRenamable() async throws {
        let tree = try TempTree("renameparent")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.commitRename(at: 0, to: "nope") == nil)
        await panel.settle()
        #expect(panel.entries[0].name == "..")
    }

    @Test("an out-of-range row is ignored rather than crashing")
    func outOfRangeRow() async throws {
        let tree = try TempTree("renamerange")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        #expect(panel.commitRename(at: 999, to: "whatever") == nil)
    }

    @Test("requestRename bumps the counter, except on the parent row")
    func renameRequests() async throws {
        let tree = try TempTree("renamerequest")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.renameRequestID == 0)
        panel.cursor = 0  // ".."
        panel.requestRename()
        #expect(panel.renameRequestID == 0, "there is nothing to rename")

        panel.cursor = 1
        panel.requestRename()
        #expect(panel.renameRequestID == 1)
        panel.requestRename()
        #expect(panel.renameRequestID == 2, "consecutive requests stay distinguishable")
    }
}
