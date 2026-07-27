import Foundation
import Observation

/// Owns both panes and which one has focus. Every command acts on `activePanel`, with the
/// other pane as the implicit destination for copy and move.
@MainActor
@Observable
final class AppState {
    enum Side: String, CaseIterable, Codable, Sendable {
        case left, right

        var other: Side { self == .left ? .right : .left }
    }

    let left: PanelViewModel
    let right: PanelViewModel
    var active: Side = .left

    /// Loaded once at launch. Rebinding requires a relaunch until step 9's keymap editor.
    let keymap: Keymap

    /// One operation at a time, shared by both panes.
    let operations = FileOperationQueue()

    /// Shared so a mount or unmount updates both panes' volume pickers at once.
    let volumes = VolumeService()

    init(
        left: URL = FileManager.default.homeDirectoryForCurrentUser,
        right: URL = FileManager.default.homeDirectoryForCurrentUser,
        keymap: Keymap = .loadFromDisk()
    ) {
        self.left = PanelViewModel(directory: left)
        self.right = PanelViewModel(directory: right)
        self.keymap = keymap
    }

    func panel(_ side: Side) -> PanelViewModel {
        side == .left ? left : right
    }

    var activePanel: PanelViewModel { panel(active) }
    var inactivePanel: PanelViewModel { panel(active.other) }

    func toggleActive() {
        active = active.other
    }

    /// Loads both panes for the first time and wires operation follow-up.
    func start() {
        // Until step 5 adds FSEvents, an operation's result only shows after an explicit
        // reload of both panes — the source pane lost items, the destination gained them.
        operations.onCompletion = { [weak self] in
            guard let self else { return }
            self.left.reload()
            self.right.reload()
            let failures = self.operations.failures
            if !failures.isEmpty {
                OperationPrompts.report(failures)
                self.operations.dismissFailures()
            }
        }
        left.navigate(to: left.directory)
        right.navigate(to: right.directory)
    }
}
