import Foundation

/// Computes directory sizes on demand and remembers them.
///
/// Sizing a tree means walking every file in it, so it is never done automatically — only
/// when asked, and the answer is cached until the directory's own timestamp changes.
@MainActor
final class DirectorySizer {
    /// Sizes ready to display, keyed by directory. Handed to the table as a plain dictionary
    /// so it can diff and repaint.
    private(set) var sizes: [URL: Int64] = [:]

    /// Called whenever a new size lands, so the panel can repaint and re-sort.
    var onUpdate: (() -> Void)?

    /// Directories still being measured. Maintained as a set rather than derived by scanning
    /// the queue, so the table can ask about every row without turning a repaint quadratic.
    private(set) var pendingURLs: Set<URL> = []

    var pendingCount: Int { pendingURLs.count }

    private struct Cached {
        let bytes: Int64
        /// The directory's timestamp when measured; a change invalidates the entry.
        let modified: Date
    }

    private var cache: [URL: Cached] = [:]
    /// Least-recently-used first, so the cache can be trimmed without unbounded growth.
    private var recency: [URL] = []
    private var active: [URL: Task<Void, Never>] = [:]
    private var queued: [(url: URL, modified: Date)] = []

    private static let capacity = 2_000
    /// Walking several trees at once helps, but only up to a point — beyond this the disk is
    /// the bottleneck and the queue just adds contention.
    private static let maxConcurrent = 4

    // MARK: - Queries

    func size(of entry: FileEntry) -> Int64? {
        guard let hit = cache[entry.url], hit.modified == entry.modified else { return nil }
        return hit.bytes
    }

    func isPending(_ entry: FileEntry) -> Bool {
        pendingURLs.contains(entry.url)
    }

    // MARK: - Requests

    /// Measures each directory that is not already known or in flight.
    func request(_ entries: [FileEntry]) {
        for entry in entries where entry.isDirectory && !entry.isParent {
            guard size(of: entry) == nil, !isPending(entry) else { continue }
            queued.append((entry.url, entry.modified))
            pendingURLs.insert(entry.url)
        }
        pump()
        // Fires so the Size column can switch to "…" immediately, not only once a size lands.
        onUpdate?()
    }

    func cancelAll() {
        for task in active.values { task.cancel() }
        active = [:]
        queued = []
        pendingURLs = []
    }

    /// Drops cached sizes whose directory has since changed, so a stale number is never shown.
    /// Called after each listing, when fresh timestamps are available.
    func prune(against entries: [FileEntry]) {
        let current = Dictionary(
            entries.lazy.filter { $0.isDirectory && !$0.isParent }.map { ($0.url, $0.modified) },
            uniquingKeysWith: { first, _ in first }
        )

        for (url, timestamp) in current {
            guard let hit = cache[url], hit.modified != timestamp else { continue }
            cache[url] = nil
            sizes[url] = nil
            recency.removeAll { $0 == url }
        }
    }

    // MARK: - Work

    private func pump() {
        while active.count < Self.maxConcurrent, !queued.isEmpty {
            let next = queued.removeFirst()
            start(next.url, modified: next.modified)
        }
    }

    private func start(_ url: URL, modified: Date) {
        active[url] = Task { [weak self] in
            let bytes = await Self.measure(url)
            guard let self, !Task.isCancelled else { return }
            self.active[url] = nil
            self.pendingURLs.remove(url)
            if let bytes {
                self.store(url, bytes: bytes, modified: modified)
            }
            self.pump()
            self.onUpdate?()
        }
    }

    /// `nonisolated async` so the walk runs off the main actor. Returns nil when cancelled.
    private nonisolated static func measure(_ url: URL) async -> Int64? {
        let bytes = FileTreeScanner.allocatedSize(of: url, isCancelled: { Task.isCancelled })
        return Task.isCancelled ? nil : bytes
    }

    private func store(_ url: URL, bytes: Int64, modified: Date) {
        cache[url] = Cached(bytes: bytes, modified: modified)
        sizes[url] = bytes
        recency.removeAll { $0 == url }
        recency.append(url)

        while recency.count > Self.capacity, let oldest = recency.first {
            recency.removeFirst()
            cache[oldest] = nil
            sizes[oldest] = nil
        }
    }
}
