import AppKit
import Testing

@testable import ShlCommander

@MainActor
@Suite("File clipboard")
struct FileClipboardTests {
    /// A private pasteboard, so the tests never touch the user's clipboard.
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("shl-commander.tests.\(UUID().uuidString)"))
    }

    private struct Fixture {
        let left: TempTree
        let right: TempTree
        let state: AppState
        let dispatcher: CommandDispatcher

        func remove() {
            left.remove()
            right.remove()
        }

        @MainActor func select(_ name: String, in panel: PanelViewModel) throws {
            panel.cursor = try #require(panel.entries.firstIndex { $0.name == name })
        }
    }

    private func fixture() async throws -> Fixture {
        let left = try TempTree("clip-left")
        let right = try TempTree("clip-right")
        try left.file("a.txt", bytes: 10)
        try left.directory("sub")

        let state = AppState(
            left: left.root, right: right.root, keymap: .defaults,
            settings: isolatedSettings(), clipboard: FileClipboard(pasteboard: pasteboard())
        )
        state.start()
        await state.left.settle()
        await state.right.settle()
        return Fixture(
            left: left, right: right, state: state, dispatcher: CommandDispatcher(state: state))
    }

    @Test("copy puts file URLs on the pasteboard, not marked as cut")
    func copyWritesURLs() {
        let clipboard = FileClipboard(pasteboard: pasteboard())
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        clipboard.copy([url])
        #expect(clipboard.contents() == .init(urls: [url], isCut: false))
    }

    @Test("a cut is forgotten once something else is copied")
    func cutExpires() {
        let board = pasteboard()
        let clipboard = FileClipboard(pasteboard: board)
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        clipboard.cut([url])
        #expect(clipboard.contents()?.isCut == true)

        // Another app copying files bumps the change count.
        board.clearContents()
        board.writeObjects([url as NSURL])
        #expect(clipboard.contents()?.isCut == false)
    }

    @Test("an empty pasteboard has nothing to paste")
    func emptyPasteboard() {
        #expect(FileClipboard(pasteboard: pasteboard()).contents() == nil)
    }

    @Test("⌘C then ⌘V in the other pane copies, leaving the source")
    func copyPaste() async throws {
        let f = try await fixture()
        defer { f.remove() }

        try f.select("a.txt", in: f.state.left)
        f.dispatcher.perform(.copyToClipboard)
        f.dispatcher.perform(.switchPane)
        f.dispatcher.perform(.pasteFromClipboard)
        await f.state.operations.settle()

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: f.right.root.appendingPathComponent("a.txt").path))
        #expect(fm.fileExists(atPath: f.left.root.appendingPathComponent("a.txt").path))
    }

    @Test("⌘X keeps the source until ⌘V moves it")
    func cutPaste() async throws {
        let f = try await fixture()
        defer { f.remove() }

        let source = f.left.root.appendingPathComponent("a.txt")
        try f.select("a.txt", in: f.state.left)
        f.dispatcher.perform(.cutToClipboard)
        #expect(FileManager.default.fileExists(atPath: source.path), "nothing goes at cut time")

        f.dispatcher.perform(.switchPane)
        f.dispatcher.perform(.pasteFromClipboard)
        await f.state.operations.settle()

        #expect(FileManager.default.fileExists(
            atPath: f.right.root.appendingPathComponent("a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(f.state.clipboard.contents() == nil, "a pasted cut empties the clipboard")
    }

    @Test("pasting a copy into its own folder keeps both")
    func pasteIntoSameFolder() async throws {
        let f = try await fixture()
        defer { f.remove() }

        try f.select("a.txt", in: f.state.left)
        f.dispatcher.perform(.copyToClipboard)
        f.dispatcher.perform(.pasteFromClipboard)
        await f.state.operations.settle()

        let names = try FileManager.default.contentsOfDirectory(atPath: f.left.root.path)
        #expect(names.filter { $0.hasSuffix(".txt") }.count == 2)
    }

    @Test("a folder is not pasted inside itself")
    func pasteIntoItself() async throws {
        let f = try await fixture()
        defer { f.remove() }

        try f.select("sub", in: f.state.left)
        f.dispatcher.perform(.copyToClipboard)
        f.state.left.navigate(to: f.left.root.appendingPathComponent("sub"))
        await f.state.left.settle()
        f.dispatcher.perform(.pasteFromClipboard)
        await f.state.operations.settle()

        let inside = try FileManager.default.contentsOfDirectory(
            atPath: f.left.root.appendingPathComponent("sub").path)
        #expect(inside.isEmpty)
    }
}
