import Foundation

/// Routes a mid-operation collision into the operation sheet rather than a free-standing alert.
///
/// The sheet brings itself back if the operation had been sent to the background: an operation
/// waiting on an answer with nothing on screen to answer would look like a hang.
@MainActor
struct SheetConflictPrompt: ConflictPrompting {
    let model: OperationSheetModel

    func resolveConflict(
        kind: FileOperationKind,
        source: URL,
        destination: URL
    ) async -> ConflictDecision? {
        await model.askConflict(
            OperationSheetModel.ConflictQuestion(
                kind: kind,
                source: source,
                destination: destination,
                sourceDetail: Self.describe(source),
                destinationDetail: Self.describe(destination)
            )
        )
    }

    private static func describe(_ url: URL) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return "unavailable" }
        let date = values.contentModificationDate.map(Formatters.timestamp.string(from:)) ?? "—"
        if values.isDirectory == true { return "folder, modified \(date)" }
        return "\(Formatters.size(Int64(values.fileSize ?? 0))), modified \(date)"
    }
}
