import AppKit
import SwiftUI

/// One pane: path bar on top, file table in the middle, tallies at the bottom.
struct PanelView: View {
    let panel: PanelViewModel

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            FileTableView(
                entries: panel.entries,
                listingID: panel.listingID,
                cursor: panel.cursor,
                sort: panel.sort,
                onCursorChange: { panel.cursor = $0 },
                onOpen: { panel.openCursor() },
                onSort: { key, ascending in
                    panel.sort = SortOrder(
                        key: key,
                        ascending: ascending,
                        directoriesFirst: panel.sort.directoriesFirst
                    )
                },
                onKeyDown: handleKeyDown
            )
            Divider()
            footer
        }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Text(panel.directory.path)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if panel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = panel.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error).lineLimit(1)
            } else {
                Text(
                    "\(panel.directoryCount) dirs, \(panel.fileCount) files, "
                        + Formatters.size(panel.totalBytes)
                )
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    /// Step 1 handles only the two navigation keys; step 3 replaces this with `KeyRouter`.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76:  // Return, numpad Enter
            panel.openCursor()
            return true
        case 51:  // Delete (labelled Backspace on a full keyboard)
            panel.goUp()
            return true
        default:
            return false
        }
    }
}
