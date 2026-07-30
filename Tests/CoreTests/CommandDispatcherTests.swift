import AppKit
import Testing

@testable import ShlCommander

@MainActor
@Suite("CommandDispatcher")
struct CommandDispatcherTests {
    private struct Fixture {
        let left: TempTree
        let right: TempTree
        let state: AppState
        let dispatcher: CommandDispatcher

        func remove() {
            left.remove()
            right.remove()
        }
    }

    private func fixture() async throws -> Fixture {
        let left = try TempTree("dispatch-left")
        let right = try TempTree("dispatch-right")
        try left.directory("sub")
        try left.file("a.txt", bytes: 10)
        try left.file("b.log", bytes: 20)
        try right.file("r.txt", bytes: 5)

        let state = AppState(
            left: left.root, right: right.root, keymap: .defaults,
            settings: isolatedSettings()
        )
        state.start()
        await state.left.settle()
        await state.right.settle()

        return Fixture(
            left: left, right: right, state: state,
            dispatcher: CommandDispatcher(state: state)
        )
    }

    @Test("switchPane flips which panel commands act on")
    func switchPane() async throws {
        let f = try await fixture()
        defer { f.remove() }

        f.dispatcher.perform(.switchPane)
        #expect(f.state.active == .right)
        f.dispatcher.perform(.switchPane)
        #expect(f.state.active == .left)
    }

    @Test("sort commands act on the active pane only, and reverse on repeat")
    func sortCommands() async throws {
        let f = try await fixture()
        defer { f.remove() }

        f.dispatcher.perform(.sortBySize)
        #expect(f.state.left.sort == SortOrder(key: .size, ascending: true))
        f.dispatcher.perform(.sortBySize)
        #expect(f.state.left.sort.ascending == false)
        // The other pane is untouched.
        #expect(f.state.right.sort.key == .name)

        f.dispatcher.perform(.sortByExtension)
        #expect(f.state.left.sort == SortOrder(key: .ext, ascending: true))
    }

    @Test("toggleHidden applies to both panes so they cannot disagree")
    func hiddenIsGlobal() async throws {
        let f = try await fixture()
        defer { f.remove() }

        f.dispatcher.perform(.toggleHidden)
        #expect(f.state.left.showHidden)
        #expect(f.state.right.showHidden)

        f.dispatcher.perform(.toggleHidden)
        #expect(f.state.left.showHidden == false)
        #expect(f.state.right.showHidden == false)
    }

    @Test("path commands move directories between the panes")
    func pathHandoff() async throws {
        let f = try await fixture()
        defer { f.remove() }

        f.dispatcher.perform(.sendPathToOtherPane)
        await f.state.right.settle()
        #expect(f.state.right.directory.path == f.left.root.path)

        f.dispatcher.perform(.switchPane)  // right is active, still on left's path
        f.dispatcher.perform(.takePathFromOtherPane)
        await f.state.right.settle()
        #expect(f.state.right.directory.path == f.left.root.path)
    }

    @Test("swapPanes exchanges the two directories")
    func swapPanes() async throws {
        let f = try await fixture()
        defer { f.remove() }

        f.dispatcher.perform(.swapPanes)
        await f.state.left.settle()
        await f.state.right.settle()

        #expect(f.state.left.directory.path == f.right.root.path)
        #expect(f.state.right.directory.path == f.left.root.path)
    }

    @Test("history walks back and forward across navigations")
    func history() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let panel = f.state.left

        #expect(f.dispatcher.isEnabled(.historyBack) == false)

        panel.cursor = 1  // "sub"
        f.dispatcher.perform(.openCursor)
        await panel.settle()
        #expect(panel.directory.lastPathComponent == "sub")
        #expect(f.dispatcher.isEnabled(.historyBack))

        f.dispatcher.perform(.historyBack)
        await panel.settle()
        #expect(panel.directory.path == f.left.root.path)
        #expect(f.dispatcher.isEnabled(.historyForward))

        f.dispatcher.perform(.historyForward)
        await panel.settle()
        #expect(panel.directory.lastPathComponent == "sub")
    }

    @Test("a fresh navigation clears the forward history")
    func navigationClearsForward() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let panel = f.state.left

        panel.cursor = 1
        f.dispatcher.perform(.openCursor)  // into sub
        await panel.settle()
        f.dispatcher.perform(.historyBack)
        await panel.settle()
        #expect(panel.canGoForward)

        panel.navigate(to: f.right.root)
        await panel.settle()
        #expect(panel.canGoForward == false)
    }

    @Test("mark commands act through the dispatcher")
    func marking() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let panel = f.state.left

        f.dispatcher.perform(.markAll)
        #expect(panel.markedCount == 3)  // sub, a.txt, b.log

        f.dispatcher.perform(.invertMarks)
        #expect(panel.markedCount == 0)

        panel.cursor = 2
        f.dispatcher.perform(.markToggleAndAdvance)
        #expect(panel.cursor == 3)
        #expect(panel.markedCount == 1)

        f.dispatcher.perform(.markNone)
        #expect(panel.markedCount == 0)
    }

    @Test("clearFilter is disabled until there is a filter to clear")
    func filterEnablement() async throws {
        let f = try await fixture()
        defer { f.remove() }

        #expect(f.dispatcher.isEnabled(.clearFilter) == false)
        f.state.left.setFilter("a")
        #expect(f.dispatcher.isEnabled(.clearFilter))

        f.dispatcher.perform(.clearFilter)
        #expect(f.state.left.filter.isEmpty)
    }

    @Test("goUp is disabled at the volume root")
    func goUpEnablement() async throws {
        let f = try await fixture()
        defer { f.remove() }

        #expect(f.dispatcher.isEnabled(.goUp))
        f.state.left.navigate(to: URL(fileURLWithPath: "/"))
        await f.state.left.settle()
        #expect(f.dispatcher.isEnabled(.goUp) == false)
    }

    @Test("copyPathToClipboard writes marked paths, or the directory when nothing is marked")
    func copyPath() async throws {
        let f = try await fixture()
        defer { f.remove() }
        let panel = f.state.left

        f.dispatcher.perform(.copyPathToClipboard)
        #expect(NSPasteboard.general.string(forType: .string) == panel.directory.path)

        panel.cursor = 2  // "a.txt"
        panel.toggleMarkAtCursor(advance: false)
        f.dispatcher.perform(.copyPathToClipboard)
        // Compared against the listed entry, not against a rebuilt path: contentsOfDirectory
        // hands back children under /private/var while the panel's own path stays /var.
        #expect(NSPasteboard.general.string(forType: .string) == panel.cursorEntry?.url.path)
    }

    @Test("volume root navigation lands on a directory that has no parent")
    func volumeRoot() async throws {
        let f = try await fixture()
        defer { f.remove() }

        f.dispatcher.perform(.goToVolumeRoot)
        await f.state.left.settle()
        #expect(DirectoryLister.parent(of: f.state.left.directory) == nil)
    }
}
