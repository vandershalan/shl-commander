import Observation
import SwiftUI

/// A fragment of a path and the colour folders matching it are drawn in.
struct PathColorRule: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    /// Matched anywhere in the path, ignoring case. A leading `~` stands for the home folder.
    var pattern: String
    var color: PaletteColor

    init(id: UUID = UUID(), pattern: String, color: PaletteColor) {
        self.id = id
        self.pattern = pattern
        self.color = color
    }

    func matches(_ path: String) -> Bool {
        let needle = Self.expandingTilde(pattern.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return false }
        return path.range(of: needle, options: .caseInsensitive) != nil
    }

    private static func expandingTilde(_ pattern: String) -> String {
        guard pattern.hasPrefix("~") else { return pattern }
        return FileManager.default.homeDirectoryForCurrentUser.path + pattern.dropFirst()
    }
}

/// Colours for favourites, tabs and the path bar, keyed by path fragment and persisted as
/// JSON in the app's support directory. The first rule from the top that matches wins.
@MainActor
@Observable
final class PathColorStore {
    private(set) var rules: [PathColorRule] = []

    /// Overridable so tests do not touch the real file.
    private let fileURL: URL

    /// With no file yet, the list starts out as one rule per favourite — deepest first, so a
    /// favourite inside another still gets its own colour. Nothing is written until the user
    /// changes something.
    init(
        fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("pathcolors.json"),
        seedingFrom favorites: [Favorite] = []
    ) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            rules = (try? JSONDecoder().decode([PathColorRule].self, from: data)) ?? []
        } else {
            rules = Self.seed(from: favorites)
        }
    }

    static func seed(from favorites: [Favorite]) -> [PathColorRule] {
        favorites
            .sorted { $0.path.count > $1.path.count }
            .enumerated()
            .map { index, favorite in
                PathColorRule(
                    pattern: favorite.path,
                    color: PaletteColor.rotation[index % PaletteColor.rotation.count]
                )
            }
    }

    func color(for path: String) -> PaletteColor? {
        rules.first { $0.matches(path) }?.color
    }

    // MARK: - Mutation

    @discardableResult
    func add(pattern: String = "") -> PathColorRule {
        let rule = PathColorRule(
            pattern: pattern,
            color: PaletteColor.rotation[rules.count % PaletteColor.rotation.count]
        )
        rules.append(rule)
        save()
        return rule
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func update(_ rule: PathColorRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Throws the list away and starts again from the favourites.
    func reset(from favorites: [Favorite]) {
        rules = Self.seed(from: favorites)
        save()
    }

    // MARK: - Persistence

    private func save() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension PathColorStore {
    /// Fill behind a path bar, and behind the tab that owns it, so the two read as one shape.
    /// A folder no rule matches keeps the plain look: tinted with the accent when active.
    func barFill(for path: String, isActive: Bool) -> Color {
        guard let color = color(for: path) else {
            return isActive ? Color.accentColor.opacity(0.18) : Color.clear
        }
        return color.color.opacity(isActive ? 0.45 : 0.28)
    }
}
