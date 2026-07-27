import AppKit

/// Resolves a key press to a command, or to quick-filter input when nothing is bound.
@MainActor
struct KeyRouter {
    let state: AppState
    let dispatcher: CommandDispatcher

    /// Returns true when the event was consumed and must not travel further.
    func handle(_ event: NSEvent) -> Bool {
        // A rename editor or dialog field owns its keystrokes.
        guard !isEditingText(event) else { return false }

        let panel = state.activePanel

        // Backspace edits an active filter and only otherwise means "go up". Checked ahead of
        // the keymap because the meaning is contextual, not a rebindable binding of its own.
        if event.keyCode == Self.backspaceKeyCode,
            event.modifierFlags.intersection(KeyChord.significant).isEmpty,
            !panel.filter.isEmpty
        {
            panel.filter = String(panel.filter.dropLast())
            return true
        }

        if let command = state.keymap.command(for: event) {
            guard dispatcher.isEnabled(command) else { return true }
            dispatcher.perform(command)
            return true
        }

        // Anything printable and unmodified extends the quick filter.
        if event.modifierFlags.intersection(KeyChord.significant).subtracting(.shift).isEmpty,
            let characters = event.charactersIgnoringModifiers,
            characters.count == 1,
            let character = characters.first,
            Self.isFilterable(character)
        {
            panel.filter.append(character)
            return true
        }

        return false
    }

    private static let backspaceKeyCode: UInt16 = 51

    /// Space is excluded because it marks rows; everything else printable feeds the filter.
    private static func isFilterable(_ character: Character) -> Bool {
        guard !character.isWhitespace, !character.isNewline else { return false }
        return character.isLetter || character.isNumber || character.isPunctuation
            || character.isSymbol
    }

    /// `NSTextField` editing runs through the window's field editor, which is an
    /// `NSTextView`, so that one check covers text fields too.
    private func isEditingText(_ event: NSEvent) -> Bool {
        event.window?.firstResponder is NSTextView
    }
}
