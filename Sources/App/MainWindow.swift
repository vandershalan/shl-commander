import SwiftUI

/// Two panes side by side with a draggable divider.
///
/// Built from an `HStack` plus a drag handle rather than `HSplitView` because the divider
/// position has to persist across launches, and `HSplitView` does not expose it.
struct MainWindow: View {
    let state: AppState

    @AppStorage("dividerFraction") private var dividerFraction: Double = 0.5
    /// Divider fraction at the moment the current drag started, or nil when idle.
    @State private var dragStartFraction: Double?

    /// Keeps either pane from being dragged down to an unusable sliver.
    private let minimumPaneWidth: CGFloat = 260
    private let dividerWidth: CGFloat = 6

    private var router: KeyRouter {
        KeyRouter(state: state, dispatcher: CommandDispatcher(state: state))
    }

    var body: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - dividerWidth
            let leftWidth = clampedLeftWidth(in: available)

            HStack(spacing: 0) {
                PanelView(
                    panel: state.left,
                    isActive: state.active == .left,
                    onActivate: { state.active = .left },
                    onKeyDown: router.handle
                )
                .frame(width: leftWidth)

                divider(available: available)

                PanelView(
                    panel: state.right,
                    isActive: state.active == .right,
                    onActivate: { state.active = .right },
                    onKeyDown: router.handle
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 2 * minimumPaneWidth + dividerWidth, minHeight: 400)
        .task { state.start() }
    }

    private func clampedLeftWidth(in available: CGFloat) -> CGFloat {
        guard available > 2 * minimumPaneWidth else { return available / 2 }
        return min(max(available * dividerFraction, minimumPaneWidth), available - minimumPaneWidth)
    }

    private func divider(available: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: dividerWidth)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 1, height: 24)
            )
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard available > 2 * minimumPaneWidth else { return }
                        // `translation` is measured from where the drag began, so the
                        // baseline has to be the fraction at that moment. Reading the live
                        // fraction here would compound each delta and race the cursor.
                        let start = dragStartFraction ?? dividerFraction
                        if dragStartFraction == nil { dragStartFraction = start }

                        let width = available * start + value.translation.width
                        dividerFraction = Double(
                            min(max(width, minimumPaneWidth), available - minimumPaneWidth)
                                / available
                        )
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }
}
