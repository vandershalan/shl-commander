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

    private(set) var directory: URL
    /// Everything the directory holds, sorted, including the `..` row.
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
            load(keeping: cursorEntry?.name)
        }
    }

    /// Case-insensitive substring match on the name. The `..` row is never filtered out,
    /// so there is always a way back.
    var filter: String = "" {
        didSet {
            guard filter != oldValue else { return }
            rebuildVisible(keeping: cursorEntry?.name)
        }
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

    private static let historyLimit = 100
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    /// Recreated on every directory change; nil when the OS refused a stream.
    private var watcher: FSEventsWatcher?

    /// Measured directory sizes for this pane. Per-pane rather than shared: the panes usually
    /// show different directories, and a shared instance would need to fan updates out to both.
    let sizer = DirectorySizer()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // Standardised on the way in so `enter` never sees two spellings of one directory.
        // Symlinks are deliberately left unresolved: the panel shows the path the user asked
        // for, not wherever it happens to point.
        self.directory = directory.standardizedFileURL
        self.tabs = [PanelTab(url: directory)]
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

    /// Measures the marked directories, or the cursor directory when nothing is marked.
    func measureSelectedDirectories() {
        sizer.request(actionTargets.filter(\.isDirectory))
    }

    /// Measures every directory in the pane.
    func measureAllDirectories() {
        sizer.request(entries)
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

    // MARK: - Navigation

    /// Enters `url`. The cursor lands on `selecting` when given, otherwise on the first row.
    func navigate(to url: URL, selecting: String? = nil) {
        enter(url.standardizedFileURL, selecting: selecting, recordHistory: true)
    }

    /// Jumps to the root of the volume the panel is currently on, which for the boot volume
    /// is `/` and for an external disk is its mount point.
    func goToVolumeRoot() {
        let volume = try? directory.resourceValues(forKeys: [.volumeURLKey]).volume
        navigate(to: volume ?? URL(fileURLWithPath: "/"))
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func historyBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(directory)
        enter(previous, selecting: nil, recordHistory: false)
    }

    func historyForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(directory)
        enter(next, selecting: nil, recordHistory: false)
    }

    /// Single funnel for every directory change, so history and filter reset behave the same
    /// no matter which command triggered the move.
    private func enter(_ url: URL, selecting: String?, recordHistory: Bool) {
        // Compared by path, not by URL: `standardizedFileURL` marks an existing directory
        // with a trailing slash, so two URLs for the same folder compare unequal and every
        // "reload where I already am" would push a bogus history entry and wipe the
        // forward stack.
        if recordHistory, url.path != directory.path {
            backStack.append(directory)
            forwardStack.removeAll()
            if backStack.count > Self.historyLimit { backStack.removeFirst() }
        }
        directory = url
        filter = ""
        // Keeps the tab strip's label in step with where the panel actually is.
        if tabs.indices.contains(activeTabIndex) {
            tabs[activeTabIndex].path = url.path
        }
        startWatching()
        load(keeping: selecting)
    }

    /// A watcher is bound to one path, so it is replaced whenever the panel moves.
    private func startWatching() {
        watcher = FSEventsWatcher(watching: directory) { [weak self] in
            // Cursor position and marks survive because reload keys them by name and URL.
            self?.reload()
        }
    }

    /// Re-reads the current directory. Holds the cursor on the same name by default, or moves
    /// it to `selecting` — used to land on a folder or file just created.
    func reload(selecting: String? = nil) {
        load(keeping: selecting ?? cursorEntry?.name)
    }

    /// Opens the row under the cursor. Directories are entered; files await step 8.
    func openCursor() {
        guard let entry = cursorEntry else { return }
        if entry.isParent {
            goUp()
        } else if entry.isNavigable {
            navigate(to: entry.url)
        }
    }

    /// Ascends one level, parking the cursor on the directory just left.
    func goUp() {
        guard let up = DirectoryLister.parent(of: directory) else { return }
        enter(up, selecting: directory.lastPathComponent, recordHistory: true)
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
            tabs = [PanelTab(url: directory, sort: sort, cursorName: cursorEntry?.name)]
            activeTabIndex = 0
            return
        }
        tabs[activeTabIndex].path = directory.path
        tabs[activeTabIndex].sort = sort
        tabs[activeTabIndex].cursorName = cursorEntry?.name
    }

    func openTab(at url: URL? = nil, activate: Bool = true) {
        captureActiveTab()
        let tab = PanelTab(url: url ?? directory, sort: sort)
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
        enter(tab.url.standardizedFileURL, selecting: tab.cursorName, recordHistory: false)
    }

    /// Restores a saved pane, falling back to the current directory if nothing usable is left.
    func restore(tabs saved: [PanelTab], activeIndex: Int) {
        let usable = saved.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !usable.isEmpty else {
            tabs = [PanelTab(url: directory, sort: sort)]
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

    /// Awaits the in-flight listing. Exists so tests can act on a settled panel instead of
    /// polling; the app itself never needs to block on a load.
    func settle() async {
        await loadTask?.value
    }

    private func load(keeping name: String?) {
        let target = directory
        let includeHidden = showHidden

        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let outcome = await Self.read(target, includeHidden: includeHidden)
            guard let self, !Task.isCancelled else { return }
            // A newer navigation may have landed while this listing was in flight.
            guard self.directory.path == target.path else { return }
            self.apply(outcome, keeping: name)
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

    private func apply(_ outcome: ListingOutcome, keeping name: String?) {
        isLoading = false
        freeSpace = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))
            .flatMap(\.volumeAvailableCapacity).map(Int64.init)
        switch outcome {
        case .listed(let children):
            var rows = sort.sorted(children, directorySizes: sizer.sizes)
            if let up = DirectoryLister.parent(of: directory) {
                rows.insert(.parent(up), at: 0)
            }
            allEntries = rows
            loadError = nil
            // Fresh timestamps are in hand, so any size measured before a change goes away.
            sizer.prune(against: rows)
            // Drop marks for anything that no longer exists.
            marks.formIntersection(Set(rows.map(\.url)))
            rebuildVisible(keeping: name)
        case .failed(let message):
            allEntries = []
            marks = []
            loadError = message
            rebuildVisible(keeping: nil)
        }
    }

    private func resort() {
        let name = cursorEntry?.name
        let parentRow = allEntries.first(where: \.isParent)
        var rows = sort.sorted(
            allEntries.filter { !$0.isParent },
            directorySizes: sizer.sizes
        )
        if let parentRow { rows.insert(parentRow, at: 0) }
        allEntries = rows
        rebuildVisible(keeping: name)
    }

    private func rebuildVisible(keeping name: String?) {
        let needle = filter.lowercased()
        entries =
            needle.isEmpty
            ? allEntries
            : allEntries.filter { $0.isParent || $0.name.lowercased().contains(needle) }
        listingID = UUID()
        restoreCursor(to: name)
    }

    /// Holds the cursor on the same *name* across reloads, re-sorts, and filter changes;
    /// falls back to the first row when that name is no longer visible.
    private func restoreCursor(to name: String?) {
        guard let name, let index = entries.firstIndex(where: { $0.name == name }) else {
            cursor = 0
            return
        }
        cursor = index
    }
}
