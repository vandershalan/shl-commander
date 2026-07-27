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

    /// - Parameter directorySizes: measured directory sizes, so a size sort can order folders
    ///   that have been measured. Unmeasured folders have no size to compare and stay grouped
    ///   together, ahead of the measured ones.
    func sorted(_ entries: [FileEntry], directorySizes: [URL: Int64] = [:]) -> [FileEntry] {
        entries.sorted { precedes($0, $1, directorySizes: directorySizes) }
    }

    func precedes(
        _ a: FileEntry,
        _ b: FileEntry,
        directorySizes: [URL: Int64] = [:]
    ) -> Bool {
        if a.isParent != b.isParent { return a.isParent }
        if directoriesFirst, a.isDirectory != b.isDirectory { return a.isDirectory }

        switch primary(a, b, directorySizes: directorySizes) {
        case .orderedAscending: return ascending
        case .orderedDescending: return !ascending
        case .orderedSame:
            // Stable, direction-independent tiebreak so equal sizes/dates keep a
            // predictable A-Z order in both directions.
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func primary(
        _ a: FileEntry,
        _ b: FileEntry,
        directorySizes: [URL: Int64]
    ) -> ComparisonResult {
        switch key {
        case .name:
            return a.name.localizedStandardCompare(b.name)
        case .ext:
            return a.ext.localizedStandardCompare(b.ext)
        case .size:
            return Self.compare(
                effectiveSize(of: a, directorySizes: directorySizes),
                effectiveSize(of: b, directorySizes: directorySizes)
            )
        case .date:
            return a.modified.compare(b.modified)
        }
    }

    /// A measured directory sorts by its measured size. An unmeasured one has no size at all,
    /// so it sorts as -1: all unmeasured folders group together rather than pretending to be
    /// empty and interleaving with genuinely empty files.
    private func effectiveSize(of entry: FileEntry, directorySizes: [URL: Int64]) -> Int64 {
        guard entry.isDirectory else { return entry.size }
        return directorySizes[entry.url] ?? -1
    }

    private static func compare(_ a: Int64, _ b: Int64) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return .orderedSame
    }
}
