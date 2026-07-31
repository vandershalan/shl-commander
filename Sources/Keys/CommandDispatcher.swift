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
            Task {
                guard let urls = await materialise([entry], reportingTo: panel),
                    let url = urls.first
                else { return }
                InternalViewer.show(url)
            }
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
            guard !panel.isInsideArchive else {
                refuseArchiveWrite()
                break
            }
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
            // A favourite is a real folder; bookmarking a spot inside an archive would point at
            // something that stops existing the moment the archive is rebuilt.
            // A favourite is a real folder. Inside an archive that is the folder holding it —
            // bookmarking a spot inside would point at something that stops existing the moment
            // the archive is rebuilt.
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

        // Copying out of an archive is extraction; moving out of one would mean deleting from
        // it, which is not supported.
        if let archive = panel.location.archiveURL {
            guard kind == .copy else {
                refuseArchiveWrite()
                return
            }
            extract(targets, from: archive, on: panel)
            return
        }

        let summary = targets.count == 1
            ? "\u{22}\(targets[0].name)\u{22}"
            : "\(targets.count) items"
        let bytes = targets.reduce(Int64(0)) { $0 + max(0, $1.size) }

        Task { [state] in
            guard
                let typed = await state.operationSheet.confirm(
                    OperationSheetModel.Confirmation(
                        title: "\(kind.title) \(summary)",
                        detail: bytes > 0 ? Formatters.size(bytes) : "",
                        paths: targets.map(\.url.path),
                        confirmTitle: kind.title,
                        destination: state.inactivePanel.directory.path
                    )
                ),
                let destination = resolveDestination(typed)
            else { return }

            state.operationSheet.showRunning()
            state.operations.start(
                FileOperationRequest(
                    kind: kind,
                    sources: targets.map(\.url),
                    destinationDirectory: destination
                ),
                prompt: SheetConflictPrompt(model: state.operationSheet)
            )
        }
    }

    /// Turns typed text into a usable destination directory, creating it when needed.
    private func resolveDestination(_ typed: String) -> URL? {
        let expanded = (typed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                report([OperationFailure(url: url, message: "Not a folder.")])
                return nil
            }
            return url
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            report([OperationFailure(url: url, message: error.localizedDescription)])
            return nil
        }
    }

    /// Asks where to extract, then pulls the selection out of the archive.
    private func extract(_ targets: [FileEntry], from archive: URL, on panel: PanelViewModel) {
        let summary = targets.count == 1
            ? "\u{22}\(targets[0].name)\u{22}"
            : "\(targets.count) items"

        Task { [state] in
            guard
                let typed = await state.operationSheet.confirm(
                    OperationSheetModel.Confirmation(
                        title: "Extract \(summary)",
                        detail: "From \(archive.lastPathComponent)",
                        paths: targets.map(\.url.path),
                        confirmTitle: "Extract",
                        destination: state.inactivePanel.directory.path
                    )
                ),
                let destination = resolveDestination(typed)
            else { return }

            state.operationSheet.showRunning()
            state.operations.startExtraction(
                from: archive,
                members: targets.filter(\.isArchiveMember),
                to: destination,
                prompt: SheetConflictPrompt(model: state.operationSheet)
            )
        }
    }

    /// Errors go to the sheet so they land centred on the window; an alert is the fallback for
    /// when the sheet is busy holding a running operation.
    private func report(_ failures: [OperationFailure]) {
        if !state.operationSheet.showFailures(failures) {
            OperationPrompts.report(failures)
        }
    }

    private func refuseArchiveWrite() {
        report([
            OperationFailure(
                url: state.activePanel.location.archiveURL ?? state.activePanel.directory,
                message: PanelViewModel.readOnlyArchiveMessage
            )
        ])
    }

    /// Copies into the current directory, where every name collides by definition — so it
    /// resolves to "keep both" without asking.
    private func duplicate(on panel: PanelViewModel) {
        let targets = panel.actionTargets
        guard !targets.isEmpty, !state.operations.isRunning else { return }
        guard !panel.isInsideArchive else {
            refuseArchiveWrite()
            return
        }

        Task { [state] in
            guard
                await state.operationSheet.confirm(
                    OperationSheetModel.Confirmation(
                        title: targets.count == 1
                            ? "Duplicate \u{22}\(targets[0].name)\u{22}"
                            : "Duplicate \(targets.count) items",
                        detail: "Copies are added alongside the originals.",
                        paths: targets.map(\.url.path),
                        confirmTitle: "Duplicate"
                    )
                ) != nil
            else { return }

            state.operationSheet.showRunning()
            state.operations.start(
                FileOperationRequest(
                    kind: .copy,
                    sources: targets.map(\.url),
                    destinationDirectory: panel.directory,
                    automaticResolution: .rename
                ),
                prompt: SheetConflictPrompt(model: state.operationSheet)
            )
        }
    }

    private func delete(on panel: PanelViewModel, toTrash: Bool) {
        let targets = panel.actionTargets
        guard !targets.isEmpty, !state.operations.isRunning else { return }
        guard !panel.isInsideArchive else {
            refuseArchiveWrite()
            return
        }
        // Both kinds confirm, listing what is about to go: a mistaken Trash move is
        // recoverable, but only once you work out what disappeared.
        let summary = OperationPrompts.deleteSummary(targets, toTrash: toTrash)
        let needsTyping = OperationPrompts.deleteNeedsTypedConfirmation(targets, toTrash: toTrash)

        Task { [state] in
            guard
                await state.operationSheet.confirm(
                    OperationSheetModel.Confirmation(
                        title: summary.headline,
                        detail: summary.detail,
                        paths: summary.paths,
                        confirmTitle: toTrash ? "Move to Trash" : "Delete",
                        isDestructive: true,
                        requiredWord: needsTyping ? "delete" : nil
                    )
                ) != nil
            else { return }

            state.operationSheet.showRunning()
            state.operations.startDeletion(of: targets.map(\.url), toTrash: toTrash)
        }
    }

    private func createItem(on panel: PanelViewModel, directory: Bool) {
        guard !panel.isInsideArchive else {
            refuseArchiveWrite()
            return
        }
        Task { [state] in
            guard
                let name = await state.operationSheet.confirm(
                    OperationSheetModel.Confirmation(
                        title: directory ? "New folder" : "New file",
                        detail: "In \(panel.directory.path)",
                        paths: [],
                        confirmTitle: "Create",
                        destination: "",
                        fieldLabel: "Name"
                    )
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { return }

            // "/" is a path separator and ":" is one to the classic Finder APIs; neither can
            // appear in a name.
            guard !name.contains("/"), !name.contains(":") else {
                report([
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
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: false)
                } else {
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    try Data().write(to: url, options: .withoutOverwriting)
                }
                panel.reload(selecting: name)
            } catch {
                report([OperationFailure(url: url, message: error.localizedDescription)])
            }
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

        Task { [weak panel] in
            // Quick Look needs real files, so members are pulled out to scratch copies first.
            guard let urls = await materialise(targets, reportingTo: panel) else { return }
            guard QuickLookController.shared.prepare(urls, startingAt: start) else { return }
            QuickLookController.shared.toggle()
        }
    }

    /// Resolves entries to files on disk, extracting any that live inside an archive.
    ///
    /// Returns nil when something could not be extracted, having already reported it — the
    /// caller should do nothing rather than act on a partial set.
    private func materialise(
        _ entries: [FileEntry],
        reportingTo panel: PanelViewModel?
    ) async -> [URL]? {
        var urls: [URL] = []
        for entry in entries {
            guard let origin = entry.archive else {
                urls.append(entry.url)
                continue
            }
            do {
                urls.append(
                    try await ArchiveStore.shared.materialise(
                        member: origin.member, from: origin.archive))
            } catch {
                OperationPrompts.report([
                    OperationFailure(url: entry.url, message: error.localizedDescription)
                ])
                return nil
            }
        }
        return urls
    }

    /// Opens in the configured editor, or in whatever the system would use otherwise.
    ///
    /// A member of an archive opens as an extracted copy, so edits to it are not written back.
    private func edit(_ panel: PanelViewModel) {
        guard let entry = panel.actionTargets.first, !entry.isDirectory else { return }
        guard entry.archive == nil else {
            Task {
                guard let urls = await materialise([entry], reportingTo: panel),
                    let url = urls.first
                else { return }
                openInEditor(url)
            }
            return
        }
        openInEditor(entry.url)
    }

    private func openInEditor(_ url: URL) {
        let identifier = AppSettings.shared.editorBundleIdentifier
        guard
            !identifier.isEmpty,
            let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
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
            report([
                OperationFailure(url: favorite.url, message: "This folder no longer exists.")
            ])
            return
        }
        state.activePanel.navigate(to: favorite.url)
    }

    private func addFavorite(_ url: URL) {
        let suggested = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        Task { [state] in
            guard
                let name = await state.operationSheet.confirm(
                    OperationSheetModel.Confirmation(
                        title: "Add to favourites",
                        detail: url.path,
                        paths: [],
                        confirmTitle: "Add",
                        destination: suggested,
                        fieldLabel: "Name"
                    )
                )?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty
            else { return }
            state.favorites.add(url, name: name)
        }
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
        // A member has no file of its own to select, so the archive is what gets revealed.
        if let archive = panel.location.archiveURL {
            NSWorkspace.shared.activateFileViewerSelecting([archive])
            return
        }
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
