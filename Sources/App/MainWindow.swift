import SwiftUI

/// Step 1 shows a single pane. Step 2 splits this into two.
struct MainWindow: View {
    @State private var panel = PanelViewModel()

    var body: some View {
        PanelView(panel: panel)
            .frame(minWidth: 700, minHeight: 400)
            .task {
                panel.navigate(to: panel.directory)
            }
    }
}
