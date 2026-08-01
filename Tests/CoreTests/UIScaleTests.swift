import AppKit
import Foundation
import Testing

@testable import ShlCommander

@Suite("UIScale")
struct UIScaleTests {
    @Test("Actual Size is one of the steps")
    func standardIsAStep() {
        #expect(UIScale.steps.contains(UIScale.standard.factor))
    }

    @Test("steps are sorted and start below Actual Size")
    func stepsAreOrdered() {
        #expect(UIScale.steps == UIScale.steps.sorted())
        #expect(UIScale.minimum < UIScale.standard.factor)
        #expect(UIScale.maximum > UIScale.standard.factor)
    }

    @Test("zooming walks one step at a time and stops at the ends")
    func stepping() {
        var factor = UIScale.standard.factor
        for _ in UIScale.steps {
            factor = UIScale.zoomedIn(from: factor)
        }
        #expect(factor == UIScale.maximum)

        for _ in UIScale.steps {
            factor = UIScale.zoomedOut(from: factor)
        }
        #expect(factor == UIScale.minimum)
    }

    @Test("a factor between two steps snaps to the next one either way")
    func steppingOffLadder() {
        #expect(UIScale.zoomedIn(from: 1.05) == 1.15)
        #expect(UIScale.zoomedOut(from: 1.05) == 1.0)
    }

    @Test("points scale and never round away to nothing")
    func scalingPoints() {
        #expect(UIScale.standard(20) == 20)
        #expect(UIScale(factor: 1.5)(20) == 30)
        #expect(UIScale(factor: 0.75)(1) >= 1)
    }
}

@MainActor
@Suite("Scaled file table")
struct FileTableScaleTests {
    /// A table wired the way `FileTableView` wires one, minus the SwiftUI plumbing.
    private func table() -> (NSTableView, NSScrollView) {
        let table = NSTableView()
        for column in FileTableController.ColumnID.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.widths.0
            tableColumn.minWidth = column.widths.1
            table.addTableColumn(tableColumn)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        return (table, scroll)
    }

    @Test("rows, header and header titles all follow the zoom")
    func headerAndRowsScale() throws {
        let (table, _) = self.table()
        let controller = FileTableController()
        let scale = UIScale(factor: 1.5)
        controller.scale = scale
        controller.applyScale(to: table)

        #expect(table.rowHeight == scale(20))
        let header = try #require(table.headerView)
        #expect(header.frame.height == scale(24))

        // The title has to carry the font, not just the cell: the header draws its attributed
        // string, so a font set only on the cell is never seen.
        let column = try #require(table.tableColumns.first)
        #expect(column.headerCell.font?.pointSize == scale(11))
        let attributes = column.headerCell.attributedStringValue.attributes(
            at: 0, effectiveRange: nil)
        #expect((attributes[.font] as? NSFont)?.pointSize == scale(11))
        #expect(column.headerCell.attributedStringValue.string == column.title)
    }

    @Test("columns grow with the zoom and keep their relative widths")
    func columnsScale() throws {
        let (table, _) = self.table()
        let controller = FileTableController()
        let name = try #require(table.tableColumns.first)
        name.width = 300  // as if the user had widened it

        controller.rescaleColumns(on: table, to: UIScale(factor: 2))
        #expect(name.width == 600)
        #expect(name.minWidth == 160)
    }
}

@MainActor
@Suite("UI scale settings")
struct UIScaleSettingsTests {
    private func settings(_ label: String) -> (AppSettings, UserDefaults, String) {
        let suite = "shl-commander.tests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test("the app starts at Actual Size and persists a zoom")
    func persistence() {
        let (settings, defaults, suite) = settings("scale")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.uiScale == UIScale.standard.factor)
        settings.uiScale = 1.5
        #expect(defaults.double(forKey: "uiScale") == 1.5)
    }

    @Test("a factor outside the range is pulled back into it")
    func clamping() {
        let (settings, _, suite) = settings("clamp")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.uiScale = 12
        #expect(settings.uiScale == UIScale.maximum)
        settings.uiScale = 0.1
        #expect(settings.uiScale == UIScale.minimum)
    }

    @Test("a stored factor of zero reads back as Actual Size")
    func zeroIsIgnored() {
        let suite = "shl-commander.tests.zero.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        defaults.set(0, forKey: "uiScale")
        #expect(AppSettings(defaults: defaults).uiScale == UIScale.standard.factor)
    }
}
