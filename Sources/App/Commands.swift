import SwiftUI

/// The menu bar, built from the same keymap the keyboard uses. Rebinding a ⌘ chord in
/// `keymap.json` moves the menu shortcut with it, so the two can never disagree.
struct MainCommands: Commands {
    let state: AppState

    private var dispatcher: CommandDispatcher { CommandDispatcher(state: state) }

    var body: some Commands {
        // SwiftUI's stock Edit menu claims ⌘A for Select All and ⌘C for Copy, which are the
        // natural bindings for Mark All and Copy here. Menus win key equivalents before a
        // view ever sees the event, so the defaults are removed rather than shadowed.
        CommandGroup(replacing: .pasteboard) {}
        CommandGroup(replacing: .undoRedo) {}
        CommandGroup(replacing: .newItem) {}
        // Sidebar and toolbar commands are not removable this way — replacing them with an
        // empty group still leaves an empty "View" menu in the bar and a dead "Toggle
        // Sidebar" item. `AppDelegate.pruneMenuBar()` strips those afterwards.

        // Listed one by one because `CommandsBuilder` takes `Commands`, and `ForEach` is a
        // `View`. The section enum still decides which items land in each menu.
        CommandMenu(Command.Section.file.title) { items(in: .file) }
        CommandMenu(Command.Section.mark.title) { items(in: .mark) }
        CommandMenu(Command.Section.go.title) { items(in: .go) }
        CommandMenu(Command.Section.view.title) { items(in: .view) }
        CommandMenu(Command.Section.panes.title) { items(in: .panes) }
        CommandMenu(Command.Section.favorites.title) { items(in: .favorites) }
    }

    @ViewBuilder
    private func items(in section: Command.Section) -> some View {
        ForEach(Command.allCases.filter { $0.section == section }, id: \.self) { command in
            item(command)
        }
    }

    /// Items are never disabled.
    ///
    /// `Commands` bodies do not re-evaluate on observable changes the way `View` bodies do,
    /// so a `.disabled` state snapshot goes stale — Invert Marks stayed greyed out seconds
    /// after the panel had loaded. A menu that lies about what is available is worse than
    /// one where an inapplicable command quietly does nothing, which `CommandDispatcher`
    /// already guarantees.
    @ViewBuilder
    private func item(_ command: Command) -> some View {
        let action = { dispatcher.perform(command) }
        if let chord = state.keymap.menuChord(for: command), let key = chord.keyEquivalent {
            Button(command.title, action: action)
                .keyboardShortcut(key, modifiers: chord.eventModifiers)
        } else {
            Button(command.title, action: action)
        }
    }
}
