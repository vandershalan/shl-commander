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

    /// Everything the window draws is sized through this, so ⌘+/⌘- rescale the lot.
    private var scale: UIScale { UIScale(factor: state.settings.uiScale) }

    /// Keeps either pane from being dragged down to an unusable sliver. Scaled with the rest:
    /// the columns inside a pane grow too, and a 260pt pane cannot hold them at ⌘+.
    private var minimumPaneWidth: CGFloat { scale(260) }
    private let dividerWidth: CGFloat = 6

    private var router: KeyRouter {
        KeyRouter(state: state, dispatcher: CommandDispatcher(state: state))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            panes
            if let progress = state.operations.progress {
                Divider()
                OperationProgressBar(
                    progress: progress,
                    isBackgrounded: state.operationSheet.isBackgrounded,
                    onCancel: { state.operations.cancel() },
                    onReveal: { state.operationSheet.showRunning() }
                )
            }
        }
        .frame(minWidth: 2 * minimumPaneWidth + dividerWidth, minHeight: scale(400))
        // A sheet is attached to the window and centred on it, which is where a confirmation
        // belongs — a free-standing alert lands in the middle of the screen instead.
        .sheet(isPresented: .constant(state.operationSheet.isPresented)) {
            OperationSheetView(
                model: state.operationSheet,
                progress: state.operations.progress,
                onCancelOperation: { state.operations.cancel() }
            )
        }
        // Outermost, so the sheet is inside it: sheet content is presented from here and takes
        // the environment as it stands at this point, not as it was inside the VStack.
        .environment(\.uiScale, scale)
        .task { state.start() }
    }

    /// Favourites plus the buttons that do not belong to any one pane.
    private var topBar: some View {
        let dispatcher = CommandDispatcher(state: state)
        // Both panes share the setting, so either one answers for it.
        let showingHidden = state.activePanel.showHidden

        return HStack(spacing: 8) {
            FavoritesBarView(
                store: state.favorites,
                onOpen: { dispatcher.open($0) },
                onAddCurrent: { dispatcher.perform(.addFavorite) }
            )

            Divider().frame(height: scale(14))

            Button {
                dispatcher.perform(.toggleHidden)
            } label: {
                Image(systemName: showingHidden ? "eye" : "eye.slash")
                    // Tinted when on, so the state reads at a glance rather than only from
                    // which of two similar glyphs is showing.
                    .foregroundStyle(showingHidden ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(
                showingHidden
                    ? "Hide hidden files (\u{2318}\u{21E7}.)"
                    : "Show hidden files (\u{2318}\u{21E7}.)"
            )

            Button {
                dispatcher.perform(.showShortcuts)
            } label: {
                Image(systemName: "keyboard")
            }
            .buttonStyle(.borderless)
            .help("Keyboard shortcuts (\u{2318}/)")
        }
        .font(.system(size: scale(13)))
        .padding(.horizontal, scale(8))
        .frame(height: scale(26))
        .background(.bar)
    }

    private var panes: some View {
        GeometryReader { geometry in
            let available = geometry.size.width - dividerWidth
            let leftWidth = clampedLeftWidth(in: available)

            HStack(spacing: 0) {
                PanelView(
                    panel: state.left,
                    volumes: state.volumes,
                    cloud: state.cloud,
                    isActive: state.active == .left,
                    onConnectToServer: { connectToServer() },
                    onDrop: accept(drop:to:copying:),
                    onActivate: { state.active = .left },
                    onKeyDown: router.handle
                )
                .frame(width: leftWidth)

                divider(available: available)

                PanelView(
                    panel: state.right,
                    volumes: state.volumes,
                    cloud: state.cloud,
                    isActive: state.active == .right,
                    onConnectToServer: { connectToServer() },
                    onDrop: accept(drop:to:copying:),
                    onActivate: { state.active = .right },
                    onKeyDown: router.handle
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func accept(drop urls: [URL], to destination: URL, copying: Bool) {
        CommandDispatcher(state: state).acceptDrop(urls, onto: destination, copying: copying)
    }

    private func connectToServer() {
        CommandDispatcher(state: state).perform(.connectToServer)
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
                    .frame(width: 1, height: scale(24))
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
