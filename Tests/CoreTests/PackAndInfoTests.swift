import AppKit
import Testing

@testable import ShlCommander

@Suite("Archive writing")
struct ArchiveWriterTests {
    private func tree(_ label: String) throws -> TempTree {
        let tree = try TempTree(label)
        try tree.file("src/notes.txt", bytes: 32)
        try tree.file("src/deep/inner.bin", bytes: 16)
        return tree
    }

    @Test("every offered format writes an archive bsdtar can read back", arguments: ArchiveWriter.Format.allCases)
    func roundTrip(format: ArchiveWriter.Format) throws {
        // tar.zst needs a zstd binary bsdtar can shell out to, which macOS does not ship.
        try #require(
            ArchiveWriter.canWrite(format) || ArchiveWriter.requiredTool(for: format) != nil)
        guard ArchiveWriter.canWrite(format) else { return }

        let tree = try tree("pack-\(format.rawValue)")
        defer { tree.remove() }
        let archive = tree.root.appendingPathComponent("out\(format.suffix)")

        try ArchiveWriter.create(
            archive: archive,
            from: ["src"],
            in: tree.root,
            format: format
        )

        #expect(FileManager.default.fileExists(atPath: archive.path))
        // Read back through the same reader the app browses with.
        let index = try ArchiveReader.index(of: archive)
        let names = index.members.map(\.path)
        #expect(names.contains { $0.hasSuffix("notes.txt") })
        #expect(names.contains { $0.hasSuffix("inner.bin") })
    }

    @Test("paths inside are relative, so unpacking does not rebuild the whole tree")
    func relativePaths() throws {
        let tree = try tree("pack-relative")
        defer { tree.remove() }
        let archive = tree.root.appendingPathComponent("out.zip")

        try ArchiveWriter.create(archive: archive, from: ["src"], in: tree.root, format: .zip)
        let index = try ArchiveReader.index(of: archive)
        #expect(index.members.allSatisfy { !$0.path.hasPrefix("/") })
        #expect(index.members.contains { $0.path.hasPrefix("src") })
    }

    @Test("an existing archive is never quietly replaced")
    func refusesToOverwrite() throws {
        let tree = try tree("pack-exists")
        defer { tree.remove() }
        let archive = try tree.file("taken.zip", bytes: 3)

        #expect(throws: ArchiveWriter.Failure.alreadyExists("taken.zip")) {
            try ArchiveWriter.create(
                archive: archive, from: ["src"], in: tree.root, format: .zip)
        }
        // The file that was there is untouched.
        #expect(try Data(contentsOf: archive).count == 3)
    }

    @Test("nothing to pack is refused rather than writing an empty archive")
    func refusesEmptySelection() throws {
        let tree = try tree("pack-empty")
        defer { tree.remove() }

        #expect(throws: ArchiveWriter.Failure.nothingToPack) {
            try ArchiveWriter.create(
                archive: tree.root.appendingPathComponent("out.zip"),
                from: [],
                in: tree.root,
                format: .zip
            )
        }
    }

    @Test("a failing pack leaves no half-written file behind")
    func cleansUpAfterFailure() throws {
        let tree = try tree("pack-failure")
        defer { tree.remove() }
        let archive = tree.root.appendingPathComponent("out.zip")

        #expect(throws: (any Error).self) {
            try ArchiveWriter.create(
                archive: archive, from: ["does-not-exist"], in: tree.root, format: .zip)
        }
        #expect(FileManager.default.fileExists(atPath: archive.path) == false)
    }

    @Test("a format needing a tool that is missing says which one")
    func missingCompressor() throws {
        let tree = try tree("pack-missing-tool")
        defer { tree.remove() }
        guard !ArchiveWriter.canWrite(.tarZstd) else { return }

        #expect(throws: ArchiveWriter.Failure.missingTool("zstd")) {
            try ArchiveWriter.create(
                archive: tree.root.appendingPathComponent("out.tar.zst"),
                from: ["src"], in: tree.root, format: .tarZstd)
        }
    }

    @Test("only formats this machine can actually write are offered")
    func writableFormats() {
        #expect(ArchiveWriter.writableFormats.contains(.zip))
        #expect(ArchiveWriter.writableFormats.contains(.tarZstd) == ArchiveWriter.canWrite(.tarZstd))
        #expect(ArchiveWriter.requiredTool(for: .zip) == nil)
        #expect(ArchiveWriter.requiredTool(for: .tarZstd) == "zstd")
    }

    @Test("the format comes from the name, longest suffix first")
    func formatFromName() {
        #expect(ArchiveWriter.Format.matching(name: "stuff.tar.gz") == .tarGzip)
        #expect(ArchiveWriter.Format.matching(name: "stuff.tar") == .tar)
        #expect(ArchiveWriter.Format.matching(name: "stuff.ZIP") == .zip)
        #expect(ArchiveWriter.Format.matching(name: "stuff.rar") == nil, "rar cannot be written")
        #expect(ArchiveWriter.Format.matching(name: "stuff") == nil)
    }

    @Test("one item is named after itself, several after the folder holding them")
    func suggestedNames() {
        let directory = URL(fileURLWithPath: "/tmp/project")
        #expect(
            ArchiveWriter.suggestedName(
                for: [directory.appendingPathComponent("notes.txt")],
                in: directory, format: .zip) == "notes.zip")
        #expect(
            ArchiveWriter.suggestedName(
                for: [
                    directory.appendingPathComponent("a"), directory.appendingPathComponent("b"),
                ],
                in: directory, format: .tarGzip) == "project.tar.gz")
    }
}

@MainActor
@Suite("Unpacking from outside")
struct UnpackTests {
    /// Answers every clash by keeping both, so a test never hangs on a question.
    private struct KeepBoth: ConflictPrompting {
        func resolveConflict(
            kind: FileOperationKind, source: URL, destination: URL
        ) async -> ConflictDecision? {
            ConflictDecision(resolution: .rename, applyToAll: true)
        }
    }

    @Test("a whole archive unpacks without being entered first")
    func unpacksEverything() async throws {
        let tree = try TempTree("unpack-all")
        defer { tree.remove() }
        try tree.file("src/notes.txt", bytes: 8)
        try tree.file("src/deep/inner.bin", bytes: 4)
        let archive = tree.root.appendingPathComponent("bundle.zip")
        try ArchiveWriter.create(archive: archive, from: ["src"], in: tree.root, format: .zip)

        let destination = try tree.directory("out")
        let queue = FileOperationQueue()
        queue.startUnpacking([archive], to: destination, prompt: KeepBoth())
        await queue.settle()

        #expect(queue.failures.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("src/notes.txt").path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("src/deep/inner.bin").path))
        // The staging directory is gone.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(leftovers == ["src"])
    }

    @Test("several archives unpack one after another")
    func unpacksSeveral() async throws {
        let tree = try TempTree("unpack-many")
        defer { tree.remove() }
        try tree.file("one/a.txt", bytes: 2)
        try tree.file("two/b.txt", bytes: 2)
        for name in ["one", "two"] {
            try ArchiveWriter.create(
                archive: tree.root.appendingPathComponent("\(name).zip"),
                from: [name], in: tree.root, format: .zip)
        }

        let destination = try tree.directory("out")
        let queue = FileOperationQueue()
        queue.startUnpacking(
            ["one.zip", "two.zip"].map(tree.root.appendingPathComponent),
            to: destination,
            prompt: KeepBoth()
        )
        await queue.settle()

        #expect(queue.failures.isEmpty)
        #expect(
            Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
                == ["one", "two"])
    }

    @Test("a file that is not an archive fails without leaving anything behind")
    func rejectsNonArchive() async throws {
        let tree = try TempTree("unpack-bad")
        defer { tree.remove() }
        let notAnArchive = try tree.file("notes.txt", bytes: 64)
        let destination = try tree.directory("out")

        let queue = FileOperationQueue()
        queue.startUnpacking([notAnArchive], to: destination, prompt: KeepBoth())
        await queue.settle()

        #expect(queue.failures.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test("packing through the queue reports failures rather than throwing")
    func packingReportsFailures() async throws {
        let tree = try TempTree("pack-queue")
        defer { tree.remove() }
        let existing = try tree.file("out.zip", bytes: 1)
        let entry = try #require(makeEntry(named: "out.zip", in: tree))

        let queue = FileOperationQueue()
        queue.startPacking([entry], into: existing, format: .zip, from: tree.root)
        await queue.settle()

        #expect(queue.failures.count == 1)
    }

    private func makeEntry(named name: String, in tree: TempTree) -> FileEntry? {
        let url = tree.root.appendingPathComponent(name)
        return FileEntry(
            url: url,
            name: name,
            baseName: url.deletingPathExtension().lastPathComponent,
            ext: url.pathExtension,
            isDirectory: false,
            isSymlink: false,
            isHidden: false,
            isPackage: false,
            size: 1,
            modified: Date(timeIntervalSince1970: 0),
            isParent: false
        )
    }
}

@Suite("Item info")
struct ItemInfoTests {
    @Test("a file reports its size, kind, owner and mode")
    func fileInfo() throws {
        let tree = try TempTree("info-file")
        defer { tree.remove() }
        let file = try tree.file("notes.txt", bytes: 1234)

        let info = ItemInfo.gather(file)
        #expect(info.name == "notes.txt")
        #expect(info.size == 1234)
        #expect(info.isDirectory == false)
        #expect(info.typeIdentifier == "public.plain-text")
        #expect(info.owner == NSUserName())
        #expect(info.mode.hasPrefix("-rw"))
        #expect(info.modified != nil)
        #expect(info.location == tree.root.standardizedFileURL.path)
    }

    @Test("a folder counts its top-level children and leaves the size to a walk")
    func folderInfo() throws {
        let tree = try TempTree("info-folder")
        defer { tree.remove() }
        try tree.file("src/a.txt", bytes: 10)
        try tree.file("src/b.txt", bytes: 20)
        try tree.directory("src/deep")

        let info = ItemInfo.gather(tree.root.appendingPathComponent("src"))
        #expect(info.isDirectory)
        #expect(info.childCount == 3)
        #expect(info.size == nil, "a folder's size costs a tree walk, which the panel asks for")
        #expect(info.mode.hasPrefix("d"))
    }

    @Test("a symlink names what it points at")
    func symlinkInfo() throws {
        let tree = try TempTree("info-symlink")
        defer { tree.remove() }
        let target = try tree.file("real.txt", bytes: 4)
        let link = tree.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let info = ItemInfo.gather(link)
        #expect(info.symlinkTarget == target.path)
        #expect(info.mode.hasPrefix("l"))
    }

    @Test("permissions read as ls -l writes them, octal included")
    func modeStrings() {
        #expect(
            ItemInfo.modeString(NSNumber(value: 0o755), isDirectory: true, isSymlink: false)
                == "drwxr-xr-x  (755)")
        #expect(
            ItemInfo.modeString(NSNumber(value: 0o644), isDirectory: false, isSymlink: false)
                == "-rw-r--r--  (644)")
        #expect(ItemInfo.modeString(nil, isDirectory: false, isSymlink: false) == "—")
    }

    @Test("a walk totals bytes, files and folders")
    func treeTotals() throws {
        let tree = try TempTree("info-totals")
        defer { tree.remove() }
        try tree.file("src/a.txt", bytes: 100)
        try tree.file("src/deep/b.txt", bytes: 200)

        let totals = TreeTotals.measure([tree.root.appendingPathComponent("src")])
        #expect(totals.bytes == 300)
        #expect(totals.files == 2)
        #expect(totals.directories == 2, "src and src/deep")
        #expect(totals.sizeOnDisk >= totals.bytes, "blocks are never smaller than the bytes")
    }
}

@MainActor
@Suite("Info window subjects")
struct InfoModelTests {
    @Test("with nothing selected the pane's own folder is the subject")
    func fallsBackToTheFolder() throws {
        let tree = try TempTree("info-model")
        defer { tree.remove() }

        let model = InfoModel(urls: [tree.root])
        #expect(model.items.count == 1)
        #expect(model.title == tree.root.lastPathComponent)
        #expect(model.needsWalk, "a folder's size has to be measured")
    }

    @Test("a single file needs no walk")
    func singleFile() throws {
        let tree = try TempTree("info-model-file")
        defer { tree.remove() }
        let file = try tree.file("notes.txt", bytes: 5)

        let model = InfoModel(urls: [file])
        #expect(model.isSingleFile)
        #expect(model.needsWalk == false)
        #expect(model.title == "notes.txt")
    }

    @Test("several items are titled by their count")
    func manyItems() throws {
        let tree = try TempTree("info-model-many")
        defer { tree.remove() }
        let a = try tree.file("a.txt", bytes: 1)
        let b = try tree.file("b.txt", bytes: 2)

        let model = InfoModel(urls: [a, b])
        #expect(model.title == "2 Items")
        #expect(model.needsWalk)
    }
}
