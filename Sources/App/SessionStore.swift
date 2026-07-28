import Foundation

/// What a pane looked like when the app last quit.
struct PanelSession: Codable, Sendable {
    var tabs: [PanelTab]
    var activeTabIndex: Int
}

struct Session: Codable, Sendable {
    var left: PanelSession
    var right: PanelSession
    var activeSide: AppState.Side
    var showHidden: Bool
}

/// Reads and writes the session file. Failure is always survivable: a missing or unreadable
/// session just means starting from the default directories.
enum SessionStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("session.json")
    }

    static func load(from url: URL = fileURL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session, to url: URL = fileURL) {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
