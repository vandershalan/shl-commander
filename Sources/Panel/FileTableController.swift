import AppKit

/// `NSTableView` subclass that gives the panel first crack at every key press before
/// AppKit's own arrow/page handling runs.
final class FileTable: NSTableView {
    var keyHandler: (NSEvent) -> Bool = { _ in false }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyHandler(event) { return }
        super.keyDown(with: event)
    }
}

/// Data source and delegate for a panel's table. Owns its own copy of the rows so
/// `numberOfRows` never has to reach back into the view model mid-draw.
@MainActor
final class FileTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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

        /// (initial, minimum) width. Name has no maximum so it soaks up slack.
        var widths: (CGFloat, CGFloat) {
            switch self {
            case .name: return (320, 120)
            case .ext: return (60, 40)
            case .size: return (90, 60)
            case .date: return (135, 90)
            }
        }
    }

    var entries: [FileEntry] = []
    var listingID: UUID?

    var onCursorChange: (Int) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onSort: (SortKey, Bool) -> Void = { _, _ in }

    /// Guards against the feedback loops that come from pushing state *into* AppKit:
    /// programmatic selection would otherwise report back as a user cursor move, and
    /// programmatic sort descriptors as a header click.
    private var isSyncingSelection = false
    private var isSyncingSort = false

    private static let rowFont = NSFont.systemFont(ofSize: 12)
    private static let numericFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

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
        let identifier = NSUserInterfaceItemIdentifier(raw)
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(column: column, identifier: identifier)

        switch column {
        case .name:
            cell.imageView?.image = IconCache.shared.icon(for: entry)
            cell.textField?.stringValue = entry.name
        case .ext:
            cell.textField?.stringValue = entry.ext
        case .size:
            cell.textField?.stringValue = Formatters.sizeColumn(for: entry)
        case .date:
            cell.textField?.stringValue = Formatters.dateColumn(for: entry)
        }

        cell.textField?.textColor = Self.color(for: entry, column: column)
        return cell
    }

    /// Hidden and symlinked rows are dimmed the way Total Commander dims them; everything
    /// else uses the label color so selection inversion stays readable.
    private static func color(for entry: FileEntry, column: ColumnID) -> NSColor {
        if entry.isHidden { return .tertiaryLabelColor }
        if entry.isSymlink { return .secondaryLabelColor }
        return column == .name ? .labelColor : .secondaryLabelColor
    }

    private func makeCell(column: ColumnID, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let field = NSTextField(labelWithString: "")
        field.font = column == .name || column == .ext ? Self.rowFont : Self.numericFont
        field.alignment = column.alignment
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field

        guard column == .name else {
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
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

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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

    // MARK: - Pushing SwiftUI state into AppKit

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
