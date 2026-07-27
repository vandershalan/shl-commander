import Foundation
import Testing

@testable import ShlCommander

/// Answers conflicts from a script instead of a dialog, and records how often it was asked.
@MainActor
private final class ScriptedPrompt: ConflictPrompting {
    private var answers: [ConflictDecision?]
    private(set) var timesAsked = 0

    init(_ answers: [ConflictDecision?]) {
        self.answers = answers
    }

    init(always resolution: ConflictResolution, applyToAll: Bool = false) {
        self.answers = []
        self.standing = ConflictDecision(resolution: resolution, applyToAll: applyToAll)
    }

    private var standing: ConflictDecision?

    func resolveConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL
    ) async -> ConflictDecision? {
        timesAsked += 1
        if let standing { return standing }
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

@MainActor
@Suite("FileOperationQueue")
struct FileOperationQueueTests {
    private let fileManager = FileManager.default

    private func run(
        _ request: FileOperationRequest,
        prompt: any ConflictPrompting = ScriptedPrompt(always: .rename)
    ) async -> FileOperationQueue {
        let queue = FileOperationQueue()
        queue.start(request, prompt: prompt)
        await queue.settle()
        return queue
    }

    @Test("copies marked files into the destination and clears progress when done")
    func copyFiles() async throws {
        let tree = try TempTree("queue-copy")
        defer { tree.remove() }
        let one = try tree.file("one.txt", bytes: 10)
        let two = try tree.file("two.txt", bytes: 20)
        let destination = try tree.directory("out")

        let queue = await run(
            FileOperationRequest(kind: .copy, sources: [one, two], destinationDirectory: destination)
        )

        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("one.txt").path))
        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("two.txt").path))
        #expect(fileManager.fileExists(atPath: one.path), "sources survive a copy")
        #expect(queue.failures.isEmpty)
        #expect(queue.progress == nil, "the progress bar goes away")
        #expect(queue.isRunning == false)
    }

    @Test("moving removes the sources")
    func moveFiles() async throws {
        let tree = try TempTree("queue-move")
        defer { tree.remove() }
        let one = try tree.file("one.txt", bytes: 10)
        let destination = try tree.directory("out")

        _ = await run(
            FileOperationRequest(kind: .move, sources: [one], destinationDirectory: destination)
        )

        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("one.txt").path))
        #expect(fileManager.fileExists(atPath: one.path) == false)
    }

    @Test("skip leaves the existing file untouched")
    func conflictSkip() async throws {
        let tree = try TempTree("queue-skip")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 10)
        let destination = try tree.directory("out")
        try Data(repeating: 0x42, count: 999).write(
            to: destination.appendingPathComponent("a.txt"))

        _ = await run(
            FileOperationRequest(kind: .copy, sources: [source], destinationDirectory: destination),
            prompt: ScriptedPrompt(always: .skip)
        )

        let existing = try Data(contentsOf: destination.appendingPathComponent("a.txt"))
        #expect(existing.count == 999, "the original was kept")
    }

    @Test("overwrite replaces the existing file")
    func conflictOverwrite() async throws {
        let tree = try TempTree("queue-overwrite")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 10)
        let destination = try tree.directory("out")
        try Data(repeating: 0x42, count: 999).write(
            to: destination.appendingPathComponent("a.txt"))

        _ = await run(
            FileOperationRequest(kind: .copy, sources: [source], destinationDirectory: destination),
            prompt: ScriptedPrompt(always: .overwrite)
        )

        let replaced = try Data(contentsOf: destination.appendingPathComponent("a.txt"))
        #expect(replaced.count == 10, "the source replaced it")
    }

    @Test("keep-both writes alongside under a free name")
    func conflictKeepBoth() async throws {
        let tree = try TempTree("queue-keepboth")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 10)
        let destination = try tree.directory("out")
        try Data(repeating: 0x42, count: 999).write(
            to: destination.appendingPathComponent("a.txt"))

        _ = await run(
            FileOperationRequest(kind: .copy, sources: [source], destinationDirectory: destination),
            prompt: ScriptedPrompt(always: .rename)
        )

        #expect(
            try Data(contentsOf: destination.appendingPathComponent("a.txt")).count == 999)
        #expect(
            try Data(contentsOf: destination.appendingPathComponent("a 2.txt")).count == 10)
    }

    @Test("apply-to-all asks once and reuses the answer")
    func applyToAllAsksOnce() async throws {
        let tree = try TempTree("queue-applyall")
        defer { tree.remove() }
        let one = try tree.file("one.txt", bytes: 10)
        let two = try tree.file("two.txt", bytes: 10)
        let destination = try tree.directory("out")
        for name in ["one.txt", "two.txt"] {
            try Data(repeating: 0x42, count: 5).write(
                to: destination.appendingPathComponent(name))
        }

        let prompt = ScriptedPrompt(always: .skip, applyToAll: true)
        let queue = FileOperationQueue()
        queue.start(
            FileOperationRequest(
                kind: .copy, sources: [one, two], destinationDirectory: destination),
            prompt: prompt
        )
        await queue.settle()

        #expect(prompt.timesAsked == 1, "the second conflict reused the decision")
        #expect(
            try Data(contentsOf: destination.appendingPathComponent("two.txt")).count == 5)
    }

    @Test("an automatic resolution never prompts at all")
    func automaticResolutionSkipsPrompt() async throws {
        let tree = try TempTree("queue-auto")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 10)

        let prompt = ScriptedPrompt(always: .overwrite)
        let queue = FileOperationQueue()
        // Duplicating into the same directory: the name always collides.
        queue.start(
            FileOperationRequest(
                kind: .copy,
                sources: [source],
                destinationDirectory: tree.root,
                automaticResolution: .rename
            ),
            prompt: prompt
        )
        await queue.settle()

        #expect(prompt.timesAsked == 0)
        #expect(fileManager.fileExists(atPath: tree.root.appendingPathComponent("a 2.txt").path))
        #expect(try Data(contentsOf: source).count == 10, "the original is intact")
    }

    @Test("declining the conflict dialog abandons the rest of the operation")
    func cancellingPromptStops() async throws {
        let tree = try TempTree("queue-abandon")
        defer { tree.remove() }
        let one = try tree.file("one.txt", bytes: 10)
        let two = try tree.file("two.txt", bytes: 10)
        let destination = try tree.directory("out")
        try Data(repeating: 0x42, count: 5).write(
            to: destination.appendingPathComponent("one.txt"))

        _ = await run(
            FileOperationRequest(
                kind: .copy, sources: [one, two], destinationDirectory: destination),
            prompt: ScriptedPrompt([nil])  // user pressed Cancel
        )

        #expect(
            try Data(contentsOf: destination.appendingPathComponent("one.txt")).count == 5)
        #expect(
            fileManager.fileExists(atPath: destination.appendingPathComponent("two.txt").path)
                == false,
            "nothing after the cancelled conflict was touched"
        )
    }

    @Test("copying a folder into its own subfolder is refused and reported")
    func refusesRecursiveCopy() async throws {
        let tree = try TempTree("queue-recursive")
        defer { tree.remove() }
        let source = try tree.directory("project")
        let destination = try tree.directory("project/inner")

        let queue = await run(
            FileOperationRequest(
                kind: .copy, sources: [source], destinationDirectory: destination)
        )

        #expect(queue.failures.count == 1)
        #expect(queue.failures[0].message.contains("inside"))
    }

    @Test("overwriting a file with itself is refused rather than truncating it")
    func refusesSelfOverwrite() async throws {
        let tree = try TempTree("queue-self")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 42)

        // Copying into the source's own directory with Overwrite aims at the source itself;
        // removing the destination first would delete the file before reading it.
        let queue = await run(
            FileOperationRequest(
                kind: .copy, sources: [source], destinationDirectory: tree.root),
            prompt: ScriptedPrompt(always: .overwrite)
        )

        #expect(queue.failures.count == 1)
        #expect(try Data(contentsOf: source).count == 42, "the file is untouched")
    }

    @Test("duplicating a folder into its own parent works")
    func duplicateFolder() async throws {
        let tree = try TempTree("queue-dupdir")
        defer { tree.remove() }
        try tree.file("sub/inner.txt", bytes: 8)
        let source = tree.root.appendingPathComponent("sub")

        let queue = FileOperationQueue()
        queue.start(
            FileOperationRequest(
                kind: .copy,
                sources: [source],
                destinationDirectory: tree.root,
                automaticResolution: .rename
            ),
            prompt: ScriptedPrompt(always: .rename)
        )
        await queue.settle()

        #expect(queue.failures.isEmpty)
        #expect(
            try Data(contentsOf: tree.root.appendingPathComponent("sub 2/inner.txt")).count == 8)
    }

    @Test("one failure does not abandon the remaining items")
    func continuesPastFailure() async throws {
        let tree = try TempTree("queue-partial")
        defer { tree.remove() }
        let missing = tree.root.appendingPathComponent("gone.txt")
        let real = try tree.file("real.txt", bytes: 10)
        let destination = try tree.directory("out")

        let queue = await run(
            FileOperationRequest(
                kind: .copy, sources: [missing, real], destinationDirectory: destination)
        )

        #expect(queue.failures.count == 1)
        #expect(
            fileManager.fileExists(atPath: destination.appendingPathComponent("real.txt").path),
            "the healthy item still went through"
        )
    }

    @Test("deleting permanently removes items outright")
    func deletePermanently() async throws {
        let tree = try TempTree("queue-delete")
        defer { tree.remove() }
        let doomed = try tree.file("doomed.txt", bytes: 10)
        try tree.file("tree/inner.txt", bytes: 5)
        let doomedTree = tree.root.appendingPathComponent("tree")

        let queue = FileOperationQueue()
        queue.startDeletion(of: [doomed, doomedTree], toTrash: false)
        await queue.settle()

        #expect(fileManager.fileExists(atPath: doomed.path) == false)
        #expect(fileManager.fileExists(atPath: doomedTree.path) == false)
        #expect(queue.failures.isEmpty)
    }

    @Test("a failed delete is reported rather than thrown away")
    func deleteFailureReported() async throws {
        let tree = try TempTree("queue-delfail")
        defer { tree.remove() }

        let queue = FileOperationQueue()
        queue.startDeletion(of: [tree.root.appendingPathComponent("never-existed")], toTrash: false)
        await queue.settle()

        #expect(queue.failures.count == 1)
    }

    @Test("a second operation is refused while one is running")
    func serialOnly() async throws {
        let tree = try TempTree("queue-serial")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 10)
        let destination = try tree.directory("out")
        let request = FileOperationRequest(
            kind: .copy, sources: [source], destinationDirectory: destination)

        let queue = FileOperationQueue()
        queue.start(request, prompt: ScriptedPrompt(always: .rename))
        // Overlapping operations on the same tree would race, so the second is dropped.
        queue.start(
            FileOperationRequest(
                kind: .move, sources: [source], destinationDirectory: destination),
            prompt: ScriptedPrompt(always: .rename)
        )
        await queue.settle()

        #expect(fileManager.fileExists(atPath: source.path), "the move never ran")
    }

    @Test("an empty request does nothing at all")
    func emptyRequest() async throws {
        let tree = try TempTree("queue-empty")
        defer { tree.remove() }
        let queue = FileOperationQueue()
        queue.start(
            FileOperationRequest(kind: .copy, sources: [], destinationDirectory: tree.root),
            prompt: ScriptedPrompt(always: .rename)
        )
        #expect(queue.isRunning == false)
        #expect(queue.progress == nil)
    }

    @Test("completion fires so panels can refresh")
    func completionCallback() async throws {
        let tree = try TempTree("queue-completion")
        defer { tree.remove() }
        let source = try tree.file("a.txt", bytes: 4)
        let destination = try tree.directory("out")

        let queue = FileOperationQueue()
        var completions = 0
        queue.onCompletion = { completions += 1 }
        queue.start(
            FileOperationRequest(
                kind: .copy, sources: [source], destinationDirectory: destination),
            prompt: ScriptedPrompt(always: .rename)
        )
        await queue.settle()

        #expect(completions == 1)
    }
}
