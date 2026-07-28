import Foundation

@testable import ShlCommander

/// Throwaway directory tree for filesystem tests. Removed when the test's `defer` fires.
struct TempTree {
    let root: URL

    init(_ label: String = "tree") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shl-commander-tests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Settings backed by a throwaway defaults domain, with session restore off so a real
/// `session.json` on the machine cannot leak into a test.
@MainActor
func isolatedSettings(_ label: String = "test") -> AppSettings {
    let suite = "shl-commander.tests.\(label).\(UUID().uuidString)"
    let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
    settings.restoreSession = false
    return settings
}
