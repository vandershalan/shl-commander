import AppKit

/// A key plus its modifiers, identified by hardware key code rather than by character.
///
/// Key codes are essential here: `⌥←` and `⌥⇧↩` arrive as composed or dead-key characters,
/// and `⇧6` is `^` on a US layout but something else elsewhere. A key code says which
/// physical key was pressed and nothing more.
struct KeyChord: Hashable, Sendable {
    let keyCode: UInt16
    /// Stored raw so `Hashable` and `Codable` come for free.
    let modifierRawValue: UInt

    /// Modifiers a binding may specify. `.function` and `.numericPad` are excluded because
    /// AppKit sets them implicitly for arrows and keypad keys.
    static let significant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    init(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        self.keyCode = keyCode
        self.modifierRawValue = modifiers.intersection(Self.significant).rawValue
    }

    init(event: NSEvent) {
        self.init(
            event.keyCode,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }
}

// MARK: - Key names

extension KeyChord {
    /// Virtual key codes, which are layout-independent. Values come from
    /// `Carbon/HIToolbox/Events.h` (`kVK_*`).
    static let keyCodesByName: [String: UInt16] = [
        // Letters
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        // Digits
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28,
        "0": 29,
        // Punctuation
        "equal": 24, "minus": 27, "rightbracket": 30, "leftbracket": 33, "quote": 39,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "period": 47,
        "grave": 50,
        // Editing and navigation
        "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53,
        "forwarddelete": 117, "help": 114, "insert": 114,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        // Keypad. Spelled out rather than "num+" so that '+' never has to be both a
        // separator and a key name.
        "keypadenter": 76, "keypadplus": 69, "keypadminus": 78,
        "keypadmultiply": 67, "keypaddivide": 75, "keypadclear": 71,
        // Function keys
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    private static let namesByKeyCode: [UInt16: String] = {
        var result: [UInt16: String] = [:]
        for (name, code) in keyCodesByName where result[code] == nil || name.count < result[code]!.count {
            result[code] = name
        }
        // "insert" and "help" share a code; prefer the label on a full-size keyboard.
        result[114] = "insert"
        return result
    }()

    private static let modifierNames: [(String, NSEvent.ModifierFlags)] = [
        ("cmd", .command), ("command", .command),
        ("ctrl", .control), ("control", .control),
        ("opt", .option), ("option", .option), ("alt", .option),
        ("shift", .shift),
    ]

    /// Parses `"shift+f6"`, `"cmd+k"`, `"ctrl+keypadplus"`. Returns nil on an unknown name so
    /// a typo in a user keymap is reported rather than silently binding the wrong key.
    init?(parsing text: String) {
        let tokens = text.lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = tokens.last, !keyName.isEmpty else { return nil }
        guard let code = Self.keyCodesByName[keyName] else { return nil }

        var flags: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            guard let match = Self.modifierNames.first(where: { $0.0 == token }) else {
                return nil
            }
            flags.insert(match.1)
        }
        self.init(code, flags)
    }

    /// Canonical keymap spelling, e.g. `"shift+f6"`.
    var canonicalName: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(Self.namesByKeyCode[keyCode] ?? "key\(keyCode)")
        return parts.joined(separator: "+")
    }

    /// How macOS would draw it in a menu, e.g. `"⇧F6"`.
    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + Self.symbol(for: keyCode)
    }

    /// Punctuation is named in a keymap file (`period`, `leftbracket`) but has to be *drawn* as
    /// the character itself: "⌘Slash" and "⇧⌘Period" are not how a Mac labels ⌘/ and ⇧⌘.
    private static let punctuationSymbols: [UInt16: String] = [
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/",
        47: ".", 50: "`",
    ]

    private static func symbol(for keyCode: UInt16) -> String {
        if let punctuation = punctuationSymbols[keyCode] { return punctuation }
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let name = namesByKeyCode[keyCode] ?? "key\(keyCode)"
            return name.count == 1 ? name.uppercased() : name.capitalized
        }
    }
}
