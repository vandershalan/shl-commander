import AppKit
import SwiftUI

extension KeyChord {
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }

    /// The SwiftUI equivalent, when AppKit can draw this key in a menu. Function keys and
    /// keypad keys return nil: they stay live through `KeyRouter` but carry no menu label.
    var keyEquivalent: KeyEquivalent? {
        Self.keyEquivalents[keyCode]
    }

    private static let keyEquivalents: [UInt16: KeyEquivalent] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u",
        34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8",
        29: "0",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
        47: ".", 50: "`",
        36: .return, 48: .tab, 49: .space, 51: .delete, 53: .escape,
        117: .deleteForward, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        123: .leftArrow, 124: .rightArrow, 125: .downArrow, 126: .upArrow,
    ]
}
