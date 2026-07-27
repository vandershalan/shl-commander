import AppKit
import SwiftUI

/// One pane: path bar on top, file table in the middle, tallies at the bottom.
struct PanelView: View {
    let panel: PanelViewModel
    let isActive: Bool
    let onActivate: () -> Void
    /// Every key press goes to `KeyRouter`; the panel itself binds nothing.
    let onKeyDown: (NSEvent) -> Bool

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            FileTableView(
                entries: panel.entries,
                listingID: panel.listingID,
                cursor: panel.cursor,
                marks: panel.marks,
                sort: panel.sort,
                isActive: isActive,
                onCursorChange: { panel.cursor = $0 },
                onMove: { panel.move($0) },
                onOpen: { panel.openCursor() },
                onSort: { key, ascending in
                    panel.sort = SortOrder(
                        key: key,
                        ascending: ascending,
                        directoriesFirst: panel.sort.directoriesFirst
                    )
                },
                onActivate: onActivate,
                onKeyDown: onKeyDown
            )
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // The active pane is outlined rather than tinted so file colours stay honest.
        .overlay(
            Rectangle()
                .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Text(panel.directory.path)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .help(panel.directory.path)
            Spacer(minLength: 0)
            if panel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = panel.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error).lineLimit(1)
            } else {
                Text(selectionSummary)
                    .foregroundStyle(panel.markedCount > 0 ? Color.red : Color.secondary)
                Spacer(minLength: 0)
                Text("\(panel.directoryCount) dirs, \(panel.fileCount) files")
            }
            Spacer(minLength: 0)
            if !panel.filter.isEmpty {
                Label(panel.filter, systemImage: "line.3.horizontal.decrease")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var selectionSummary: String {
        let marked = panel.markedCount
        let total = panel.fileCount + panel.directoryCount
        return "\(marked) of \(total) marked, "
            + Formatters.size(panel.markedBytes) + " of " + Formatters.size(panel.totalBytes)
    }

}
