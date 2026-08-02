import AppKit
import Darwin
import Foundation
import Observation

/// Outcome of an off-main directory read. Carries the message rather than the `Error`
/// because `any Error` is not `Sendable`.
enum ListingOutcome: Sendable {
    case listed([FileEntry])
    case failed(String)
}

/// Where the cursor should land after a move.
enum CursorMove: Sendable {
    case up, down, top, bottom
    case pageUp(rows: Int), pageDown(rows: Int)
}

/// State of one pane: where it is, what it lists, where the cursor sits, what is marked.
///
/// The cursor is deliberately separate from marks: Total Commander moves the cursor with
/// the arrows while `Space` and `Insert` mark rows independently of it.
@MainActor
@Observable
final class PanelViewModel: Identifiable {
    let id = UUID()

    /// Where the pane is looking: a directory on disk, or a path inside an archive.
    private(set) var location: PanelLocation

    /// The real directory the pane sits in or under. Inside an archive this is the folder
    /// holding the archive file, which is what commands needing somewhere real should use.
    var directory: URL { location.containingDirectory }

    var isInsideArchive: Bool { location.isInsideArchive }
    var displayPath: String { location.displayPath }

    /// Everything the location holds, sorted, including the `..` row.
    private(set) var allEntries: [FileEntry] = []
    /// What the table shows — `allEntries` minus anything the quick filter excludes.
    private(set) var entries: [FileEntry] = []
    /// Bumped whenever `entries` is replaced. The table reloads only on a change here, so
    /// cursor moves and mark toggles never trigger a full reload.
    private(set) var listingID = UUID()
    private(set) var loadError: String?
    private(set) var isLoading = false
    /// Free space on the volume the panel is on, refreshed with each listing.
    private(set) var freeSpace: Int64?

    /// What the open archive turned out to be, and whether its name said otherwise. Shown as the
    /// tooltip on the archive marker, because a file whose name lies is worth saying out loud —
    /// it explains why a `.zip` holds a single row.
    private(set) var archiveNote: String?

    /// Marked rows, held by URL so they survive a reload of the same directory.
    private(set) var marks: Set<URL> = []

    var sort: SortOrder = SortOrder() {
        didSet {
            guard sort != oldValue else { return }
            resort()
        }
    }

    var showHidden: Bool = false {
        didSet {
            guard showHidden != oldValue else { return }
            load(holdingCursor())
        }
    }

    /// Case-insensitive substring match on the name. The `..` row is never filtered out,
    /// so there is always a way back.
    private(set) var filter: String = "" {
        didSet {
            guard filter != oldValue else { return }
            // Typing follows the cursor down to the first match, so narrowing to a single row
            // leaves Return one keystroke from opening it. An emptied filter is not a request
            // to move anywhere, so the cursor stays on whatever it had reached.
            rebuildVisible(filter.isEmpty ? holdingCursor() : .firstMatch)
        }
    }

    /// True from the first typed character until Escape or a directory change.
    ///
    /// Tracked separately from `filter` being non-empty so that backspacing the last character
    /// does not silently hand the next Backspace to "go up": deleting your way back to an empty
    /// filter should leave you in the directory, not one level above it.
    private(set) var isFiltering = false

    func appendToFilter(_ character: Character) {
        isFiltering = true
        filter.append(character)
    }

    /// Backspace inside the filter. A no-op once the filter is empty, which is the point.
    func deleteFilterCharacter() {
        guard isFiltering, !filter.isEmpty else { return }
        filter.removeLast()
    }

    /// Sets the whole filter text at once, as though it had been typed. Non-empty text opens a
    /// session; use `stopFiltering()` to close one.
    func setFilter(_ text: String) {
        if !text.isEmpty { isFiltering = true }
        filter = text
    }

    /// Ends the filter session and shows everything again.
    func stopFiltering() {
        isFiltering = false
        filter = ""
    }

    /// Index into `entries`, clamped so it can never dangle past the end.
    ///
    /// Clamping happens in the setter, not in a `didSet`: `@Observable` turns stored
    /// properties into computed ones, so assigning to `cursor` inside its own `didSet`
    /// re-enters the setter and recurses until the stack overflows.
    var cursor: Int {
        get { cursorStorage }
        set { cursorStorage = min(max(0, newValue), max(0, entries.count - 1)) }
    }

    private var cursorStorage: Int = 0
    private var loadTask: Task<Void, Never>?
    /// Work that happens before a location changes: checking an archive can be read, or pulling
    /// a member out so something can open it. Tracked so `settle()` still means "finished
    /// reacting" now that opening is no longer immediate.
    private var openTask: Task<Void, Never>?

    private static let historyLimit = 100
    private var backStack: [PanelLocation] = []
    private var forwardStack: [PanelLocation] = []

    /// Recreated on every directory change; nil when the OS refused a stream.
    private var watcher: FSEventsWatcher?

    /// Measured directory sizes for this pane. Per-pane rather than shared: the panes usually
    /// show different directories, and a shared instance would need to fan updates out to both.
    let sizer = DirectorySizer()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // Standardised on the way in so `enter` never sees two spellings of one directory.
        // Symlinks are deliberately left unresolved: the panel shows the path the user asked
        // for, not wherever it happens to point.
        self.location = .directory(directory.standardizedFileURL)
        self.tabs = [PanelTab(location: .directory(directory.standardizedFileURL))]
        sizer.onUpdate = { [weak self] in self?.directorySizesChanged() }
    }

    /// Sizes arriving change what the Size column shows, and can change the order when sorting
    /// by size.
    private func directorySizesChanged() {
        if sort.key == .size {
            resort()
        } else {
            listingID = UUID()
        }
    }

    /// Shown wherever a write is attempted inside an archive.
    static let readOnlyArchiveMessage = "Archives are read-only. Copy the files out first."

    /// Measures the marked directories, or the cursor directory when nothing is marked.
    ///
    /// Archive members are skipped: their sizes already came from the archive's table of
    /// contents, and there is no tree on disk to walk.
    func measureSelectedDirectories() {
        sizer.request(actionTargets.filter { $0.isDirectory && !$0.isArchiveMember })
    }

    /// Measures every directory in the pane.
    func measureAllDirectories() {
        sizer.request(entries.filter { !$0.isArchiveMember })
    }

    /// Directories currently being measured, so their Size cell can show progress.
    var measuringDirectories: Set<URL> { sizer.pendingURLs }

    var cursorEntry: FileEntry? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }

    // MARK: - Tallies

    var fileCount: Int { entries.count(where: { !$0.isDirectory }) }
    var directoryCount: Int { entries.count(where: { $0.isDirectory && !$0.isParent }) }
    var totalBytes: Int64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }

    /// Marked rows in display order. Restricted to what is currently visible so a filtered
    /// panel never acts on rows the user cannot see.
    var markedEntries: [FileEntry] { entries.filter { marks.contains($0.url) } }
    var markedCount: Int { markedEntries.count }
    var markedBytes: Int64 {
        markedEntries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) }
    }

    /// What a command should act on: the marked rows, or the cursor row when nothing is
    /// marked. This is how every Total Commander file operation picks its targets.
    var actionTargets: [FileEntry] {
        let marked = markedEntries
        if !marked.isEmpty { return marked }
        guard let entry = cursorEntry, !entry.isParent else { return [] }
        return [entry]
    }

    func isMarked(_ entry: FileEntry) -> Bool { marks.contains(entry.url) }

    // MARK: - Drag and drop

    /// What a drag beginning on `row` should carry.
    ///
    /// Dragging a marked row takes every marked row with it, which is the same rule the file
    /// commands use; dragging an unmarked one takes only that row, so a drag never picks up
    /// marks the user had forgotten about somewhere off screen.
    ///
    /// Empty for rows that are not files on disk: "..", and anything inside an archive, which
    /// has no path a receiving app could open.
    func dragSources(at row: Int) -> [URL] {
        guard entries.indices.contains(row) else { return [] }
        let entry = entries[row]
        guard !entry.isParent, !entry.isArchiveMember else { return [] }
        guard marks.contains(entry.url) else { return [entry.url] }
        return markedEntries.filter { !$0.isParent && !$0.isArchiveMember }.map(\.url)
    }

    /// Where a drop over `row` should land: that row's folder, or the pane's own directory when
    /// the drop was over a file or over empty space. Nil when this pane cannot take a drop.
    ///
    /// ".." is a destination like any other — dropping onto it moves a file up a level, which
    /// is how the Finder's own list view behaves.
    func dropDestination(row: Int?) -> URL? {
        guard !isInsideArchive else { return nil }
        guard let row, entries.indices.contains(row) else { return directory }
        let entry = entries[row]
        guard entry.isDirectory, !entry.isArchiveMember else { return directory }
        return entry.url
    }

    // MARK: - Navigation

    /// Enters `url`. The cursor lands on `selecting` when given, otherwise on the first row.
    func navigate(to url: URL, selecting: String? = nil) {
        go(to: .directory(url.standardizedFileURL), selecting: selecting, recordHistory: true)
    }

    /// Jumps to the root of the volume the panel is currently on, which for the boot volume
    /// is `/` and for an external disk is its mount point.
    func goToVolumeRoot() {
        let volume = try? directory.resourceValues(forKeys: [.volumeURLKey]).volume
        navigate(to: volume ?? URL(fileURLWithPath: "/"))
    }

    /// Reported when an archive cannot be opened, so the failure is not left to a footer line
    /// that is easy to miss.
    var onOpenFailure: ((URL, String) -> Void)?

    /// Opens an archive only if it can actually be read.
    ///
    /// The listing is fetched before the pane moves. Navigating first and failing afterwards
    /// left the pane apparently inside a file, showing nothing but the way back out, which reads
    /// as an empty archive rather than an unreadable one.
    func openArchive(_ archive: URL) {
        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ArchiveStore.shared.index(for: archive)
                guard !Task.isCancelled else { return }
                self.enterArchive(archive)
            } catch {
                guard !Task.isCancelled else { return }
                self.onOpenFailure?(archive, error.localizedDescription)
            }
            self.openTask = nil
        }
    }

    /// Opens an archive and shows its root, as though it were a folder.
    ///
    /// The archive's URL is canonicalised on the way in, so the same file reached by different
    /// spellings of its path is one location and shares one cached listing.
    func enterArchive(_ archive: URL, path: String = "") {
        go(
            to: .archive(archive: archive.canonicalFileURL, path: path),
            selecting: nil,
            recordHistory: true
        )
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func historyBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        go(to: previous, selecting: nil, recordHistory: false)
    }

    func historyForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        go(to: next, selecting: nil, recordHistory: false)
    }

    /// Single funnel for every directory change, so history and filter reset behave the same
    /// no matter which command triggered the move.
    private func go(to target: PanelLocation, selecting: String?, recordHistory: Bool) {
        // Compared through `isSamePlace`, not by URL: `standardizedFileURL` marks an existing
        // directory with a trailing slash, so two URLs for the same folder compare unequal and
        // every "reload where I already am" would push a bogus history entry and wipe the
        // forward stack.
        if recordHistory, !target.isSamePlace(as: location) {
            backStack.append(location)
            forwardStack.removeAll()
            if backStack.count > Self.historyLimit { backStack.removeFirst() }
        }
        location = target
        // A change of location ends the filter session outright: the text no longer describes
        // anything on screen.
        isFiltering = false
        filter = ""
        // Keeps the tab strip's label in step with where the panel actually is.
        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].setLocation(target)
        }
        startWatching()
        load(.named(selecting))
    }

    /// A watcher is bound to one path, so it is replaced whenever the panel moves.
    private func startWatching() {
        // Inside an archive this watches the folder holding it, so rebuilding the archive
        // shows up as a reload rather than a stale listing.
        watcher = FSEventsWatcher(watching: directory) { [weak self] in
            // Cursor position and marks survive because reload keys them by name and URL.
            self?.reload()
        }
    }

    /// Re-reads the current directory. Holds the cursor on the same name by default, or moves
    /// it to `selecting` — used to land on a folder or file just created.
    func reload(selecting: String? = nil) {
        // Without an explicit target this is a refresh, not a move, so the cursor holds its
        // place — that is what keeps it put after a copy, move, or delete.
        load(selecting.map(CursorTarget.named) ?? holdingCursor())
    }

    /// Opens the row under the cursor: directories and archives are entered, files are handed
    /// to the system, which launches whatever is registered for them.
    ///
    /// A file inside an archive has to be pulled out to a scratch copy before anything can open
    /// it, and that copy is read-only in effect: edits are never written back.
    func openCursor() {
        guard let entry = cursorEntry else { return }

        if entry.isParent {
            goUp()
            return
        }

        if let origin = entry.archive {
            openArchiveMember(entry, origin: origin)
            return
        }

        if entry.isDirectory {
            navigate(to: entry.url)
        } else if entry.isBrowsableArchive {
            openArchive(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    /// Handles a row that lives inside an archive.
    private func openArchiveMember(_ entry: FileEntry, origin: ArchiveOrigin) {
        if entry.isDirectory {
            go(
                to: .archive(archive: origin.archive, path: origin.member),
                selecting: nil,
                recordHistory: true
            )
            return
        }

        openTask?.cancel()
        openTask = Task { [weak self] in
            guard let self else { return }
            defer { self.openTask = nil }
            do {
                let extracted = try await ArchiveStore.shared.materialise(
                    member: origin.member, from: origin.archive)
                // A nested archive opens as an archive rather than being handed to the system,
                // so browsing keeps working all the way down.
                if entry.isBrowsableArchive {
                    self.openArchive(extracted)
                } else {
                    NSWorkspace.shared.open(extracted)
                }
            } catch {
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Ascends one level, parking the cursor on whatever was just left. At an archive's root
    /// that means stepping out of the archive and onto the archive file itself.
    func goUp() {
        guard let up = location.parent else { return }
        go(to: up, selecting: location.nameWithinParent, recordHistory: true)
    }

    func move(_ move: CursorMove) {
        switch move {
        case .up: cursor -= 1
        case .down: cursor += 1
        case .top: cursor = 0
        case .bottom: cursor = entries.count - 1
        case .pageUp(let rows): cursor -= max(1, rows)
        case .pageDown(let rows): cursor += max(1, rows)
        }
    }

    // MARK: - Tabs

    /// Always at least one. The active tab mirrors whatever the panel is currently showing.
    private(set) var tabs: [PanelTab] = []
    private(set) var activeTabIndex = 0

    var hasMultipleTabs: Bool { tabs.count > 1 }

    /// Folds the panel's live state back into the active tab. Called before anything that
    /// switches away, and before the session is written out.
    func captureActiveTab() {
        guard tabs.indices.contains(activeTabIndex) else {
            tabs = [PanelTab(location: location, sort: sort, cursorName: cursorEntry?.name)]
            activeTabIndex = 0
            return
        }
        tabs[activeTabIndex].setLocation(location)
        tabs[activeTabIndex].sort = sort
        tabs[activeTabIndex].cursorName = cursorEntry?.name
    }

    func openTab(at url: URL? = nil, activate: Bool = true) {
        captureActiveTab()
        let tab = PanelTab(
            location: url.map { PanelLocation.directory($0.standardizedFileURL) } ?? location,
            sort: sort
        )
        tabs.insert(tab, at: activeTabIndex + 1)
        if activate {
            activeTabIndex += 1
            show(tabs[activeTabIndex])
        }
    }

    /// Closing the last tab is refused: a pane always shows something.
    func closeActiveTab() {
        guard tabs.count > 1, tabs.indices.contains(activeTabIndex) else { return }
        tabs.remove(at: activeTabIndex)
        activeTabIndex = min(activeTabIndex, tabs.count - 1)
        show(tabs[activeTabIndex])
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        captureActiveTab()
        activeTabIndex = index
        show(tabs[index])
    }

    func nextTab() {
        guard tabs.count > 1 else { return }
        selectTab((activeTabIndex + 1) % tabs.count)
    }

    func previousTab() {
        guard tabs.count > 1 else { return }
        selectTab((activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    /// Replaces the panel's contents with a tab's snapshot. Deliberately does not touch
    /// history: switching tabs is not navigation within a tab.
    private func show(_ tab: PanelTab) {
        sort = tab.sort
        go(to: tab.location, selecting: tab.cursorName, recordHistory: false)
    }

    /// Restores a saved pane, falling back to the current directory if nothing usable is left.
    func restore(tabs saved: [PanelTab], activeIndex: Int) {
        let usable = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !usable.isEmpty else {
            tabs = [PanelTab(location: location, sort: sort)]
            activeTabIndex = 0
            return
        }
        tabs = usable
        activeTabIndex = min(max(0, activeIndex), usable.count - 1)
        show(tabs[activeTabIndex])
    }

    // MARK: - Renaming

    /// Bumped to ask the table to open its in-place editor on the cursor row. A counter
    /// rather than a flag, so consecutive requests are distinguishable.
    private(set) var renameRequestID: Int = 0

    func requestRename() {
        guard let entry = cursorEntry, !entry.isParent else { return }
        renameRequestID += 1
    }

    /// Commits an edited name. Returns an error message, or nil on success or a no-op.
    func commitRename(at index: Int, to newName: String) -> String? {
        guard entries.indices.contains(index) else { return nil }
        let entry = entries[index]
        guard !entry.isParent else { return nil }
        guard !entry.isArchiveMember else { return Self.readOnlyArchiveMessage }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return nil }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            return "A name cannot contain / or :"
        }

        let target = directory.appendingPathComponent(trimmed)
        // A case-only change collides with itself on a case-insensitive volume, so it is
        // allowed through: "readme" to "README" is a rename, not a conflict.
        let isCaseOnlyChange = trimmed.lowercased() == entry.name.lowercased()
        if !isCaseOnlyChange, FileManager.default.fileExists(atPath: target.path) {
            return "\u{22}\(trimmed)\u{22} already exists."
        }

        do {
            try FileManager.default.moveItem(at: entry.url, to: target)
            reload(selecting: trimmed)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Marking

    /// Toggles the cursor row. `advance` matches `Insert`, which steps down afterwards so a
    /// run of files can be marked by holding the key.
    func toggleMarkAtCursor(advance: Bool) {
        if let entry = cursorEntry, !entry.isParent {
            toggleMark(entry)
        }
        if advance { cursor += 1 }
    }

    func toggleMark(_ entry: FileEntry) {
        guard !entry.isParent else { return }
        if marks.contains(entry.url) {
            marks.remove(entry.url)
        } else {
            marks.insert(entry.url)
        }
    }

    func markAll() {
        marks = Set(entries.filter { !$0.isParent }.map(\.url))
    }

    func clearMarks() {
        marks = []
    }

    func invertMarks() {
        let all = Set(entries.filter { !$0.isParent }.map(\.url))
        marks = all.subtracting(marks)
    }

    /// Marks or unmarks by shell glob (`*.txt`, `report?.pdf`), the way Total Commander's
    /// `Num +` / `Num -` do. Uses `fnmatch` so the wildcard semantics are the real ones.
    func mark(matching pattern: String, marked: Bool) {
        guard !pattern.isEmpty else { return }
        for entry in entries where !entry.isParent {
            guard entry.name.withCString({ name in
                pattern.withCString { glob in
                    fnmatch(glob, name, FNM_CASEFOLD) == 0
                }
            }) else { continue }
            if marked {
                marks.insert(entry.url)
            } else {
                marks.remove(entry.url)
            }
        }
    }

    // MARK: - Loading

    /// Awaits whatever the panel is currently doing. Exists so tests can act on a settled panel
    /// instead of polling; the app itself never needs to block.
    ///
    /// Both an open and a listing have to be awaited, and in that order: opening an archive
    /// checks it can be read *before* moving, and only then schedules the listing. Bounded, so a
    /// panel that somehow keeps rescheduling cannot hang a test forever.
    func settle() async {
        for _ in 0..<10 {
            await openTask?.value
            await loadTask?.value
            if openTask == nil, loadTask == nil { return }
        }
    }

    private func load(_ cursorTarget: CursorTarget) {
        let target = location
        let includeHidden = showHidden

        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let outcome: ListingOutcome
            switch target {
            case .directory(let url):
                outcome = await Self.read(url, includeHidden: includeHidden)
            case .archive(let archive, let path):
                outcome = await Self.readArchive(archive, path: path)
            }
            guard let self, !Task.isCancelled else { return }
            // A newer navigation may have landed while this listing was in flight.
            guard self.location.isSamePlace(as: target) else { return }
            self.apply(outcome, cursorTarget)
            self.loadTask = nil
        }
    }

    /// `nonisolated async` so it runs on the cooperative pool instead of the main actor.
    private nonisolated static func read(_ url: URL, includeHidden: Bool) async -> ListingOutcome {
        do {
            return .listed(try DirectoryLister.list(url, includeHidden: includeHidden))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Lists one level inside an archive. Sizes come straight from the archive's own table of
    /// contents, including recursive totals for directories, so nothing has to be measured.
    private static func readArchive(_ archive: URL, path: String) async -> ListingOutcome {
        do {
            let index = try await ArchiveStore.shared.index(for: archive)
            await MainActor.run {
                ArchiveNote.latest = ArchiveNote.describe(index: index, archive: archive)
            }
            let rows = index.children(of: path).map { member in
                FileEntry(
                    member: member,
                    in: archive,
                    directorySize: member.isDirectory ? index.size(ofDirectory: member.path) : 0
                )
            }
            return .listed(rows)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func apply(_ outcome: ListingOutcome, _ target: CursorTarget) {
        isLoading = false
        freeSpace = (try? location.containingDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]))
            .flatMap(\.volumeAvailableCapacity).map(Int64.init)
        switch outcome {
        case .listed(let children):
            archiveNote = location.isInsideArchive ? ArchiveNote.latest : nil
            var rows = sort.sorted(children, directorySizes: sizer.sizes)
            switch location {
            case .directory:
                if let up = DirectoryLister.parent(of: directory) {
                    rows.insert(.parent(up), at: 0)
                }
            case .archive(let archive, let path):
                // Always present inside an archive: at its root the row is the way back out.
                rows.insert(.archiveParent(archive: archive, path: path), at: 0)
            }
            allEntries = rows
            loadError = nil
            // Fresh timestamps are in hand, so any size measured before a change goes away.
            sizer.prune(against: rows)
            // Drop marks for anything that no longer exists.
            marks.formIntersection(Set(rows.map(\.url)))
            rebuildVisible(target)
        case .failed(let message):
            allEntries = []
            marks = []
            loadError = message
            rebuildVisible(target)
        }
    }

    private func resort() {
        let target = holdingCursor()
        let parentRow = allEntries.first(where: \.isParent)
        var rows = sort.sorted(
            allEntries.filter { !$0.isParent },
            directorySizes: sizer.sizes
        )
        if let parentRow { rows.insert(parentRow, at: 0) }
        allEntries = rows
        rebuildVisible(target)
    }

    private func rebuildVisible(_ target: CursorTarget) {
        let needle = filter.lowercased()
        entries =
            needle.isEmpty
            ? allEntries
            : allEntries.filter { $0.isParent || $0.name.lowercased().contains(needle) }
        listingID = UUID()
        restoreCursor(target)
    }

    /// Snapshot of what is on screen right now, so a rebuild can put the cursor back where it
    /// was. Must be taken before `entries` is replaced.
    private func holdingCursor() -> CursorTarget {
        .hold(previousNames: entries.map(\.name), previousIndex: cursorStorage)
    }

    private func restoreCursor(_ target: CursorTarget) {
        switch target {
        case .firstMatch:
            cursor = entries.firstIndex { !$0.isParent } ?? 0

        case .named(let name):
            guard let name, let index = entries.firstIndex(where: { $0.name == name }) else {
                cursor = 0
                return
            }
            cursor = index

        case .hold(let previousNames, let previousIndex):
            guard !previousNames.isEmpty else {
                cursor = 0
                return
            }
            let start = min(max(0, previousIndex), previousNames.count - 1)

            // The same row, if it is still there. Covers the common case where an operation
            // changed something else in the directory.
            if let index = entries.firstIndex(where: { $0.name == previousNames[start] }) {
                cursor = index
                return
            }

            // The row is gone, so hand the cursor to the nearest surviving row above where it
            // was. Walking rather than simply stepping back one place matters for a bulk
            // delete, where the whole block above the cursor may have gone too.
            //
            // The ".." row is skipped: after deleting a file, dropping the cursor onto
            // "enclosing folder" would put Return one keystroke away from leaving the
            // directory.
            var probe = start - 1
            while probe >= 0 {
                let name = previousNames[probe]
                if name != ".." , let index = entries.firstIndex(where: { $0.name == name }) {
                    cursor = index
                    return
                }
                probe -= 1
            }

            // Nothing above survived, so the row that went was the topmost one. Take whatever
            // moved up into its place; only an emptied directory falls through to "..".
            cursor = entries.firstIndex { !$0.isParent } ?? 0
        }
    }
}

/// Where the cursor should end up once the row set has been rebuilt.
private enum CursorTarget {
    /// Land on this name, or on the first row when it is not there. For moves the user asked
    /// for: entering a directory, or landing on something just created or renamed.
    case named(String?)
    /// Do not move. Stay on the same row, and if it has gone, take the nearest surviving row
    /// above where it was. For reloads and re-sorts — nothing there is a request to move the
    /// cursor.
    case hold(previousNames: [String], previousIndex: Int)
    /// Land on the first row that is not "..". For quick-filter typing, where the point is to
    /// walk the cursor onto what was typed.
    case firstMatch
}
