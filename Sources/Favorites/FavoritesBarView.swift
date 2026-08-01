import SwiftUI
import UniformTypeIdentifiers

/// Favourite folders across the top of the window. Clicking one sends the active pane there;
/// the first nine also answer to ⌘1–⌘9.
///
/// Draws no background or fixed height of its own: `MainWindow` owns the bar it sits in, so
/// the buttons beside it share the same strip.
struct FavoritesBarView: View {
    let store: FavoritesStore
    /// Where a click should navigate to.
    let onOpen: (Favorite) -> Void
    let onAddCurrent: () -> Void

    /// Favourite being dragged, so a drop knows what to move.
    @State private var dragging: Favorite?

    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, favorite in
                        chip(favorite, number: index + 1)
                    }
                }
                .padding(.horizontal, 2)
            }
            Spacer(minLength: 0)
            Button(action: onAddCurrent) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add the active folder to favourites (⌘⇧D)")
        }
    }

    private func chip(_ favorite: Favorite, number: Int) -> some View {
        Button { onOpen(favorite) } label: {
            HStack(spacing: 4) {
                if number <= 9 {
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
            .background(Color.secondary.opacity(0.15), in: Capsule())
            // A folder that has been moved or deleted is dimmed rather than silently dead.
            .opacity(favorite.exists ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .help(favorite.path)
        .contextMenu {
            Button("Rename…") { rename(favorite) }
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
        guard let dragging, dragging.id != target.id,
            let destination = store.favorites.firstIndex(where: { $0.id == target.id })
        else { return }
        store.move(id: dragging.id, to: destination)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
