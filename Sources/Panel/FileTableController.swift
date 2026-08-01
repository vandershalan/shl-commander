import AppKit
import QuickLookUI

/// `NSTableView` subclass that gives the panel first crack at every key press.
///
/// Cursor movement is routed to the view model rather than left to AppKit so the cursor has
/// exactly one owner. It also fixes two places where AppKit disagrees with Total Commander:
/// Home/End scroll without moving the selection, and Page Up/Down page the scroll view
/// rather than the cursor.
final class FileTable: NSTableView {
    var keyHandler: (NSEvent) -> Bool = { _ in false }
    var onMove: (CursorMove) -> Void = { _ in }
    var onBecomeFirstResponder: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder() }
        return accepted
    }

    // MARK: - Quick Look
    //
    // Quick Look hands control to whoever in the responder chain claims it. The active pane's
    // table is first responder, so claiming it here is what makes the panel show this pane's
    // selection rather than nothing at all.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // These NSResponder hooks carry no main-actor annotation, but the panel only ever calls
    // them on the main thread.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookController.shared
            panel.delegate = QuickLookController.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    /// Rows a Page Up/Down should travel: one screenful less a row of overlap, so the user
    /// keeps a line of context across the jump.
    private var rowsPerPage: Int {
        max(1, Int(visibleRect.height / max(rowHeight, 1)) - 1)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler(event) { return }

        let move: CursorMove? =
            switch event.keyCode {
            case 126: .up  // Up arrow
            case 125: .down  // Down arrow
            case 115: .top  // Home
            case 119: .bottom  // End
            case 116: .pageUp(rows: rowsPerPage)  // Page Up
            case 121: .pageDown(rows: rowsPerPage)  // Page Down
            default: nil
            }

        guard let move else {
            super.keyDown(with: event)
            return
        }
        onMove(move)
    }
}

/// Data source and delegate for a panel's table. Owns its own copy of the rows so
/// `numberOfRows` never has to reach back into the view model mid-draw.
@MainActor
final class FileTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    enum ColumnID: String, CaseIterable {
        case name, ext, size, date

        var title: String {
            switch self {
            case .name: return "Name"
            case .ext: return "Ext"
            case .size: return "Size"
            case .date: return "Modified"
            }
        }

        var sortKey: SortKey {
            switch self {
            case .name: return .name
            case .ext: return .ext
            case .size: return .size
            case .date: return .date
            }
        }

        var alignment: NSTextAlignment {
            switch self {
            case .name, .ext: return .left
            case .size, .date: return .right
            }
        }

        /// (initial, minimum) width.
        ///
        /// The initial widths deliberately total less than a narrow pane (474pt) so
        /// `firstColumnOnlyAutoresizingStyle` grows Name into the slack. Sizing them to fill
        /// instead would overflow a split window and clip Modified, since the table has no
        /// horizontal scroller. The minimums total 250pt, inside the 260pt pane minimum.
        var widths: (CGFloat, CGFloat) {
            switch self {
            case .name: return (200, 80)
            case .ext: return (56, 30)
            case .size: return (86, 55)
            case .date: return (132, 85)
            }
        }
    }

    var entries: [FileEntry] = []
    var listingID: UUID?
    var marks: Set<URL> = []
    var directorySizes: [URL: Int64] = [:]
    var measuringDirectories: Set<URL> = []

    var onCursorChange: (Int) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onSort: (SortKey, Bool) -> Void = { _, _ in }
    var onRename: (Int, String) -> Void = { _, _ in }

    /// Last rename request the table has acted on, so a bumped counter triggers exactly once.
    var handledRenameRequest = 0
    private var editingRow: Int?

    /// Guards against the feedback loops that come from pushing state *into* AppKit:
    /// programmatic selection would otherwise report back as a user cursor move, and
    /// programmatic sort descriptors as a header click.
    private var isSyncingSelection = false
    private var isSyncingSort = false

    /// Interface zoom, pushed in by `FileTableView`. Everything the table draws is sized off
    /// it, so ⌘+/⌘- move the rows, fonts and icons together.
    var scale = UIScale.standard

    private var rowFont: NSFont { NSFont.systemFont(ofSize: scale(12)) }
    private var numericFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: scale(12), weight: .regular)
    }

    /// Unscaled row height and icon edge; the scaled values follow from these.
    private static let baseRowHeight: CGFloat = 20
    private static let baseIconSize: CGFloat = 16
    private static let baseHeaderHeight: CGFloat = 24

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard
            let raw = tableColumn?.identifier.rawValue,
            let column = ColumnID(rawValue: raw),
            entries.indices.contains(row)
        else { return nil }

        let entry = entries[row]
        // The scale rides in the identifier because a cell's icon size and insets are fixed by
        // constraints when it is built. Keying the reuse pool on it means a zoom hands back
        // freshly built cells instead of ones laid out for the old size.
        let identifier = NSUserInterfaceItemIdentifier("\(raw)@\(Int(scale.factor * 100))")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(column: column, identifier: identifier)

        switch column {
        case .name:
            cell.imageView?.image = IconCache.shared.icon(for: entry)
            cell.textField?.stringValue = entry.name
        case .ext:
            cell.textField?.stringValue = entry.ext
        case .size:
            cell.textField?.stringValue = Formatters.sizeColumn(
                for: entry,
                directorySize: directorySizes[entry.url],
                measuring: measuringDirectories.contains(entry.url)
            )
        case .date:
            cell.textField?.stringValue = Formatters.dateColumn(for: entry)
        }

        let isMarked = marks.contains(entry.url)
        cell.textField?.textColor = Self.color(for: entry, column: column, marked: isMarked)
        cell.textField?.font = font(for: column, marked: isMarked)
        return cell
    }

    /// Marked rows go red across every column, which is how Total Commander signals them.
    /// Hidden and symlinked rows are dimmed; everything else uses the label color so
    /// selection inversion stays readable.
    private static func color(for entry: FileEntry, column: ColumnID, marked: Bool) -> NSColor {
        if marked { return .systemRed }
        if entry.isHidden { return .tertiaryLabelColor }
        if entry.isSymlink { return .secondaryLabelColor }
        return column == .name ? .labelColor : .secondaryLabelColor
    }

    /// Bold reinforces the mark colour for anyone who cannot rely on red alone.
    private func font(for column: ColumnID, marked: Bool) -> NSFont {
        let base = column == .name || column == .ext ? rowFont : numericFont
        guard marked else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    private func makeCell(column: ColumnID, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let field = NSTextField(labelWithString: "")
        field.font = column == .name || column == .ext ? rowFont : numericFont
        field.alignment = column.alignment
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field

        guard column == .name else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: scale(4)),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -scale(6)),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        // Symbol images report a taller intrinsic size than 16pt and would otherwise
        // stretch the image view past the row.
        icon.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        icon.setContentHuggingPriority(.defaultLow, for: .vertical)
        cell.addSubview(icon)
        cell.imageView = icon

        let iconSize = scale(Self.baseIconSize)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: scale(3)),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: scale(5)),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -scale(4)),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Zoom

    /// Applies the current scale to everything the table owns rather than the cells do.
    func applyScale(to table: NSTableView) {
        table.rowHeight = scale(Self.baseRowHeight)
        for column in table.tableColumns {
            column.headerCell.font = NSFont.systemFont(ofSize: scale(11))
        }
        // A header view resizes to whatever frame it is handed, but only picks the height up
        // when it is (re)installed, so it is replaced rather than resized in place.
        let header = NSTableHeaderView()
        header.frame = NSRect(
            x: 0, y: 0,
            width: table.bounds.width,
            height: scale(Self.baseHeaderHeight)
        )
        table.headerView = header
    }

    /// Grows or shrinks every column by the ratio between the old scale and the new one.
    ///
    /// Call before `scale` is updated: the ratio is measured against the scale the current
    /// widths were laid out at.
    func rescaleColumns(on table: NSTableView, to newScale: UIScale) {
        let ratio = newScale.factor / scale.factor
        for column in table.tableColumns {
            let identifier = ColumnID(rawValue: column.identifier.rawValue)
            let width = column.width * ratio
            // Minimums move first when shrinking, or the old floor would hold the width up.
            column.minWidth = newScale(identifier?.widths.1 ?? column.minWidth)
            column.width = width
        }
    }

    // MARK: - Delegate

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection,
              let table = notification.object as? NSTableView,
              table.selectedRow >= 0
        else { return }
        onCursorChange(table.selectedRow)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        guard !isSyncingSort,
              let descriptor = tableView.sortDescriptors.first,
              let raw = descriptor.key,
              let column = ColumnID(rawValue: raw)
        else { return }
        onSort(column.sortKey, descriptor.ascending)
    }

    @objc func handleDoubleClick(_ sender: Any?) {
        onOpen()
    }

    // MARK: - In-place rename

    /// Opens the name cell for editing.
    ///
    /// Cells are left non-editable normally and flipped only for this one edit, so a stray
    /// click can never start a rename — a single click has to stay a cursor move.
    func beginRename(row: Int, on table: NSTableView) {
        guard entries.indices.contains(row), !entries[row].isParent else { return }
        guard
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
            let field = cell.textField
        else { return }

        editingRow = row
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        field.delegate = self
        table.editColumn(0, row: row, with: nil, select: true)

        // Preselect just the stem, the way the Finder does, so the extension survives typing.
        let entry = entries[row]
        if !entry.isDirectory, !entry.ext.isEmpty,
            let editor = table.window?.fieldEditor(false, for: field) as? NSTextView
        {
            let stem = (entry.name as NSString).deletingPathExtension
            let stemLength = (stem as NSString).length
            editor.setSelectedRange(NSRange(location: 0, length: stemLength))
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let row = editingRow else { return }
        editingRow = nil
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = nil

        let movement = notification.userInfo?["NSTextMovement"] as? Int
        guard movement != NSTextMovement.cancel.rawValue else {
            // Escape reverts, so the cell has to be put back by hand.
            if entries.indices.contains(row) { field.stringValue = entries[row].name }
            return
        }
        onRename(row, field.stringValue)
    }

    // MARK: - Pushing SwiftUI state into AppKit

    /// Reloads every row with the selection callback muted.
    ///
    /// `reloadData` adjusts the selection itself when the row count shrinks, and that
    /// adjustment arrives as `tableViewSelectionDidChange` — indistinguishable from the user
    /// clicking a row. Left unmuted it overwrites the cursor position the panel just restored
    /// after a delete, with the model and the table then disagreeing about where the cursor is.
    func reloadRows(on table: NSTableView) {
        isSyncingSelection = true
        table.reloadData()
        isSyncingSelection = false
    }

    func syncCursor(_ cursor: Int, on table: NSTableView) {
        guard entries.indices.contains(cursor), table.selectedRow != cursor else { return }
        isSyncingSelection = true
        table.selectRowIndexes(IndexSet(integer: cursor), byExtendingSelection: false)
        table.scrollRowToVisible(cursor)
        isSyncingSelection = false
    }

    func syncSort(_ sort: SortOrder, on table: NSTableView) {
        let current = table.sortDescriptors.first
        guard current?.key != sort.key.columnIdentifier || current?.ascending != sort.ascending
        else { return }
        isSyncingSort = true
        table.sortDescriptors = [
            NSSortDescriptor(key: sort.key.columnIdentifier, ascending: sort.ascending)
        ]
        isSyncingSort = false
    }
}
