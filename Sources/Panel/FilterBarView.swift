import SwiftUI

/// Quick-search bar, shown from the first typed character until Escape.
///
/// Total Commander puts this at the bottom of the pane, and it appears as soon as typing
/// starts — including while the text is still empty after backspacing, which is what tells you
/// the next Backspace will edit the filter rather than leave the directory.
struct FilterBarView: View {
    let text: String
    /// Rows the filter currently matches, excluding the `..` row.
    let matchCount: Int
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))

            HStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                // A caret makes it obvious this is a live text field and not a static label.
                Rectangle()
                    .fill(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 1.5, height: 13)
                    .padding(.leading, 1)
            }

            Spacer(minLength: 8)

            Text(matchLabel)
                .font(.system(size: 11))
                .foregroundStyle(matchCount == 0 && !text.isEmpty ? .red : .secondary)
            Text("Esc to clear")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            (isActive ? Color.accentColor : Color.secondary).opacity(0.22)
        )
    }

    private var matchLabel: String {
        if text.isEmpty { return "type to filter" }
        return matchCount == 1 ? "1 match" : "\(matchCount) matches"
    }
}
