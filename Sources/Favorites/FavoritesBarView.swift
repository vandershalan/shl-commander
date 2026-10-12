import SwiftUI
import UniformTypeIdentifiers

/// One pane's favourite folders, shown above the window. Clicking one opens it in a new tab
/// of that pane, whichever pane has focus; ⌥-clicking sends the pane's current tab there
/// instead. The first nine across both groups also answer to ⌘1–⌘9.
///
/// Draws no background or fixed height of its own: `MainWindow` owns the bar it sits in.
struct FavoritesBarView: View {
    let store: FavoritesStore
    let colors: PathColorStore
    /// Whose favourites to show; the right pane's sit against the window's right edge.
    let side: AppState.Side
    /// Where a click should navigate to, and whether it should open a new tab.
    let onOpen: (Favorite, _ inNewTab: Bool) -> Void

    /// Favourite being dragged, so a drop knows what to move. Shared by both groups, so a
    /// chip can be carried from one to the other.
    @Binding var dragging: Favorite?

    @Environment(\.uiScale) private var scale

    var body: some View {
        let alignment: UnitPoint = side == .left ? .leading : .trailing
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(store.favorites(on: side)) { favorite in
                    chip(favorite, number: store.number(of: favorite))
                }
            }
            .padding(.horizontal, 2)
        }
        .defaultScrollAnchor(alignment, for: .alignment)
        .defaultScrollAnchor(alignment, for: .initialOffset)
        // The whole group takes drops, so a chip can land in an empty group or past the end.
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: [.text],
            delegate: GroupDropDelegate(side: side, store: store, dragging: $dragging)
        )
    }

    /// A tap gesture rather than a `Button`: on macOS a button keeps the mouse to itself and
    /// a drag never starts.
    private func chip(_ favorite: Favorite, number: Int?) -> some View {
        HStack(spacing: 4) {
            if let number {
                Text("\u{2318}\(number)")
                    .font(.system(size: scale(9), weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text(favorite.name)
                .font(.system(size: scale(11)))
                .lineLimit(1)
        }
        .padding(.horizontal, scale(7))
        .padding(.vertical, scale(2))
        .background(
            colors.color(for: favorite.path)?.color.opacity(0.5)
                ?? Color.secondary.opacity(0.15),
            in: Capsule()
        )
        // A folder that has been moved or deleted is dimmed rather than silently dead.
        .opacity(favorite.exists ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture {
            let replacing = NSEvent.modifierFlags.contains(.option)
            onOpen(favorite, !replacing)
        }
        .help("\(favorite.path)\nClick: new tab \u{2014} \u{2325}-click: current tab")
        .contextMenu {
            Button("Rename…") { rename(favorite) }
            Button(side == .left ? "Move to Right Pane" : "Move to Left Pane") {
                store.setSide(favorite, to: side.other)
            }
            Button("Remove") { store.remove(favorite) }
        }
        .onDrag {
            dragging = favorite
            return NSItemProvider(object: favorite.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text],
            delegate: ReorderDelegate(
                target: favorite,
                store: store,
                dragging: $dragging
            )
        )
    }

    private func rename(_ favorite: Favorite) {
        guard
            let name = OperationPrompts.askForName(
                title: "Rename favourite",
                initial: favorite.name,
                buttonTitle: "Rename"
            )
        else { return }
        store.rename(favorite, to: name)
    }
}

/// Reorders as the pointer passes over a chip, so the bar rearranges under the drag rather
/// than only on release.
private struct ReorderDelegate: DropDelegate {
    let target: Favorite
    let store: FavoritesStore
    @Binding var dragging: Favorite?

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        store.move(id: dragging.id, onto: target)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Catches drops on a group's empty space: a chip from the other group joins this one at the
/// end, which is the only way into a group that has no chips yet.
private struct GroupDropDelegate: DropDelegate {
    let side: AppState.Side
    let store: FavoritesStore
    @Binding var dragging: Favorite?

    func validateDrop(info: DropInfo) -> Bool {
        dragging != nil
    }

    func dropEntered(info: DropInfo) {
        guard let dragging,
            let current = store.favorites.first(where: { $0.id == dragging.id }),
            current.side != side
        else { return }
        store.setSide(current, to: side)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
