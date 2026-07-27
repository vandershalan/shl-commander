import SwiftUI

/// Placeholder shell. Step 2 replaces the body with the dual-pane split view.
struct MainWindow: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("shl-commander")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("scaffold — dual panes land in step 2")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}
