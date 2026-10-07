import SwiftUI

/// Tabs for one pane. Hidden while a pane has a single tab, so the common case costs no
/// vertical space.
///
/// Drawn as folder tabs sitting on the path bar: the selected one shares the bar's fill and
/// has no bottom edge, so it reads as the same shape; each tab takes the colour of its folder.
struct TabStripView: View {
    let panel: PanelViewModel
    let colors: PathColorStore
    let isActive: Bool
    let onActivate: () -> Void

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
        .frame(height: scale(22), alignment: .bottom)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tabButton(_ tab: PanelTab, index: Int) -> some View {
        let selected = index == panel.activeTabIndex
        // The selected tab's stored path lags behind navigation until it is captured, so it
        // follows the live directory instead.
        let path = selected ? panel.directory.path : tab.path
        let shape = UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)

        return Button {
            onActivate()
            panel.selectTab(index)
        } label: {
            HStack(spacing: 4) {
                Text(tab.title)
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
                if !selected {
                    shape.strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(tab.path)
    }
}
