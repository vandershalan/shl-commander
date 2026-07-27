import Foundation
import Observation

/// Outcome of an off-main directory read. Carries the message rather than the `Error`
/// because `any Error` is not `Sendable`.
enum ListingOutcome: Sendable {
    case listed([FileEntry])
    case failed(String)
}

/// State of one pane: where it is, what it lists, where the cursor sits.
///
/// The cursor is deliberately separate from marks (step 2): Total Commander moves the
/// cursor with the arrows while `Space` marks rows independently.
@MainActor
@Observable
final class PanelViewModel: Identifiable {
    let id = UUID()

    private(set) var directory: URL
    private(set) var entries: [FileEntry] = []
    /// Bumped on every successful listing or re-sort. The table view reloads only when
    /// this changes, so cursor moves alone never trigger a full reload.
    private(set) var listingID = UUID()
    private(set) var loadError: String?
    private(set) var isLoading = false

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

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = directory
    }

    var cursorEntry: FileEntry? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }

    var fileCount: Int { entries.count(where: { !$0.isDirectory }) }
    var directoryCount: Int { entries.count(where: { $0.isDirectory && !$0.isParent }) }
    var totalBytes: Int64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) } }

    // MARK: - Navigation

    /// Enters `url`. The cursor lands on `selecting` when given, otherwise on the first row.
    func navigate(to url: URL, selecting: String? = nil) {
        directory = url.standardizedFileURL
        load(keeping: selecting)
    }

    /// Re-reads the current directory, holding the cursor on the same name.
    func reload() {
        load(keeping: cursorEntry?.name)
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
        let leaving = directory.lastPathComponent
        directory = up
        load(keeping: leaving)
    }

    // MARK: - Loading

    private func load(keeping name: String?) {
        let target = directory
        let includeHidden = showHidden

        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let outcome = await Self.read(target, includeHidden: includeHidden)
            guard let self, !Task.isCancelled else { return }
            // A newer navigation may have landed while this listing was in flight.
            guard self.directory == target else { return }
            self.apply(outcome, keeping: name)
        }
    }

    /// `nonisolated async` so it runs on the cooperative pool instead of the main actor.
    /// Awaits the in-flight listing. Exists so tests can act on a settled panel instead of
    /// polling; the app itself never needs to block on a load.
    func settle() async {
        await loadTask?.value
    }

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
            entries = rows
            listingID = UUID()
            loadError = nil
            restoreCursor(to: name)
        case .failed(let message):
            entries = []
            listingID = UUID()
            cursor = 0
            loadError = message
        }
    }

    private func resort() {
        let name = cursorEntry?.name
        let parentRow = entries.first(where: \.isParent)
        var rows = sort.sorted(entries.filter { !$0.isParent })
        if let parentRow { rows.insert(parentRow, at: 0) }
        entries = rows
        listingID = UUID()
        restoreCursor(to: name)
    }

    /// Holds the cursor on the same *name* across reloads and re-sorts; falls back to the
    /// first row when that name is gone.
    private func restoreCursor(to name: String?) {
        guard let name, let index = entries.firstIndex(where: { $0.name == name }) else {
            cursor = 0
            return
        }
        cursor = index
    }
}
