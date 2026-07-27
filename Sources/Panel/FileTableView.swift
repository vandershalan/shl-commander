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
    let sort: SortOrder

    let onCursorChange: (Int) -> Void
    let onOpen: () -> Void
    let onSort: (SortKey, Bool) -> Void
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> FileTableController { FileTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.style = .fullWidth
        table.rowSizeStyle = .custom
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.focusRingType = .none
        // Name is the only flexible column, so slack goes there.
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.headerView = NSTableHeaderView()

        for column in FileTableController.ColumnID.allCases {
            let (width, minWidth) = column.widths
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = width
            tableColumn.minWidth = minWidth
            tableColumn.headerCell.alignment = column.alignment
            tableColumn.sortDescriptorPrototype =
                NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }

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
        table.keyHandler = onKeyDown

        if controller.listingID != listingID {
            controller.listingID = listingID
            controller.entries = entries
            table.reloadData()
        }

        controller.syncSort(sort, on: table)
        controller.syncCursor(cursor, on: table)
    }
}
