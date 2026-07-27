import Foundation
import Observation

/// Asked mid-operation how to handle a name that is already taken.
@MainActor
protocol ConflictPrompting: Sendable {
    /// Returns nil to abandon the whole operation.
    func resolveConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL
    ) async -> ConflictDecision?
}

/// Thread-safe byte tally.
///
/// The engine's progress callback is synchronous and runs off the main actor thousands of
/// times per file, so it cannot hop actors. It bumps this counter instead, and a ticker on
/// the main actor publishes the value a few times a second.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    func add(_ delta: Int64) {
        lock.lock()
        value += delta
        lock.unlock()
    }

    var current: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Runs one file operation at a time, reporting progress and collecting per-item failures so
/// a long run is not abandoned at the first error.
@MainActor
@Observable
final class FileOperationQueue {
    struct Progress: Sendable {
        var title: String
        var currentItem: String = ""
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var itemsDone: Int = 0
        var itemsTotal: Int = 0
        /// True while totals are still being gathered, when there is no denominator yet.
        var isScanning: Bool = true

        var fraction: Double {
            guard bytesTotal > 0 else { return 0 }
            return min(1, Double(bytesDone) / Double(bytesTotal))
        }
    }

    private(set) var progress: Progress?
    private(set) var failures: [OperationFailure] = []

    /// Called on the main actor once an operation finishes, so panels can refresh.
    var onCompletion: (() -> Void)?

    var isRunning: Bool { task != nil }

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    func cancel() {
        task?.cancel()
    }

    /// Awaits the running operation. Exists for tests; the app observes `progress` instead.
    func settle() async {
        while let task {
            await task.value
        }
    }

    func dismissFailures() {
        failures = []
    }

    // MARK: - Copy and move

    func start(_ request: FileOperationRequest, prompt: any ConflictPrompting) {
        // Serial by design: two concurrent operations on overlapping trees would race.
        guard task == nil, !request.sources.isEmpty else { return }

        failures = []
        progress = Progress(title: request.kind.verb, itemsTotal: request.sources.count)

        let counter = ByteCounter()
        startTicker(counter)
        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.transfer(request, prompt: prompt, counter: counter)
            await self?.finish()
        }
    }

    // MARK: - Delete

    func startDeletion(of urls: [URL], toTrash: Bool) {
        guard task == nil, !urls.isEmpty else { return }

        failures = []
        progress = Progress(
            title: toTrash ? "Moving to Trash" : "Deleting",
            itemsTotal: urls.count,
            isScanning: false
        )

        task = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.delete(urls, toTrash: toTrash)
            await self?.finish()
        }
    }

    // MARK: - Workers

    /// `nonisolated` so the file I/O runs off the main actor; the main-actor updates it needs
    /// are awaited explicitly.
    private nonisolated func transfer(
        _ request: FileOperationRequest,
        prompt: any ConflictPrompting,
        counter: ByteCounter
    ) async {
        let stats = FileTreeScanner.stats(of: request.sources)
        await setTotals(bytes: stats.bytes, items: request.sources.count)

        /// Set once the user picks "apply to all", then reused without asking again. A request
        /// carrying an automatic resolution starts out already decided.
        var standingResolution: ConflictResolution? = request.automaticResolution
        let fileManager = FileManager.default
        let exists: (URL) -> Bool = { fileManager.fileExists(atPath: $0.path) }
        let modified: (URL) -> Date? = {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        for (index, source) in request.sources.enumerated() {
            if Task.isCancelled { break }
            await setCurrent(item: source.lastPathComponent, itemsDone: index)

            let destination = request.destinationDirectory
                .appendingPathComponent(source.lastPathComponent)

            if let rejection = ConflictResolver.rejectContainment(
                source: source,
                destinationDirectory: request.destinationDirectory
            ) {
                await record(OperationFailure(url: source, message: rejection.message))
                continue
            }

            var resolution = ConflictResolution.rename
            if exists(destination) {
                if let standingResolution {
                    resolution = standingResolution
                } else {
                    guard
                        let decision = await prompt.resolveConflict(
                            kind: request.kind, source: source, destination: destination)
                    else { break }
                    if decision.applyToAll { standingResolution = decision.resolution }
                    resolution = decision.resolution
                }
            }

            let plan = ConflictResolver.plan(
                source: source,
                destination: destination,
                resolution: resolution,
                exists: exists,
                modified: modified
            )

            // Checked now that the final name is known: duplicating starts out aimed at the
            // source's own name and is only safe because the plan redirected it.
            if let target = plan.target,
                let rejection = ConflictResolver.rejectSameLocation(source: source, target: target)
            {
                await record(OperationFailure(url: source, message: rejection.message))
                continue
            }

            do {
                switch plan {
                case .skip:
                    // Still credit the bytes, or the bar would stall on a skipped item.
                    counter.add(FileTreeScanner.stats(of: source).bytes)
                case .overwrite(let target):
                    try fileManager.removeItem(at: target)
                    try run(request.kind, source, target, counter)
                case .write(let target):
                    try run(request.kind, source, target, counter)
                }
            } catch is CancellationError {
                break
            } catch let failure as CopyEngine.Failure {
                if case .cancelled = failure { break }
                await record(
                    OperationFailure(url: source, message: failure.localizedDescription))
            } catch {
                await record(OperationFailure(url: source, message: error.localizedDescription))
            }
        }

        await setCurrent(item: "", itemsDone: request.sources.count)
    }

    private nonisolated func run(
        _ kind: FileOperationKind,
        _ source: URL,
        _ destination: URL,
        _ counter: ByteCounter
    ) throws {
        let isCancelled = { Task.isCancelled }
        switch kind {
        case .copy:
            try CopyEngine.copy(
                from: source, to: destination, isCancelled: isCancelled, progress: counter.add)
        case .move:
            try CopyEngine.move(
                from: source, to: destination, isCancelled: isCancelled, progress: counter.add)
        }
    }

    private nonisolated func delete(_ urls: [URL], toTrash: Bool) async {
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            await setCurrent(item: url.lastPathComponent, itemsDone: index)
            do {
                if toTrash {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                await record(OperationFailure(url: url, message: error.localizedDescription))
            }
        }
        await setCurrent(item: "", itemsDone: urls.count)
    }

    // MARK: - Main-actor state

    private func startTicker(_ counter: ByteCounter) {
        ticker = Task { [weak self] in
            while let self, self.task != nil || self.progress != nil {
                self.progress?.bytesDone = counter.current
                try? await Task.sleep(for: .milliseconds(120))
                if Task.isCancelled { return }
            }
        }
    }

    private func setTotals(bytes: Int64, items: Int) {
        progress?.bytesTotal = bytes
        progress?.itemsTotal = items
        progress?.isScanning = false
    }

    private func setCurrent(item: String, itemsDone: Int) {
        progress?.currentItem = item
        progress?.itemsDone = itemsDone
    }

    private func record(_ failure: OperationFailure) {
        failures.append(failure)
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        task = nil
        progress = nil
        onCompletion?()
    }
}
