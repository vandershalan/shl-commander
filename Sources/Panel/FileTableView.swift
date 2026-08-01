import AppKit
import SwiftUI

/// SwiftUI wrapper around `FileTable`.
///
/// State arrives as plain values rather than through the view model so SwiftUI can diff it
/// and so `updateNSView` reloads only when `listingID` actually changes — a cursor move in
/// a 20k-row panel must not trigger `reloadData`.
struct FileTableView: NSViewRepresentable {
    let entries: [FileEntry]
    let listingID: UUID
    let cursor: Int
    let marks: Set<URL>
    let directorySizes: [URL: Int64]
    let measuringDirectories: Set<URL>
    let sort: SortOrder
    /// Row height, fonts, icons and column widths all come off this.
    let scale: UIScale
    /// Drives first-responder handoff between the two panes.
    let isActive: Bool
    /// Opens the in-place editor when this counter changes.
    let renameRequestID: Int

    let onCursorChange: (Int) -> Void
    let onMove: (CursorMove) -> Void
    let onOpen: () -> Void
    let onSort: (SortKey, Bool) -> Void
    let onActivate: () -> Void
    let onRename: (Int, String) -> Void
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> FileTableController { FileTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.style = .fullWidth
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        // The quick filter replaces AppKit's type-select, which would otherwise swallow the
        // keystrokes meant for it.
        table.allowsTypeSelect = false
        table.focusRingType = .none
        // Name is the only flexible column, so slack goes there.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // The header itself is installed by `applyScale`, which sizes it.

        for column in FileTableController.ColumnID.allCases {
            let (width, minWidth) = column.widths
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = scale(width)
            tableColumn.minWidth = scale(minWidth)
            tableColumn.headerCell.alignment = column.alignment
            tableColumn.sortDescriptorPrototype =
                NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }

        context.coordinator.scale = scale
        context.coordinator.applyScale(to: table)

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(FileTableController.handleDoubleClick(_:))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? FileTable else { return }
        let controller = context.coordinator

        // Closures capture this render pass's state, so rebind them every update.
        controller.onCursorChange = onCursorChange
        controller.onOpen = onOpen
        controller.onSort = onSort
        controller.onRename = onRename
        table.keyHandler = onKeyDown
        table.onMove = onMove
        table.onBecomeFirstResponder = onActivate

        if controller.scale != scale {
            // Columns are resized in proportion to the zoom step rather than reset to their
            // defaults, so a column the user widened stays wide relative to the others.
            controller.rescaleColumns(on: table, to: scale)
            controller.scale = scale
            controller.applyScale(to: table)
            // Cells are cached per scale, so this is what swaps in the newly sized ones.
            controller.reloadRows(on: table)
        }

        if controller.listingID != listingID {
            controller.listingID = listingID
            controller.entries = entries
            controller.marks = marks
            controller.directorySizes = directorySizes
            controller.measuringDirectories = measuringDirectories
            controller.reloadRows(on: table)
        } else if controller.marks != marks
            || controller.directorySizes != directorySizes
            || controller.measuringDirectories != measuringDirectories
        {
            // Marks and sizes repaint in place; the row set has not changed.
            controller.marks = marks
            controller.directorySizes = directorySizes
            controller.measuringDirectories = measuringDirectories
            table.reloadData(
                forRowIndexes: IndexSet(entries.indices),
                columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
            )
        }

        controller.syncSort(sort, on: table)
        controller.syncCursor(cursor, on: table)

        if isActive, table.window?.firstResponder !== table {
            table.window?.makeFirstResponder(table)
        }

        // After the cursor is in sync, so the editor opens on the right row.
        if controller.handledRenameRequest != renameRequestID {
            controller.handledRenameRequest = renameRequestID
            if renameRequestID > 0, isActive {
                controller.beginRename(row: cursor, on: table)
            }
        }
    }
}
