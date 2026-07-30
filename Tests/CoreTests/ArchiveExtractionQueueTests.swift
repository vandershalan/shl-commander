import Foundation
import Testing

@testable import ShlCommander

/// Answers conflicts from a script, and records how often it was asked.
@MainActor
private final class StubPrompt: ConflictPrompting {
    private let decision: ConflictDecision?
    private(set) var timesAsked = 0

    init(_ resolution: ConflictResolution, applyToAll: Bool = true) {
        decision = ConflictDecision(resolution: resolution, applyToAll: applyToAll)
    }

    /// Cancels instead of deciding.
    init() { decision = nil }

    func resolveConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL
    ) async -> ConflictDecision? {
        timesAsked += 1
        return decision
    }
}

@MainActor
@Suite("Extracting out of an archive")
struct ArchiveExtractionQueueTests {
    /// Entries as the panel would present them, so the queue is driven the way the app drives it.
    private func members(_ paths: [(String, Bool, Int64)], in archive: URL) -> [FileEntry] {
        paths.map { path, isDirectory, size in
            FileEntry(
                member: ArchiveMember(
                    path: path, isDirectory: isDirectory, isSymlink: false, size: size,
                    modified: Date(timeIntervalSince1970: 1_000)),
                in: archive,
                directorySize: 0
            )
        }
    }

    @Test("extracts the chosen members into the destination")
    func extractsSelection() async throws {
        let fixture = try ArchiveFixture("queue-extract")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16), ("deep/data.csv", false, 6)], in: archive),
            to: out,
            prompt: StubPrompt(.rename)
        )
        await queue.settle()

        #expect(queue.failures.isEmpty)
        #expect(try Data(contentsOf: out.appendingPathComponent("readme.txt")).count == 16)
        #expect(try Data(contentsOf: out.appendingPathComponent("deep/data.csv")).count == 6)
        #expect(queue.progress == nil, "the progress bar goes away")
    }

    @Test("the staging directory is cleaned up, whatever happened")
    func stagingIsRemoved() async throws {
        let fixture = try ArchiveFixture("queue-staging")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16)], in: archive),
            to: out,
            prompt: StubPrompt(.rename)
        )
        await queue.settle()

        // Nothing beginning with the staging prefix survives.
        let left = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(left.contains { $0.hasPrefix(".shl-extract-") } == false)
        #expect(left.contains("readme.txt"))
    }

    @Test("a folder comes out whole")
    func extractsDirectory() async throws {
        let fixture = try ArchiveFixture("queue-dir")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("deep", true, 0)], in: archive),
            to: out,
            prompt: StubPrompt(.rename)
        )
        await queue.settle()

        #expect(queue.failures.isEmpty)
        #expect(try Data(contentsOf: out.appendingPathComponent("deep/data.csv")).count == 6)
        #expect(
            try Data(contentsOf: out.appendingPathComponent("deep/nested/blob.bin")).count == 8)
    }

    @Test("an existing file is kept when the answer is skip")
    func conflictSkip() async throws {
        let fixture = try ArchiveFixture("queue-skip")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")
        try Data(repeating: 0x42, count: 999).write(to: out.appendingPathComponent("readme.txt"))

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16)], in: archive),
            to: out,
            prompt: StubPrompt(.skip)
        )
        await queue.settle()

        #expect(try Data(contentsOf: out.appendingPathComponent("readme.txt")).count == 999)
    }

    @Test("keep-both writes the extracted copy alongside")
    func conflictKeepBoth() async throws {
        let fixture = try ArchiveFixture("queue-keepboth")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")
        try Data(repeating: 0x42, count: 999).write(to: out.appendingPathComponent("readme.txt"))

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16)], in: archive),
            to: out,
            prompt: StubPrompt(.rename)
        )
        await queue.settle()

        #expect(try Data(contentsOf: out.appendingPathComponent("readme.txt")).count == 999)
        #expect(try Data(contentsOf: out.appendingPathComponent("readme 2.txt")).count == 16)
    }

    @Test("overwrite replaces what was there")
    func conflictOverwrite() async throws {
        let fixture = try ArchiveFixture("queue-overwrite")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")
        try Data(repeating: 0x42, count: 999).write(to: out.appendingPathComponent("readme.txt"))

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16)], in: archive),
            to: out,
            prompt: StubPrompt(.overwrite)
        )
        await queue.settle()

        #expect(try Data(contentsOf: out.appendingPathComponent("readme.txt")).count == 16)
    }

    @Test("apply-to-all asks once for a batch of conflicts")
    func asksOnce() async throws {
        let fixture = try ArchiveFixture("queue-once")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")
        for name in ["readme.txt", "big.dat"] {
            try Data(repeating: 0x42, count: 5).write(to: out.appendingPathComponent(name))
        }

        let prompt = StubPrompt(.skip, applyToAll: true)
        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16), ("big.dat", false, 5_000)], in: archive),
            to: out,
            prompt: prompt
        )
        await queue.settle()

        #expect(prompt.timesAsked == 1)
    }

    @Test("declining the conflict dialog abandons the rest")
    func cancelStops() async throws {
        let fixture = try ArchiveFixture("queue-cancel")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")
        try Data(repeating: 0x42, count: 5).write(to: out.appendingPathComponent("readme.txt"))

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16), ("big.dat", false, 5_000)], in: archive),
            to: out,
            prompt: StubPrompt()  // cancels
        )
        await queue.settle()

        #expect(try Data(contentsOf: out.appendingPathComponent("readme.txt")).count == 5)
        #expect(
            FileManager.default.fileExists(atPath: out.appendingPathComponent("big.dat").path)
                == false,
            "nothing after the cancelled conflict was written"
        )
    }

    @Test("a corrupt archive reports a failure rather than a silent no-op")
    func corruptArchiveFails() async throws {
        let tree = try TempTree("queue-corrupt")
        defer { tree.remove() }
        let fake = tree.root.appendingPathComponent("broken.zip")
        try Data("nonsense".utf8).write(to: fake)
        let out = try tree.directory("out")

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: fake,
            members: members([("readme.txt", false, 1)], in: fake),
            to: out,
            prompt: StubPrompt(.rename)
        )
        await queue.settle()

        #expect(queue.failures.isEmpty == false)
    }

    @Test("extracting nothing does not start an operation")
    func emptySelection() async throws {
        let fixture = try ArchiveFixture("queue-empty")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()

        let queue = FileOperationQueue()
        queue.startExtraction(
            from: archive, members: [], to: fixture.tree.root, prompt: StubPrompt(.rename))
        #expect(queue.isRunning == false)
        #expect(queue.progress == nil)
    }

    @Test("completion fires so the panes can refresh")
    func completionFires() async throws {
        let fixture = try ArchiveFixture("queue-completion")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()
        let out = try fixture.tree.directory("out")

        let queue = FileOperationQueue()
        var completions = 0
        queue.onCompletion = { completions += 1 }
        queue.startExtraction(
            from: archive,
            members: members([("readme.txt", false, 16)], in: archive),
            to: out,
            prompt: StubPrompt(.rename)
        )
        await queue.settle()

        #expect(completions == 1)
    }
}
