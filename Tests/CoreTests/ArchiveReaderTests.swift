import Foundation
import Testing

@testable import ShlCommander

/// Builds real archives with the system tools, so the reader is tested against what it will
/// actually meet rather than against fixtures someone hand-wrote.
struct ArchiveFixture {
    let tree: TempTree
    let source: URL

    init(_ label: String) throws {
        tree = try TempTree("archive-\(label)")
        source = try tree.directory("payload")
        try tree.file("payload/readme.txt", bytes: 16)
        try tree.file("payload/big.dat", bytes: 5_000)
        try tree.file("payload/a file with spaces.txt", bytes: 17)
        try tree.file("payload/deep/data.csv", bytes: 6)
        try tree.file("payload/deep/nested/blob.bin", bytes: 8)
        try tree.directory("payload/empty dir")
    }

    /// Runs a build command inside the payload directory.
    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = source
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// `zip -r`, which records directory entries.
    func makeZip(named name: String = "test.zip") throws -> URL {
        let url = tree.root.appendingPathComponent(name)
        try run("/usr/bin/zip", ["-qr", url.path, "."])
        return url
    }

    /// `zip -rD`, which omits them — very common, and the case that needs synthesising.
    func makeZipWithoutDirectoryEntries() throws -> URL {
        let url = tree.root.appendingPathComponent("nodirs.zip")
        try run("/usr/bin/zip", ["-qrD", url.path, "."])
        return url
    }

    func makeTarGzip() throws -> URL {
        let url = tree.root.appendingPathComponent("test.tar.gz")
        try run("/usr/bin/tar", ["-czf", url.path, "."])
        return url
    }

    func remove() { tree.remove() }
}

@Suite("ArchiveFormat")
struct ArchiveFormatTests {
    @Test("recognises the container formats, including zips under other names")
    func recognises() {
        #expect(ArchiveFormat.detect(name: "a.zip") == .zip)
        #expect(ArchiveFormat.detect(name: "a.ZIP") == .zip, "case-insensitive")
        #expect(ArchiveFormat.detect(name: "app.ipa") == .zip)
        #expect(ArchiveFormat.detect(name: "lib.jar") == .zip)
        #expect(ArchiveFormat.detect(name: "book.cbz") == .zip)
        #expect(ArchiveFormat.detect(name: "a.tar") == .tar)
        #expect(ArchiveFormat.detect(name: "a.7z") == .sevenZip)
        #expect(ArchiveFormat.detect(name: "a.rar") == .rar)
    }

    @Test("a compound extension beats the plain one it ends with")
    func compoundExtensions() {
        // ".tar.gz" must not be read as a bare ".gz", which is not a container at all.
        #expect(ArchiveFormat.detect(name: "a.tar.gz") == .tarGzip)
        #expect(ArchiveFormat.detect(name: "a.tgz") == .tarGzip)
        #expect(ArchiveFormat.detect(name: "a.tar.bz2") == .tarBzip2)
        #expect(ArchiveFormat.detect(name: "a.tar.xz") == .tarXZ)
    }

    @Test("single compressed streams open, holding one payload each")
    func singleStreams() {
        // These were excluded at first on the grounds that there is nothing to navigate. That
        // was the wrong call: a stream holds exactly one payload, and showing it as a single row
        // means it can be previewed and copied out decompressed.
        #expect(ArchiveFormat.detect(name: "a.gz") == .gzipStream)
        #expect(ArchiveFormat.detect(name: "a.bz2") == .bzip2Stream)
        #expect(ArchiveFormat.detect(name: "a.xz") == .xzStream)
        #expect(ArchiveFormat.detect(name: "a.zst") == .zstdStream)
        #expect(ArchiveFormat.detect(name: "a.gz")?.isSingleStream == true)
        #expect(ArchiveFormat.detect(name: "a.zip")?.isSingleStream == false)
    }

    @Test("names that are not archives at all stay unrecognised")
    func notArchives() {
        #expect(ArchiveFormat.detect(name: "notes.txt") == nil)
        #expect(ArchiveFormat.detect(name: "zip") == nil, "an extensionless name is not a zip")
        #expect(ArchiveFormat.detect(name: "image.png") == nil)
    }
}

@Suite("ArchiveReader listing")
struct ArchiveReaderListingTests {
    @Test("parses a listing line into a member")
    func parsesFileLine() throws {
        let member = try #require(
            ArchiveReader.parse(line: "-rw-r--r--  0 501    0        5000 Jul 30 15:43 big.dat"))
        #expect(member.path == "big.dat")
        #expect(member.size == 5_000)
        #expect(member.isDirectory == false)
        #expect(member.isSymlink == false)
    }

    @Test("a directory line is recognised by its mode and loses its trailing slash")
    func parsesDirectoryLine() throws {
        let member = try #require(
            ArchiveReader.parse(line: "drwxr-xr-x  0 501    0           0 Jul 30 15:43 deep/"))
        #expect(member.path == "deep")
        #expect(member.isDirectory)
        #expect(member.size == 0)
    }

    @Test("a name containing spaces survives, since it is whatever follows the date")
    func parsesNameWithSpaces() throws {
        let member = try #require(
            ArchiveReader.parse(
                line: "-rw-r--r--  0 501    0          17 Jul 30 15:43 a file with spaces.txt"))
        #expect(member.path == "a file with spaces.txt")
    }

    @Test("a symlink keeps only its own name, not the arrow and target")
    func parsesSymlink() throws {
        let member = try #require(
            ArchiveReader.parse(
                line: "lrwxr-xr-x  0 shalan wheel       0 Jul 30 15:44 ./link.txt -> target.txt"))
        #expect(member.path == "link.txt")
        #expect(member.isSymlink)
    }

    @Test("the leading ./ that tar writes is stripped")
    func stripsDotSlash() throws {
        let member = try #require(
            ArchiveReader.parse(
                line: "-rw-r--r--  0 shalan wheel       7 Jan  2  2020 ./target.txt"))
        #expect(member.path == "target.txt")
    }

    @Test("an entry escaping the archive root is dropped rather than listed")
    func rejectsZipSlip() {
        // The zip-slip attack. Never shown, never counted, never handed to tar.
        #expect(
            ArchiveReader.parse(
                line: "-rw-r--r--  0 501 0  10 Jul 30 15:43 ../../etc/passwd") == nil)
        #expect(ArchiveIndex.isUnsafe("../evil"))
        #expect(ArchiveIndex.isUnsafe("a/../../b"))
        #expect(ArchiveIndex.isUnsafe("a/b") == false)
    }

    @Test("noise and blank lines yield nothing instead of a bogus member")
    func rejectsGarbage() {
        #expect(ArchiveReader.parse(line: "") == nil)
        #expect(ArchiveReader.parse(line: "tar: some warning") == nil)
        #expect(ArchiveReader.parse(line: "not a listing line at all") == nil)
    }

    @Test("both date shapes bsdtar emits are understood")
    func parsesDates() {
        let calendar = Calendar(identifier: .gregorian)

        // With a year and no time.
        let old = ArchiveReader.parseDate(month: "Jan", day: "2", timeOrYear: "2020")
        #expect(calendar.component(.year, from: old) == 2020)
        #expect(calendar.component(.month, from: old) == 1)
        #expect(calendar.component(.day, from: old) == 2)

        // With a time and no year: bsdtar omits the year for recent entries, so it is inferred
        // and can never land more than a day in the future.
        let recent = ArchiveReader.parseDate(month: "Jul", day: "30", timeOrYear: "15:43")
        #expect(calendar.component(.month, from: recent) == 7)
        #expect(calendar.component(.hour, from: recent) == 15)
        #expect(recent.timeIntervalSinceNow < 86_400)

        #expect(ArchiveReader.parseDate(month: nil, day: nil, timeOrYear: nil) == .distantPast)
    }

    @Test("reads a real zip built by the system zip tool")
    func readsZip() throws {
        let fixture = try ArchiveFixture("zip")
        defer { fixture.remove() }
        let index = try ArchiveReader.index(of: try fixture.makeZip())

        #expect(index.format == .zip)
        let paths = Set(index.members.map(\.path))
        #expect(paths.contains("readme.txt"))
        #expect(paths.contains("deep/data.csv"))
        #expect(paths.contains("deep/nested/blob.bin"))
        #expect(paths.contains("a file with spaces.txt"))
        #expect(index.member(at: "big.dat")?.size == 5_000)
    }

    @Test("reads a real tar.gz")
    func readsTarGzip() throws {
        let fixture = try ArchiveFixture("targz")
        defer { fixture.remove() }
        let index = try ArchiveReader.index(of: try fixture.makeTarGzip())

        #expect(index.format == .tarGzip)
        #expect(index.member(at: "readme.txt")?.size == 16)
        #expect(index.isDirectory("deep"))
    }

    @Test("a file that is not an archive is refused by name")
    func refusesNonArchive() throws {
        let tree = try TempTree("archive-plain")
        defer { tree.remove() }
        let file = try tree.file("notes.txt", bytes: 4)
        #expect(throws: ArchiveReader.Failure.self) {
            try ArchiveReader.index(of: file)
        }
    }

    @Test("a corrupt archive fails with the tool's own message rather than hanging")
    func refusesCorruptArchive() throws {
        let tree = try TempTree("archive-corrupt")
        defer { tree.remove() }
        let fake = tree.root.appendingPathComponent("broken.zip")
        try Data("this is definitely not a zip".utf8).write(to: fake)

        #expect(throws: (any Error).self) {
            try ArchiveReader.index(of: fake)
        }
    }
}

@Suite("ArchiveIndex")
struct ArchiveIndexTests {
    private func member(
        _ path: String,
        directory: Bool = false,
        size: Int64 = 0
    ) -> ArchiveMember {
        ArchiveMember(
            path: path, isDirectory: directory, isSymlink: false, size: size,
            modified: Date(timeIntervalSince1970: 1_000))
    }

    private func index(_ members: [ArchiveMember]) -> ArchiveIndex {
        ArchiveIndex(
            archive: URL(fileURLWithPath: "/tmp/a.zip"), format: .zip, members: members)
    }

    @Test("lists one level at a time")
    func listsOneLevel() {
        let subject = index([
            member("readme.txt", size: 10),
            member("deep", directory: true),
            member("deep/data.csv", size: 6),
            member("deep/nested", directory: true),
            member("deep/nested/blob.bin", size: 8),
        ])

        #expect(Set(subject.children(of: "").map(\.name)) == ["readme.txt", "deep"])
        #expect(Set(subject.children(of: "deep").map(\.name)) == ["data.csv", "nested"])
        #expect(subject.children(of: "deep/nested").map(\.name) == ["blob.bin"])
        #expect(subject.children(of: "nowhere").isEmpty)
    }

    @Test("directories missing from the archive are synthesised")
    func synthesisesDirectories() {
        // What `zip -D` produces: files only, no directory records.
        let subject = index([
            member("deep/nested/blob.bin", size: 8),
            member("readme.txt", size: 10),
        ])

        #expect(Set(subject.children(of: "").map(\.name)) == ["deep", "readme.txt"])
        #expect(subject.children(of: "").first { $0.name == "deep" }?.isDirectory == true)
        #expect(subject.children(of: "deep").map(\.name) == ["nested"])
        #expect(subject.children(of: "deep/nested").map(\.name) == ["blob.bin"])
    }

    @Test("a synthesised directory borrows a timestamp instead of inventing now")
    func synthesisedDirectoryDate() throws {
        let stamp = Date(timeIntervalSince1970: 1_000)
        let subject = index([member("deep/file.txt", size: 1)])
        let deep = try #require(subject.member(at: "deep"))
        #expect(deep.modified == stamp)
    }

    @Test("directory sizes are recursive totals, taken straight from the archive")
    func recursiveSizes() {
        let subject = index([
            member("deep/data.csv", size: 6),
            member("deep/nested/blob.bin", size: 8),
            member("readme.txt", size: 10),
        ])

        // Nothing is walked here: every size was already listed.
        #expect(subject.size(ofDirectory: "deep") == 14)
        #expect(subject.size(ofDirectory: "deep/nested") == 8)
        #expect(subject.size(ofDirectory: "") == 24, "the root totals everything")
    }

    @Test("paths are normalised so one location has one spelling")
    func normalisesPaths() {
        #expect(ArchiveIndex.normalise("./a/b/") == "a/b")
        #expect(ArchiveIndex.normalise("/a/b") == "a/b")
        #expect(ArchiveIndex.normalise("a/b") == "a/b")
        #expect(ArchiveIndex.normalise(".") == "")
        #expect(ArchiveIndex.normalise("./") == "")
    }

    @Test("children can be asked for with any spelling of the same path")
    func childrenToleratesSpelling() {
        let subject = index([member("deep/data.csv", size: 6)])
        #expect(subject.children(of: "deep").count == 1)
        #expect(subject.children(of: "deep/").count == 1)
        #expect(subject.children(of: "./deep").count == 1)
    }

    @Test("the archive root counts as a directory even with nothing in it")
    func rootIsADirectory() {
        #expect(index([]).isDirectory(""))
        #expect(index([member("a.txt", size: 1)]).isDirectory("a.txt") == false)
    }
}

@Suite("ArchiveReader extraction")
struct ArchiveReaderExtractionTests {
    @Test("extracts named members, keeping their paths")
    func extractsMembers() throws {
        let fixture = try ArchiveFixture("extract")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        try ArchiveReader.extract(
            members: ["readme.txt", "deep/data.csv"], from: archive, to: out)

        #expect(
            try Data(contentsOf: out.appendingPathComponent("readme.txt")).count == 16)
        #expect(
            try Data(contentsOf: out.appendingPathComponent("deep/data.csv")).count == 6)
        // Nothing unasked-for came along.
        #expect(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("big.dat").path)
                == false
        )
    }

    @Test("a name containing spaces extracts intact")
    func extractsNameWithSpaces() throws {
        let fixture = try ArchiveFixture("extract-spaces")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        try ArchiveReader.extract(members: ["a file with spaces.txt"], from: archive, to: out)
        #expect(
            try Data(contentsOf: out.appendingPathComponent("a file with spaces.txt")).count == 17)
    }

    @Test("selecting a directory brings out everything beneath it")
    func extractsDirectoryRecursively() throws {
        let fixture = try ArchiveFixture("extract-dir")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        try ArchiveReader.extract(members: ["deep"], from: archive, to: out)

        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("deep/data.csv").path))
        #expect(
            FileManager.default.fileExists(
                atPath: out.appendingPathComponent("deep/nested/blob.bin").path))
    }

    @Test("extractOne reports where the file landed")
    func extractOne() throws {
        let fixture = try ArchiveFixture("extract-one")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        let url = try ArchiveReader.extractOne(member: "deep/data.csv", from: archive, to: out)
        #expect(url.lastPathComponent == "data.csv")
        #expect(try Data(contentsOf: url).count == 6)
    }

    @Test("a zip built without directory records still extracts its nested files")
    func extractsFromZipWithoutDirectoryEntries() throws {
        let fixture = try ArchiveFixture("extract-nodirs")
        defer { fixture.remove() }
        let archive = try fixture.makeZipWithoutDirectoryEntries()
        let out = try fixture.tree.directory("out")

        try ArchiveReader.extract(members: ["deep/nested/blob.bin"], from: archive, to: out)
        #expect(
            try Data(contentsOf: out.appendingPathComponent("deep/nested/blob.bin")).count == 8)
    }

    @Test("an unsafe member is never passed to the tool")
    func refusesUnsafeMembers() throws {
        let fixture = try ArchiveFixture("extract-unsafe")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        // Filtered out, so the call becomes a no-op rather than an escape.
        try ArchiveReader.extract(members: ["../escape.txt"], from: archive, to: out)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test("extracting nothing is a no-op, not an error")
    func extractsNothing() throws {
        let fixture = try ArchiveFixture("extract-empty")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        try ArchiveReader.extract(members: [], from: archive, to: out)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test("cancelling before any work throws instead of extracting")
    func cancels() throws {
        let fixture = try ArchiveFixture("extract-cancel")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        #expect(throws: ArchiveReader.Failure.self) {
            try ArchiveReader.extract(
                members: ["readme.txt"], from: archive, to: out, isCancelled: { true })
        }
    }
}
