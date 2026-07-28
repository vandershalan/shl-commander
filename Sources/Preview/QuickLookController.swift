import AppKit
import QuickLookUI

/// Feeds Quick Look. Previewing the marked set rather than one file means the panel's own
/// arrow keys step through exactly what was selected.
@MainActor
/// The Quick Look protocols carry no main-actor annotation even though the panel only ever
/// calls them on the main thread, so the conformances are marked `@preconcurrency`.
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate
{
    static let shared = QuickLookController()

    private var items: [URL] = []
    private var startIndex = 0

    /// Loads the panel's contents. Returns false when there is nothing previewable.
    func prepare(_ urls: [URL], startingAt index: Int) -> Bool {
        guard !urls.isEmpty else { return false }
        items = urls
        startIndex = min(max(0, index), urls.count - 1)
        return true
    }

    /// Opens the panel, or closes it if it is already showing — F3 toggles.
    func toggle() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = startIndex
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        items.indices.contains(index) ? items[index] as NSURL : nil
    }

    // MARK: - QLPreviewPanelDelegate

    /// Lets the panel keep working the way the rest of the app does: keys it does not use go
    /// back to the table, so Escape closes and the arrows still walk the preview set.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}
