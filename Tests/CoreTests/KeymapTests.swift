import AppKit
import Testing

@testable import ShlCommander

@Suite("Keymap")
struct KeymapTests {
    @Test("every default binding parses, so the preconditions can never fire")
    func defaultsAreAllParseable() {
        // Constructing .defaults would already trap on a bad chord; this pins the
        // expectation and reports which command is at fault rather than crashing.
        let keymap = Keymap.defaults
        for command in Command.allCases {
            let chords = keymap.chords(for: command)
            #expect(!chords.isEmpty, "\(command.rawValue) has no default binding")
            for chord in chords {
                #expect(
                    KeyChord(parsing: chord.canonicalName) == chord,
                    "\(command.rawValue) chord \(chord.canonicalName) does not round-trip"
                )
            }
        }
    }

    @Test("no chord is claimed by two commands")
    func noDuplicateChords() {
        var owners: [KeyChord: [Command]] = [:]
        for command in Command.allCases {
            for chord in Keymap.defaults.chords(for: command) {
                owners[chord, default: []].append(command)
            }
        }
        let clashes = owners.filter { $0.value.count > 1 }
        for (chord, commands) in clashes {
            Issue.record("\(chord.canonicalName) is claimed by \(commands.map(\.rawValue))")
        }
        #expect(clashes.isEmpty)
    }

    /// Key codes a stock Mac cannot produce. F1-F12 need "use F-keys as standard function
    /// keys"; Insert exists only on full-size external keyboards.
    ///
    /// Listed explicitly rather than as a range: 96-122 also covers Home, End, Page Up,
    /// Page Down and the arrows, which every Mac keyboard has.
    private static let awkwardKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,  // F1-F12
        114,  // Insert
    ]

    @Test("no command is reachable only through a key a stock Mac cannot press")
    func everyCommandIsReachable() {
        for command in Command.allCases {
            let chords = Keymap.defaults.chords(for: command)
            guard !chords.isEmpty else { continue }
            guard chords.allSatisfy({ Self.awkwardKeyCodes.contains($0.keyCode) }) else {
                continue
            }
            let bindings = chords.map(\.canonicalName).joined(separator: ", ")
            Issue.record(
                Comment(
                    rawValue:
                        "\(command.rawValue) is only bound to keys a stock Mac cannot press: \(bindings)"
                )
            )
        }
    }

    @Test("resolves an event to its command")
    func lookup() throws {
        let keymap = Keymap.defaults
        let chord = try #require(keymap.chords(for: .swapPanes).first)
        #expect(chord.canonicalName == "ctrl+u")
        #expect(keymap.command(for: chord) == .swapPanes)
        #expect(keymap.command(for: KeyChord(parsing: "cmd+ctrl+opt+shift+q")!) == nil)
    }

    @Test("menuChord reports the ⌘ binding, which is all a menu can draw")
    func menuChords() {
        #expect(Keymap.defaults.menuChord(for: .refresh)?.canonicalName == "cmd+r")
        #expect(Keymap.defaults.menuChord(for: .sortByName)?.canonicalName == "cmd+opt+1")
        // markByPattern is keypad-only, so it appears in the menu without a shortcut.
        #expect(Keymap.defaults.menuChord(for: .markByPattern) == nil)
    }

    @Test("every ⌘ chord a menu shows can be expressed as a SwiftUI key equivalent")
    func menuChordsAreRenderable() {
        for command in Command.allCases {
            guard let chord = Keymap.defaults.menuChord(for: command) else { continue }
            #expect(
                chord.keyEquivalent != nil,
                Comment(rawValue: "\(command.rawValue): \(chord.canonicalName) has no menu key")
            )
        }
    }

    @Test("user overrides replace a command's bindings and leave the rest alone")
    func overridesReplace() throws {
        let json = Data(
            #"{"swapPanes": ["cmd+shift+s"], "refresh": ["f5"]}"#.utf8
        )
        let keymap = Keymap.merging(overrides: json)

        #expect(keymap.chords(for: .swapPanes).map(\.canonicalName) == ["cmd+shift+s"])
        #expect(keymap.command(for: KeyChord(parsing: "ctrl+u")!) == nil)  // old binding gone
        #expect(keymap.chords(for: .refresh).map(\.canonicalName) == ["f5"])
        // Untouched commands keep their defaults. Compared as a set because the binding
        // order within a command carries no meaning.
        #expect(Set(keymap.chords(for: .markAll).map(\.canonicalName)) == ["ctrl+a", "cmd+a"])
        #expect(keymap.warnings.isEmpty)
    }

    @Test("an empty array unbinds a command outright")
    func emptyArrayUnbinds() {
        let keymap = Keymap.merging(overrides: Data(#"{"swapPanes": []}"#.utf8))
        #expect(keymap.chords(for: .swapPanes).isEmpty)
        #expect(keymap.command(for: KeyChord(parsing: "ctrl+u")!) == nil)
    }

    @Test("bad entries are reported rather than silently dropped")
    func warnsOnBadInput() {
        let json = Data(
            #"{"notACommand": ["cmd+z"], "refresh": ["nope+f5"], "swapPanes": "cmd+s"}"#.utf8
        )
        let keymap = Keymap.merging(overrides: json)

        #expect(keymap.warnings.count == 3)
        #expect(keymap.warnings.contains { $0.contains("notACommand") })
        #expect(keymap.warnings.contains { $0.contains("nope+f5") })
        #expect(keymap.warnings.contains { $0.contains("array of strings") })
        // A rejected chord leaves the command bound to nothing rather than to the wrong key.
        #expect(keymap.chords(for: .refresh).isEmpty)
        // The malformed value leaves swapPanes on its default.
        #expect(keymap.chords(for: .swapPanes).map(\.canonicalName) == ["ctrl+u"])
    }

    @Test("keys beginning with an underscore are treated as comments")
    func underscoreKeysIgnored() {
        let keymap = Keymap.merging(overrides: Data(#"{"_comment": "hello"}"#.utf8))
        #expect(keymap.warnings.isEmpty)
    }

    @Test("malformed JSON falls back to the defaults with a warning")
    func malformedJSON() {
        let keymap = Keymap.merging(overrides: Data("not json at all".utf8))
        #expect(keymap.warnings.count == 1)
        #expect(keymap.command(for: KeyChord(parsing: "ctrl+u")!) == .swapPanes)
    }
}
