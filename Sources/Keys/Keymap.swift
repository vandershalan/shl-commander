import AppKit

/// Chord-to-command bindings, built from the shipped defaults and then overridden by the
/// user's `keymap.json`.
struct Keymap: Sendable {
    /// One command may answer to several chords: the Total Commander key and its ⌘ twin.
    private(set) var chordsByCommand: [Command: [KeyChord]]
    private var commandsByChord: [KeyChord: Command]

    /// Problems found while merging a user keymap, surfaced rather than swallowed so a typo
    /// does not silently leave a key unbound.
    private(set) var warnings: [String] = []

    init(_ chordsByCommand: [Command: [KeyChord]]) {
        self.chordsByCommand = chordsByCommand
        self.commandsByChord = Self.invert(chordsByCommand)
    }

    private static func invert(_ input: [Command: [KeyChord]]) -> [KeyChord: Command] {
        var result: [KeyChord: Command] = [:]
        // Sorted so that when two commands claim the same chord the winner is deterministic
        // rather than dependent on dictionary order.
        for command in input.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            for chord in input[command] ?? [] where result[chord] == nil {
                result[chord] = command
            }
        }
        return result
    }

    func command(for chord: KeyChord) -> Command? {
        commandsByChord[chord]
    }

    func command(for event: NSEvent) -> Command? {
        command(for: KeyChord(event: event))
    }

    func chords(for command: Command) -> [KeyChord] {
        chordsByCommand[command] ?? []
    }

    /// The ⌘ chord for a command, if it has one. Menu items show only these, because that is
    /// what AppKit can render as a key equivalent.
    func menuChord(for command: Command) -> KeyChord? {
        chords(for: command).first { $0.modifiers.contains(.command) }
    }
}

// MARK: - Defaults

extension Keymap {
    /// Total Commander's keys, each paired with a ⌘ twin.
    ///
    /// The twins are not a luxury: macOS maps F1–F12 to brightness and media unless "Use
    /// F1, F2, etc. keys as standard function keys" is on, so without them a stock Mac
    /// could not drive the app at all.
    static let defaults = Keymap([
        .showShortcuts: [chord("f1"), chord("cmd+slash")],
        .quickLook: [chord("f3"), chord("cmd+y")],
        .viewInternal: [chord("opt+f3"), chord("cmd+shift+y")],
        .editFile: [chord("f4"), chord("cmd+e")],
        .newFolder: [chord("f7"), chord("cmd+shift+n")],
        .newFile: [chord("shift+f4"), chord("cmd+shift+f")],
        .copyToOtherPane: [chord("f5"), chord("cmd+c")],
        .moveToOtherPane: [chord("f6"), chord("cmd+m")],
        .duplicate: [chord("shift+f5"), chord("cmd+d")],
        .renameInPlace: [chord("shift+f6"), chord("cmd+return")],
        // ⌘⌫ is what the Finder uses, so the muscle memory transfers either way.
        .moveToTrash: [chord("f8"), chord("cmd+backspace")],
        .deletePermanently: [chord("shift+f8"), chord("cmd+shift+backspace")],
        // Total Commander packs with ⌥F5 and unpacks with ⌥F9; ⌘I is the Finder's info panel.
        .createArchive: [chord("opt+f5"), chord("cmd+shift+p")],
        .unpackArchive: [chord("opt+f9"), chord("cmd+shift+u")],
        .getInfo: [chord("opt+return"), chord("cmd+i")],

        .switchPane: [chord("tab")],
        .openCursor: [chord("return"), chord("keypadenter")],
        .goUp: [chord("backspace"), chord("ctrl+pageup"), chord("cmd+up")],
        .goToVolumeRoot: [chord("ctrl+backslash")],
        .historyBack: [chord("opt+left"), chord("cmd+leftbracket")],
        .historyForward: [chord("opt+right"), chord("cmd+rightbracket")],
        .refresh: [chord("f2"), chord("ctrl+r"), chord("cmd+r")],
        // ⌘K is what the Finder uses for the same dialog.
        .connectToServer: [chord("cmd+k")],

        // ⌘⌥1-4 mirror the column order, so sorting stays reachable when F-keys are still
        // wired to brightness and media.
        .sortByName: [chord("ctrl+f3"), chord("cmd+opt+1")],
        .sortByExtension: [chord("ctrl+f4"), chord("cmd+opt+2")],
        .sortByDate: [chord("ctrl+f5"), chord("cmd+opt+3")],
        .sortBySize: [chord("ctrl+f6"), chord("cmd+opt+4")],
        .toggleHidden: [chord("ctrl+h"), chord("cmd+shift+period")],
        .clearFilter: [chord("escape")],
        .measureSelectedDirectories: [chord("ctrl+l"), chord("cmd+l")],
        .measureAllDirectories: [chord("opt+shift+return"), chord("cmd+shift+l")],
        // The Mac's own zoom keys. ⌘+ is ⇧⌘= on most layouts, so both spellings are bound —
        // the menu shows ⌘=, which is what AppKit can draw as a key equivalent.
        .zoomIn: [chord("cmd+equal"), chord("cmd+shift+equal")],
        .zoomOut: [chord("cmd+minus")],
        .resetZoom: [chord("cmd+0")],

        .markToggle: [chord("space")],
        // Most Mac keyboards have no Insert key, so ⇧Space carries the same meaning.
        .markToggleAndAdvance: [chord("insert"), chord("shift+space")],
        .markByPattern: [chord("keypadplus")],
        .unmarkByPattern: [chord("keypadminus")],
        .invertMarks: [chord("keypadmultiply")],
        .markAll: [chord("ctrl+a"), chord("cmd+a")],
        .markNone: [chord("ctrl+shift+a"), chord("cmd+shift+a")],

        .newTab: [chord("ctrl+t"), chord("cmd+t")],
        .closeTab: [chord("ctrl+w"), chord("cmd+w")],
        .nextTab: [chord("ctrl+tab"), chord("cmd+shift+rightbracket")],
        .previousTab: [chord("ctrl+shift+tab"), chord("cmd+shift+leftbracket")],
        .openInOtherPaneTab: [chord("ctrl+up")],

        .addFavorite: [chord("cmd+shift+d")],
        .showFavorites: [chord("ctrl+d"), chord("cmd+b")],
        .favorite1: [chord("cmd+1")],
        .favorite2: [chord("cmd+2")],
        .favorite3: [chord("cmd+3")],
        .favorite4: [chord("cmd+4")],
        .favorite5: [chord("cmd+5")],
        .favorite6: [chord("cmd+6")],
        .favorite7: [chord("cmd+7")],
        .favorite8: [chord("cmd+8")],
        .favorite9: [chord("cmd+9")],

        .sendPathToOtherPane: [chord("ctrl+shift+right")],
        .takePathFromOtherPane: [chord("ctrl+shift+left")],
        .swapPanes: [chord("ctrl+u")],

        .openInTerminal: [chord("cmd+shift+t")],
        .revealInFinder: [chord("cmd+shift+r")],
        .copyPathToClipboard: [chord("ctrl+shift+return"), chord("cmd+opt+c")],
    ])

    /// Force-unwraps because these are compile-time constants covered by
    /// `KeymapTests.defaultsAreAllParseable`.
    private static func chord(_ text: String) -> KeyChord {
        guard let chord = KeyChord(parsing: text) else {
            preconditionFailure("Malformed default binding: \(text)")
        }
        return chord
    }
}

// MARK: - User overrides

extension Keymap {
    /// `{"copy": ["f5", "cmd+c"], "swapPanes": []}` — an empty array unbinds a command.
    /// Commands the file does not mention keep their defaults, so the file only ever needs
    /// to hold the differences.
    static func merging(defaults: Keymap = .defaults, overrides json: Data) -> Keymap {
        var chords = defaults.chordsByCommand
        var warnings: [String] = []

        guard let raw = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            var result = defaults
            result.warnings = ["keymap.json is not a JSON object; using defaults."]
            return result
        }

        for (name, value) in raw {
            // Lets the file carry a "_comment" key without tripping the unknown-command path.
            guard !name.hasPrefix("_") else { continue }
            guard let command = Command(rawValue: name) else {
                warnings.append("Unknown command \u{22}\(name)\u{22} ignored.")
                continue
            }
            guard let names = value as? [String] else {
                warnings.append("Binding for \u{22}\(name)\u{22} must be an array of strings.")
                continue
            }

            var parsed: [KeyChord] = []
            for text in names {
                guard let chord = KeyChord(parsing: text) else {
                    warnings.append("Unrecognised key \u{22}\(text)\u{22} for \u{22}\(name)\u{22}.")
                    continue
                }
                parsed.append(chord)
            }
            chords[command] = parsed
        }

        var result = Keymap(chords)
        result.warnings = warnings
        return result
    }

    /// `~/Library/Application Support/shl-commander/keymap.json`
    static var userKeymapURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("keymap.json")
    }

    /// Defaults when the file is absent, which is the normal case.
    static func loadFromDisk() -> Keymap {
        guard let data = try? Data(contentsOf: userKeymapURL) else { return .defaults }
        return merging(overrides: data)
    }

    /// The full binding table as JSON. Every command is written out, not just the differences,
    /// so the exported file doubles as a reference of what is bindable.
    func exportJSON() -> Data? {
        var object: [String: Any] = [
            "_comment": "Edit and relaunch. An empty array unbinds a command."
        ]
        for command in Command.allCases {
            object[command.rawValue] = chords(for: command).map(\.canonicalName)
        }
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    @discardableResult
    func writeToDisk() -> Bool {
        guard AppPaths.ensureSupportDirectory() != nil, let data = exportJSON() else {
            return false
        }
        return (try? data.write(to: Self.userKeymapURL, options: .atomic)) != nil
    }

    /// Replaces one command's bindings, dropping the chord from any command that already
    /// claimed it — two commands on one key would make the winner arbitrary.
    func rebinding(_ command: Command, to chords: [KeyChord]) -> Keymap {
        var table = chordsByCommand
        for chord in chords {
            for (other, existing) in table where other != command {
                table[other] = existing.filter { $0 != chord }
            }
        }
        table[command] = chords
        return Keymap(table)
    }
}

/// Where the app keeps its own files.
enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("shl-commander", isDirectory: true)
    }

    /// Creates the support directory on demand. Returns nil when it cannot be created, so
    /// callers degrade to defaults instead of crashing.
    @discardableResult
    static func ensureSupportDirectory() -> URL? {
        let url = supportDirectory
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }
}
