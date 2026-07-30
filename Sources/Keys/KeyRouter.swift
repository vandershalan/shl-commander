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

        // While an operation is running, Escape cancels it. Checked first so it beats the
        // clear-filter binding.
        if event.keyCode == Self.escapeKeyCode,
            event.modifierFlags.intersection(KeyChord.significant).isEmpty,
            state.operations.isRunning
        {
            state.operations.cancel()
            return true
        }

        let panel = state.activePanel

        // Backspace belongs to the filter for as long as a filter session is open, and only
        // means "go up" outside one. Checked ahead of the keymap because the meaning is
        // contextual, not a rebindable binding of its own.
        //
        // Deliberately keyed on the session rather than on the filter still having text:
        // otherwise backspacing away the last character would hand the very next Backspace to
        // "go up", and clearing a filter would walk you out of the directory.
        if event.keyCode == Self.backspaceKeyCode,
            event.modifierFlags.intersection(KeyChord.significant).isEmpty,
            panel.isFiltering
        {
            panel.deleteFilterCharacter()
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
            panel.appendToFilter(character)
            return true
        }

        return false
    }

    private static let backspaceKeyCode: UInt16 = 51
    private static let escapeKeyCode: UInt16 = 53

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
