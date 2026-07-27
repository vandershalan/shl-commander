import Foundation
import Testing

@testable import ShlCommander

@Suite("CopyEngine")
struct CopyEngineTests {
    private let fileManager = FileManager.default

    private func contents(of url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    @Test("copies a file with its contents intact")
    func copyFile() throws {
        let tree = try TempTree("copyfile")
        defer { tree.remove() }
        let source = try tree.file("source.bin", bytes: 5_000)
        let destination = tree.root.appendingPathComponent("copy.bin")

        var reported: Int64 = 0
        try CopyEngine.copy(
            from: source, to: destination, isCancelled: { false }, progress: { reported += $0 })

        #expect(fileManager.fileExists(atPath: destination.path))
        #expect(try contents(of: destination).count == 5_000)
        #expect(try contents(of: source).count == 5_000, "the original survives a copy")
        #expect(reported == 5_000, "progress accounts for every byte")
    }

    @Test("copies a directory tree, contents and all")
    func copyTree() throws {
        let tree = try TempTree("copytree")
        defer { tree.remove() }
        try tree.file("src/one.txt", bytes: 10)
        try tree.file("src/nested/two.txt", bytes: 20)
        try tree.directory("src/empty")

        let source = tree.root.appendingPathComponent("src")
        let destination = tree.root.appendingPathComponent("dst")
        try CopyEngine.copy(
            from: source, to: destination, isCancelled: { false }, progress: { _ in })

        #expect(try contents(of: destination.appendingPathComponent("one.txt")).count == 10)
        #expect(
            try contents(of: destination.appendingPathComponent("nested/two.txt")).count == 20)
        var isDirectory: ObjCBool = false
        #expect(
            fileManager.fileExists(
                atPath: destination.appendingPathComponent("empty").path,
                isDirectory: &isDirectory
            )
        )
        #expect(isDirectory.boolValue, "an empty directory is still copied")
    }

    @Test("a symlink is recreated rather than followed")
    func copySymlink() throws {
        let tree = try TempTree("symlink")
        defer { tree.remove() }
        try tree.file("target.txt", bytes: 3)
        let link = tree.root.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")

        let copied = tree.root.appendingPathComponent("link-copy.txt")
        try CopyEngine.copy(from: link, to: copied, isCancelled: { false }, progress: { _ in })

        let destination = try fileManager.destinationOfSymbolicLink(atPath: copied.path)
        #expect(destination == "target.txt", "the link still points where it pointed")
    }

    @Test("moving within a volume leaves nothing behind")
    func moveFile() throws {
        let tree = try TempTree("movefile")
        defer { tree.remove() }
        let source = try tree.file("moving.bin", bytes: 128)
        let destination = tree.root.appendingPathComponent("moved.bin")

        try CopyEngine.move(
            from: source, to: destination, isCancelled: { false }, progress: { _ in })

        #expect(fileManager.fileExists(atPath: destination.path))
        #expect(fileManager.fileExists(atPath: source.path) == false)
        #expect(try contents(of: destination).count == 128)
    }

    @Test("moving a tree relocates the whole thing")
    func moveTree() throws {
        let tree = try TempTree("movetree")
        defer { tree.remove() }
        try tree.file("src/deep/file.txt", bytes: 7)
        let source = tree.root.appendingPathComponent("src")
        let destination = tree.root.appendingPathComponent("dst")

        try CopyEngine.move(
            from: source, to: destination, isCancelled: { false }, progress: { _ in })

        #expect(fileManager.fileExists(atPath: source.path) == false)
        #expect(
            try contents(of: destination.appendingPathComponent("deep/file.txt")).count == 7)
    }

    @Test("cancelling before any work throws rather than half-copying")
    func cancelUpFront() throws {
        let tree = try TempTree("cancel")
        defer { tree.remove() }
        let source = try tree.file("big.bin", bytes: 1_000)
        let destination = tree.root.appendingPathComponent("big-copy.bin")

        #expect(throws: CopyEngine.Failure.self) {
            try CopyEngine.copy(
                from: source, to: destination, isCancelled: { true }, progress: { _ in })
        }
        #expect(
            fileManager.fileExists(atPath: destination.path) == false,
            "a cancelled copy leaves no partial file"
        )
    }

    @Test("clone reports EEXIST rather than clobbering an existing destination")
    func cloneRefusesExisting() throws {
        let tree = try TempTree("cloneexists")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 4)
        let destination = try tree.file("b.txt", bytes: 4)

        let code = CopyEngine.clone(from: source, to: destination)
        #expect(code == EEXIST)
        // EEXIST is a real failure, not a "fast path does not apply" signal — otherwise the
        // slow path would silently overwrite a file the resolver decided to keep.
        #expect(CopyEngine.isFastPathRejection(EEXIST) == false)
    }

    @Test("copying preserves the modification date")
    func preservesMetadata() throws {
        let tree = try TempTree("metadata")
        defer { tree.remove() }
        let source = try tree.file("dated.txt", bytes: 16)
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)
        try fileManager.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)

        let destination = tree.root.appendingPathComponent("dated-copy.txt")
        try CopyEngine.copy(
            from: source, to: destination, isCancelled: { false }, progress: { _ in })

        let copiedDate = try destination.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        #expect(
            abs((copiedDate ?? .distantPast).timeIntervalSince(stamp)) < 1,
            "timestamps carry across"
        )
    }
}

@Suite("FileTreeScanner")
struct FileTreeScannerTests {
    @Test("totals bytes, files, and directories across a tree")
    func stats() throws {
        let tree = try TempTree("scan")
        defer { tree.remove() }
        try tree.file("a.bin", bytes: 100)
        try tree.file("sub/b.bin", bytes: 250)
        try tree.file("sub/deeper/c.bin", bytes: 50)

        let stats = FileTreeScanner.stats(of: tree.root)
        #expect(stats.bytes == 400)
        #expect(stats.files == 3)
        #expect(stats.directories == 3)  // root, sub, deeper
    }

    @Test("a symlink counts as one file and contributes no bytes")
    func symlinksAreNotFollowed() throws {
        let tree = try TempTree("scanlink")
        defer { tree.remove() }
        try tree.file("real.bin", bytes: 500)
        try FileManager.default.createSymbolicLink(
            atPath: tree.root.appendingPathComponent("link.bin").path,
            withDestinationPath: "real.bin"
        )

        let stats = FileTreeScanner.stats(of: tree.root)
        #expect(stats.bytes == 500, "the link's target is not counted twice")
        #expect(stats.files == 2)
    }

    @Test("allocated size rounds up to whole blocks, so it meets or beats logical size")
    func allocatedSize() throws {
        let tree = try TempTree("alloc")
        defer { tree.remove() }
        try tree.file("small.bin", bytes: 10)

        let allocated = FileTreeScanner.allocatedSize(of: tree.root)
        #expect(allocated >= 10)
    }

    @Test("a cancelled scan stops early")
    func cancellableScan() throws {
        let tree = try TempTree("scancancel")
        defer { tree.remove() }
        try tree.file("a.bin", bytes: 1_000)

        #expect(FileTreeScanner.allocatedSize(of: tree.root, isCancelled: { true }) == 0)
    }

    @Test("totalling several sources adds them together")
    func multipleSources() throws {
        let tree = try TempTree("scanmulti")
        defer { tree.remove() }
        let first = try tree.file("one.bin", bytes: 30)
        let second = try tree.file("two.bin", bytes: 70)

        let stats = FileTreeScanner.stats(of: [first, second])
        #expect(stats.bytes == 100)
        #expect(stats.files == 2)
        #expect(stats.directories == 0)
    }
}
