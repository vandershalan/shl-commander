import AppKit
import Observation

/// Files on the system pasteboard, the way ⌘C / ⌘X / ⌘V work in the Finder and everywhere else.
///
/// What goes on the pasteboard is plain file URLs, so a copy made here pastes in the Finder,
/// Mail or a terminal, and files copied there paste here.
///
/// Cut is the one thing the pasteboard cannot express: there is no system-wide "cut files"
/// flavour. So the cut is remembered here, tied to the pasteboard's change count — the moment
/// anything else is copied, by this app or another, the count moves on and the cut is forgotten.
/// Nothing is removed at cut time: the sources only go when the paste moves them, so a cut that
/// is never pasted loses nothing.
@MainActor
@Observable
final class FileClipboard {
    struct Contents: Equatable {
        let urls: [URL]
        /// True when the files were cut here and should be moved, not copied, on paste.
        let isCut: Bool
    }

    /// The files waiting to be moved, so the panes can draw them dimmed the way the Finder
    /// and Explorer show a pending cut. Empty once the cut is pasted or superseded.
    private(set) var cutURLs: Set<URL> = []

    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var cutChangeCount: Int?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    /// Injectable so tests can use a private pasteboard instead of the user's clipboard.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        // Another app can only replace the clipboard while this one is in the background, so
        // coming back to the front is when a superseded cut has to stop looking cut.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forgetStaleCut() }
        }
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func copy(_ urls: [URL]) {
        write(urls)
        cutChangeCount = nil
        cutURLs = []
    }

    func cut(_ urls: [URL]) {
        write(urls)
        cutChangeCount = pasteboard.changeCount
        cutURLs = Set(urls)
    }

    /// The files waiting to be pasted, or nil when the pasteboard holds none.
    func contents() -> Contents? {
        forgetStaleCut()
        let urls = FileTableController.fileURLs(on: pasteboard)
        guard !urls.isEmpty else { return nil }
        return Contents(urls: urls, isCut: cutChangeCount == pasteboard.changeCount)
    }

    /// Called once a cut has been pasted. The sources are on their way to a new home, so the
    /// pasteboard is emptied rather than left pointing at paths that are about to stop existing.
    func finishCut() {
        guard cutChangeCount == pasteboard.changeCount else { return }
        pasteboard.clearContents()
        cutChangeCount = nil
        cutURLs = []
    }

    /// Drops the cut once something else has been put on the pasteboard.
    func forgetStaleCut() {
        guard let cutChangeCount, cutChangeCount != pasteboard.changeCount else { return }
        self.cutChangeCount = nil
        cutURLs = []
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
