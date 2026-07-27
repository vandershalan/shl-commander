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

    /// Confirms a permanent delete. Anything recursive or bulk demands the word "delete" be
    /// typed, because unlike a trash move there is nothing to undo.
    static func confirmPermanentDelete(_ targets: [FileEntry]) -> Bool {
        let directories = targets.count(where: \.isDirectory)
        let needsTyping = targets.count > 10 || directories > 0

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = targets.count == 1
            ? "Permanently delete \u{22}\(targets[0].name)\u{22}?"
            : "Permanently delete \(targets.count) items?"

        var detail = "This cannot be undone. The Trash is not involved."
        if directories > 0 {
            detail += "\n\n\(directories) folder\(directories == 1 ? "" : "s") and everything inside will be removed."
        }
        alert.informativeText = detail

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

        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard let field else { return true }
        return field.stringValue.trimmingCharacters(in: .whitespaces).lowercased() == "delete"
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
