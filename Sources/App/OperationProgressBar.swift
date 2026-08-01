import SwiftUI

/// Bottom bar shown only while an operation is running.
struct OperationProgressBar: View {
    let progress: FileOperationQueue.Progress
    /// True once the operation was sent to the background, so the bar is the only sign of it.
    let isBackgrounded: Bool
    let onCancel: () -> Void
    let onReveal: () -> Void

    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isBackgrounded {
                        // Says plainly that this is still going, unattended.
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                            .help("Running in the background")
                    }
                    Text(progress.title).fontWeight(.medium)
                    Text(progress.currentItem)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(detail).foregroundStyle(.secondary).monospacedDigit()
                }
                // An indeterminate bar while scanning: totals are not known yet, and a bar
                // sitting at zero would read as a stall.
                if progress.isScanning || progress.bytesTotal == 0 {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                }
            }
            if isBackgrounded {
                Button("Show", action: onReveal)
                    .help("Bring the operation window back")
            }
            Button("Cancel", action: onCancel)
        }
        .font(.system(size: scale(11)))
        .padding(.horizontal, scale(10))
        .padding(.vertical, scale(6))
        .background(.bar)
    }

    private var detail: String {
        if progress.isScanning { return "measuring…" }
        var parts: [String] = []
        if progress.itemsTotal > 1 {
            parts.append("\(progress.itemsDone) of \(progress.itemsTotal) items")
        }
        if progress.bytesTotal > 0 {
            parts.append(
                Formatters.size(progress.bytesDone) + " of " + Formatters.size(progress.bytesTotal)
            )
        }
        return parts.joined(separator: " · ")
    }
}
