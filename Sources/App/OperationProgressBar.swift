import SwiftUI

/// Bottom bar shown only while an operation is running.
struct OperationProgressBar: View {
    let progress: FileOperationQueue.Progress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
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
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
