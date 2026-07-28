import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Panel tabs")
struct PanelTabTests {
    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.directory("alpha")
        try tree.directory("beta")
        try tree.file("root.txt", bytes: 4)
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    @Test("a pane starts with exactly one tab and hides its strip")
    func startsWithOneTab() async throws {
        let tree = try TempTree("tab-start")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        #expect(panel.tabs.count == 1)
        #expect(panel.activeTabIndex == 0)
        #expect(panel.hasMultipleTabs == false)
    }

    @Test("a new tab opens beside the current one and becomes active")
    func openTab() async throws {
        let tree = try TempTree("tab-open")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.openTab(at: tree.root.appendingPathComponent("alpha"))
        await panel.settle()

        #expect(panel.tabs.count == 2)
        #expect(panel.activeTabIndex == 1)
        #expect(panel.directory.lastPathComponent == "alpha")
        #expect(panel.hasMultipleTabs)
    }

    @Test("each tab remembers its own folder, sort, and cursor")
    func tabsKeepTheirOwnState() async throws {
        let tree = try TempTree("tab-state")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        // First tab: sorted by size, cursor parked on a file.
        panel.sort = SortOrder(key: .size, ascending: false)
        let row = try #require(panel.entries.firstIndex { $0.name == "root.txt" })
        panel.cursor = row

        panel.openTab(at: tree.root.appendingPathComponent("alpha"))
        await panel.settle()
        panel.sort = SortOrder(key: .date, ascending: true)

        panel.selectTab(0)
        await panel.settle()
        #expect(panel.sort == SortOrder(key: .size, ascending: false))
        #expect(panel.cursorEntry?.name == "root.txt")

        panel.selectTab(1)
        await panel.settle()
        #expect(panel.sort == SortOrder(key: .date, ascending: true))
        #expect(panel.directory.lastPathComponent == "alpha")
    }

    @Test("the last tab cannot be closed")
    func cannotCloseLastTab() async throws {
        let tree = try TempTree("tab-last")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.closeActiveTab()
        #expect(panel.tabs.count == 1, "a pane always shows something")
    }

    @Test("closing a tab moves to a neighbour")
    func closeTab() async throws {
        let tree = try TempTree("tab-close")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.openTab(at: tree.root.appendingPathComponent("alpha"))
        await panel.settle()
        panel.closeActiveTab()
        await panel.settle()

        #expect(panel.tabs.count == 1)
        #expect(panel.activeTabIndex == 0)
        #expect(panel.directory.path == tree.root.path)
    }

    @Test("next and previous wrap around")
    func cycling() async throws {
        let tree = try TempTree("tab-cycle")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        panel.openTab(at: tree.root.appendingPathComponent("alpha"))
        await panel.settle()
        panel.openTab(at: tree.root.appendingPathComponent("beta"))
        await panel.settle()

        #expect(panel.activeTabIndex == 2)
        panel.nextTab()
        await panel.settle()
        #expect(panel.activeTabIndex == 0, "wraps past the end")

        panel.previousTab()
        await panel.settle()
        #expect(panel.activeTabIndex == 2, "wraps past the start")
    }

    @Test("navigating updates the active tab's label")
    func navigationUpdatesTab() async throws {
        let tree = try TempTree("tab-navigate")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.navigate(to: tree.root.appendingPathComponent("beta"))
        await panel.settle()
        #expect(panel.tabs[0].title == "beta")
    }

    @Test("switching tabs does not add history entries")
    func tabSwitchIsNotNavigation() async throws {
        let tree = try TempTree("tab-history")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.openTab(at: tree.root.appendingPathComponent("alpha"))
        await panel.settle()
        let couldGoBack = panel.canGoBack

        panel.selectTab(0)
        await panel.settle()
        panel.selectTab(1)
        await panel.settle()

        #expect(panel.canGoBack == couldGoBack, "tab switches left history alone")
    }

    @Test("restoring drops tabs whose folders are gone")
    func restoreSkipsMissing() async throws {
        let tree = try TempTree("tab-restore")
        defer { tree.remove() }
        let panel = try await panel(in: tree)
        let alive = PanelTab(url: tree.root.appendingPathComponent("alpha"))
        let dead = PanelTab(url: tree.root.appendingPathComponent("deleted-since"))

        panel.restore(tabs: [dead, alive], activeIndex: 1)
        await panel.settle()

        #expect(panel.tabs.count == 1)
        #expect(panel.directory.lastPathComponent == "alpha")
    }

    @Test("restoring nothing usable falls back to the current folder")
    func restoreFallsBack() async throws {
        let tree = try TempTree("tab-fallback")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.restore(tabs: [PanelTab(url: URL(fileURLWithPath: "/nope-gone"))], activeIndex: 0)
        #expect(panel.tabs.count == 1)
        #expect(panel.directory.path == tree.root.path)
    }
}

@MainActor
@Suite("Session")
struct SessionTests {
    @Test("a session round-trips through disk")
    func roundTrip() throws {
        let tree = try TempTree("session-roundtrip")
        defer { tree.remove() }
        let url = tree.root.appendingPathComponent("session.json")

        let session = Session(
            left: PanelSession(
                tabs: [PanelTab(url: tree.root, sort: SortOrder(key: .size, ascending: false))],
                activeTabIndex: 0
            ),
            right: PanelSession(tabs: [PanelTab(url: tree.root)], activeTabIndex: 0),
            activeSide: .right,
            showHidden: true
        )
        SessionStore.save(session, to: url)

        let loaded = try #require(SessionStore.load(from: url))
        #expect(loaded.activeSide == .right)
        #expect(loaded.showHidden)
        #expect(loaded.left.tabs[0].sort == SortOrder(key: .size, ascending: false))
    }

    @Test("a missing or corrupt session file loads as nil rather than throwing")
    func missingSession() throws {
        let tree = try TempTree("session-missing")
        defer { tree.remove() }
        #expect(SessionStore.load(from: tree.root.appendingPathComponent("absent.json")) == nil)

        let corrupt = tree.root.appendingPathComponent("corrupt.json")
        try Data("nonsense".utf8).write(to: corrupt)
        #expect(SessionStore.load(from: corrupt) == nil)
    }

    @Test("capturing a session records both panes and the active side")
    func capture() async throws {
        let left = try TempTree("session-left")
        let right = try TempTree("session-right")
        defer {
            left.remove()
            right.remove()
        }
        try left.directory("sub")

        let state = AppState(left: left.root, right: right.root, keymap: .defaults)
        state.left.navigate(to: left.root)
        state.right.navigate(to: right.root)
        await state.left.settle()
        await state.right.settle()
        state.active = .right
        state.left.openTab(at: left.root.appendingPathComponent("sub"))
        await state.left.settle()

        let session = state.currentSession()
        #expect(session.activeSide == .right)
        #expect(session.left.tabs.count == 2)
        #expect(session.left.activeTabIndex == 1)
        #expect(session.right.tabs.count == 1)
    }

    @Test("restoring puts both panes back where they were")
    func restore() async throws {
        let left = try TempTree("session-rleft")
        let right = try TempTree("session-rright")
        defer {
            left.remove()
            right.remove()
        }
        let sub = try left.directory("sub")

        let state = AppState(left: left.root, right: right.root, keymap: .defaults)
        state.restore(
            Session(
                left: PanelSession(
                    tabs: [PanelTab(url: left.root), PanelTab(url: sub)],
                    activeTabIndex: 1
                ),
                right: PanelSession(tabs: [PanelTab(url: right.root)], activeTabIndex: 0),
                activeSide: .right,
                showHidden: true
            )
        )
        await state.left.settle()
        await state.right.settle()

        #expect(state.active == .right)
        #expect(state.left.tabs.count == 2)
        #expect(state.left.directory.lastPathComponent == "sub")
        #expect(state.left.showHidden)
        #expect(state.right.showHidden, "the hidden-files setting is shared")
    }
}
