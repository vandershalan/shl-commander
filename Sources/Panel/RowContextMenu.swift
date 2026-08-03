import AppKit

/// The right-click menu for a row, and for the empty space below the rows.
///
/// Every item runs a `Command` through `CommandDispatcher`, so a menu entry and its key can
/// never mean two different things — the exceptions are Open With and the folder-specific
/// Terminal item, which have no command of their own.
@MainActor
enum RowContextMenu {
    /// Builds the menu for `row`, or the folder menu when the click was not on a file row.
    ///
    /// The cursor is expected to have been moved to `row` already: several commands act on the
    /// cursor rather than on a list of targets.
    static func build(row: Int?, panel: PanelViewModel, state: AppState) -> NSMenu {
        let dispatcher = CommandDispatcher(state: state)
        let targets = row.map { panel.contextMenuTargets(at: $0) } ?? []
        let menu = NSMenu()
        menu.autoenablesItems = false

        guard !targets.isEmpty else {
            addFolderItems(to: menu, panel: panel, state: state, dispatcher: dispatcher)
            return menu
        }

        let urls = targets.map(\.url)
        let openable = targets.allSatisfy { !$0.isArchiveMember }
        let single = targets.count == 1 ? targets[0] : nil

        add(.openCursor, to: menu, panel: panel, targets: targets, state: state)

        // Archive members have no path on disk, so there is nothing another app could be
        // handed; F5 is what gets them out.
        if openable {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWith.submenu = openWithMenu(for: urls, state: state)
            menu.addItem(openWith)
        }

        menu.addItem(.separator())
        add(.quickLook, to: menu, panel: panel, targets: targets, state: state)
        if single?.isDirectory == false {
            add(.viewInternal, to: menu, panel: panel, targets: targets, state: state)
            add(.editFile, to: menu, panel: panel, targets: targets, state: state)
        }

        menu.addItem(.separator())
        add(.copyToOtherPane, to: menu, panel: panel, targets: targets, state: state)
        add(.moveToOtherPane, to: menu, panel: panel, targets: targets, state: state)
        add(.duplicate, to: menu, panel: panel, targets: targets, state: state)
        if single != nil {
            add(.renameInPlace, to: menu, panel: panel, targets: targets, state: state)
        }
        add(.moveToTrash, to: menu, panel: panel, targets: targets, state: state)
        add(.deletePermanently, to: menu, panel: panel, targets: targets, state: state)

        menu.addItem(.separator())
        if let folder = single, folder.isDirectory, !folder.isArchiveMember {
            menu.addItem(
                item("New Terminal at Folder") {
                    CommandDispatcher(state: state).openTerminal(at: folder.url)
                })
            menu.addItem(
                item("Add to Favourites") {
                    state.favorites.add(folder.url)
                })
        }
        add(.revealInFinder, to: menu, panel: panel, targets: targets, state: state)
        add(.copyPathToClipboard, to: menu, panel: panel, targets: targets, state: state)

        menu.addItem(.separator())
        let marked = targets.allSatisfy { panel.isMarked($0) }
        menu.addItem(
            item(marked ? "Unmark" : "Mark") {
                for entry in targets where panel.isMarked(entry) != !marked {
                    panel.toggleMark(entry)
                }
            })

        return menu
    }

    /// The menu for a click that landed on nothing: the pane's own folder is the subject.
    private static func addFolderItems(
        to menu: NSMenu,
        panel: PanelViewModel,
        state: AppState,
        dispatcher: CommandDispatcher
    ) {
        add(.newFolder, to: menu, panel: panel, targets: [], state: state)
        add(.newFile, to: menu, panel: panel, targets: [], state: state)
        menu.addItem(.separator())

        let openWith = NSMenuItem(title: "Open This Folder With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: [panel.directory], state: state)
        menu.addItem(openWith)
        add(.openInTerminal, to: menu, panel: panel, targets: [], state: state)
        add(.revealInFinder, to: menu, panel: panel, targets: [], state: state)

        menu.addItem(.separator())
        add(.addFavorite, to: menu, panel: panel, targets: [], state: state)
        add(.measureAllDirectories, to: menu, panel: panel, targets: [], state: state)
        add(.refresh, to: menu, panel: panel, targets: [], state: state)
    }

    /// System suggestions first, then the apps the user has picked before, then "Other…".
    private static func openWithMenu(for urls: [URL], state: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let candidates = AppOpener.candidates(for: urls)
        let systemDefault = urls.first.flatMap { AppOpener.defaultApplication(for: $0) }

        if candidates.isEmpty {
            let empty = NSMenuItem(title: "No applications known", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for app in candidates {
            let isDefault = app.path == systemDefault?.path
            let entry = item(isDefault ? "\(app.name) (default)" : app.name) {
                AppOpener.open(urls, with: app.url)
            }
            entry.toolTip = app.path
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(
            item("Other…") {
                guard let application = AppOpener.chooseApplication() else { return }
                AppOpener.open(urls, with: application)
            })
        return menu
    }

    // MARK: - Items

    /// Adds a command, carrying its ⌘ key so the menu teaches the keyboard, and the targets the
    /// click implies.
    private static func add(
        _ command: Command,
        to menu: NSMenu,
        panel: PanelViewModel,
        targets: [FileEntry],
        state: AppState
    ) {
        let entry = item(command.title) {
            let dispatcher = CommandDispatcher(state: state)
            panel.contextTargets = targets.isEmpty ? nil : targets
            dispatcher.perform(command)
            panel.contextTargets = nil
        }
        if let chord = state.keymap.menuChord(for: command),
            let key = chord.keyEquivalentString
        {
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = chord.modifiers
        }
        menu.addItem(entry)
    }

    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        let entry = NSMenuItem(
            title: title,
            action: #selector(MenuActionTarget.fire(_:)),
            keyEquivalent: ""
        )
        entry.target = MenuActionTarget.shared
        entry.representedObject = MenuAction(run)
        return entry
    }
}

/// A closure an `NSMenuItem` can carry. Items retain their `representedObject`, so each one
/// keeps its own action alive for as long as the menu exists.
@MainActor
final class MenuAction: NSObject {
    let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }
}

/// The one target every context-menu item points at.
///
/// `NSMenuItem` holds its target weakly and needs it to outlive the menu, which rules out the
/// per-command `CommandDispatcher` struct; the work itself lives in each item's `MenuAction`.
@MainActor
final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func fire(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }
}
