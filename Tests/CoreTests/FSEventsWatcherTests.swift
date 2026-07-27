import Foundation
import Testing

@testable import ShlCommander

/// Counts notifications from a watcher.
@MainActor
private final class ChangeCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@MainActor
@Suite("FSEventsWatcher", .serialized)
struct FSEventsWatcherTests {
    /// FSEvents has a coalescing latency plus the watcher's own debounce, so tests have to
    /// wait rather than assert immediately. Generous enough not to be flaky on a busy machine.
    private func waitForChange(
        _ counter: ChangeCounter,
        atLeast target: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if counter.count >= target { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return counter.count >= target
    }

    @Test("a new file in the watched directory triggers a change")
    func detectsCreation() async throws {
        let tree = try TempTree("watch-create")
        defer { tree.remove() }
        let counter = ChangeCounter()
        let watcher = FSEventsWatcher(watching: tree.root) { counter.bump() }
        #expect(watcher != nil)

        try tree.file("appeared.txt", bytes: 5)
        let seen = await waitForChange(counter, atLeast: 1)
        withExtendedLifetime(watcher) { #expect(seen) }
    }

    @Test("a deletion triggers a change")
    func detectsDeletion() async throws {
        let tree = try TempTree("watch-delete")
        defer { tree.remove() }
        let doomed = try tree.file("doomed.txt", bytes: 5)
        let counter = ChangeCounter()
        let watcher = FSEventsWatcher(watching: tree.root) { counter.bump() }

        try FileManager.default.removeItem(at: doomed)
        let seen = await waitForChange(counter, atLeast: 1)
        withExtendedLifetime(watcher) { #expect(seen) }
    }

    @Test("a burst of changes is coalesced instead of firing per file")
    func coalescesBursts() async throws {
        let tree = try TempTree("watch-burst")
        defer { tree.remove() }
        let counter = ChangeCounter()
        let watcher = FSEventsWatcher(watching: tree.root) { counter.bump() }

        for index in 0..<50 {
            try tree.file("file-\(index).txt", bytes: 16)
        }
        let seen = await waitForChange(counter, atLeast: 1)
        // Settle, then check the debounce kept the count far below the number of files.
        try? await Task.sleep(for: .milliseconds(600))
        withExtendedLifetime(watcher) {
            #expect(seen)
            #expect(counter.count < 10, Comment(rawValue: "50 files produced \(counter.count) reloads"))
        }
    }

    @Test("changes deep inside a subtree are ignored")
    func ignoresDeepChanges() async throws {
        let tree = try TempTree("watch-deep")
        defer { tree.remove() }
        try tree.directory("sub/deeper")
        let counter = ChangeCounter()
        let watcher = FSEventsWatcher(watching: tree.root) { counter.bump() }
        // Let the directory creation above settle so it is not mistaken for the change below.
        try? await Task.sleep(for: .milliseconds(600))
        let baseline = counter.count

        // FSEvents reports recursively; a panel showing tree.root displays nothing of this.
        try tree.file("sub/deeper/buried.txt", bytes: 5)
        try? await Task.sleep(for: .seconds(1))

        withExtendedLifetime(watcher) {
            #expect(counter.count == baseline, "a two-levels-down change caused a reload")
        }
    }

    @Test("a change in a sibling directory is ignored")
    func ignoresSiblings() async throws {
        let tree = try TempTree("watch-sibling")
        defer { tree.remove() }
        let watched = try tree.directory("watched")
        try tree.directory("sibling")
        let counter = ChangeCounter()
        let watcher = FSEventsWatcher(watching: watched) { counter.bump() }
        try? await Task.sleep(for: .milliseconds(600))
        let baseline = counter.count

        try tree.file("sibling/other.txt", bytes: 5)
        try? await Task.sleep(for: .seconds(1))

        withExtendedLifetime(watcher) { #expect(counter.count == baseline) }
    }

    @Test("a released watcher stops reporting")
    func stopsWhenReleased() async throws {
        let tree = try TempTree("watch-release")
        defer { tree.remove() }
        let counter = ChangeCounter()
        var watcher: FSEventsWatcher? = FSEventsWatcher(watching: tree.root) { counter.bump() }
        #expect(watcher != nil)

        watcher = nil  // deinit stops and releases the stream
        try tree.file("after.txt", bytes: 5)
        try? await Task.sleep(for: .seconds(1))

        #expect(counter.count == 0)
    }
}

@MainActor
@Suite("Panel live refresh", .serialized)
struct PanelLiveRefreshTests {
    @Test("a panel picks up a file created behind its back")
    func panelReloadsOnExternalChange() async throws {
        let tree = try TempTree("live-panel")
        defer { tree.remove() }
        try tree.file("existing.txt", bytes: 5)

        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()
        #expect(panel.entries.contains { $0.name == "appeared.txt" } == false)

        try tree.file("appeared.txt", bytes: 5)

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if panel.entries.contains(where: { $0.name == "appeared.txt" }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(panel.entries.contains { $0.name == "appeared.txt" })
    }

    @Test("a live reload keeps the cursor and the marks")
    func liveReloadPreservesState() async throws {
        let tree = try TempTree("live-state")
        defer { tree.remove() }
        try tree.file("aaa.txt", bytes: 5)
        try tree.file("bbb.txt", bytes: 5)

        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()

        let row = try #require(panel.entries.firstIndex { $0.name == "bbb.txt" })
        panel.cursor = row
        panel.toggleMarkAtCursor(advance: false)

        // "zzz" sorts last, so it does not shift bbb.txt's index.
        try tree.file("zzz.txt", bytes: 5)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if panel.entries.contains(where: { $0.name == "zzz.txt" }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(panel.entries.contains { $0.name == "zzz.txt" })
        #expect(panel.cursorEntry?.name == "bbb.txt", "the cursor stayed on its file")
        #expect(panel.markedEntries.map(\.name) == ["bbb.txt"], "the mark survived")
    }

    @Test("free space is reported for the panel's volume")
    func reportsFreeSpace() async throws {
        let tree = try TempTree("live-free")
        defer { tree.remove() }
        let panel = PanelViewModel(directory: tree.root)
        panel.navigate(to: tree.root)
        await panel.settle()

        let free = try #require(panel.freeSpace)
        #expect(free > 0)
    }
}

@MainActor
@Suite("VolumeService")
struct VolumeServiceTests {
    @Test("the boot volume is listed")
    func listsBootVolume() {
        let service = VolumeService()
        #expect(service.volumes.isEmpty == false)
        #expect(service.volumes.contains { $0.url.path == "/" })
    }

    @Test("the boot volume reports capacity and is not ejectable")
    func bootVolumeDetails() throws {
        let service = VolumeService()
        let root = try #require(service.volumes.first { $0.url.path == "/" })
        #expect(root.totalCapacity > 0)
        #expect(root.availableCapacity > 0)
        #expect(root.canEject == false, "the startup disk cannot be ejected")
    }

    @Test("a path resolves to the volume holding it")
    func resolvesContainingVolume() throws {
        let service = VolumeService()
        let volume = try #require(service.volume(containing: FileManager.default.temporaryDirectory))
        #expect(service.volumes.contains(volume))
    }
}
