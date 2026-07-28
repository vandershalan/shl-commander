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
    case measureSelectedDirectories
    case measureAllDirectories

    // Marking
    case markToggle
    case markToggleAndAdvance
    case markByPattern
    case unmarkByPattern
    case invertMarks
    case markAll
    case markNone

    // Tabs
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case openInOtherPaneTab

    // Favourites
    case addFavorite
    case showFavorites
    case favorite1
    case favorite2
    case favorite3
    case favorite4
    case favorite5
    case favorite6
    case favorite7
    case favorite8
    case favorite9

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
        case .measureSelectedDirectories: return "Measure Selected Folders"
        case .measureAllDirectories: return "Measure All Folders"
        case .markToggle: return "Mark"
        case .markToggleAndAdvance: return "Mark and Advance"
        case .markByPattern: return "Mark by Pattern…"
        case .unmarkByPattern: return "Unmark by Pattern…"
        case .invertMarks: return "Invert Marks"
        case .markAll: return "Mark All"
        case .markNone: return "Mark None"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .openInOtherPaneTab: return "Open in Other Pane"
        case .addFavorite: return "Add to Favourites"
        case .showFavorites: return "Favourites…"
        case .favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6,
            .favorite7, .favorite8, .favorite9:
            return "Favourite \(favoriteNumber ?? 0)"
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
            .clearFilter, .measureSelectedDirectories, .measureAllDirectories:
            return .view
        case .markToggle, .markToggleAndAdvance, .markByPattern, .unmarkByPattern, .invertMarks,
            .markAll, .markNone:
            return .mark
        case .sendPathToOtherPane, .takePathFromOtherPane, .swapPanes, .newTab, .closeTab,
            .nextTab, .previousTab, .openInOtherPaneTab:
            return .panes
        case .addFavorite, .showFavorites, .favorite1, .favorite2, .favorite3, .favorite4,
            .favorite5, .favorite6, .favorite7, .favorite8, .favorite9:
            return .favorites
        case .newFolder, .newFile, .copyToOtherPane, .moveToOtherPane, .duplicate,
            .renameInPlace, .moveToTrash, .deletePermanently, .openInTerminal, .revealInFinder,
            .copyPathToClipboard:
            return .file
        }
    }

    /// 1-9 for the numbered favourite commands, nil for everything else. Lets one dispatcher
    /// branch cover all nine rather than repeating it nine times.
    var favoriteNumber: Int? {
        switch self {
        case .favorite1: return 1
        case .favorite2: return 2
        case .favorite3: return 3
        case .favorite4: return 4
        case .favorite5: return 5
        case .favorite6: return 6
        case .favorite7: return 7
        case .favorite8: return 8
        case .favorite9: return 9
        default: return nil
        }
    }

    enum Section: String, CaseIterable, Sendable {
        case file, mark, go, view, panes, favorites

        var title: String {
            switch self {
            case .file: return "File"
            case .mark: return "Mark"
            case .go: return "Go"
            case .view: return "View"
            case .panes: return "Panes"
            case .favorites: return "Favourites"
            }
        }
    }
}
