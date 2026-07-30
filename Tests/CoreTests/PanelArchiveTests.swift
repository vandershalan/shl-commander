import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Browsing inside an archive")
struct PanelArchiveTests {
    /// A panel sitting on a folder that contains `test.zip` alongside a loose file.
    private func panel(_ fixture: ArchiveFixture) async throws -> (PanelViewModel, URL) {
        let archive = try fixture.makeZip()
        try fixture.tree.file("loose.txt", bytes: 3)
        let panel = PanelViewModel(directory: fixture.tree.root)
        panel.navigate(to: fixture.tree.root)
        await panel.settle()
        return (panel, archive)
    }

    private func cursor(_ panel: PanelViewModel, on name: String) throws {
        panel.cursor = try #require(panel.entries.firstIndex { $0.name == name })
    }

    @Test("an archive is a navigable row, a plain file is not")
    func archivesAreNavigable() async throws {
        let fixture = try ArchiveFixture("nav")
        defer { fixture.remove() }
        let (panel, _) = try await panel(fixture)

        let zip = try #require(panel.entries.first { $0.name == "test.zip" })
        #expect(zip.isBrowsableArchive)
        #expect(zip.isNavigable)

        let loose = try #require(panel.entries.first { $0.name == "loose.txt" })
        #expect(loose.isBrowsableArchive == false)
        #expect(loose.isNavigable == false)
    }

    @Test("Enter on an archive shows its contents")
    func entersArchive() async throws {
        let fixture = try ArchiveFixture("enter")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        try cursor(panel, on: "test.zip")
        panel.openCursor()
        await panel.settle()

        #expect(panel.isInsideArchive)
        #expect(panel.location.archiveURL?.canonicalPath == archive.canonicalPath)
        let names = Set(panel.entries.map(\.name))
        #expect(names.contains("readme.txt"))
        #expect(names.contains("deep"))
        #expect(names.contains(".."), "there is always a way back out")
    }

    @Test("navigating deeper inside the archive works like folders")
    func navigatesDeeper() async throws {
        let fixture = try ArchiveFixture("deeper")
        defer { fixture.remove() }
        let (panel, _) = try await panel(fixture)

        try cursor(panel, on: "test.zip")
        panel.openCursor()
        await panel.settle()

        try cursor(panel, on: "deep")
        panel.openCursor()
        await panel.settle()
        #expect(panel.location.archivePath == "deep")
        #expect(Set(panel.entries.map(\.name)) == ["..", "data.csv", "nested"])

        try cursor(panel, on: "nested")
        panel.openCursor()
        await panel.settle()
        #expect(panel.location.archivePath == "deep/nested")
        #expect(panel.entries.map(\.name) == ["..", "blob.bin"])
    }

    @Test("going up inside the archive climbs one level at a time")
    func goesUpInside() async throws {
        let fixture = try ArchiveFixture("upinside")
        defer { fixture.remove() }
        let (panel, _) = try await panel(fixture)

        panel.enterArchive(try fixture.makeZip(), path: "deep/nested")
        await panel.settle()

        panel.goUp()
        await panel.settle()
        #expect(panel.location.archivePath == "deep")
        #expect(panel.cursorEntry?.name == "nested", "the cursor lands on what was left")
    }

    @Test("going up from the archive root leaves the archive and selects it")
    func leavesArchive() async throws {
        let fixture = try ArchiveFixture("leave")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()
        #expect(panel.isInsideArchive)

        panel.goUp()
        await panel.settle()

        #expect(panel.isInsideArchive == false)
        #expect(panel.directory.canonicalPath == fixture.tree.root.canonicalPath)
        #expect(panel.cursorEntry?.name == "test.zip", "back on the archive it came from")
    }

    @Test("the parent row leaves the archive the same way")
    func parentRowLeaves() async throws {
        let fixture = try ArchiveFixture("parentrow")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()
        panel.cursor = 0
        panel.openCursor()
        await panel.settle()

        #expect(panel.isInsideArchive == false)
    }

    @Test("members carry their archive origin and a size from the listing")
    func memberMetadata() async throws {
        let fixture = try ArchiveFixture("meta")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()

        let readme = try #require(panel.entries.first { $0.name == "readme.txt" })
        #expect(readme.isArchiveMember)
        #expect(readme.archive?.member == "readme.txt")
        #expect(readme.archive?.archive.canonicalPath == archive.canonicalPath)
        #expect(readme.size == 16)
        #expect(readme.ext == "txt")
    }

    @Test("a folder inside an archive already shows its recursive size")
    func directorySizesAreKnown() async throws {
        let fixture = try ArchiveFixture("sizes")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()

        let deep = try #require(panel.entries.first { $0.name == "deep" })
        // data.csv (6) + nested/blob.bin (8); nothing had to be measured.
        #expect(deep.size == 14)
        #expect(
            Formatters.sizeColumn(for: deep, directorySize: nil, measuring: false) != "<DIR>",
            "the column shows the number rather than a placeholder"
        )
    }

    @Test("the path bar reads as one path continuing into the archive")
    func displayPath() async throws {
        let fixture = try ArchiveFixture("display")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive, path: "deep")
        await panel.settle()
        #expect(panel.displayPath == archive.canonicalPath + "/deep")
        // Somewhere real is still available for the commands that need it.
        #expect(panel.directory.canonicalPath == fixture.tree.root.canonicalPath)
    }

    @Test("history walks in and out of the archive")
    func history() async throws {
        let fixture = try ArchiveFixture("history")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()
        #expect(panel.canGoBack)

        panel.historyBack()
        await panel.settle()
        #expect(panel.isInsideArchive == false)

        panel.historyForward()
        await panel.settle()
        #expect(panel.isInsideArchive)
    }

    @Test("a tab remembers that it was inside an archive, across a save and load")
    func tabsRoundTrip() async throws {
        let fixture = try ArchiveFixture("tabs")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive, path: "deep")
        await panel.settle()
        panel.captureActiveTab()

        let tab = panel.tabs[panel.activeTabIndex]
        #expect(tab.archivePath == "deep")
        #expect(tab.title == "deep")

        let encoded = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(PanelTab.self, from: encoded)
        #expect(decoded.location.isSamePlace(as: panel.location))
    }

    @Test("a tab saved before archive support still loads, as an ordinary folder")
    func oldTabsStillDecode() throws {
        // No "archivePath" key at all, which is what older sessions look like.
        let json = Data(
            #"{"id":"7E1B0F5E-0000-4000-8000-000000000001","path":"/tmp","sort":{"key":"name","ascending":true,"directoriesFirst":true}}"#
                .utf8
        )
        let tab = try JSONDecoder().decode(PanelTab.self, from: json)
        #expect(tab.archivePath == nil)
        #expect(tab.location == .directory(URL(fileURLWithPath: "/tmp")))
    }

    @Test("filtering and marking work on members like any other row")
    func filterAndMark() async throws {
        let fixture = try ArchiveFixture("filtermark")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()

        panel.setFilter("read")
        #expect(panel.entries.map(\.name) == ["..", "readme.txt"])

        panel.cursor = 1
        panel.toggleMarkAtCursor(advance: false)
        #expect(panel.markedEntries.map(\.name) == ["readme.txt"])
        #expect(panel.actionTargets.map(\.name) == ["readme.txt"])
    }

    @Test("writes inside an archive are refused rather than half-done")
    func writesRefused() async throws {
        let fixture = try ArchiveFixture("readonly")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()

        let row = try #require(panel.entries.firstIndex { $0.name == "readme.txt" })
        let message = panel.commitRename(at: row, to: "other.txt")
        #expect(message == PanelViewModel.readOnlyArchiveMessage)
        // The archive is untouched.
        let index = try await ArchiveStore.shared.index(for: archive)
        #expect(index.member(at: "readme.txt") != nil)
    }

    @Test("measuring skips members, which have nothing on disk to walk")
    func measuringSkipsMembers() async throws {
        let fixture = try ArchiveFixture("measure")
        defer { fixture.remove() }
        let (panel, archive) = try await panel(fixture)

        panel.enterArchive(archive)
        await panel.settle()
        panel.measureAllDirectories()

        #expect(panel.sizer.pendingCount == 0)
    }

    @Test("a corrupt archive reports an error instead of showing an empty folder")
    func corruptArchiveReportsError() async throws {
        let tree = try TempTree("archive-panel-corrupt")
        defer { tree.remove() }
        let fake = tree.root.appendingPathComponent("broken.zip")
        try Data("nonsense".utf8).write(to: fake)

        let panel = PanelViewModel(directory: tree.root)
        panel.enterArchive(fake)
        await panel.settle()

        #expect(panel.loadError != nil)
        #expect(panel.entries.count <= 1, "only the way back out")
    }
}

@MainActor
@Suite("ArchiveStore")
struct ArchiveStoreTests {
    @Test("a listing is reused until the archive itself changes")
    func cachesUntilChanged() async throws {
        let fixture = try ArchiveFixture("store-cache")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()

        let first = try await ArchiveStore.shared.index(for: archive)
        let second = try await ArchiveStore.shared.index(for: archive)
        #expect(first.members.count == second.members.count)

        // Rebuild the archive with different contents; the stamp changes, so must the listing.
        try FileManager.default.removeItem(at: archive)
        try fixture.tree.file("payload/added.txt", bytes: 2)
        let rebuilt = try fixture.makeZip()
        let third = try await ArchiveStore.shared.index(for: rebuilt)
        #expect(third.member(at: "added.txt") != nil)
    }

    @Test("a member is extracted once and reused")
    func materialisesMembers() async throws {
        let fixture = try ArchiveFixture("store-materialise")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()

        let first = try await ArchiveStore.shared.materialise(
            member: "deep/data.csv", from: archive)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try Data(contentsOf: first).count == 6)

        let second = try await ArchiveStore.shared.materialise(
            member: "deep/data.csv", from: archive)
        #expect(second == first, "the same scratch copy answers again")
    }

    @Test("scratch copies live under one removable directory")
    func scratchIsContained() async throws {
        let fixture = try ArchiveFixture("store-scratch")
        defer { fixture.remove() }
        let archive = try fixture.makeZip()

        let url = try await ArchiveStore.shared.materialise(member: "readme.txt", from: archive)
        #expect(url.path.hasPrefix(ArchiveStore.root.path))
    }
}
