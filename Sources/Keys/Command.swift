import Foundation

/// Everything the user can ask for, by name. Keymap entries and menu items both key off
/// these, so a rebind in `keymap.json` moves the menu shortcut with it.
///
/// Commands are added in the step that implements them; a name here always does something.
enum Command: String, CaseIterable, Codable, Sendable {
    // File operations
    case newFolder
    case newFile
    case copyToOtherPane
    case moveToOtherPane
    case duplicate
    case renameInPlace
    case moveToTrash
    case deletePermanently

    // Navigation
    case switchPane
    case openCursor
    case goUp
    case goToVolumeRoot
    case historyBack
    case historyForward
    case refresh

    // Display
    case sortByName
    case sortByExtension
    case sortByDate
    case sortBySize
    case toggleHidden
    case clearFilter

    // Marking
    case markToggle
    case markToggleAndAdvance
    case markByPattern
    case unmarkByPattern
    case invertMarks
    case markAll
    case markNone

    // Panes
    case sendPathToOtherPane
    case takePathFromOtherPane
    case swapPanes

    // Shell integration
    case openInTerminal
    case revealInFinder
    case copyPathToClipboard

    /// Menu title. Also what the README's shortcut table prints.
    var title: String {
        switch self {
        case .newFolder: return "New Folder…"
        case .newFile: return "New File…"
        case .copyToOtherPane: return "Copy…"
        case .moveToOtherPane: return "Move…"
        case .duplicate: return "Duplicate"
        case .renameInPlace: return "Rename"
        case .moveToTrash: return "Move to Trash"
        case .deletePermanently: return "Delete Permanently…"
        case .switchPane: return "Switch Pane"
        case .openCursor: return "Open"
        case .goUp: return "Enclosing Folder"
        case .goToVolumeRoot: return "Volume Root"
        case .historyBack: return "Back"
        case .historyForward: return "Forward"
        case .refresh: return "Refresh"
        case .sortByName: return "Sort by Name"
        case .sortByExtension: return "Sort by Extension"
        case .sortByDate: return "Sort by Date"
        case .sortBySize: return "Sort by Size"
        case .toggleHidden: return "Show Hidden Files"
        case .clearFilter: return "Clear Filter"
        case .markToggle: return "Mark"
        case .markToggleAndAdvance: return "Mark and Advance"
        case .markByPattern: return "Mark by Pattern…"
        case .unmarkByPattern: return "Unmark by Pattern…"
        case .invertMarks: return "Invert Marks"
        case .markAll: return "Mark All"
        case .markNone: return "Mark None"
        case .sendPathToOtherPane: return "Send Path to Other Pane"
        case .takePathFromOtherPane: return "Take Path from Other Pane"
        case .swapPanes: return "Swap Panes"
        case .openInTerminal: return "Open in Terminal"
        case .revealInFinder: return "Reveal in Finder"
        case .copyPathToClipboard: return "Copy Path"
        }
    }

    /// Which menu the command appears under.
    var section: Section {
        switch self {
        case .switchPane, .openCursor, .goUp, .goToVolumeRoot, .historyBack, .historyForward:
            return .go
        case .refresh, .sortByName, .sortByExtension, .sortByDate, .sortBySize, .toggleHidden,
            .clearFilter:
            return .view
        case .markToggle, .markToggleAndAdvance, .markByPattern, .unmarkByPattern, .invertMarks,
            .markAll, .markNone:
            return .mark
        case .sendPathToOtherPane, .takePathFromOtherPane, .swapPanes:
            return .panes
        case .newFolder, .newFile, .copyToOtherPane, .moveToOtherPane, .duplicate,
            .renameInPlace, .moveToTrash, .deletePermanently, .openInTerminal, .revealInFinder,
            .copyPathToClipboard:
            return .file
        }
    }

    enum Section: String, CaseIterable, Sendable {
        case file, mark, go, view, panes

        var title: String {
            switch self {
            case .file: return "File"
            case .mark: return "Mark"
            case .go: return "Go"
            case .view: return "View"
            case .panes: return "Panes"
            }
        }
    }
}
