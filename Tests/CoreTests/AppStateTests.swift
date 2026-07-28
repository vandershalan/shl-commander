import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("AppState")
struct AppStateTests {
    @Test("Tab flips focus between the two panes")
    func toggleActive() {
        let state = AppState(settings: isolatedSettings())
        #expect(state.active == .left)
        #expect(state.activePanel === state.left)
        #expect(state.inactivePanel === state.right)

        state.toggleActive()
        #expect(state.active == .right)
        #expect(state.activePanel === state.right)
        #expect(state.inactivePanel === state.left)
    }

    @Test("the panes are independent view models")
    func independentPanes() throws {
        let left = try TempTree("left")
        let right = try TempTree("right")
        defer {
            left.remove()
            right.remove()
        }

        let state = AppState(left: left.root, right: right.root, settings: isolatedSettings())
        #expect(state.left !== state.right)
        #expect(state.left.directory.path == left.root.path)
        #expect(state.right.directory.path == right.root.path)

        state.left.sort = state.left.sort.toggled(to: .size)
        #expect(state.right.sort.key == .name)
    }

    @Test("start() loads both panes")
    func startLoadsBoth() async throws {
        let left = try TempTree("startleft")
        let right = try TempTree("startright")
        defer {
            left.remove()
            right.remove()
        }
        try left.file("l.txt")
        try right.file("r.txt")

        let state = AppState(left: left.root, right: right.root, settings: isolatedSettings())
        state.start()
        await state.left.settle()
        await state.right.settle()

        #expect(state.left.entries.contains { $0.name == "l.txt" })
        #expect(state.right.entries.contains { $0.name == "r.txt" })
    }
}
