import AppKit

/// Turns a `Command` into an effect on `AppState`. The single place a command's meaning is
/// defined, shared by the keymap and the menu bar so the two can never drift.
@MainActor
struct CommandDispatcher {
    let state: AppState

    func perform(_ command: Command) {
        let panel = state.activePanel

        switch command {
        // Help
        case .showShortcuts:
            ShortcutsWindow.show(keymap: state.keymap)

        // Viewing
        case .quickLook:
            quickLook(panel)
        case .viewInternal:
            guard let entry = panel.actionTargets.first, !entry.isDirectory else { break }
            InternalViewer.show(entry.url)
        case .editFile:
            edit(panel)

        // File operations
        case .newFolder:
            createItem(on: panel, directory: true)
        case .newFile:
            createItem(on: panel, directory: false)
        case .copyToOtherPane:
            startTransfer(.copy)
        case .moveToOtherPane:
            startTransfer(.move)
        case .duplicate:
            duplicate(on: panel)
        case .renameInPlace:
            panel.requestRename()
        case .moveToTrash:
            delete(on: panel, toTrash: true)
        case .deletePermanently:
            delete(on: panel, toTrash: false)

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
            panel.stopFiltering()
        case .measureSelectedDirectories:
            panel.measureSelectedDirectories()
        case .measureAllDirectories:
            panel.measureAllDirectories()

        // Marking
        case .markToggle:
            // Total Commander also measures a folder when you mark it with Space, which is
            // the quickest way to size one directory.
            if let entry = panel.cursorEntry, entry.isDirectory, !entry.isParent {
                panel.sizer.request([entry])
            }
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

        // Tabs
        case .newTab:
            panel.openTab()
        case .closeTab:
            panel.closeActiveTab()
        case .nextTab:
            panel.nextTab()
        case .previousTab:
            panel.previousTab()
        case .openInOtherPaneTab:
            openInOtherPaneTab(from: panel)

        // Favourites
        case .addFavorite:
            addFavorite(panel.directory)
        case .showFavorites:
            showFavoritesMenu()
        case .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6,
            .favorite7, .favorite8, .favorite9:
            guard let number = command.favoriteNumber,
                let favorite = state.favorites.favorite(number: number)
            else { break }
            open(favorite)

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
        case .clearFilter: return panel.isFiltering
        case .markNone, .invertMarks: return !panel.entries.isEmpty
        case .goUp: return DirectoryLister.parent(of: panel.directory) != nil
        default: return true
        }
    }

    // MARK: - File operations

    /// Copy and move both confirm through a dialog holding the other pane's path, which is
    /// how Total Commander works: Enter accepts, and the path can be edited to send the files
    /// somewhere else entirely.
    private func startTransfer(_ kind: FileOperationKind) {
        let panel = state.activePanel
        let targets = panel.actionTargets
        guard !targets.isEmpty, !state.operations.isRunning else { return }

        let summary = targets.count == 1
            ? "\u{22}\(targets[0].name)\u{22}"
            : "\(targets.count) items"
        guard
            let typed = OperationPrompts.askForName(
                title: "\(kind.title) \(summary) to:",
                message: "The folder is created if it does not exist.",
                initial: state.inactivePanel.directory.path,
                buttonTitle: kind.title
            )
        else { return }

        guard let destination = resolveDestination(typed) else { return }
        state.operations.start(
            FileOperationRequest(
                kind: kind,
                sources: targets.map(\.url),
                destinationDirectory: destination
            ),
            prompt: OperationPrompts()
        )
    }

    /// Turns typed text into a usable destination directory, creating it when needed.
    private func resolveDestination(_ typed: String) -> URL? {
        let expanded = (typed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                OperationPrompts.report([
                    OperationFailure(url: url, message: "Not a folder.")
                ])
                return nil
            }
            return url
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            OperationPrompts.report([
                OperationFailure(url: url, message: error.localizedDescription)
            ])
            return nil
        }
    }

    /// Copies into the current directory, where every name collides by definition — so it
    /// resolves to "keep both" without asking.
    private func duplicate(on panel: PanelViewModel) {
        let targets = panel.actionTargets
        guard !targets.isEmpty, !state.operations.isRunning else { return }

        state.operations.start(
            FileOperationRequest(
                kind: .copy,
                sources: targets.map(\.url),
                destinationDirectory: panel.directory,
                automaticResolution: .rename
            ),
            prompt: OperationPrompts()
        )
    }

    private func delete(on panel: PanelViewModel, toTrash: Bool) {
        let targets = panel.actionTargets
        guard !targets.isEmpty, !state.operations.isRunning else { return }
        // Both kinds confirm, listing what is about to go: a mistaken Trash move is
        // recoverable, but only once you work out what disappeared.
        guard OperationPrompts.confirmDelete(targets, toTrash: toTrash) else { return }

        state.operations.startDeletion(of: targets.map(\.url), toTrash: toTrash)
    }

    private func createItem(on panel: PanelViewModel, directory: Bool) {
        guard
            let name = OperationPrompts.askForName(
                title: directory ? "New folder name:" : "New file name:"
            )
        else { return }
        // "/" is a path separator and ":" is one to the classic Finder APIs; neither can
        // appear in a name.
        guard !name.contains("/"), !name.contains(":") else {
            OperationPrompts.report([
                OperationFailure(
                    url: panel.directory.appendingPathComponent(name),
                    message: "A name cannot contain / or :"
                )
            ])
            return
        }

        let url = panel.directory.appendingPathComponent(name)
        do {
            if directory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try Data().write(to: url, options: .withoutOverwriting)
            }
            panel.reload(selecting: name)
        } catch {
            OperationPrompts.report([
                OperationFailure(url: url, message: error.localizedDescription)
            ])
        }
    }

    // MARK: - Viewing

    /// Previews the marked set, or the cursor row when nothing is marked, so the panel's own
    /// arrows step through exactly the selection.
    private func quickLook(_ panel: PanelViewModel) {
        let targets = panel.actionTargets.filter { !$0.isDirectory }
        guard !targets.isEmpty else { return }
        let cursorURL = panel.cursorEntry?.url
        let start = targets.firstIndex { $0.url == cursorURL } ?? 0
        guard QuickLookController.shared.prepare(targets.map(\.url), startingAt: start) else {
            return
        }
        QuickLookController.shared.toggle()
    }

    /// Opens in the configured editor, or in whatever the system would use otherwise.
    private func edit(_ panel: PanelViewModel) {
        guard let entry = panel.actionTargets.first, !entry.isDirectory else { return }
        let identifier = AppSettings.shared.editorBundleIdentifier
        guard
            !identifier.isEmpty,
            let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else {
            NSWorkspace.shared.open(entry.url)
            return
        }
        NSWorkspace.shared.open(
            [entry.url],
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    // MARK: - Tabs and favourites

    /// Total Commander's Ctrl+Up: send the folder under the cursor to the other pane as a new
    /// tab, without leaving the pane you are in.
    private func openInOtherPaneTab(from panel: PanelViewModel) {
        guard let entry = panel.cursorEntry else { return }
        let target = entry.isParent || entry.isDirectory ? entry.url : panel.directory
        state.inactivePanel.openTab(at: target)
    }

    func open(_ favorite: Favorite) {
        guard favorite.exists else {
            OperationPrompts.report([
                OperationFailure(url: favorite.url, message: "This folder no longer exists.")
            ])
            return
        }
        state.activePanel.navigate(to: favorite.url)
    }

    private func addFavorite(_ url: URL) {
        let suggested = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        guard
            let name = OperationPrompts.askForName(
                title: "Add to favourites",
                message: url.path,
                initial: suggested,
                buttonTitle: "Add"
            )
        else { return }
        state.favorites.add(url, name: name)
    }

    /// Popped up from code because a SwiftUI Menu cannot be opened by a keyboard command.
    private func showFavoritesMenu() {
        let menu = NSMenu(title: "Favourites")
        if state.favorites.favorites.isEmpty {
            let empty = NSMenuItem(title: "No favourites yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, favorite) in state.favorites.favorites.enumerated() {
            let item = NSMenuItem(
                title: favorite.name,
                action: #selector(FavoriteMenuTarget.open(_:)),
                keyEquivalent: index < 9 ? String(index + 1) : ""
            )
            item.keyEquivalentModifierMask = .command
            item.target = state.favoriteMenuTarget
            item.representedObject = favorite.path
            item.toolTip = favorite.path
            item.isEnabled = favorite.exists
            menu.addItem(item)
        }

        state.favoriteMenuTarget.onOpen = { [state] path in
            state.activePanel.navigate(to: URL(fileURLWithPath: path))
        }
        let window = NSApp.keyWindow
        let location = NSPoint(x: 20, y: (window?.contentView?.bounds.height ?? 400) - 20)
        menu.popUp(positioning: nil, at: location, in: window?.contentView)
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
