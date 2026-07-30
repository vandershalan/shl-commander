import Foundation
import Testing

@testable import ShlCommander

/// Regression cover for a real file: a gzipped CSV handed out under a `.zip` name. The name said
/// zip, bsdtar said "Unrecognized archive format", and entering it failed.
@Suite("Identifying an archive by content")
struct ArchiveProbeTests {
    /// Writes a file whose name and contents deliberately disagree.
    private func file(named name: String, bytes: [UInt8], in tree: TempTree) throws -> URL {
        let url = tree.root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    /// A real gzip stream, built with the system tool.
    private func gzip(named name: String, payload: String, in tree: TempTree) throws -> URL {
        let plain = tree.root.appendingPathComponent("payload.txt")
        try Data(payload.utf8).write(to: plain)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plain.path]
        let output = tree.root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        try FileManager.default.removeItem(at: plain)
        return output
    }

    @Test("signatures are recognised from the first bytes")
    func recognisesSignatures() {
        #expect(ArchiveProbe.signature(of: Data([0x50, 0x4B, 0x03, 0x04])) == .zip)
        #expect(ArchiveProbe.signature(of: Data([0x1F, 0x8B, 0x08, 0x00])) == .gzipStream)
        #expect(ArchiveProbe.signature(of: Data([0x42, 0x5A, 0x68, 0x39])) == .bzip2Stream)
        #expect(
            ArchiveProbe.signature(of: Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) == .xzStream)
        #expect(ArchiveProbe.signature(of: Data([0x28, 0xB5, 0x2F, 0xFD])) == .zstdStream)
        #expect(
            ArchiveProbe.signature(of: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])) == .sevenZip)
        #expect(ArchiveProbe.signature(of: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07])) == .rar)
    }

    @Test("tar is recognised by ustar at offset 257, not at the start")
    func recognisesTar() {
        var header = Data(repeating: 0, count: 264)
        header.replaceSubrange(257..<262, with: Data("ustar".utf8))
        #expect(ArchiveProbe.signature(of: header) == .tar)
        // The same bytes at the start mean nothing.
        #expect(ArchiveProbe.signature(of: Data("ustar".utf8)) == nil)
    }

    @Test("plain content matches nothing")
    func rejectsPlainContent() {
        #expect(ArchiveProbe.signature(of: Data("item_id,brand_name\n1,x\n".utf8)) == nil)
        #expect(ArchiveProbe.signature(of: Data()) == nil)
        #expect(ArchiveProbe.signature(of: Data([0x1F])) == nil, "a truncated signature")
    }

    @Test("content beats a name that lies")
    func contentWinsOverName() throws {
        let tree = try TempTree("probe-misnamed")
        defer { tree.remove() }
        // The reported case: a gzip stream named .zip.
        let url = try gzip(named: "SNAPSHOT_INC.zip", payload: "item_id,brand\n1,x\n", in: tree)

        #expect(ArchiveFormat.detect(url: url) == .zip, "the name still claims zip")
        #expect(ArchiveProbe.format(of: url) == .gzipStream, "the bytes decide")
        #expect(ArchiveProbe.nameDisagreesWithContent(url))
    }

    @Test("a name spelling a compressed tar keeps its more precise answer")
    func compressedTarKeepsTheName() throws {
        let fixture = try ArchiveFixture("probe-targz")
        defer { fixture.remove() }
        let url = try fixture.makeTarGzip()

        // A .tar.gz and a bare .gz share a gzip signature but mean different things, so here the
        // name carries information the first bytes do not.
        #expect(ArchiveProbe.format(of: url) == .tarGzip)
        #expect(ArchiveProbe.nameDisagreesWithContent(url) == false)
    }

    @Test("an unrecognisable file falls back to whatever its name suggests")
    func fallsBackToName() throws {
        let tree = try TempTree("probe-fallback")
        defer { tree.remove() }
        // No signature is implemented for iso, so the name is all there is to go on.
        let url = try file(named: "disc.iso", bytes: Array(repeating: 0, count: 64), in: tree)
        #expect(ArchiveProbe.format(of: url) == .iso)
    }

    @Test("a file that is neither by name nor by content is not an archive")
    func neither() throws {
        let tree = try TempTree("probe-neither")
        defer { tree.remove() }
        let url = try file(named: "notes.txt", bytes: Array("hello".utf8), in: tree)
        #expect(ArchiveProbe.format(of: url) == nil)
    }
}

@Suite("Single compressed streams")
struct SingleStreamTests {
    private func gzip(named name: String, payload: Data, in tree: TempTree) throws -> URL {
        let plain = tree.root.appendingPathComponent("inner.bin")
        try payload.write(to: plain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plain.path]
        let output = tree.root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()
        try FileManager.default.removeItem(at: plain)
        return output
    }

    @Test("a stream lists exactly one member: its payload")
    func listsOnePayload() throws {
        let tree = try TempTree("stream-list")
        defer { tree.remove() }
        let url = try gzip(named: "report.csv.gz", payload: Data(repeating: 0x41, count: 500), in: tree)

        let index = try ArchiveReader.index(of: url)
        #expect(index.format == .gzipStream)
        #expect(index.members.count == 1)
        #expect(index.members.first?.path == "report.csv", "the .gz suffix comes off")
        #expect(index.members.first?.isDirectory == false)
    }

    @Test("gzip records its payload size, so the column shows a number")
    func gzipSizeFromFooter() throws {
        let tree = try TempTree("stream-size")
        defer { tree.remove() }
        let url = try gzip(named: "data.gz", payload: Data(repeating: 0x41, count: 1_234), in: tree)

        // gzip keeps the uncompressed size in its last four bytes, so this costs one seek.
        #expect(ArchiveReader.uncompressedSize(of: url, format: .gzipStream) == 1_234)
    }

    @Test("a format with no size field reports unknown rather than zero")
    func unknownSize() throws {
        let tree = try TempTree("stream-unknown")
        defer { tree.remove() }
        let url = try gzip(named: "data.gz", payload: Data(repeating: 0x41, count: 10), in: tree)

        // bzip2 keeps no such field; claiming 0 bytes would be a lie.
        #expect(ArchiveReader.uncompressedSize(of: url, format: .bzip2Stream) == FileEntry.unknownSize)
    }

    @Test("the payload is named by dropping a misleading extension when there is no real suffix")
    func namesPayloadFromMisleadingExtension() {
        let url = URL(fileURLWithPath: "/tmp/ITEM_RE_SNAPSHOT_2026_07_06_INC.zip")
        // The name has no compression suffix to strip, and ".zip" describes a format the file is
        // not in, so it goes.
        #expect(
            ArchiveReader.payloadName(for: url, format: .gzipStream)
                == "ITEM_RE_SNAPSHOT_2026_07_06_INC")
    }

    @Test("a real compression suffix is what gets stripped")
    func namesPayloadFromSuffix() {
        #expect(
            ArchiveReader.payloadName(
                for: URL(fileURLWithPath: "/tmp/archive.tar.gz"), format: .gzipStream)
                == "archive.tar"
        )
        #expect(
            ArchiveReader.payloadName(
                for: URL(fileURLWithPath: "/tmp/notes.txt.bz2"), format: .bzip2Stream)
                == "notes.txt"
        )
    }

    @Test("extracting a stream writes the decompressed payload")
    func extractsPayload() throws {
        let tree = try TempTree("stream-extract")
        defer { tree.remove() }
        let payload = Data(repeating: 0x42, count: 2_048)
        let url = try gzip(named: "report.csv.gz", payload: payload, in: tree)
        let out = try tree.directory("out")

        try ArchiveReader.extract(members: ["report.csv"], from: url, to: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("report.csv")) == payload)
    }

    @Test("extracting a misnamed stream still works, and drops the wrong extension")
    func extractsMisnamedStream() throws {
        let tree = try TempTree("stream-misnamed")
        defer { tree.remove() }
        let payload = Data("item_id,brand\n1,x\n".utf8)
        let url = try gzip(named: "SNAPSHOT.zip", payload: payload, in: tree)
        let out = try tree.directory("out")

        try ArchiveReader.extract(members: ["SNAPSHOT"], from: url, to: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("SNAPSHOT")) == payload)
    }

    @Test("a failed decompression leaves no half-written file behind")
    func noPartialFile() throws {
        let tree = try TempTree("stream-partial")
        defer { tree.remove() }
        // Claims gzip in its name but holds nothing gzip can read.
        let broken = tree.root.appendingPathComponent("broken.gz")
        try Data("not gzip at all".utf8).write(to: broken)
        let out = try tree.directory("out")

        #expect(throws: (any Error).self) {
            try ArchiveReader.extractStream(from: broken, format: .gzipStream, to: out)
        }
        // A truncated file looks like a finished one, so it must not survive.
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test("cancelling a stream extraction writes nothing")
    func cancelled() throws {
        let tree = try TempTree("stream-cancel")
        defer { tree.remove() }
        let url = try gzip(named: "data.gz", payload: Data(repeating: 0x41, count: 10), in: tree)
        let out = try tree.directory("out")

        #expect(throws: ArchiveReader.Failure.self) {
            try ArchiveReader.extractStream(
                from: url, format: .gzipStream, to: out, isCancelled: { true })
        }
    }
}

@MainActor
@Suite("Opening a stream in a panel")
struct PanelSingleStreamTests {
    @Test("entering a gzip shows its payload as one row")
    func entersStream() async throws {
        let tree = try TempTree("panel-stream")
        defer { tree.remove() }
        let plain = tree.root.appendingPathComponent("inner.csv")
        try Data(repeating: 0x41, count: 900).write(to: plain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [plain.path]
        try process.run()
        process.waitUntilExit()
        let archive = tree.root.appendingPathComponent("inner.csv.gz")

        let panel = PanelViewModel(directory: tree.root)
        panel.enterArchive(archive)
        await panel.settle()

        #expect(panel.loadError == nil)
        #expect(panel.isInsideArchive)
        let rows = panel.entries.filter { !$0.isParent }
        #expect(rows.map(\.name) == ["inner.csv"])
        #expect(rows.first?.size == 900)
    }

    @Test("a file that cannot be read as an archive leaves the pane where it was")
    func failureKeepsThePanePut() async throws {
        let tree = try TempTree("panel-stream-bad")
        defer { tree.remove() }
        let broken = tree.root.appendingPathComponent("broken.zip")
        try Data("nonsense, not any archive".utf8).write(to: broken)

        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()

        var reported: String?
        panel.onOpenFailure = { _, message in reported = message }

        panel.openArchive(broken)
        // openArchive checks the listing before moving, so give that task a moment.
        for _ in 0..<100 where reported == nil {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(reported != nil, "the failure is reported rather than left to a footer line")
        #expect(panel.isInsideArchive == false, "the pane did not move into an unreadable file")
        #expect(panel.entries.contains { $0.name == "broken.zip" })
    }
}

@MainActor
@Suite("Archive note")
struct ArchiveNoteTests {
    private func index(_ format: ArchiveFormat, archive: URL) -> ArchiveIndex {
        ArchiveIndex(archive: archive, format: format, members: [])
    }

    @Test("a matching name gets a plain read-only note")
    func matchingName() throws {
        let fixture = try ArchiveFixture("note-match")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()

        let note = ArchiveNote.describe(index: index(.zip, archive: archive), archive: archive)
        #expect(note.contains("zip"))
        #expect(note.contains("read-only"))
        #expect(note.contains("but the contents are not") == false)
    }

    @Test("a lying name is called out, which explains the single row")
    func lyingName() throws {
        let tree = try TempTree("note-lying")
        defer { tree.remove() }
        // A gzip stream named .zip: the reported case.
        let plain = tree.root.appendingPathComponent("inner.csv")
        try Data(repeating: 0x41, count: 32).write(to: plain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", plain.path]
        let archive = tree.root.appendingPathComponent("SNAPSHOT.zip")
        FileManager.default.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        process.standardOutput = handle
        try process.run()
        process.waitUntilExit()
        try handle.close()

        let note = ArchiveNote.describe(
            index: index(.gzipStream, archive: archive), archive: archive)
        #expect(note.contains("gzip stream"))
        #expect(note.contains("says zip"))
        #expect(note.contains("but the contents are not"))
    }
}
