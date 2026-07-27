import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("DirectorySizer")
struct DirectorySizerTests {
    /// Waits for a condition the sizer satisfies asynchronously.
    private func wait(
        for condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func entry(for url: URL) throws -> FileEntry {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        return FileEntry(
            url: url,
            name: url.lastPathComponent,
            baseName: url.lastPathComponent,
            ext: "",
            isDirectory: values.isDirectory ?? false,
            isSymlink: false,
            isHidden: false,
            isPackage: false,
            size: 0,
            modified: values.contentModificationDate ?? .distantPast,
            isParent: false
        )
    }

    @Test("measures a tree and reports the total")
    func measuresTree() async throws {
        let tree = try TempTree("sizer-measure")
        defer { tree.remove() }
        try tree.file("sub/a.bin", bytes: 4_000)
        try tree.file("sub/deep/b.bin", bytes: 6_000)
        let sub = try entry(for: tree.root.appendingPathComponent("sub"))

        let sizer = DirectorySizer()
        #expect(sizer.size(of: sub) == nil)
        sizer.request([sub])
        #expect(sizer.isPending(sub), "the Size cell can show progress right away")

        #expect(await wait(for: { sizer.size(of: sub) != nil }))
        let measured = try #require(sizer.size(of: sub))
        #expect(measured >= 10_000, "allocated size meets or exceeds logical size")
        #expect(sizer.isPending(sub) == false)
        #expect(sizer.pendingCount == 0)
    }

    @Test("onUpdate fires when work is queued and again when it lands")
    func reportsUpdates() async throws {
        let tree = try TempTree("sizer-updates")
        defer { tree.remove() }
        try tree.file("sub/a.bin", bytes: 100)
        let sub = try entry(for: tree.root.appendingPathComponent("sub"))

        let sizer = DirectorySizer()
        var updates = 0
        sizer.onUpdate = { updates += 1 }

        sizer.request([sub])
        #expect(updates >= 1, "queuing alone repaints the column")
        #expect(await wait(for: { sizer.size(of: sub) != nil }))
        #expect(updates >= 2)
    }

    @Test("a second request for a known size does no work")
    func cachesResults() async throws {
        let tree = try TempTree("sizer-cache")
        defer { tree.remove() }
        try tree.file("sub/a.bin", bytes: 500)
        let sub = try entry(for: tree.root.appendingPathComponent("sub"))

        let sizer = DirectorySizer()
        sizer.request([sub])
        #expect(await wait(for: { sizer.size(of: sub) != nil }))

        sizer.request([sub])
        #expect(sizer.pendingCount == 0, "nothing was queued a second time")
    }

    @Test("a size measured before the folder changed is not reused")
    func staleSizeIsNotReused() async throws {
        let tree = try TempTree("sizer-stale")
        defer { tree.remove() }
        let sub = try tree.directory("sub")
        try tree.file("sub/a.bin", bytes: 500)
        let before = try entry(for: sub)

        let sizer = DirectorySizer()
        sizer.request([before])
        #expect(await wait(for: { sizer.size(of: before) != nil }))

        // Touch the folder so its timestamp moves on.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sub.path)
        let after = try entry(for: sub)

        #expect(sizer.size(of: after) == nil, "a changed folder needs measuring again")
    }

    @Test("prune drops sizes for folders whose timestamp moved")
    func pruneDropsStale() async throws {
        let tree = try TempTree("sizer-prune")
        defer { tree.remove() }
        let sub = try tree.directory("sub")
        try tree.file("sub/a.bin", bytes: 500)
        let before = try entry(for: sub)

        let sizer = DirectorySizer()
        sizer.request([before])
        #expect(await wait(for: { sizer.sizes[sub] != nil }))

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: sub.path)
        sizer.prune(against: [try entry(for: sub)])

        #expect(sizer.sizes[sub] == nil, "the table is never handed a stale number")
    }

    @Test("files and the parent row are never measured")
    func ignoresNonDirectories() async throws {
        let tree = try TempTree("sizer-files")
        defer { tree.remove() }
        let file = try tree.file("plain.bin", bytes: 10)

        let sizer = DirectorySizer()
        sizer.request([try entry(for: file), .parent(tree.root)])
        #expect(sizer.pendingCount == 0)
    }

    @Test("cancelling clears the queue")
    func cancelClearsQueue() async throws {
        let tree = try TempTree("sizer-cancel")
        defer { tree.remove() }
        var entries: [FileEntry] = []
        for index in 0..<20 {
            let sub = try tree.directory("sub-\(index)")
            try tree.file("sub-\(index)/a.bin", bytes: 100)
            entries.append(try entry(for: sub))
        }

        let sizer = DirectorySizer()
        sizer.request(entries)
        sizer.cancelAll()
        #expect(sizer.pendingCount == 0)
    }

    @Test("many folders are measured a few at a time, not all at once")
    func limitsConcurrency() async throws {
        let tree = try TempTree("sizer-concurrency")
        defer { tree.remove() }
        var entries: [FileEntry] = []
        for index in 0..<12 {
            let sub = try tree.directory("sub-\(index)")
            try tree.file("sub-\(index)/a.bin", bytes: 100)
            entries.append(try entry(for: sub))
        }

        let sizer = DirectorySizer()
        sizer.request(entries)
        #expect(sizer.pendingCount == 12, "every folder is accounted for")

        #expect(
            await wait(
                for: { entries.allSatisfy { sizer.size(of: $0) != nil } },
                timeout: .seconds(10)
            )
        )
        #expect(sizer.pendingCount == 0)
    }
}

@MainActor
@Suite("Panel directory sizes")
struct PanelDirectorySizeTests {
    private func wait(
        for condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func panel(in tree: TempTree) async throws -> PanelViewModel {
        try tree.file("small/a.bin", bytes: 1_000)
        try tree.file("big/b.bin", bytes: 900_000)
        try tree.file("loose.bin", bytes: 50)
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        return panel
    }

    @Test("measuring all folders fills every folder's size")
    func measureAll() async throws {
        let tree = try TempTree("panel-sizeall")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.measureAllDirectories()
        #expect(await wait(for: { panel.sizer.sizes.count == 2 }))

        let folders = panel.entries.filter { $0.isDirectory && !$0.isParent }
        #expect(folders.allSatisfy { panel.sizer.size(of: $0) != nil })
    }

    @Test("measuring the selection only touches the marked folders")
    func measureSelected() async throws {
        let tree = try TempTree("panel-sizesel")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        let row = try #require(panel.entries.firstIndex { $0.name == "big" })
        panel.cursor = row
        panel.toggleMarkAtCursor(advance: false)
        panel.measureSelectedDirectories()

        #expect(await wait(for: { panel.sizer.sizes.count == 1 }))
        let small = try #require(panel.entries.first { $0.name == "small" })
        #expect(panel.sizer.size(of: small) == nil, "the unmarked folder was left alone")
    }

    @Test("sorting by size orders measured folders and leaves unmeasured ones grouped")
    func sortBySizeUsesMeasurements() async throws {
        let tree = try TempTree("panel-sizesort")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.sort = SortOrder(key: .size, ascending: false)
        panel.measureAllDirectories()
        #expect(await wait(for: { panel.sizer.sizes.count == 2 }))
        // The re-sort happens on the sizer's callback.
        #expect(
            await wait(for: {
                let folders = panel.entries.filter { $0.isDirectory && !$0.isParent }
                return folders.map(\.name) == ["big", "small"]
            })
        )
    }

    @Test("an unmeasured folder does not masquerade as empty when sorting by size")
    func unmeasuredFoldersGroupTogether() async throws {
        let tree = try TempTree("panel-unmeasured")
        defer { tree.remove() }
        let panel = try await panel(in: tree)

        panel.sort = SortOrder(key: .size, ascending: true, directoriesFirst: false)
        // Nothing measured yet: the folders sort as "no size", ahead of a 50-byte file,
        // rather than tying with it at zero.
        let names = panel.entries.filter { !$0.isParent }.map(\.name)
        #expect(names.prefix(2).allSatisfy { $0 == "big" || $0 == "small" })
        #expect(names.last == "loose.bin")
    }
}
