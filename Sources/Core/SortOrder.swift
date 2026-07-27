import Foundation

enum SortKey: String, CaseIterable, Codable, Sendable {
    case name, ext, size, date

    var columnIdentifier: String { rawValue }
}

/// Panel sort state. Directories group ahead of files the way Total Commander does,
/// and the `..` row always wins regardless of key or direction.
struct SortOrder: Equatable, Codable, Sendable {
    var key: SortKey = .name
    var ascending: Bool = true
    var directoriesFirst: Bool = true

    /// Selecting the key that is already active reverses the direction instead.
    func toggled(to newKey: SortKey) -> SortOrder {
        var copy = self
        if key == newKey {
            copy.ascending.toggle()
        } else {
            copy.key = newKey
            copy.ascending = true
        }
        return copy
    }

    func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted(by: precedes)
    }

    func precedes(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if a.isParent != b.isParent { return a.isParent }
        if directoriesFirst, a.isDirectory != b.isDirectory { return a.isDirectory }

        switch primary(a, b) {
        case .orderedAscending: return ascending
        case .orderedDescending: return !ascending
        case .orderedSame:
            // Stable, direction-independent tiebreak so equal sizes/dates keep a
            // predictable A-Z order in both directions.
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func primary(_ a: FileEntry, _ b: FileEntry) -> ComparisonResult {
        switch key {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .ext:
            return a.ext.localizedStandardCompare(b.ext)
        case .size:
            // Directories carry no size yet, so they only order among themselves by name.
            if a.isDirectory, b.isDirectory { return .orderedSame }
            return Self.compare(a.size, b.size)
        case .date:
            return a.modified.compare(b.modified)
        }
    }

    private static func compare(_ a: Int64, _ b: Int64) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }
}
