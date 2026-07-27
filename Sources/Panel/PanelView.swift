import AppKit
import SwiftUI

/// One pane: path bar on top, file table in the middle, tallies at the bottom.
struct PanelView: View {
    let panel: PanelViewModel
    let volumes: VolumeService
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
                directorySizes: panel.sizer.sizes,
                measuringDirectories: panel.measuringDirectories,
                sort: panel.sort,
                isActive: isActive,
                renameRequestID: panel.renameRequestID,
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
                onRename: { row, newName in
                    if let message = panel.commitRename(at: row, to: newName) {
                        OperationPrompts.report([
                            OperationFailure(
                                url: panel.directory.appendingPathComponent(newName),
                                message: message
                            )
                        ])
                    }
                },
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
            volumePicker
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

    /// Total Commander's drive buttons, condensed into one menu per pane.
    private var volumePicker: some View {
        Menu {
            ForEach(volumes.volumes) { volume in
                Button {
                    onActivate()
                    panel.navigate(to: volume.url)
                } label: {
                    Text(
                        "\(volume.name) — \(Formatters.size(volume.availableCapacity)) free"
                    )
                }
            }
            let ejectable = volumes.volumes.filter(\.canEject)
            if !ejectable.isEmpty {
                Divider()
                ForEach(ejectable) { volume in
                    Button("Eject \(volume.name)") {
                        if let message = volumes.eject(volume) {
                            OperationPrompts.report([
                                OperationFailure(url: volume.url, message: message)
                            ])
                        }
                    }
                }
            }
        } label: {
            Text(volumes.volume(containing: panel.directory)?.name ?? "Volume")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch volume")
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
                if let free = panel.freeSpace {
                    Text("· \(Formatters.size(free)) free")
                }
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
