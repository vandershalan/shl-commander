import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("InternalViewer")
struct InternalViewerTests {
    @Test("text that decodes as UTF-8 is shown as text")
    func rendersText() {
        let data = Data("hello\nworld".utf8)
        #expect(InternalViewer.render(data) == "hello\nworld")
    }

    @Test("non-UTF-8 bytes fall back to a hex dump")
    func rendersHex() {
        // 0xFF 0xFE is not valid UTF-8.
        let data = Data([0xFF, 0xFE, 0x00, 0x41])
        let rendered = InternalViewer.render(data)
        #expect(rendered.contains("ff fe 00 41"))
        #expect(rendered.hasPrefix("00000000"))
    }

    @Test("a hex dump lays out offset, bytes, and printable characters")
    func hexLayout() {
        let data = Data("Hello".utf8) + Data([0x00, 0x01])
        let lines = InternalViewer.hexDump(data).split(separator: "\n")

        #expect(lines.count == 1)
        let line = String(lines[0])
        #expect(line.hasPrefix("00000000  "))
        #expect(line.contains("48 65 6c 6c 6f 00 01"))
        // Unprintable bytes show as dots, so column widths stay fixed.
        #expect(line.hasSuffix("|Hello..|"))
    }

    @Test("a dump wraps every sixteen bytes and keeps offsets in step")
    func hexWraps() {
        let data = Data(repeating: 0x41, count: 20)
        let lines = InternalViewer.hexDump(data).split(separator: "\n")

        #expect(lines.count == 2)
        #expect(lines[1].hasPrefix("00000010"))
        // The short final line pads its hex column so the ASCII section starts in the same
        // place. The text inside |…| is genuinely shorter, as in any hex dump.
        func asciiColumn(_ line: Substring) -> Int? {
            guard let bar = line.firstIndex(of: "|") else { return nil }
            return line.distance(from: line.startIndex, to: bar)
        }
        #expect(asciiColumn(lines[0]) == asciiColumn(lines[1]))
    }

    @Test("an empty file dumps to nothing rather than crashing")
    func emptyData() {
        #expect(InternalViewer.hexDump(Data()).isEmpty)
        #expect(InternalViewer.render(Data()).isEmpty)
    }
}

@MainActor
@Suite("QuickLookController")
struct QuickLookControllerTests {
    @Test("preparing with no files is refused")
    func refusesEmpty() {
        #expect(QuickLookController.shared.prepare([], startingAt: 0) == false)
    }

    @Test("the panel is loaded with the given files")
    func loadsItems() throws {
        let tree = try TempTree("quicklook")
        defer { tree.remove() }
        let first = try tree.file("a.txt", bytes: 1)
        let second = try tree.file("b.txt", bytes: 1)

        let controller = QuickLookController.shared
        #expect(controller.prepare([first, second], startingAt: 1))
        #expect(controller.numberOfPreviewItems(in: nil) == 2)
        #expect((controller.previewPanel(nil, previewItemAt: 0) as? NSURL) as URL? == first)
        #expect((controller.previewPanel(nil, previewItemAt: 1) as? NSURL) as URL? == second)
    }

    @Test("an out-of-range index yields nothing instead of trapping")
    func outOfRangeItem() throws {
        let tree = try TempTree("quicklook-range")
        defer { tree.remove() }
        let file = try tree.file("a.txt", bytes: 1)

        let controller = QuickLookController.shared
        #expect(controller.prepare([file], startingAt: 0))
        #expect(controller.previewPanel(nil, previewItemAt: 5) == nil)
    }

    @Test("a start index past the end is clamped rather than rejected")
    func clampsStartIndex() throws {
        let tree = try TempTree("quicklook-clamp")
        defer { tree.remove() }
        let file = try tree.file("a.txt", bytes: 1)
        #expect(QuickLookController.shared.prepare([file], startingAt: 99))
    }
}
