import AppKit

/// Turns a `Command` into an effect on `AppState`. The single place a command's meaning is
/// defined, shared by the keymap and the menu bar so the two can never drift.
@MainActor
struct CommandDispatcher {
    let state: AppState

    func perform(_ command: Command) {
        let panel = state.activePanel

        switch command {
        // Navigation
        case .switchPane:
            state.toggleActive()
        case .openCursor:
            panel.openCursor()
        case .goUp:
            panel.goUp()
        case .goToVolumeRoot:
            panel.goToVolumeRoot()
        case .historyBack:
            panel.historyBack()
        case .historyForward:
            panel.historyForward()
        case .refresh:
            panel.reload()

        // Display
        case .sortByName:
            panel.sort = panel.sort.toggled(to: .name)
        case .sortByExtension:
            panel.sort = panel.sort.toggled(to: .ext)
        case .sortByDate:
            panel.sort = panel.sort.toggled(to: .date)
        case .sortBySize:
            panel.sort = panel.sort.toggled(to: .size)
        case .toggleHidden:
            // Both panes follow, so the two never disagree about what exists.
            let showing = !panel.showHidden
            state.left.showHidden = showing
            state.right.showHidden = showing
        case .clearFilter:
            panel.filter = ""

        // Marking
        case .markToggle:
            panel.toggleMarkAtCursor(advance: false)
        case .markToggleAndAdvance:
            panel.toggleMarkAtCursor(advance: true)
        case .markByPattern:
            promptForPattern(on: panel, marked: true)
        case .unmarkByPattern:
            promptForPattern(on: panel, marked: false)
        case .invertMarks:
            panel.invertMarks()
        case .markAll:
            panel.markAll()
        case .markNone:
            panel.clearMarks()

        // Panes
        case .sendPathToOtherPane:
            state.inactivePanel.navigate(to: panel.directory)
        case .takePathFromOtherPane:
            panel.navigate(to: state.inactivePanel.directory)
        case .swapPanes:
            let leftDirectory = state.left.directory
            state.left.navigate(to: state.right.directory)
            state.right.navigate(to: leftDirectory)

        // Shell integration
        case .openInTerminal:
            openInTerminal(panel.directory)
        case .revealInFinder:
            revealInFinder(panel)
        case .copyPathToClipboard:
            copyPaths(panel)
        }
    }

    /// True when the command would currently do nothing, so menus can grey it out.
    func isEnabled(_ command: Command) -> Bool {
        let panel = state.activePanel
        switch command {
        case .historyBack: return panel.canGoBack
        case .historyForward: return panel.canGoForward
        case .clearFilter: return !panel.filter.isEmpty
        case .markNone, .invertMarks: return !panel.entries.isEmpty
        case .goUp: return DirectoryLister.parent(of: panel.directory) != nil
        default: return true
        }
    }

    // MARK: - Effects

    private func promptForPattern(on panel: PanelViewModel, marked: Bool) {
        let alert = NSAlert()
        alert.messageText = marked ? "Mark files matching" : "Unmark files matching"
        alert.informativeText = "Shell wildcards, for example *.txt or report?.pdf"
        let field = NSTextField(string: "*")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: marked ? "Mark" : "Unmark")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        panel.mark(matching: field.stringValue, marked: marked)
    }

    private func revealInFinder(_ panel: PanelViewModel) {
        let targets = panel.actionTargets.map(\.url)
        if targets.isEmpty {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: panel.directory.path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(targets)
        }
    }

    private func copyPaths(_ panel: PanelViewModel) {
        let targets = panel.actionTargets.map(\.url.path)
        let text = targets.isEmpty ? panel.directory.path : targets.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Prefers iTerm when it is installed, since anyone who has it installed wants it.
    private func openInTerminal(_ directory: URL) {
        let candidates = ["com.googlecode.iterm2", "com.apple.Terminal"]
        let application = candidates.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
        guard let application else { return }
        NSWorkspace.shared.open(
            [directory],
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
