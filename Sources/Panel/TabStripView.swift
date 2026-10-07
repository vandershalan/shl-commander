import SwiftUI

/// Tabs for one pane. Hidden while a pane has a single tab, so the common case costs no
/// vertical space.
struct TabStripView: View {
    let panel: PanelViewModel
    let isActive: Bool
    let onActivate: () -> Void

    @Environment(\.uiScale) private var scale

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: scale(4)) {
                ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
                    tabButton(tab, index: index)
                }
            }
            .padding(.horizontal, scale(4))
        }
        .frame(height: scale(22))
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func tabButton(_ tab: PanelTab, index: Int) -> some View {
        let selected = index == panel.activeTabIndex
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
            .padding(.horizontal, scale(7))
            .padding(.vertical, scale(2))
            .background(
                selected
                    ? (isActive ? Color.accentColor.opacity(0.30) : Color.secondary.opacity(0.20))
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 4)
            )
            // Outline every tab so neighbouring inactive tabs don't read as one line of text.
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(selected ? 0 : 0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(tab.path)
    }
}
