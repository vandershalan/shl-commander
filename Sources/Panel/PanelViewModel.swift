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

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        // Standardised on the way in so `enter` never sees two spellings of one directory.
        // Symlinks are deliberately left unresolved: the panel shows the path the user asked
        // for, not wherever it happens to point.
        self.directory = directory.standardizedFileURL
    }

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
        load(keeping: selecting)
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
        switch outcome {
        case .listed(let children):
            var rows = sort.sorted(children)
            if let up = DirectoryLister.parent(of: directory) {
                rows.insert(.parent(up), at: 0)
            }
            allEntries = rows
            loadError = nil
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
        var rows = sort.sorted(allEntries.filter { !$0.isParent })
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
