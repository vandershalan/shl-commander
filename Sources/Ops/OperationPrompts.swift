import AppKit

/// The modal dialogs file operations need. Kept apart from the queue so the queue stays
/// testable without a UI.
@MainActor
struct OperationPrompts: ConflictPrompting {
    func resolveConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL
    ) async -> ConflictDecision? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\u{22}\(destination.lastPathComponent)\u{22} already exists"
        alert.informativeText = """
            Source:      \(Self.describe(source))
            Destination: \(Self.describe(destination))
            """

        let applyToAll = NSButton(checkboxWithTitle: "Apply to all remaining", target: nil, action: nil)
        // Turns Overwrite into overwrite-if-newer, so all four resolutions are reachable
        // without a fifth button crowding the dialog.
        let onlyIfNewer = NSButton(checkboxWithTitle: "Only if the source is newer", target: nil, action: nil)
        alert.accessoryView = Self.stack([applyToAll, onlyIfNewer])

        alert.addButton(withTitle: ConflictResolution.rename.buttonTitle)  // safest first
        alert.addButton(withTitle: ConflictResolution.overwrite.buttonTitle)
        alert.addButton(withTitle: ConflictResolution.skip.buttonTitle)
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let isApplyToAll = applyToAll.state == .on

        switch response {
        case .alertFirstButtonReturn:
            return ConflictDecision(resolution: .rename, applyToAll: isApplyToAll)
        case .alertSecondButtonReturn:
            return ConflictDecision(
                resolution: onlyIfNewer.state == .on ? .overwriteIfNewer : .overwrite,
                applyToAll: isApplyToAll
            )
        case .alertThirdButtonReturn:
            return ConflictDecision(resolution: .skip, applyToAll: isApplyToAll)
        default:
            return nil  // abandons the operation
        }
    }

    /// Confirms a delete, listing exactly what is about to go.
    ///
    /// Both kinds ask, because a mistaken Trash move still has to be hunted down and put back.
    /// A permanent delete of a folder or of more than ten items additionally demands the word
    /// "delete" be typed, since there is nothing to undo.
    static func confirmDelete(_ targets: [FileEntry], toTrash: Bool) -> Bool {
        guard !targets.isEmpty else { return false }

        let summary = deleteSummary(targets, toTrash: toTrash)
        let needsTyping = deleteNeedsTypedConfirmation(targets, toTrash: toTrash)

        let alert = NSAlert()
        alert.alertStyle = toTrash ? .warning : .critical
        alert.messageText = summary.headline
        alert.informativeText = summary.detail

        var field: NSTextField?
        if needsTyping {
            let input = NSTextField(string: "")
            input.placeholderString = "delete"
            input.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            let label = NSTextField(labelWithString: "Type \u{201C}delete\u{201D} to confirm:")
            alert.accessoryView = stack([label, input])
            alert.window.initialFirstResponder = input
            field = input
        }

        alert.addButton(withTitle: toTrash ? "Move to Trash" : "Delete")
        alert.addButton(withTitle: "Cancel")
        // Escape and ⌘. cancel, so a stray Return cannot confirm a destructive dialog by
        // reflex alone.
        alert.buttons[1].keyEquivalent = "\u{1b}"

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard let field else { return true }
        return field.stringValue.trimmingCharacters(in: .whitespaces).lowercased() == "delete"
    }

    /// The two strings a delete confirmation shows. Built separately from the dialog so the
    /// wording and the counts can be tested without putting a window on screen.
    struct DeleteSummary: Equatable, Sendable {
        let headline: String
        let detail: String
    }

    /// Typing is demanded for a permanent delete of a folder or of a large batch — the cases
    /// where a reflex Return would destroy the most. A trash move never demands it.
    static func deleteNeedsTypedConfirmation(_ targets: [FileEntry], toTrash: Bool) -> Bool {
        guard !toTrash else { return false }
        return targets.count > 10 || targets.contains(where: \.isDirectory)
    }

    /// Long lists are capped so the dialog cannot grow past the screen.
    static func deleteSummary(_ targets: [FileEntry], toTrash: Bool) -> DeleteSummary {
        let folders = targets.count(where: \.isDirectory)
        let files = targets.count - folders

        let verb = toTrash ? "Move" : "Permanently delete"
        let suffix = toTrash ? " to the Trash?" : "?"
        let what = targets.count == 1
            ? "\u{22}\(targets.first?.name ?? "")\u{22}"
            : "\(targets.count) items"

        var lines: [String] = []

        var counts: [String] = []
        if files > 0 { counts.append("\(files) file\(files == 1 ? "" : "s")") }
        if folders > 0 { counts.append("\(folders) folder\(folders == 1 ? "" : "s")") }

        // Only files have a size to hand. Measuring a folder's contents means walking it,
        // which is far too slow to do while the user waits on a dialog.
        let bytes = targets.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
        var totals = counts.joined(separator: ", ")
        if bytes > 0 { totals += " · \(Formatters.size(bytes))" }
        if folders > 0 { totals += " (folder contents included)" }
        lines.append(totals)

        let shown = 12
        lines.append("")
        for target in targets.prefix(shown) {
            lines.append(target.isDirectory ? "\(target.name)/" : target.name)
        }
        if targets.count > shown {
            lines.append("… and \(targets.count - shown) more")
        }

        lines.append("")
        lines.append(
            toTrash
                ? "Items can be put back from the Trash."
                : "This cannot be undone. The Trash is not involved."
        )

        return DeleteSummary(
            headline: "\(verb) \(what)\(suffix)",
            detail: lines.joined(separator: "\n")
        )
    }

    /// Used for New Folder, New File, and Rename.
    static func askForName(
        title: String,
        message: String? = nil,
        initial: String = "",
        buttonTitle: String = "Create"
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }

        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func report(_ failures: [OperationFailure]) {
        guard !failures.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? "1 item could not be completed"
            : "\(failures.count) items could not be completed"
        alert.informativeText = failures.prefix(10)
            .map { "\($0.url.lastPathComponent): \($0.message)" }
            .joined(separator: "\n")
            + (failures.count > 10 ? "\n… and \(failures.count - 10) more" : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Helpers

    private static func describe(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return "unavailable" }
        let date = values.contentModificationDate.map(Formatters.timestamp.string(from:)) ?? "—"
        if values.isDirectory == true { return "folder, modified \(date)" }
        return "\(Formatters.size(Int64(values.fileSize ?? 0))), modified \(date)"
    }

    private static func stack(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(
            x: 0, y: 0, width: 280,
            height: CGFloat(views.count) * 24 + CGFloat(max(0, views.count - 1)) * 6
        )
        return stack
    }
}
