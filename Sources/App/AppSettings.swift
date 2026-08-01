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
            Key.uiScale: UIScale.standard.factor,
        ])
        self.uiScale = Self.clamped(defaults.double(forKey: Key.uiScale))
    }

    private enum Key {
        static let restoreSession = "restoreSession"
        static let showHiddenByDefault = "showHiddenByDefault"
        static let editorBundleIdentifier = "editorBundleIdentifier"
        static let leftStartDirectory = "leftStartDirectory"
        static let rightStartDirectory = "rightStartDirectory"
        static let uiScale = "uiScale"
    }

    /// Interface zoom, driven by ⌘+, ⌘- and ⌘0.
    ///
    /// Stored rather than read straight back out of `UserDefaults` like the settings above:
    /// `@Observable` only tracks stored properties, and the whole window has to redraw the
    /// moment this changes.
    var uiScale: Double {
        didSet {
            let clamped = Self.clamped(uiScale)
            guard clamped == uiScale else {
                uiScale = clamped
                return
            }
            defaults.set(uiScale, forKey: Key.uiScale)
        }
    }

    /// A factor outside the step range — hand-edited into the defaults, or written by an
    /// older build — is pulled back to the nearest end rather than honoured.
    private static func clamped(_ factor: Double) -> Double {
        guard factor > 0 else { return UIScale.standard.factor }
        return min(max(factor, UIScale.minimum), UIScale.maximum)
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
