import AppKit
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

    /// Loaded at launch and replaceable from Preferences, so a rebind takes effect at once.
    /// Menu shortcuts are the exception: SwiftUI installs those once and does not rebuild
    /// them on demand.
    var keymap: Keymap

    /// One operation at a time, shared by both panes.
    let operations = FileOperationQueue()

    /// Shared so a mount or unmount updates both panes' volume pickers at once.
    let volumes = VolumeService()

    let favorites = FavoritesStore()

    /// Outlives the pop-up favourites menu, which needs an NSObject target.
    let favoriteMenuTarget = FavoriteMenuTarget()

    /// `settings` is injectable so tests can run against their own defaults domain instead of
    /// the user's, which would otherwise pull in a real saved session.
    let settings: AppSettings

    init(
        left: URL = FileManager.default.homeDirectoryForCurrentUser,
        right: URL = FileManager.default.homeDirectoryForCurrentUser,
        keymap: Keymap = .loadFromDisk(),
        settings: AppSettings = .shared
    ) {
        self.left = PanelViewModel(directory: left)
        self.right = PanelViewModel(directory: right)
        self.keymap = keymap
        self.settings = settings
    }

    func panel(_ side: Side) -> PanelViewModel {
        side == .left ? left : right
    }

    var activePanel: PanelViewModel { panel(active) }
    var inactivePanel: PanelViewModel { panel(active.other) }

    func toggleActive() {
        active = active.other
    }

    /// Snapshot of both panes, for `session.json`.
    func currentSession() -> Session {
        left.captureActiveTab()
        right.captureActiveTab()
        return Session(
            left: PanelSession(tabs: left.tabs, activeTabIndex: left.activeTabIndex),
            right: PanelSession(tabs: right.tabs, activeTabIndex: right.activeTabIndex),
            activeSide: active,
            showHidden: left.showHidden
        )
    }

    func saveSession() {
        SessionStore.save(currentSession())
    }

    /// Applies a saved session. Tabs whose folders have since gone are dropped, and a pane
    /// left with nothing falls back to its default directory.
    func restore(_ session: Session) {
        left.showHidden = session.showHidden
        right.showHidden = session.showHidden
        left.restore(tabs: session.left.tabs, activeIndex: session.left.activeTabIndex)
        right.restore(tabs: session.right.tabs, activeIndex: session.right.activeTabIndex)
        active = session.activeSide
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
        // Written on quit rather than continuously; a crash costs at most the last session.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }

        if settings.restoreSession, let session = SessionStore.load() {
            restore(session)
        } else {
            // The panes were constructed with the directories they should open at, so this
            // path just loads them rather than second-guessing where they came from.
            left.showHidden = settings.showHiddenByDefault
            right.showHidden = settings.showHiddenByDefault
            left.navigate(to: left.directory)
            right.navigate(to: right.directory)
        }
    }
}
