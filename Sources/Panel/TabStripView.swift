import SwiftUI

/// Tabs for one pane. Hidden while a pane has a single tab, so the common case costs no
/// vertical space.
struct TabStripView: View {
    let panel: PanelViewModel
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { index, tab in
                    tabButton(tab, index: index)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 22)
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
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if selected, panel.hasMultipleTabs {
                    Button {
                        onActivate()
                        panel.closeActiveTab()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                selected
                    ? (isActive ? Color.accentColor.opacity(0.30) : Color.secondary.opacity(0.20))
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
        }
        .buttonStyle(.plain)
        .help(tab.path)
    }
}
