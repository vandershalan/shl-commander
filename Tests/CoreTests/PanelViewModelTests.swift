import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("PanelViewModel")
struct PanelViewModelTests {
    /// Builds `root/{sub/,a.txt,b.md}` and a panel already settled on `root`.
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.directory("sub")
        try tree.file("a.txt", bytes: 100)
        try tree.file("b.md", bytes: 20)
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    @Test("a listing is led by the parent row, then directories, then files")
    func listingShape() async throws {
        let tree = try TempTree("shape")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.entries.map(\.name) == ["..", "sub", "a.txt", "b.md"])
        #expect(panel.loadError == nil)
        #expect(panel.isLoading == false)
        #expect(panel.cursor == 0)
    }

    @Test("tallies count only real rows and only file bytes")
    func tallies() async throws {
        let tree = try TempTree("tallies")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.directoryCount == 1)  // "sub", not ".."
        #expect(panel.fileCount == 2)
        #expect(panel.totalBytes == 120)
    }

    @Test("descending into a directory resets the cursor to the parent row")
    func descend() async throws {
        let tree = try TempTree("descend")
        defer { tree.remove() }
        try tree.file("sub/inner.txt", bytes: 3)
        let panel = try await panel(in: tree)

        panel.cursor = 1  // "sub"
        panel.openCursor()
        await panel.settle()

        #expect(panel.directory.lastPathComponent == "sub")
        #expect(panel.entries.map(\.name) == ["..", "inner.txt"])
        #expect(panel.cursor == 0)
    }

    @Test("ascending parks the cursor on the directory just left")
    func ascendSelectsOrigin() async throws {
        let tree = try TempTree("ascend")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 1
        panel.openCursor()
        await panel.settle()
        panel.goUp()
        await panel.settle()

        #expect(panel.directory.path == tree.root.path)
        #expect(panel.cursorEntry?.name == "sub")
    }

    @Test("the parent row ascends the same way goUp does")
    func parentRowAscends() async throws {
        let tree = try TempTree("parentrow")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 1
        panel.openCursor()
        await panel.settle()

        panel.cursor = 0  // ".."
        panel.openCursor()
        await panel.settle()

        #expect(panel.directory.path == tree.root.path)
    }

    @Test("re-sorting holds the cursor on the same name")
    func resortKeepsCursor() async throws {
        let tree = try TempTree("resort")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 2  // "a.txt"
        #expect(panel.cursorEntry?.name == "a.txt")

        panel.sort = panel.sort.toggled(to: .name)  // now descending

        #expect(panel.entries.map(\.name) == ["..", "sub", "b.md", "a.txt"])
        #expect(panel.cursorEntry?.name == "a.txt")
        #expect(panel.cursor == 3)
    }

    @Test("toggling hidden files reloads and keeps the cursor")
    func hiddenToggleReloads() async throws {
        let tree = try TempTree("hiddentoggle")
        defer { tree.remove() }
        try tree.file(".secret", bytes: 1)
        let panel = try await panel(in: tree)

        #expect(panel.entries.contains { $0.name == ".secret" } == false)
        panel.cursor = 2  // "a.txt"

        panel.showHidden = true
        await panel.settle()

        #expect(panel.entries.contains { $0.name == ".secret" })
        #expect(panel.cursorEntry?.name == "a.txt")
    }

    @Test("the cursor clamps instead of dangling past the last row")
    func cursorClamps() async throws {
        let tree = try TempTree("clamp")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = 999
        #expect(panel.cursor == panel.entries.count - 1)

        panel.cursor = -5
        #expect(panel.cursor == 0)
    }

    @Test("an unreadable directory reports the error and empties the panel")
    func loadFailure() async throws {
        let panel = PanelViewModel(directory: URL(fileURLWithPath: "/nope-\(UUID().uuidString)"))
        panel.navigate(to: panel.directory)
        await panel.settle()

        #expect(panel.entries.isEmpty)
        #expect(panel.loadError != nil)
        #expect(panel.isLoading == false)
    }
}
