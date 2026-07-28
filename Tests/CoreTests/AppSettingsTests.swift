import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {
    /// An isolated defaults domain, so tests never disturb the real preferences.
    private func settings(_ label: String) -> (AppSettings, UserDefaults, String) {
        let suite = "shl-commander.tests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test("session restore is on out of the box")
    func defaultsAreSensible() {
        let (settings, _, suite) = settings("defaults")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(settings.restoreSession)
        #expect(settings.showHiddenByDefault == false)
        #expect(settings.editorBundleIdentifier.isEmpty)
        #expect(settings.editorName == "System default")
    }

    @Test("start directories default to the home folder")
    func startDirectoriesDefault() {
        let (settings, _, suite) = settings("start")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(settings.leftStartDirectory == home)
        #expect(settings.startURL(forLeft: true).path == home)
    }

    @Test("a start directory that has gone falls back to home")
    func missingStartDirectory() {
        let (settings, _, suite) = settings("missing")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.leftStartDirectory = "/definitely-not-here-\(UUID().uuidString)"
        #expect(
            settings.startURL(forLeft: true).path
                == FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    @Test("a file is not accepted as a start directory")
    func fileIsNotAStartDirectory() throws {
        let tree = try TempTree("settings-file")
        defer { tree.remove() }
        let (settings, _, suite) = settings("file")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.rightStartDirectory = try tree.file("notes.txt", bytes: 1).path
        #expect(
            settings.startURL(forLeft: false).path
                == FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    @Test("values persist to the defaults domain")
    func persistence() {
        let (settings, defaults, suite) = settings("persist")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        settings.showHiddenByDefault = true
        settings.editorBundleIdentifier = "com.example.editor"
        #expect(defaults.bool(forKey: "showHiddenByDefault"))
        #expect(defaults.string(forKey: "editorBundleIdentifier") == "com.example.editor")

        // Clearing the editor removes the key rather than storing an empty string.
        settings.editorBundleIdentifier = ""
        #expect(defaults.string(forKey: "editorBundleIdentifier") == nil)
    }
}

@Suite("Keymap editing")
struct KeymapEditingTests {
    @Test("rebinding replaces a command's chords")
    func rebind() throws {
        let chord = try #require(KeyChord(parsing: "cmd+shift+s"))
        let keymap = Keymap.defaults.rebinding(.swapPanes, to: [chord])

        #expect(keymap.chords(for: .swapPanes) == [chord])
        #expect(keymap.command(for: chord) == .swapPanes)
        #expect(keymap.command(for: KeyChord(parsing: "ctrl+u")!) == nil)
    }

    @Test("taking a key from another command unbinds it there")
    func stealsChordFromOtherCommand() throws {
        // ⌘R belongs to Refresh; giving it to Swap Panes must not leave both claiming it,
        // or which one wins would come down to dictionary order.
        let chord = try #require(KeyChord(parsing: "cmd+r"))
        #expect(Keymap.defaults.command(for: chord) == .refresh)

        let keymap = Keymap.defaults.rebinding(.swapPanes, to: [chord])
        #expect(keymap.command(for: chord) == .swapPanes)
        #expect(keymap.chords(for: .refresh).contains(chord) == false)
        // Refresh keeps its other bindings.
        #expect(keymap.chords(for: .refresh).isEmpty == false)
    }

    @Test("rebinding to nothing clears a command")
    func clearBindings() {
        let keymap = Keymap.defaults.rebinding(.swapPanes, to: [])
        #expect(keymap.chords(for: .swapPanes).isEmpty)
    }

    @Test("the exported file lists every command and reloads to the same map")
    func exportRoundTrips() throws {
        let chord = try #require(KeyChord(parsing: "cmd+shift+s"))
        let original = Keymap.defaults.rebinding(.swapPanes, to: [chord])
        let data = try #require(original.exportJSON())

        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        for command in Command.allCases {
            #expect(object[command.rawValue] != nil, "\(command.rawValue) is missing")
        }

        let reloaded = Keymap.merging(overrides: data)
        #expect(reloaded.warnings.isEmpty)
        for command in Command.allCases {
            #expect(
                Set(reloaded.chords(for: command)) == Set(original.chords(for: command)),
                Comment(rawValue: "\(command.rawValue) did not round-trip")
            )
        }
    }
}
