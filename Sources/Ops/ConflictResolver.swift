import Foundation

/// Decides where a source should land. Pure, with existence probed through a closure, so the
/// whole decision matrix is testable without touching a disk.
enum ConflictResolver {
    /// What the engine should do with one source.
    enum Plan: Equatable, Sendable {
        case skip
        /// Remove whatever is at the URL, then write.
        case overwrite(URL)
        /// Nothing is in the way; write directly.
        case write(URL)

        /// Where the item will land, or nil when nothing will be written.
        var target: URL? {
            switch self {
            case .skip: return nil
            case .overwrite(let url), .write(let url): return url
            }
        }
    }

    /// Why an operation cannot even be attempted.
    enum Rejection: Equatable, Sendable {
        case destinationInsideSource
        case sameLocation

        var message: String {
            switch self {
            case .destinationInsideSource:
                return "The destination is inside the folder being copied."
            case .sameLocation:
                return "The source and destination are the same."
            }
        }
    }

    /// Refuses to copy a folder into itself or into its own descendant, which would recurse
    /// forever on the slow path.
    ///
    /// Checked against the destination *directory*, before any name is chosen: containment
    /// does not depend on what the copy ends up being called.
    static func rejectContainment(source: URL, destinationDirectory: URL) -> Rejection? {
        let sourcePath = source.standardizedFileURL.path
        let directoryPath = destinationDirectory.standardizedFileURL.path

        // Copying "X" into "X" would produce "X/X" and enumerate what it is writing.
        if directoryPath == sourcePath { return .destinationInsideSource }
        // Compared with a trailing separator so "/a/bc" is not read as being inside "/a/b".
        if directoryPath.hasPrefix(sourcePath + "/") { return .destinationInsideSource }
        return nil
    }

    /// Refuses to write an item onto itself, which for `.overwrite` would delete the source
    /// before reading it.
    ///
    /// Checked against the *final* target, after planning: duplicating into the current
    /// directory starts out aimed at the source's own name and is only safe because the plan
    /// redirects it to a free one.
    static func rejectSameLocation(source: URL, target: URL) -> Rejection? {
        source.standardizedFileURL.path == target.standardizedFileURL.path ? .sameLocation : nil
    }

    /// - Parameters:
    ///   - exists: whether something already occupies a URL.
    ///   - modified: last-modified date of a URL, used only by `.overwriteIfNewer`.
    static func plan(
        source: URL,
        destination: URL,
        resolution: ConflictResolution,
        exists: (URL) -> Bool,
        modified: (URL) -> Date?
    ) -> Plan {
        guard exists(destination) else { return .write(destination) }

        switch resolution {
        case .skip:
            return .skip
        case .overwrite:
            return .overwrite(destination)
        case .rename:
            return .write(freeURL(basedOn: destination, exists: exists))
        case .overwriteIfNewer:
            guard let sourceDate = modified(source), let destinationDate = modified(destination)
            else {
                // Without both dates there is no basis for "newer", so keep what is there.
                return .skip
            }
            return sourceDate > destinationDate ? .overwrite(destination) : .skip
        }
    }

    /// `report.txt` → `report 2.txt` → `report 3.txt`. Matches the Finder's numbering so
    /// duplicates made here look like duplicates made anywhere else on the system.
    ///
    /// A name that already ends in a counter continues it rather than stacking a second one,
    /// so repeatedly duplicating a file does not produce "report 2 2 2.txt".
    static func freeURL(basedOn url: URL, exists: (URL) -> Bool) -> URL {
        let directory = url.deletingLastPathComponent()
        let `extension` = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        let (base, start) = splitCounter(from: stem)
        // Bounded so a pathological directory cannot hang the operation.
        for counter in start...(start + 10_000) {
            let candidate = "\(base) \(counter)"
            let url = `extension`.isEmpty
                ? directory.appendingPathComponent(candidate)
                : directory.appendingPathComponent(candidate).appendingPathExtension(`extension`)
            if !exists(url) { return url }
        }
        // Fall back to something unique rather than looping forever.
        let unique = "\(base) \(UUID().uuidString)"
        return `extension`.isEmpty
            ? directory.appendingPathComponent(unique)
            : directory.appendingPathComponent(unique).appendingPathExtension(`extension`)
    }

    /// Splits `"report 3"` into `("report", 4)`, and `"report"` into `("report", 2)`.
    private static func splitCounter(from stem: String) -> (base: String, next: Int) {
        guard let separator = stem.lastIndex(of: " ") else { return (stem, 2) }
        let suffix = stem[stem.index(after: separator)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let value = Int(suffix), value >= 2
        else {
            return (stem, 2)
        }
        return (String(stem[stem.startIndex..<separator]), value + 1)
    }
}
