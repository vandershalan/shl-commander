import AppKit
import Observation

/// An application the user picked to open something with.
///
/// Stored by path rather than by bundle identifier: the path is what the user chose, it reads
/// as itself in a hand-edited file, and two builds of one app (a beta beside a release) have
/// the same identifier but are not the same choice.
struct OpenWithApp: Codable, Identifiable, Hashable, Sendable {
    var path: String
    var name: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    init(url: URL) {
        self.path = url.standardizedFileURL.path
        self.name = url.deletingPathExtension().lastPathComponent
    }
}

/// The apps offered under "Open With", remembered across launches.
///
/// macOS only suggests apps that *claim* a type, and no editor claims `public.folder` — Cursor,
/// IntelliJ and iTerm all open a directory perfectly well but none of them advertise it. So the
/// user's own choices are kept here and offered alongside the system's suggestions.
@MainActor
@Observable
final class OpenWithStore {
    static let shared = OpenWithStore()

    private(set) var apps: [OpenWithApp] = []

    /// Most recent first, capped: this is a menu, not a history.
    private static let limit = 12

    private let fileURL: URL

    init(
        fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("openwith.json"),
        seedingFrom searchPaths: [URL] = OpenWithStore.applicationFolders
    ) {
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // First run: the editors and terminals that are actually installed go in, so Open
            // With is useful before the user has taught it anything. The file is written even
            // when nothing is found, which is what stops a list the user emptied on purpose
            // from filling itself back up.
            apps = Self.installedDeveloperApps(in: searchPaths)
            save()
            return
        }
        load()
    }

    static var applicationFolders: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Apps worth offering a folder to, in the order they should appear.
    ///
    /// Matched by name rather than by bundle identifier: JetBrains ships a dozen IDEs with
    /// versioned identifiers, and "IntelliJ IDEA.app" is both stabler and easier to read here.
    /// Everything a developer would drag a folder onto is a fair candidate.
    static let seedNames = [
        "Cursor", "Visual Studio Code", "Zed", "Sublime Text", "IntelliJ IDEA",
        "IntelliJ IDEA Ultimate", "IntelliJ IDEA CE", "PyCharm", "WebStorm", "GoLand",
        "DataGrip", "Android Studio", "Xcode", "iTerm", "Warp", "Ghostty", "Alacritty",
        "Terminal",
    ]

    static func installedDeveloperApps(in folders: [URL]) -> [OpenWithApp] {
        var found: [OpenWithApp] = []
        for name in seedNames {
            for folder in folders {
                let candidate = folder.appendingPathComponent("\(name).app")
                guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
                found.append(OpenWithApp(url: candidate))
                break
            }
            if found.count >= limit { break }
        }
        return found
    }

    /// Remembers an app, moving it to the front when it was already known — the last thing used
    /// is the likeliest next choice.
    @discardableResult
    func remember(_ applicationURL: URL) -> OpenWithApp {
        let app = OpenWithApp(url: applicationURL)
        apps.removeAll { $0.path == app.path }
        apps.insert(app, at: 0)
        if apps.count > Self.limit { apps.removeLast(apps.count - Self.limit) }
        save()
        return app
    }

    func remove(_ app: OpenWithApp) {
        apps.removeAll { $0.path == app.path }
        save()
    }

    /// Remembered apps that are still installed. An app that has been deleted is kept in the
    /// file rather than pruned, so reinstalling it brings the entry back.
    var available: [OpenWithApp] { apps.filter(\.exists) }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        apps = (try? JSONDecoder().decode([OpenWithApp].self, from: data)) ?? []
    }

    private func save() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(apps) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
