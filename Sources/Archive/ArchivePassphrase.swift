import AppKit

/// Passwords for encrypted archives, remembered for as long as the app runs.
///
/// Nothing is written to disk and nothing goes to the Keychain: a password typed to look inside
/// a zip is wanted for this session, not for ever, and keeping it in memory means quitting the
/// app forgets it. It is keyed by canonical path, so one password covers every pane, tab and
/// operation working on the same archive.
@MainActor
final class ArchivePassphraseStore {
    static let shared = ArchivePassphraseStore()

    private var byPath: [String: String] = [:]

    init() {}

    func passphrase(for archive: URL) -> String? { byPath[archive.canonicalPath] }

    func remember(_ passphrase: String, for archive: URL) {
        byPath[archive.canonicalPath] = passphrase
    }

    func forget(_ archive: URL) { byPath.removeValue(forKey: archive.canonicalPath) }

    func forgetAll() { byPath.removeAll() }

    /// Asks for the password, remembers it, and hands it back. Nil when the dialog was cancelled.
    ///
    /// A rejected password is dropped before asking again, so a typo cannot linger and fail
    /// every later operation on the same archive.
    func ask(for archive: URL, afterFailure: Bool = false) -> String? {
        if afterFailure { forget(archive) }
        guard
            let typed = OperationPrompts.askForPassphrase(
                archive: archive, afterFailure: afterFailure)
        else { return nil }
        remember(typed, for: archive)
        return typed
    }
}

/// Runs archive work that may need a password, asking for one and retrying when it does.
///
/// An encrypted zip still lists without a password — only the entry data is encrypted — so the
/// question is asked at the moment something is actually read out, which is where the user can
/// tell what they are being asked about.
enum ArchivePassphrase {
    /// Calls `body` with the password known for `archive`, asking for one and retrying whenever
    /// bsdtar reports that the archive is encrypted. Throws `.cancelled` when the user declines.
    static func retrying<T: Sendable>(
        on archive: URL,
        _ body: @escaping @Sendable (String?) throws -> T
    ) async throws -> T {
        var passphrase = await ArchivePassphraseStore.shared.passphrase(for: archive)

        while true {
            do {
                return try await offMainActor(passphrase, body)
            } catch ArchiveReader.Failure.passphraseNeeded {
                // A password was already in hand and the archive refused it, which is worth
                // saying rather than showing the same blank field twice.
                let typed = await ArchivePassphraseStore.shared.ask(
                    for: archive, afterFailure: passphrase != nil)
                guard let typed else { throw ArchiveReader.Failure.cancelled }
                passphrase = typed
            }
        }
    }

    /// Runs the work on a background task, so a subprocess and its output never hold up the
    /// main actor, and cancelling the caller cancels it.
    private static func offMainActor<T: Sendable>(
        _ passphrase: String?,
        _ body: @escaping @Sendable (String?) throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try body(passphrase) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
