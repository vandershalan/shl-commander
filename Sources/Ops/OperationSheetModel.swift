import AppKit
import Observation

/// Drives the one sheet an operation lives in, from confirmation through to completion.
///
/// A sheet rather than a free-standing alert because a sheet is attached to the window and
/// centred on it, and because the same panel has to stay on screen while the work runs. Rolling
/// confirmation, progress and mid-operation questions into a single presented view avoids
/// stacking an AppKit alert on top of a SwiftUI sheet, which is where sheet ordering gets
/// unpredictable.
@MainActor
@Observable
final class OperationSheetModel {
    /// What to confirm before starting.
    struct Confirmation: Sendable {
        var title: String
        /// Prose: counts, totals, consequences.
        var detail: String
        /// Full paths of everything involved.
        var paths: [String]
        var confirmTitle: String
        /// Colours the confirm button and the icon.
        var isDestructive: Bool = false
        /// Prefilled and editable when the operation needs somewhere to put things, or a name.
        var destination: String?
        /// Label above that field. "Destination" for a path, "Name" when creating something.
        var fieldLabel: String = "Destination"
        /// When set, this word has to be typed before the operation can be confirmed.
        var requiredWord: String?
    }

    /// A name collision the running operation cannot resolve on its own.
    struct ConflictQuestion: Sendable {
        var kind: FileOperationKind
        var source: URL
        var destination: URL
        var sourceDetail: String
        var destinationDetail: String
    }

    enum Stage {
        case confirming(Confirmation)
        case running
        case asking(ConflictQuestion)
        case failed([OperationFailure])
    }

    private(set) var stage: Stage?

    /// True once a running operation has been sent to the background. The sheet is gone, the work
    /// continues, and the window's progress bar is what says so.
    private(set) var isBackgrounded = false

    /// Text the user is editing in the confirmation stage.
    var destinationText = ""
    var typedConfirmation = ""
    /// Conflict options, held here so the view can bind to them.
    var applyToAll = false
    var onlyIfNewer = false

    var isPresented: Bool { stage != nil }

    private var confirmContinuation: CheckedContinuation<String?, Never>?
    private var conflictContinuation: CheckedContinuation<ConflictDecision?, Never>?

    // MARK: - Confirmation

    /// Shows the confirmation and waits. Returns the destination text on confirm — empty when the
    /// operation needs none — or nil when the user backed out.
    func confirm(_ confirmation: Confirmation) async -> String? {
        destinationText = confirmation.destination ?? ""
        typedConfirmation = ""
        isBackgrounded = false
        stage = .confirming(confirmation)

        return await withCheckedContinuation { continuation in
            confirmContinuation = continuation
        }
    }

    /// True while the typed word is still missing, so the view can keep the button disabled
    /// rather than letting a reflex Return through.
    func canConfirm(_ confirmation: Confirmation) -> Bool {
        guard let required = confirmation.requiredWord else { return true }
        return typedConfirmation.trimmingCharacters(in: .whitespaces).lowercased()
            == required.lowercased()
    }

    func acceptConfirmation() {
        guard case .confirming(let confirmation) = stage, canConfirm(confirmation) else { return }
        let value = confirmation.destination == nil ? "" : destinationText
        resumeConfirm(with: value)
    }

    func cancelConfirmation() {
        resumeConfirm(with: nil)
    }

    private func resumeConfirm(with value: String?) {
        guard let continuation = confirmContinuation else { return }
        confirmContinuation = nil
        // Cleared before resuming: the caller starts the operation and calls showRunning, and a
        // stale confirmation stage flashing in between would be visible.
        stage = nil
        continuation.resume(returning: value)
    }

    // MARK: - Running

    func showRunning() {
        isBackgrounded = false
        stage = .running
    }

    /// Hides the sheet and leaves the operation running.
    func sendToBackground() {
        guard case .running = stage else { return }
        isBackgrounded = true
        stage = nil
    }

    // MARK: - Mid-operation questions

    /// Asks about a collision, bringing the sheet back if it had been sent to the background —
    /// otherwise the operation would sit waiting for an answer with nothing on screen to answer.
    func askConflict(_ question: ConflictQuestion) async -> ConflictDecision? {
        applyToAll = false
        onlyIfNewer = false
        isBackgrounded = false
        stage = .asking(question)

        return await withCheckedContinuation { continuation in
            conflictContinuation = continuation
        }
    }

    func answerConflict(_ resolution: ConflictResolution?) {
        guard let continuation = conflictContinuation else { return }
        conflictContinuation = nil

        guard let resolution else {
            // Abandoning the whole operation; the queue will wind down and call finish.
            stage = .running
            continuation.resume(returning: nil)
            return
        }
        let effective =
            resolution == .overwrite && onlyIfNewer ? .overwriteIfNewer : resolution
        stage = .running
        continuation.resume(
            returning: ConflictDecision(resolution: effective, applyToAll: applyToAll))
    }

    // MARK: - Completion

    /// Called when the queue finishes. Failures keep the sheet up so they are actually read;
    /// a clean run closes it.
    func finish(failures: [OperationFailure]) {
        conflictContinuation?.resume(returning: nil)
        conflictContinuation = nil

        guard !failures.isEmpty else {
            stage = nil
            isBackgrounded = false
            return
        }
        isBackgrounded = false
        stage = .failed(failures)
    }

    func dismissFailures() {
        stage = nil
    }

    /// Shows an error in the sheet, so it lands centred on the window like everything else.
    ///
    /// Declines while an operation holds the sheet: clobbering progress or a pending question
    /// with an unrelated error would strand the operation waiting for an answer.
    @discardableResult
    func showFailures(_ failures: [OperationFailure]) -> Bool {
        guard !failures.isEmpty else { return true }
        guard stage == nil else { return false }
        stage = .failed(failures)
        return true
    }
}
