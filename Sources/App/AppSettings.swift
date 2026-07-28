import AppKit
import Observation

/// User preferences, stored in `UserDefaults`.
///
/// Wrapped in an observable object rather than read through `@AppStorage` at each use site so
/// non-view code — `AppState.start()`, the dispatcher — can read the same values.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.restoreSession: true,
            Key.showHiddenByDefault: false,
        ])
    }

    private enum Key {
        static let restoreSession = "restoreSession"
        static let showHiddenByDefault = "showHiddenByDefault"
        static let editorBundleIdentifier = "editorBundleIdentifier"
        static let leftStartDirectory = "leftStartDirectory"
        static let rightStartDirectory = "rightStartDirectory"
    }

    /// When off, both panes open at the configured start directories instead.
    var restoreSession: Bool {
        get { defaults.bool(forKey: Key.restoreSession) }
        set { defaults.set(newValue, forKey: Key.restoreSession) }
    }

    var showHiddenByDefault: Bool {
        get { defaults.bool(forKey: Key.showHiddenByDefault) }
        set { defaults.set(newValue, forKey: Key.showHiddenByDefault) }
    }

    /// Bundle identifier used by F4. Empty means "whatever the system would open it with".
    var editorBundleIdentifier: String {
        get { defaults.string(forKey: Key.editorBundleIdentifier) ?? "" }
        set {
            defaults.set(
                newValue.isEmpty ? nil : newValue, forKey: Key.editorBundleIdentifier)
        }
    }

    var editorName: String {
        guard !editorBundleIdentifier.isEmpty,
            let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: editorBundleIdentifier)
        else { return "System default" }
        return url.deletingPathExtension().lastPathComponent
    }

    var leftStartDirectory: String {
        get { defaults.string(forKey: Key.leftStartDirectory) ?? Self.home }
        set { defaults.set(newValue, forKey: Key.leftStartDirectory) }
    }

    var rightStartDirectory: String {
        get { defaults.string(forKey: Key.rightStartDirectory) ?? Self.home }
        set { defaults.set(newValue, forKey: Key.rightStartDirectory) }
    }

    private static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    func startURL(forLeft left: Bool) -> URL {
        let path = left ? leftStartDirectory : rightStartDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: path)
    }
}
