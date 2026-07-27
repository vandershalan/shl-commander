import SwiftUI

@main
struct ShlCommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owned here rather than in `MainWindow` so the menu bar can reach it too.
    @State private var state = AppState()

    var body: some Scene {
        Window("shl-commander", id: "main") {
            MainWindow(state: state)
        }
        .defaultSize(width: 1200, height: 750)
        .commands { MainCommands(state: state) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Deferred a turn: SwiftUI installs the menu bar after this callback returns.
        Task { @MainActor in
            await Task.yield()
            Self.pruneMenuBar()
        }
        #if DEBUG
            RenderProbe.run()
        #endif
    }

    /// Removes menu entries SwiftUI adds unconditionally for window features this app does
    /// not have. `CommandGroup(replacing: .sidebar)` does not suppress them — it leaves an
    /// empty "View" menu next to ours and a "Toggle Sidebar" item that toggles nothing.
    ///
    /// Matched on selector rather than title so the pass is not localisation-dependent.
    private static func pruneMenuBar() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let deadActions: Set<Selector> = [
            Selector(("toggleSidebar:")),
            Selector(("toggleToolbarShown:")),
            Selector(("runToolbarCustomizationPalette:")),
        ]

        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items where item.action.map(deadActions.contains) == true {
                submenu.removeItem(item)
            }
            while let first = submenu.items.first, first.isSeparatorItem {
                submenu.removeItem(first)
            }
            while let last = submenu.items.last, last.isSeparatorItem {
                submenu.removeItem(last)
            }
            if submenu.items.isEmpty {
                mainMenu.removeItem(top)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
