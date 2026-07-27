import AppKit
import SwiftUI

/// One pane: path bar on top, file table in the middle, tallies at the bottom.
struct PanelView: View {
    let panel: PanelViewModel
    let isActive: Bool
    let onActivate: () -> Void
    let onSwitchPane: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            FileTableView(
                entries: panel.entries,
                listingID: panel.listingID,
                cursor: panel.cursor,
                marks: panel.marks,
                sort: panel.sort,
                isActive: isActive,
                onCursorChange: { panel.cursor = $0 },
                onMove: { panel.move($0) },
                onOpen: { panel.openCursor() },
                onSort: { key, ascending in
                    panel.sort = SortOrder(
                        key: key,
                        ascending: ascending,
                        directoriesFirst: panel.sort.directoriesFirst
                    )
                },
                onActivate: onActivate,
                onKeyDown: handleKeyDown
            )
            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
        // The active pane is outlined rather than tinted so file colours stay honest.
        .overlay(
            Rectangle()
                .strokeBorder(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Text(panel.directory.path)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .help(panel.directory.path)
            Spacer(minLength: 0)
            if panel.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let error = panel.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error).lineLimit(1)
            } else {
                Text(selectionSummary)
                    .foregroundStyle(panel.markedCount > 0 ? Color.red : Color.secondary)
                Spacer(minLength: 0)
                Text("\(panel.directoryCount) dirs, \(panel.fileCount) files")
            }
            Spacer(minLength: 0)
            if !panel.filter.isEmpty {
                Label(panel.filter, systemImage: "line.3.horizontal.decrease")
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.25), in: Capsule())
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var selectionSummary: String {
        let marked = panel.markedCount
        let total = panel.fileCount + panel.directoryCount
        return "\(marked) of \(total) marked, "
            + Formatters.size(panel.markedBytes) + " of " + Formatters.size(panel.totalBytes)
    }

    // MARK: - Keyboard

    /// Step 2 wires the keys the panes need to be usable. Step 3 replaces this with the
    /// remappable `KeyRouter`, at which point every binding moves into the keymap.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // `.function`/`.numericPad` ride along on arrows and keypad keys, so they do not
        // count against "no modifier held".
        let unmodified = modifiers
            .subtracting([.shift, .capsLock, .function, .numericPad])
            .isEmpty

        switch event.keyCode {
        case 48 where unmodified:  // Tab
            onSwitchPane()
            return true
        case 36, 76:  // Return, keypad Enter
            panel.openCursor()
            return true
        case 51:  // Delete, labelled Backspace on a full keyboard
            // Backspace edits the filter while one is active, and only otherwise ascends.
            if panel.filter.isEmpty {
                panel.goUp()
            } else {
                panel.filter = String(panel.filter.dropLast())
            }
            return true
        case 53:  // Escape
            guard !panel.filter.isEmpty else { return false }
            panel.filter = ""
            return true
        case 49 where unmodified:  // Space marks without moving
            panel.toggleMarkAtCursor(advance: false)
            return true
        case 114:  // Insert marks and steps down
            panel.toggleMarkAtCursor(advance: true)
            return true
        case 67:  // keypad *
            panel.invertMarks()
            return true
        case 69:  // keypad +
            promptForPattern(marked: true)
            return true
        case 78:  // keypad -
            promptForPattern(marked: false)
            return true
        default:
            break
        }

        // Leave ⌘ combinations to the menu bar and to step 3's keymap.
        guard unmodified else { return false }

        if let character = event.charactersIgnoringModifiers?.first,
            event.charactersIgnoringModifiers?.count == 1,
            Self.isFilterable(character)
        {
            panel.filter.append(character)
            return true
        }
        return false
    }

    /// Space is excluded because it marks rows; everything else printable feeds the filter.
    private static func isFilterable(_ character: Character) -> Bool {
        guard !character.isWhitespace, !character.isNewline else { return false }
        return character.isLetter || character.isNumber || character.isPunctuation
            || character.isSymbol
    }

    private func promptForPattern(marked: Bool) {
        let alert = NSAlert()
        alert.messageText = marked ? "Mark files matching" : "Unmark files matching"
        alert.informativeText = "Shell wildcards, for example *.txt or report?.pdf"
        let field = NSTextField(string: "*")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: marked ? "Mark" : "Unmark")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        panel.mark(matching: field.stringValue, marked: marked)
    }
}
