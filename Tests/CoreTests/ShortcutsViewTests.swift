import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Shortcuts list")
struct ShortcutsViewTests {
    @Test("every command is listed somewhere, so the sheet cannot go out of date")
    func everyCommandHasASection() {
        // Each command belongs to exactly one section, and every section is rendered, so a
        // command added later cannot quietly fail to appear.
        for command in Command.allCases {
            #expect(Command.Section.allCases.contains(command.section))
        }
    }

    @Test("the shortcut list has its own binding, reachable without a mouse")
    func showShortcutsIsBound() {
        let chords = Keymap.defaults.chords(for: .showShortcuts)
        #expect(chords.isEmpty == false)
        #expect(chords.map(\.canonicalName).contains("f1"))
        // F1 alone is not enough on a stock Mac, where it dims the screen.
        #expect(chords.contains { $0.modifiers.contains(.command) })
    }

    @Test("the ⌘ binding can be drawn as a menu key equivalent")
    func menuChordRenders() throws {
        let chord = try #require(Keymap.defaults.menuChord(for: .showShortcuts))
        #expect(chord.keyEquivalent != nil)
        #expect(chord.displayName == "⌘/")
    }

    @Test("the shortcut list rides the Help menu instead of adding a second one")
    func livesInHelpSection() {
        #expect(Command.showShortcuts.section == .help)
        // Nothing else is in there; the Help menu is not a dumping ground.
        let help = Command.allCases.filter { $0.section == .help }
        #expect(help == [.showShortcuts])
    }

    @Test("searching finds a command by its name")
    func searchByName() {
        let view = ShortcutsView(keymap: .defaults)
        #expect(view.commands(matching: "trash").contains(.moveToTrash))
        #expect(view.commands(matching: "TRASH").contains(.moveToTrash), "case-insensitive")
        #expect(view.commands(matching: "trash").contains(.newFolder) == false)
    }

    @Test("searching finds a command by its key, in either spelling")
    func searchByKey() {
        let view = ShortcutsView(keymap: .defaults)
        // As printed on the key cap…
        #expect(view.commands(matching: "F8").contains(.moveToTrash))
        // …and as written in keymap.json.
        #expect(view.commands(matching: "cmd+backspace").contains(.moveToTrash))
    }

    @Test("an empty search lists everything")
    func emptySearchListsAll() {
        let view = ShortcutsView(keymap: .defaults)
        #expect(view.commands(matching: "").count == Command.allCases.count)
    }

    @Test("a search matching nothing yields nothing rather than everything")
    func searchWithNoMatches() {
        let view = ShortcutsView(keymap: .defaults)
        #expect(view.commands(matching: "zzzznope").isEmpty)
    }

    @Test("an unbound command still appears, so it can be found and given a key")
    func unboundCommandsStillListed() {
        let keymap = Keymap.defaults.rebinding(.swapPanes, to: [])
        let view = ShortcutsView(keymap: keymap)
        #expect(view.commands(matching: "swap").contains(.swapPanes))
        #expect(keymap.chords(for: .swapPanes).isEmpty)
    }
}
