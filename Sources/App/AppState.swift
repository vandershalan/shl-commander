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

    /// Loads both panes for the first time.
    func start() {
        left.navigate(to: left.directory)
        right.navigate(to: right.directory)
    }
}
