import CoreServices
import Foundation

/// What the FSEvents callback actually talks to.
///
/// It exists separately from `FSEventsWatcher` to break a lifetime problem: the stream must
/// hold a strong reference to whatever its context points at, or a callback already queued on
/// the main queue will fire into freed memory. Retaining the watcher itself would instead
/// create a cycle, and since `deinit` is what stops the stream, the stream would never stop.
///
/// So the stream retains this object, the watcher holds it too, and the watcher's `deinit`
/// invalidates it first — after which a late callback is a no-op rather than a crash.
private final class EventTarget: @unchecked Sendable {
    /// Symlink-resolved, because that is the form FSEvents reports paths in.
    private let watchedPath: String
    private let lock = NSLock()
    private var onChange: (@MainActor () -> Void)?
    private var pending: DispatchWorkItem?

    /// Extra debounce on top of the stream's own latency, so a thousand-file copy triggers a
    /// handful of reloads rather than hundreds.
    private static let debounce: DispatchTimeInterval = .milliseconds(250)

    init(watchedPath: String, onChange: @escaping @MainActor () -> Void) {
        self.watchedPath = watchedPath
        self.onChange = onChange
    }

    func invalidate() {
        lock.lock()
        onChange = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
    }

    func deliver(paths: [String]) {
        // An empty list means the paths could not be read; reload rather than risk showing
        // stale contents.
        guard paths.isEmpty || paths.contains(where: isRelevant) else { return }

        lock.lock()
        guard onChange != nil else {
            lock.unlock()
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.onChange
            self.lock.unlock()
            guard let handler else { return }
            MainActor.assumeIsolated { handler() }
        }
        pending = work
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// True for the watched directory itself and for its immediate children only.
    private func isRelevant(_ path: String) -> Bool {
        if path == watchedPath { return true }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).deletingLastPathComponent == watchedPath
    }
}

/// Watches one directory and reports when its direct contents change.
///
/// FSEvents is always recursive, so a change deep inside a subtree would otherwise reload a
/// panel that shows nothing of it. Events are filtered down to the watched directory's own
/// children and then debounced.
final class FSEventsWatcher {
    private let target: EventTarget
    private var stream: FSEventStreamRef?

    /// The stream's own coalescing window.
    private static let latency: CFTimeInterval = 0.2

    init?(watching directory: URL, onChange: @escaping @MainActor () -> Void) {
        let watchedPath = directory.canonicalPath
        target = EventTarget(watchedPath: watchedPath, onChange: onChange)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(target).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(Unmanaged<EventTarget>.fromOpaque(pointer).retain().toOpaque())
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<EventTarget>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let target = Unmanaged<EventTarget>.fromOpaque(info).takeUnretainedValue()
            // Valid only because the stream is created with kFSEventStreamCreateFlagUseCFTypes.
            // Without that flag this argument is a C `char **`, and bridging it as an NSArray
            // dereferences string pointers as objects.
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            target.deliver(paths: changed)
        }

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [watchedPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagNoDefer
                        // Makes the callback's paths argument a CFArray of CFString rather
                        // than a C char**, which is what the callback above bridges.
                        | kFSEventStreamCreateFlagUseCFTypes
                )
            )
        else {
            target.invalidate()
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            target.invalidate()
            return nil
        }
    }

    deinit {
        // Invalidated before the stream is torn down, so a callback already sitting on the
        // main queue finds nothing to call.
        target.invalidate()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
