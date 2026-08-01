import SwiftUI

/// The one sheet an operation lives in: confirm, then progress, then anything that went wrong.
struct OperationSheetView: View {
    let model: OperationSheetModel
    let progress: FileOperationQueue.Progress?
    let onCancelOperation: () -> Void

    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.stage {
            case .confirming(let confirmation):
                confirmStage(confirmation)
            case .running:
                runningStage
            case .asking(let question):
                conflictStage(question)
            case .failed(let failures):
                failureStage(failures)
            case nil:
                EmptyView()
            }
        }
        // Wide enough for a full path, which is the whole reason these are not stock alerts.
        .frame(width: scale(620))
        // Semantic fonts do not follow a zoom, so the sizes AppKit gives them are spelled out
        // and scaled: 13 for a headline, 12 for a callout, 10 for a caption.
        .font(.system(size: scale(13)))
    }

    // MARK: - Confirm

    private func confirmStage(_ confirmation: Confirmation) -> some View {
        VStack(alignment: .leading, spacing: scale(12)) {
            header(
                title: confirmation.title,
                detail: confirmation.detail,
                symbol: confirmation.isDestructive ? "exclamationmark.triangle.fill" : "doc.on.doc",
                tint: confirmation.isDestructive ? .orange : .accentColor
            )

            if confirmation.destination != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(confirmation.fieldLabel)
                        .font(.system(size: scale(10)))
                        .foregroundStyle(.secondary)
                    TextField("", text: Binding(
                        get: { model.destinationText },
                        set: { model.destinationText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: scale(12), design: .monospaced))
                    .onSubmit { model.acceptConfirmation() }
                }
            }

            if !confirmation.paths.isEmpty {
                pathList(confirmation.paths)
            }

            if let word = confirmation.requiredWord {
                HStack(spacing: 8) {
                    Text("Type \u{201C}\(word)\u{201D} to confirm:").font(.system(size: scale(12)))
                    TextField("", text: Binding(
                        get: { model.typedConfirmation },
                        set: { model.typedConfirmation = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: scale(140))
                }
            }

            buttons {
                Button("Cancel") { model.cancelConfirmation() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle) { model.acceptConfirmation() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConfirm(confirmation))
            }
        }
        .padding(scale(20))
    }

    // MARK: - Running

    private var runningStage: some View {
        VStack(alignment: .leading, spacing: scale(12)) {
            header(
                title: progress?.title ?? "Working…",
                detail: progress?.currentItem ?? "",
                symbol: "arrow.triangle.2.circlepath",
                tint: .accentColor
            )

            if let progress {
                if progress.isScanning || progress.bytesTotal == 0 {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                }
                Text(detailLine(progress))
                    .font(.system(size: scale(11)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }

            buttons {
                Button("Cancel", action: onCancelOperation)
                    .keyboardShortcut(.cancelAction)
                // Leaves the work running; the window's progress bar takes over as the sign that
                // something is still going.
                Button("Continue in Background") { model.sendToBackground() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(scale(20))
    }

    private func detailLine(_ progress: FileOperationQueue.Progress) -> String {
        if progress.isScanning { return "Measuring…" }
        var parts: [String] = []
        if progress.itemsTotal > 0 {
            parts.append("\(progress.itemsDone) of \(progress.itemsTotal) items")
        }
        if progress.bytesTotal > 0 {
            parts.append(
                Formatters.size(progress.bytesDone) + " of "
                    + Formatters.size(progress.bytesTotal))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Conflict

    private func conflictStage(_ question: ConflictQuestion) -> some View {
        VStack(alignment: .leading, spacing: scale(12)) {
            header(
                title: "\u{22}\(question.destination.lastPathComponent)\u{22} already exists",
                detail:
                    "Source: \(question.sourceDetail)\nDestination: \(question.destinationDetail)",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )

            pathList([
                "From:  \(question.source.path)",
                "To:    \(question.destination.path)",
            ])

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Apply to all remaining", isOn: Binding(
                    get: { model.applyToAll }, set: { model.applyToAll = $0 }))
                Toggle("Only if the source is newer", isOn: Binding(
                    get: { model.onlyIfNewer }, set: { model.onlyIfNewer = $0 }))
            }
            .toggleStyle(.checkbox)

            buttons {
                Button("Cancel") { model.answerConflict(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(ConflictResolution.skip.buttonTitle) { model.answerConflict(.skip) }
                Button(ConflictResolution.overwrite.buttonTitle) {
                    model.answerConflict(.overwrite)
                }
                Button(ConflictResolution.rename.buttonTitle) { model.answerConflict(.rename) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(scale(20))
    }

    // MARK: - Failures

    private func failureStage(_ failures: [OperationFailure]) -> some View {
        VStack(alignment: .leading, spacing: scale(12)) {
            header(
                title: failures.count == 1
                    ? "1 item could not be completed"
                    : "\(failures.count) items could not be completed",
                detail: "",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
            pathList(failures.map { "\($0.url.path)\n    \($0.message)" })
            buttons {
                Button("OK") { model.dismissFailures() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(scale(20))
    }

    // MARK: - Pieces

    private func header(title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: scale(12)) {
            Image(systemName: symbol)
                .font(.system(size: scale(26)))
                .foregroundStyle(tint)
                .frame(width: scale(32))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: scale(13), weight: .semibold))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: scale(12)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Full paths, selectable, scrolling when there are more than fit. Nothing is truncated: a
    /// "and N more" tail hides exactly the entries worth checking.
    private func pathList(_ lines: [String]) -> some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: scale(11), design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(scale(6))
        }
        .frame(height: min(scale(200), max(scale(44), CGFloat(lines.count) * scale(30) + scale(16))))
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: scale(10)) {
            Spacer()
            content()
        }
    }
}

private typealias Confirmation = OperationSheetModel.Confirmation
private typealias ConflictQuestion = OperationSheetModel.ConflictQuestion
