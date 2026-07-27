import AppKit
import Testing

@testable import ShlCommander

@Suite("KeyChord")
struct KeyChordTests {
    @Test("parses modifiers and key names, in any order and any case")
    func parsing() throws {
        let shiftF6 = try #require(KeyChord(parsing: "shift+f6"))
        #expect(shiftF6.keyCode == 97)
        #expect(shiftF6.modifiers == .shift)

        let commandK = try #require(KeyChord(parsing: "CMD+K"))
        #expect(commandK.keyCode == 40)
        #expect(commandK.modifiers == .command)

        let busy = try #require(KeyChord(parsing: "cmd+ctrl+opt+shift+a"))
        #expect(busy.modifiers == [.command, .control, .option, .shift])

        // "alt" and "option", "control" and "ctrl" are interchangeable.
        #expect(KeyChord(parsing: "alt+left") == KeyChord(parsing: "option+left"))
        #expect(KeyChord(parsing: "ctrl+r") == KeyChord(parsing: "control+r"))
    }

    @Test("rejects unknown keys and unknown modifiers instead of guessing")
    func rejectsGarbage() {
        #expect(KeyChord(parsing: "f13") == nil)  // not in the table
        #expect(KeyChord(parsing: "meta+k") == nil)
        #expect(KeyChord(parsing: "") == nil)
        #expect(KeyChord(parsing: "+") == nil)
        #expect(KeyChord(parsing: "cmd+") == nil)
    }

    @Test("canonical names round-trip back to the same chord")
    func roundTrip() throws {
        let samples = [
            "shift+f6", "cmd+k", "ctrl+f3", "opt+left", "space", "return", "backspace",
            "escape", "tab", "keypadplus", "keypadminus", "keypadmultiply", "home", "end",
            "pageup", "pagedown", "up", "down", "cmd+shift+period", "ctrl+backslash",
            "cmd+leftbracket", "insert",
        ]
        for sample in samples {
            let chord = try #require(KeyChord(parsing: sample), "failed to parse \(sample)")
            let reparsed = try #require(KeyChord(parsing: chord.canonicalName))
            #expect(reparsed == chord, "\(sample) canonicalised to \(chord.canonicalName)")
        }
    }

    @Test("modifiers that AppKit sets implicitly are not part of a binding")
    func implicitModifiersIgnored() {
        // Arrows arrive with .function and .numericPad set; a binding for "up" must still
        // match, or no arrow key would ever resolve.
        let plainUp = KeyChord(126, [])
        let decoratedUp = KeyChord(126, [.function, .numericPad])
        #expect(plainUp == decoratedUp)

        // Caps Lock likewise must not break a binding.
        #expect(KeyChord(0, [.capsLock]) == KeyChord(0, []))
    }

    @Test("display names read like macOS menu shortcuts")
    func displayNames() throws {
        #expect(try #require(KeyChord(parsing: "cmd+k")).displayName == "⌘K")
        #expect(try #require(KeyChord(parsing: "shift+f6")).displayName == "⇧F6")
        #expect(try #require(KeyChord(parsing: "cmd+shift+a")).displayName == "⇧⌘A")
        #expect(try #require(KeyChord(parsing: "opt+left")).displayName == "⌥←")
        #expect(try #require(KeyChord(parsing: "backspace")).displayName == "⌫")
    }
}
