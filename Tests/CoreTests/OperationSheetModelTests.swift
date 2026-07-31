import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Operation sheet")
struct OperationSheetModelTests {
    private func confirmation(
        destination: String? = nil,
        requiredWord: String? = nil
    ) -> OperationSheetModel.Confirmation {
        OperationSheetModel.Confirmation(
            title: "Delete 2 items",
            detail: "2 files · 3 KB",
            paths: ["/tmp/a.txt", "/tmp/b.txt"],
            confirmTitle: "Delete",
            isDestructive: true,
            destination: destination,
            requiredWord: requiredWord
        )
    }

    private func question() -> OperationSheetModel.ConflictQuestion {
        OperationSheetModel.ConflictQuestion(
            kind: .copy,
            source: URL(fileURLWithPath: "/tmp/from/a.txt"),
            destination: URL(fileURLWithPath: "/tmp/to/a.txt"),
            sourceDetail: "1 KB, modified now",
            destinationDetail: "2 KB, modified then"
        )
    }

    /// Waits for the sheet to reach a particular stage.
    ///
    /// Waiting on `isPresented` alone is not enough: after a collision is answered the sheet goes
    /// back to `.running`, which is still presented, so a second question could be answered before
    /// its continuation was installed — and then nothing would ever resume it.
    private func waitForConfirming(_ model: OperationSheetModel) async {
        while true {
            if case .confirming = model.stage { return }
            await Task.yield()
        }
    }

    private func waitForAsking(_ model: OperationSheetModel) async {
        while true {
            if case .asking = model.stage { return }
            await Task.yield()
        }
    }

    @Test("nothing is presented until something asks")
    func idle() {
        let model = OperationSheetModel()
        #expect(model.isPresented == false)
        #expect(model.stage == nil)
    }

    @Test("confirming returns an empty string when there is no field to fill")
    func confirmWithoutField() async {
        let model = OperationSheetModel()
        let answer = Task { await model.confirm(confirmation()) }

        // Let the sheet come up before answering it.
        await waitForConfirming(model)
        #expect(model.isPresented)
        model.acceptConfirmation()

        #expect(await answer.value == "")
        #expect(model.isPresented == false, "the sheet closes before the operation starts")
    }

    @Test("cancelling returns nothing, so the caller does no work")
    func cancelConfirmation() async {
        let model = OperationSheetModel()
        let answer = Task { await model.confirm(confirmation()) }
        await waitForConfirming(model)

        model.cancelConfirmation()
        #expect(await answer.value == nil)
        #expect(model.isPresented == false)
    }

    @Test("an edited destination comes back from the confirmation")
    func confirmWithDestination() async {
        let model = OperationSheetModel()
        let answer = Task { await model.confirm(confirmation(destination: "/tmp/original")) }
        await waitForConfirming(model)

        #expect(model.destinationText == "/tmp/original", "the field starts prefilled")
        model.destinationText = "/tmp/somewhere else"
        model.acceptConfirmation()

        #expect(await answer.value == "/tmp/somewhere else")
    }

    @Test("a typed word gates the confirm button")
    func typedConfirmation() async {
        let model = OperationSheetModel()
        let subject = confirmation(requiredWord: "delete")
        let answer = Task { await model.confirm(subject) }
        await waitForConfirming(model)

        #expect(model.canConfirm(subject) == false)
        // Accepting while the word is missing does nothing, so a reflex Return cannot get through.
        model.acceptConfirmation()
        #expect(model.isPresented)

        model.typedConfirmation = "  DELETE "
        #expect(model.canConfirm(subject), "trimmed and case-insensitive")
        model.acceptConfirmation()
        #expect(await answer.value != nil)
    }

    @Test("the sheet stays up showing progress once the operation starts")
    func running() {
        let model = OperationSheetModel()
        model.showRunning()

        #expect(model.isPresented, "the confirmation window becomes the progress window")
        if case .running = model.stage {} else { Issue.record("expected the running stage") }
        #expect(model.isBackgrounded == false)
    }

    @Test("sending to the background hides the sheet and leaves the work going")
    func background() {
        let model = OperationSheetModel()
        model.showRunning()
        model.sendToBackground()

        #expect(model.isPresented == false)
        #expect(model.isBackgrounded, "so the window's progress bar can say what is happening")
    }

    @Test("only a running operation can be backgrounded")
    func backgroundOnlyWhileRunning() async {
        let model = OperationSheetModel()
        let answer = Task { await model.confirm(confirmation()) }
        await waitForConfirming(model)

        // A confirmation is a question, not work in progress; there is nothing to background.
        model.sendToBackground()
        #expect(model.isPresented)
        #expect(model.isBackgrounded == false)

        model.cancelConfirmation()
        _ = await answer.value
    }

    @Test("a collision brings the sheet back and returns the chosen resolution")
    func conflict() async {
        let model = OperationSheetModel()
        model.showRunning()
        model.sendToBackground()
        #expect(model.isPresented == false)

        let answer = Task { await model.askConflict(question()) }
        await waitForAsking(model)
        // Otherwise the operation would wait for an answer with nothing on screen to answer.
        #expect(model.isBackgrounded == false)

        model.answerConflict(.skip)
        let decision = await answer.value
        #expect(decision?.resolution == .skip)
        #expect(decision?.applyToAll == false)
    }

    @Test("apply-to-all rides along with the answer")
    func conflictApplyToAll() async {
        let model = OperationSheetModel()
        let answer = Task { await model.askConflict(question()) }
        await waitForAsking(model)

        model.applyToAll = true
        model.answerConflict(.overwrite)
        let decision = await answer.value
        #expect(decision?.resolution == .overwrite)
        #expect(decision?.applyToAll == true)
    }

    @Test("only-if-newer turns Overwrite into the conditional form")
    func conflictOnlyIfNewer() async {
        let model = OperationSheetModel()
        let answer = Task { await model.askConflict(question()) }
        await waitForAsking(model)

        model.onlyIfNewer = true
        model.answerConflict(.overwrite)
        #expect(await answer.value?.resolution == .overwriteIfNewer)

        // It only qualifies Overwrite; Keep Both is unaffected.
        let second = Task { await model.askConflict(question()) }
        await waitForAsking(model)
        model.onlyIfNewer = true
        model.answerConflict(.rename)
        #expect(await second.value?.resolution == .rename)
    }

    @Test("the conflict options reset between questions")
    func conflictOptionsReset() async {
        let model = OperationSheetModel()
        let first = Task { await model.askConflict(question()) }
        await waitForAsking(model)
        model.applyToAll = true
        model.onlyIfNewer = true
        model.answerConflict(.skip)
        _ = await first.value

        let second = Task { await model.askConflict(question()) }
        await waitForAsking(model)
        #expect(model.applyToAll == false, "a stale tick would silently answer for every file")
        #expect(model.onlyIfNewer == false)
        model.answerConflict(.skip)
        _ = await second.value
    }

    @Test("cancelling a collision abandons the operation and returns to progress")
    func conflictCancel() async {
        let model = OperationSheetModel()
        let answer = Task { await model.askConflict(question()) }
        await waitForAsking(model)

        model.answerConflict(nil)
        #expect(await answer.value == nil)
        // Still up: the queue is winding down and will close it.
        if case .running = model.stage {} else { Issue.record("expected the running stage") }
    }

    @Test("a clean finish closes the sheet")
    func finishClean() {
        let model = OperationSheetModel()
        model.showRunning()
        model.finish(failures: [])

        #expect(model.isPresented == false)
        #expect(model.isBackgrounded == false)
    }

    @Test("failures keep the sheet up, even after it was backgrounded")
    func finishWithFailures() {
        let model = OperationSheetModel()
        model.showRunning()
        model.sendToBackground()

        let failure = OperationFailure(
            url: URL(fileURLWithPath: "/tmp/a.txt"), message: "Permission denied")
        model.finish(failures: [failure])

        #expect(model.isPresented, "so the failure is actually read")
        #expect(model.isBackgrounded == false)
        if case .failed(let shown) = model.stage {
            #expect(shown.count == 1)
        } else {
            Issue.record("expected the failure stage")
        }

        model.dismissFailures()
        #expect(model.isPresented == false)
    }

    @Test("finishing while a question is open releases the waiting operation")
    func finishReleasesPendingQuestion() async {
        let model = OperationSheetModel()
        let answer = Task { await model.askConflict(question()) }
        await waitForAsking(model)

        // A cancelled queue finishes without anyone answering; the worker must not wait forever.
        model.finish(failures: [])
        #expect(await answer.value == nil)
    }

    @Test("an error can be shown on its own")
    func showFailures() {
        let model = OperationSheetModel()
        let failure = OperationFailure(url: URL(fileURLWithPath: "/tmp/a"), message: "Nope")

        #expect(model.showFailures([failure]))
        #expect(model.isPresented)
    }

    @Test("an error never displaces a running operation")
    func showFailuresDeclinesWhileBusy() {
        let model = OperationSheetModel()
        model.showRunning()

        let failure = OperationFailure(url: URL(fileURLWithPath: "/tmp/a"), message: "Nope")
        // Clobbering progress — or worse, a pending question — would strand the operation.
        #expect(model.showFailures([failure]) == false)
        if case .running = model.stage {} else { Issue.record("expected the running stage") }
    }

    @Test("showing no errors is a no-op that reports success")
    func showNoFailures() {
        let model = OperationSheetModel()
        #expect(model.showFailures([]))
        #expect(model.isPresented == false)
    }
}
