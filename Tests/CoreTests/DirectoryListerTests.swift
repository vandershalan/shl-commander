import Foundation
import Testing

@testable import ShlCommander

@Suite("DirectoryLister")
struct DirectoryListerTests {
    @Test("lists children and skips dotfiles unless asked")
    func hiddenFiltering() throws {
        let tree = try TempTree("hidden")
        defer { tree.remove() }
        try tree.file("visible.txt", bytes: 10)
        try tree.file(".hidden.txt", bytes: 5)
        try tree.directory("sub")

        let visible = try DirectoryLister.list(tree.root, includeHidden: false)
        #expect(Set(visible.map(\.name)) == ["visible.txt", "sub"])

        let all = try DirectoryLister.list(tree.root, includeHidden: true)
        #expect(Set(all.map(\.name)) == ["visible.txt", ".hidden.txt", "sub"])
        #expect(all.first { $0.name == ".hidden.txt" }?.isHidden == true)
    }

    @Test("captures size, extension, and directory flags")
    func metadata() throws {
        let tree = try TempTree("meta")
        defer { tree.remove() }
        try tree.file("Report.TXT", bytes: 1_234)
        try tree.file("noext", bytes: 7)
        try tree.directory("folder")

        let entries = try DirectoryLister.list(tree.root, includeHidden: false)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })

        let report = try #require(byName["Report.TXT"])
        #expect(report.ext == "txt")  // lowercased for case-insensitive sorting
        #expect(report.baseName == "Report")
        #expect(report.size == 1_234)
        #expect(report.isDirectory == false)

        let noext = try #require(byName["noext"])
        #expect(noext.ext.isEmpty)
        #expect(noext.size == 7)

        let folder = try #require(byName["folder"])
        #expect(folder.isDirectory)
        #expect(folder.ext.isEmpty)
        #expect(folder.size == 0)
    }

    @Test("no listing includes a synthetic parent row — panels add that")
    func noParentRow() throws {
        let tree = try TempTree("noparent")
        defer { tree.remove() }
        try tree.file("a.txt")
        let entries = try DirectoryLister.list(tree.root, includeHidden: true)
        #expect(entries.allSatisfy { !$0.isParent })
    }

    @Test("parent(of:) walks up and stops at the volume root")
    func parentResolution() throws {
        let tree = try TempTree("parent")
        defer { tree.remove() }
        let sub = try tree.directory("outer/inner")

        #expect(DirectoryLister.parent(of: sub)?.lastPathComponent == "outer")
        #expect(DirectoryLister.parent(of: URL(fileURLWithPath: "/")) == nil)
    }

    @Test("a missing directory surfaces as a thrown error, not an empty listing")
    func missingDirectory() {
        let ghost = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            try DirectoryLister.list(ghost, includeHidden: false)
        }
    }
}
