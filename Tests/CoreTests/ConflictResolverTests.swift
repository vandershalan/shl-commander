import Foundation
import Testing

@testable import ShlCommander

@Suite("ConflictResolver")
struct ConflictResolverTests {
    private let directory = URL(fileURLWithPath: "/dest")

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// Existence and dates come from a dictionary, so the whole matrix runs without a disk.
    private func exists(_ taken: Set<String>) -> (URL) -> Bool {
        { taken.contains($0.lastPathComponent) }
    }

    // MARK: - Rejections

    @Test("copying a folder into its own descendant is refused")
    func destinationInsideSource() {
        #expect(
            ConflictResolver.rejectContainment(
                source: URL(fileURLWithPath: "/Users/me/project"),
                destinationDirectory: URL(fileURLWithPath: "/Users/me/project/backup")
            ) == .destinationInsideSource
        )
    }

    @Test("copying a folder into itself is refused")
    func destinationIsSource() {
        let source = URL(fileURLWithPath: "/Users/me/project")
        #expect(
            ConflictResolver.rejectContainment(source: source, destinationDirectory: source)
                == .destinationInsideSource
        )
    }

    @Test("a sibling whose name merely shares a prefix is not 'inside'")
    func prefixIsNotContainment() {
        // "/a/bc" starts with the characters of "/a/b" but is not inside it.
        #expect(
            ConflictResolver.rejectContainment(
                source: URL(fileURLWithPath: "/a/b"),
                destinationDirectory: URL(fileURLWithPath: "/a/bc")
            ) == nil
        )
    }

    @Test("duplicating a file into its own folder is allowed")
    func duplicateIntoOwnDirectory() {
        // The destination directory is the source's parent, which is not containment. The
        // rename plan is what keeps it from landing on itself.
        #expect(
            ConflictResolver.rejectContainment(
                source: URL(fileURLWithPath: "/a/file.txt"),
                destinationDirectory: URL(fileURLWithPath: "/a")
            ) == nil
        )
    }

    @Test("writing an item onto itself is refused")
    func sameLocation() {
        let source = URL(fileURLWithPath: "/Users/me/file.txt")
        #expect(ConflictResolver.rejectSameLocation(source: source, target: source) == .sameLocation)
        #expect(
            ConflictResolver.rejectSameLocation(
                source: source,
                target: URL(fileURLWithPath: "/Users/me/file 2.txt")
            ) == nil
        )
    }

    @Test("an ordinary copy into another folder is allowed")
    func ordinaryCopyAllowed() {
        #expect(
            ConflictResolver.rejectContainment(
                source: URL(fileURLWithPath: "/a/file.txt"),
                destinationDirectory: URL(fileURLWithPath: "/b")
            ) == nil
        )
    }

    @Test("a plan reports where it will write, and skip reports nothing")
    func planTargets() {
        #expect(ConflictResolver.Plan.skip.target == nil)
        #expect(ConflictResolver.Plan.write(url("a.txt")).target == url("a.txt"))
        #expect(ConflictResolver.Plan.overwrite(url("a.txt")).target == url("a.txt"))
    }

    // MARK: - Decision matrix

    @Test("a free destination is written directly, whatever the resolution")
    func noConflict() {
        for resolution in ConflictResolution.allCases {
            let plan = ConflictResolver.plan(
                source: url("a.txt"),
                destination: url("a.txt"),
                resolution: resolution,
                exists: exists([]),
                modified: { _ in nil }
            )
            #expect(plan == .write(url("a.txt")), "resolution \(resolution)")
        }
    }

    @Test("skip leaves the existing file alone")
    func skip() {
        let plan = ConflictResolver.plan(
            source: url("a.txt"),
            destination: url("a.txt"),
            resolution: .skip,
            exists: exists(["a.txt"]),
            modified: { _ in nil }
        )
        #expect(plan == .skip)
    }

    @Test("overwrite replaces in place")
    func overwrite() {
        let plan = ConflictResolver.plan(
            source: url("a.txt"),
            destination: url("a.txt"),
            resolution: .overwrite,
            exists: exists(["a.txt"]),
            modified: { _ in nil }
        )
        #expect(plan == .overwrite(url("a.txt")))
    }

    @Test("keep-both writes to the next free name")
    func keepBoth() {
        let plan = ConflictResolver.plan(
            source: URL(fileURLWithPath: "/src/a.txt"),
            destination: url("a.txt"),
            resolution: .rename,
            exists: exists(["a.txt"]),
            modified: { _ in nil }
        )
        #expect(plan == .write(url("a 2.txt")))
    }

    @Test("overwrite-if-newer compares timestamps in both directions")
    func overwriteIfNewer() {
        let source = URL(fileURLWithPath: "/src/a.txt")
        let destination = url("a.txt")
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        let sourceIsNewer = ConflictResolver.plan(
            source: source, destination: destination, resolution: .overwriteIfNewer,
            exists: exists(["a.txt"]),
            modified: { $0 == source ? new : old }
        )
        #expect(sourceIsNewer == .overwrite(destination))

        let sourceIsOlder = ConflictResolver.plan(
            source: source, destination: destination, resolution: .overwriteIfNewer,
            exists: exists(["a.txt"]),
            modified: { $0 == source ? old : new }
        )
        #expect(sourceIsOlder == .skip)

        let sameAge = ConflictResolver.plan(
            source: source, destination: destination, resolution: .overwriteIfNewer,
            exists: exists(["a.txt"]),
            modified: { _ in old }
        )
        #expect(sameAge == .skip, "equal timestamps are not newer")
    }

    @Test("overwrite-if-newer keeps the existing file when a date is unknown")
    func overwriteIfNewerWithoutDates() {
        let plan = ConflictResolver.plan(
            source: URL(fileURLWithPath: "/src/a.txt"),
            destination: url("a.txt"),
            resolution: .overwriteIfNewer,
            exists: exists(["a.txt"]),
            modified: { _ in nil }
        )
        #expect(plan == .skip)
    }

    // MARK: - Name generation

    @Test("free names count up past every taken one")
    func countsUp() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "a 3.txt"]
        #expect(
            ConflictResolver.freeURL(basedOn: url("a.txt"), exists: exists(taken))
                == url("a 4.txt")
        )
    }

    @Test("a name already carrying a counter continues it instead of stacking another")
    func continuesExistingCounter() {
        // Duplicating "report 2.txt" must give "report 3.txt", not "report 2 2.txt".
        #expect(
            ConflictResolver.freeURL(
                basedOn: url("report 2.txt"),
                exists: exists(["report 2.txt"])
            ) == url("report 3.txt")
        )
    }

    @Test("a trailing 1 or 0 is part of the name, not a counter")
    func lowNumbersAreNotCounters() {
        // Counters start at 2, so "part 1" is a real name and its duplicate is "part 1 2".
        #expect(
            ConflictResolver.freeURL(basedOn: url("part 1.txt"), exists: exists(["part 1.txt"]))
                == url("part 1 2.txt")
        )
    }

    @Test("extensionless names and dotfiles keep their shape")
    func namesWithoutExtensions() {
        #expect(
            ConflictResolver.freeURL(basedOn: url("Makefile"), exists: exists(["Makefile"]))
                == url("Makefile 2")
        )
        // ".gitignore" is a stem, not an extension, as far as URL is concerned.
        let dotfile = ConflictResolver.freeURL(
            basedOn: url(".gitignore"), exists: exists([".gitignore"]))
        #expect(dotfile.lastPathComponent.hasPrefix(".gitignore"))
        #expect(dotfile != url(".gitignore"))
    }

    @Test("multi-part extensions keep only the last segment as the extension")
    func compoundExtension() {
        // URL treats "tar.gz" as extension "gz", so the counter lands before it.
        #expect(
            ConflictResolver.freeURL(
                basedOn: url("archive.tar.gz"), exists: exists(["archive.tar.gz"])
            ) == url("archive.tar 2.gz")
        )
    }
}
