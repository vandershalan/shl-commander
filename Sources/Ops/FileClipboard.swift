import AppKit

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
final class FileClipboard {
    struct Contents: Equatable {
        let urls: [URL]
        /// True when the files were cut here and should be moved, not copied, on paste.
        let isCut: Bool
    }

    private let pasteboard: NSPasteboard
    private var cutChangeCount: Int?

    /// Injectable so tests can use a private pasteboard instead of the user's clipboard.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func copy(_ urls: [URL]) {
        write(urls)
        cutChangeCount = nil
    }

    func cut(_ urls: [URL]) {
        write(urls)
        cutChangeCount = pasteboard.changeCount
    }

    /// The files waiting to be pasted, or nil when the pasteboard holds none.
    func contents() -> Contents? {
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
    }

    private func write(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
