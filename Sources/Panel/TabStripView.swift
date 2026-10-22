import SwiftUI

/// Tabs for one pane. Hidden while a pane has a single tab, so the common case costs no
/// vertical space.
///
/// Drawn as folder tabs sitting on the path bar: the selected one shares the bar's fill and
/// has no bottom edge, so it reads as the same shape; each tab takes the colour of its folder.
struct TabStripView: View {
    let panel: PanelViewModel
    let side: AppState.Side
    let colors: PathColorStore
    let isActive: Bool
    /// Favourite names by path; a tab on a bookmarked folder takes that name.
    let favoriteNames: [String: String]
    let onActivate: () -> Void
    /// Tab being dragged, shared by both panes so it can be carried from one to the other.
    @Binding var dragging: TabDrag?
    /// Moves the dragged tab into this pane, at an index or at the end.
    let onTransfer: (TabDrag, Int?) -> Void

    @Environment(\.uiScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: scale(2)) {
                ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
                    tabButton(tab, index: index)
                }
            }
            .padding(.horizontal, scale(4))
        }
        // The whole strip takes drops, so a tab from the other pane can land past the end.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onDrop(
            of: [.text],
            delegate: TabDropDelegate(
                side: side, panel: panel, index: nil, dragging: $dragging,
                onTransfer: onTransfer)
        )
        .frame(height: scale(22), alignment: .bottom)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tabButton(_ tab: PanelTab, index: Int) -> some View {
        let selected = index == panel.activeTabIndex
        // The selected tab's stored path lags behind navigation until it is captured, so it
        // follows the live directory instead.
        let path = selected ? panel.shownDirectory.path : tab.path
        // Labelled from where the pane shows it is, so the title changes with the rows.
        var shown = tab
        if selected { shown.setLocation(panel.shownLocation) }
        let shape = UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)

        // A tap gesture rather than a `Button`: on macOS a button keeps the mouse to itself and
        // a drag never starts.
        return HStack(spacing: 4) {
            Text(shown.title(favoriteNames: favoriteNames))
                .font(.system(size: scale(11), weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(selected ? .primary : .secondary)
            if selected, panel.hasMultipleTabs {
                Button {
                    onActivate()
                    panel.closeActiveTab()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: scale(7), weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, scale(8))
        .frame(height: scale(selected ? 20 : 18))
        // Layered on the pane's own background, exactly as the path bar is, so a
        // translucent fill comes out the same colour in both places.
        .background(
            colors.barFill(for: path, isActive: selected && isActive), in: shape
        )
        .background(Color(nsColor: .controlBackgroundColor), in: shape)
        .overlay {
            if selected {
                // Open at the bottom, so the outline stands out without cutting the tab
                // off from the path bar it belongs to.
                OpenTabOutline(radius: 5)
                    .stroke(
                        isActive ? Color.activeOutline : Color.secondary.opacity(0.5),
                        lineWidth: 1.5
                    )
            } else {
                shape.strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
        }
        .contentShape(shape)
        .onTapGesture {
            onActivate()
            panel.selectTab(index)
        }
        .help(tab.path)
        .onDrag {
            dragging = TabDrag(side: side, id: tab.id)
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: TabDropDelegate(
                side: side, panel: panel, index: index, dragging: $dragging,
                onTransfer: onTransfer)
        )
    }
}

/// A tab in flight: which pane it came from, and which tab it is.
struct TabDrag: Equatable {
    let side: AppState.Side
    let id: UUID
}

/// Within a pane, tabs reorder as the pointer passes over them, so the strip rearranges
/// under the drag. From the other pane, the tab moves over on release, at `index` or — for a
/// drop on empty space — at the end.
struct TabDropDelegate: DropDelegate {
    let side: AppState.Side
    let panel: PanelViewModel
    let index: Int?
    @Binding var dragging: TabDrag?
    let onTransfer: (TabDrag, Int?) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.side == side, let index else { return }
        panel.moveTab(id: dragging.id, to: index)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil }
        guard let dragging else { return false }
        if dragging.side != side {
            onTransfer(dragging, index)
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// A tab's left, top and right edges with rounded top corners — no bottom edge.
private struct OpenTabOutline: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        // Inset by half a typical stroke so the line is not clipped at the frame's edge.
        let r = rect.insetBy(dx: 0.75, dy: 0.75)
        let radius = min(radius, r.width / 2, r.height)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: r.minX, y: r.minY),
            tangent2End: CGPoint(x: r.minX + radius, y: r.minY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(
            tangent1End: CGPoint(x: r.maxX, y: r.minY),
            tangent2End: CGPoint(x: r.maxX, y: r.minY + radius),
            radius: radius
        )
        path.addLine(to: CGPoint(x: r.maxX, y: rect.maxY))
        return path
    }
}
