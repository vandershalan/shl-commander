import AppKit

/// Alert-based prompts, and the text the operation sheet displays.
///
/// Confirmation, progress and collision questions all live in `OperationSheetModel` now, because
/// a sheet is attached to the window and stays up while the work runs. What remains here is the
/// name prompt still used outside an operation, the error alert used as a fallback when the sheet
/// is busy, and the summary builders — kept apart from any UI so their wording and counts stay
/// testable.
@MainActor
struct OperationPrompts {
    /// Width every operation dialog is built to.
    ///
    /// `NSAlert` sizes itself around its accessory view, so this is what makes these dialogs wide
    /// enough to read a full path in. The default width fits roughly a folder name and nothing
    /// more, which is useless for confirming *which* file is about to be overwritten or deleted.
    static let dialogWidth: CGFloat = 620

    /// Tallest a path list grows before it scrolls instead.
    private static let listMaxHeight: CGFloat = 220

    /// What a delete confirmation shows. Built separately from the dialog so the wording, the
    /// counts and the paths can be tested without putting a window on screen.
    struct DeleteSummary: Equatable, Sendable {
        let headline: String
        /// Counts, total size and the consequence — prose, not data.
        let detail: String
        /// Full path of every item, in display order. Not truncated: the dialog scrolls.
        let paths: [String]
    }

    /// Typing is demanded for a permanent delete of a folder or of a large batch — the cases
    /// where a reflex Return would destroy the most. A trash move never demands it.
    static func deleteNeedsTypedConfirmation(_ targets: [FileEntry], toTrash: Bool) -> Bool {
        guard !toTrash else { return false }
        return targets.count > 10 || targets.contains(where: \.isDirectory)
    }

    static func deleteSummary(_ targets: [FileEntry], toTrash: Bool) -> DeleteSummary {
        let folders = targets.count(where: \.isDirectory)
        let files = targets.count - folders

        let verb = toTrash ? "Move" : "Permanently delete"
        let suffix = toTrash ? " to the Trash?" : "?"
        let what = targets.count == 1
            ? "\u{22}\(targets.first?.name ?? "")\u{22}"
            : "\(targets.count) items"

        var counts: [String] = []
        if files > 0 { counts.append("\(files) file\(files == 1 ? "" : "s")") }
        if folders > 0 { counts.append("\(folders) folder\(folders == 1 ? "" : "s")") }

        // Only files have a size to hand. Measuring a folder's contents means walking it,
        // which is far too slow to do while the user waits on a dialog.
        let bytes = targets.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + max(0, $1.size) }
        var totals = counts.joined(separator: ", ")
        if bytes > 0 { totals += " · \(Formatters.size(bytes))" }
        if folders > 0 { totals += " (folder contents included)" }

        let consequence =
            toTrash
            ? "Items can be put back from the Trash."
            : "This cannot be undone. The Trash is not involved."

        return DeleteSummary(
            headline: "\(verb) \(what)\(suffix)",
            detail: totals + "\n\n" + consequence,
            // A trailing slash marks a folder, whose contents go with it.
            paths: targets.map { $0.isDirectory ? "\($0.url.path)/" : $0.url.path }
        )
    }

    /// Used for New Folder, New File, Rename, and for the destination of a copy, move or extract.
    ///
    /// The field is the full dialog width because it is usually prefilled with a path, and a path
    /// you cannot read is a path you cannot check before pressing Return.
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
        field.frame = NSRect(x: 0, y: 0, width: dialogWidth, height: 24)
        field.lineBreakMode = .byTruncatingHead
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
        // Full paths, and every failure rather than the first ten: knowing which item failed is
        // the whole point of the dialog.
        alert.accessoryView = verticalStack([
            pathList(failures.map { "\($0.url.path)\n    \($0.message)" })
        ])
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

    /// A read-only, selectable list of paths that scrolls when it runs out of room.
    ///
    /// Long paths wrap rather than scrolling sideways, so all of a path is on screen at once —
    /// across two lines if need be, which beats having to drag a scroller to read the end of it.
    /// Selectable so a path can be copied out of the dialog.
    private static func pathList(_ lines: [String]) -> NSView {
        let text = NSTextView()
        text.string = lines.joined(separator: "\n")
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true

        // Two visual lines allowed per entry, since a long path wraps.
        let estimated = CGFloat(lines.count) * 2 * 14 + 12
        let scroll = NSScrollView(
            frame: NSRect(
                x: 0, y: 0,
                width: dialogWidth,
                height: min(listMaxHeight, max(34, estimated))
            )
        )
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    /// Stacks accessory views at the dialog's width, sizing itself to their heights.
    ///
    /// Framed rather than auto-laid-out: `NSAlert` measures an accessory view by its frame, so a
    /// view that only knows its size through constraints comes out flat.
    private static func verticalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSView {
        // `sizeToFit` lives on NSControl, not NSView, and only the controls here need it: a
        // checkbox or label built from a convenience initialiser starts out with a zero frame.
        for case let control as NSControl in views where control.frame.height == 0 {
            control.sizeToFit()
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing

        let height =
            views.reduce(0) { $0 + max($1.frame.height, 18) }
            + CGFloat(max(0, views.count - 1)) * spacing
        stack.frame = NSRect(x: 0, y: 0, width: dialogWidth, height: height)
        return stack
    }
}
