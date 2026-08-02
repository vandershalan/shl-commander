import AppKit
import Testing

@testable import ShlCommander

@MainActor
@Suite("Drag sources and drop targets")
struct PanelDragTests {
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.directory("sub")
        try tree.file("alpha.txt", bytes: 10)
        try tree.file("beta.txt", bytes: 10)
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    private func row(_ panel: PanelViewModel, named name: String) throws -> Int {
        try #require(panel.entries.firstIndex { $0.name == name })
    }

    @Test("dragging an unmarked row carries that row alone")
    func unmarkedRow() async throws {
        let tree = try TempTree("drag-single")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        let urls = panel.dragSources(at: try row(panel, named: "alpha.txt"))
        #expect(urls.map(\.lastPathComponent) == ["alpha.txt"])
    }

    @Test("dragging a marked row takes every mark with it")
    func markedRows() async throws {
        let tree = try TempTree("drag-marks")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = try row(panel, named: "alpha.txt")
        panel.toggleMarkAtCursor(advance: false)
        panel.cursor = try row(panel, named: "beta.txt")
        panel.toggleMarkAtCursor(advance: false)

        let urls = panel.dragSources(at: try row(panel, named: "alpha.txt"))
        #expect(Set(urls.map(\.lastPathComponent)) == ["alpha.txt", "beta.txt"])
    }

    @Test("an unmarked row ignores marks elsewhere")
    func unmarkedRowIgnoresMarks() async throws {
        let tree = try TempTree("drag-mixed")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.cursor = try row(panel, named: "beta.txt")
        panel.toggleMarkAtCursor(advance: false)

        let urls = panel.dragSources(at: try row(panel, named: "alpha.txt"))
        #expect(urls.map(\.lastPathComponent) == ["alpha.txt"])
    }

    @Test("the parent row is not draggable")
    func parentRowIsNotDraggable() async throws {
        let tree = try TempTree("drag-parent")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.dragSources(at: try row(panel, named: "..")).isEmpty)
        #expect(panel.dragSources(at: -1).isEmpty)
        #expect(panel.dragSources(at: 99).isEmpty)
    }

    @Test("a drop over a folder lands in it; anywhere else lands in the pane's folder")
    func dropTargets() async throws {
        let tree = try TempTree("drop-target")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        let folder = panel.dropDestination(row: try row(panel, named: "sub"))
        #expect(folder?.lastPathComponent == "sub")

        let file = panel.dropDestination(row: try row(panel, named: "alpha.txt"))
        #expect(file?.standardizedFileURL == panel.directory.standardizedFileURL)

        #expect(panel.dropDestination(row: nil)?.standardizedFileURL
            == panel.directory.standardizedFileURL)
    }

    @Test("dropping onto .. means the folder above")
    func dropOnParent() async throws {
        let tree = try TempTree("drop-parent")
        defer { tree.remove() }
        try tree.directory("sub/inner")
        let panel = PanelViewModel(directory: tree.root.appendingPathComponent("sub"))
        panel.navigate(to: tree.root.appendingPathComponent("sub"))
        await panel.settle()

        let destination = panel.dropDestination(row: try row(panel, named: ".."))
        #expect(destination?.standardizedFileURL == tree.root.standardizedFileURL)
    }

    @Test("an archive pane takes no drops, and its rows cannot be dragged out")
    func archivesRefuseDrops() async throws {
        let tree = try TempTree("drop-archive")
        defer { tree.remove() }
        try tree.file("inside/file.txt", bytes: 4)
        let archive = try makeZip(from: tree.root.appendingPathComponent("inside"), in: tree)

        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        panel.openArchive(archive)
        await panel.settle()

        try #require(panel.isInsideArchive)
        #expect(panel.dropDestination(row: nil) == nil)
        // Members have no path on disk, so there is nothing a receiving app could open.
        let member = try #require(panel.entries.firstIndex { !$0.isParent })
        #expect(panel.dragSources(at: member).isEmpty)
    }

    /// A real zip, built with the same `tar` the app reads archives with.
    private func makeZip(from directory: URL, in tree: TempTree) throws -> URL {
        let archive = tree.root.appendingPathComponent("bundle.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", archive.path, directory.lastPathComponent]
        process.currentDirectoryURL = directory.deletingLastPathComponent()
        try process.run()
        process.waitUntilExit()
        return archive
    }
}

@MainActor
@Suite("Drop operation")
struct DropOperationTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    @Test("within one volume a drag moves")
    func sameVolumeMoves() {
        let operation = FileTableController.operation(
            dragging: [home.appendingPathComponent("a.txt")],
            to: home.appendingPathComponent("Documents"),
            allowed: [.copy, .move],
            modifiers: []
        )
        #expect(operation == .move)
    }

    @Test("Option forces a copy, Command forces a move")
    func modifiersWin() {
        let source = [home.appendingPathComponent("a.txt")]
        let destination = home.appendingPathComponent("Documents")

        #expect(
            FileTableController.operation(
                dragging: source, to: destination, allowed: [.copy, .move], modifiers: [.option])
                == .copy)
        #expect(
            FileTableController.operation(
                dragging: source, to: destination, allowed: [.copy, .move], modifiers: [.command])
                == .move)
    }

    @Test("a source that only allows copying is copied whatever is held down")
    func respectsAllowedMask() {
        let operation = FileTableController.operation(
            dragging: [home.appendingPathComponent("a.txt")],
            to: home,
            allowed: [.copy],
            modifiers: [.command]
        )
        #expect(operation == .copy)
    }

    @Test("files already in the destination are recognised as such")
    func detectsSameFolder() {
        let inside = [home.appendingPathComponent("a.txt"), home.appendingPathComponent("b.txt")]
        #expect(FileTableController.allSit(in: home, inside))
        #expect(
            FileTableController.allSit(
                in: home, inside + [home.appendingPathComponent("Documents/c.txt")]) == false)
    }

    @Test("a pasteboard with no file URLs yields nothing")
    func readsFileURLsOnly() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("shl-commander.tests.drop"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        #expect(FileTableController.fileURLs(on: pasteboard).isEmpty)

        pasteboard.clearContents()
        pasteboard.writeObjects([home as NSURL])
        #expect(FileTableController.fileURLs(on: pasteboard) == [home])
    }
}
