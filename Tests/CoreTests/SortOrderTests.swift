import Foundation
import Testing

@testable import ShlCommander

@Suite("SortOrder")
struct SortOrderTests {
    private func entry(
        _ name: String,
        dir: Bool = false,
        size: Int64 = 0,
        date: Date = Date(timeIntervalSince1970: 0)
    ) -> FileEntry {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        return FileEntry(
            url: url,
            name: name,
            baseName: url.deletingPathExtension().lastPathComponent,
            ext: dir ? "" : url.pathExtension.lowercased(),
            isDirectory: dir,
            isSymlink: false,
            isHidden: false,
            isPackage: false,
            size: size,
            modified: date,
            isParent: false
        )
    }

    private func names(_ entries: [FileEntry]) -> [String] { entries.map(\.name) }

    @Test("the parent row sorts first in both directions")
    func parentAlwaysFirst() {
        let rows = [entry("zz.txt"), .parent(URL(fileURLWithPath: "/")), entry("aa.txt")]
        var order = SortOrder()
        #expect(order.sorted(rows).first?.isParent == true)
        order.ascending = false
        #expect(order.sorted(rows).first?.isParent == true)
    }

    @Test("directories group ahead of files regardless of direction")
    func directoriesFirst() {
        let rows = [entry("b.txt"), entry("a-dir", dir: true), entry("a.txt"), entry("z-dir", dir: true)]
        var order = SortOrder()
        #expect(names(order.sorted(rows)) == ["a-dir", "z-dir", "a.txt", "b.txt"])
        order.ascending = false
        #expect(names(order.sorted(rows)) == ["z-dir", "a-dir", "b.txt", "a.txt"])
    }

    @Test("directoriesFirst off interleaves directories with files")
    func directoriesMixed() {
        let rows = [entry("b.txt"), entry("a-dir", dir: true), entry("c.txt")]
        let order = SortOrder(key: .name, ascending: true, directoriesFirst: false)
        #expect(names(order.sorted(rows)) == ["a-dir", "b.txt", "c.txt"])
    }

    @Test("names sort naturally, so file10 follows file9")
    func naturalNameOrder() {
        let rows = [entry("file10.txt"), entry("file9.txt"), entry("file1.txt")]
        #expect(names(SortOrder().sorted(rows)) == ["file1.txt", "file9.txt", "file10.txt"])
    }

    @Test("size sorts numerically and directories stay name-ordered among themselves")
    func sizeOrder() {
        let rows = [
            entry("big.bin", size: 5_000),
            entry("small.bin", size: 10),
            entry("z-dir", dir: true),
            entry("a-dir", dir: true),
        ]
        let order = SortOrder(key: .size, ascending: true)
        #expect(names(order.sorted(rows)) == ["a-dir", "z-dir", "small.bin", "big.bin"])
    }

    @Test("extension sort falls back to an ascending name tiebreak in both directions")
    func extensionTiebreak() {
        let rows = [entry("b.txt"), entry("a.txt"), entry("c.md")]
        var order = SortOrder(key: .ext, ascending: true)
        #expect(names(order.sorted(rows)) == ["c.md", "a.txt", "b.txt"])
        order.ascending = false
        #expect(names(order.sorted(rows)) == ["a.txt", "b.txt", "c.md"])
    }

    @Test("date sorts oldest first when ascending")
    func dateOrder() {
        let rows = [
            entry("new.txt", date: Date(timeIntervalSince1970: 2_000)),
            entry("old.txt", date: Date(timeIntervalSince1970: 1_000)),
        ]
        #expect(names(SortOrder(key: .date, ascending: true).sorted(rows)) == ["old.txt", "new.txt"])
    }

    @Test("re-selecting the active key reverses; a new key resets to ascending")
    func toggleSemantics() {
        let base = SortOrder(key: .name, ascending: true)
        let reversed = base.toggled(to: .name)
        #expect(reversed.key == .name)
        #expect(reversed.ascending == false)

        let switched = reversed.toggled(to: .size)
        #expect(switched.key == .size)
        #expect(switched.ascending == true)
    }
}
