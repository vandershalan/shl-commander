import Foundation

enum FileOperationKind: String, Sendable {
    case copy, move

    var verb: String { self == .copy ? "Copying" : "Moving" }
    var title: String { self == .copy ? "Copy" : "Move" }
}

/// What the user asked for, before any conflict has been looked at.
struct FileOperationRequest: Sendable {
    let kind: FileOperationKind
    let sources: [URL]
    let destinationDirectory: URL
    /// Set to resolve every conflict the same way without asking. Duplicating into the
    /// current directory uses this, since a collision there is the whole point.
    var automaticResolution: ConflictResolution?
}

/// How to proceed when the destination name is already taken.
enum ConflictResolution: String, CaseIterable, Sendable {
    case skip
    case overwrite
    /// Write alongside the existing file under a free name.
    case rename
    /// Overwrite only when the source is newer, otherwise skip.
    case overwriteIfNewer

    var buttonTitle: String {
        switch self {
        case .skip: return "Skip"
        case .overwrite: return "Overwrite"
        case .rename: return "Keep Both"
        case .overwriteIfNewer: return "Overwrite if Newer"
        }
    }
}

/// A resolution plus whether it stands for the rest of the operation.
struct ConflictDecision: Sendable {
    let resolution: ConflictResolution
    let applyToAll: Bool

    static let cancelled = ConflictDecision(resolution: .skip, applyToAll: true)
}

/// Totals gathered before an operation starts, so progress has a denominator.
struct TreeStats: Sendable, Equatable {
    var bytes: Int64 = 0
    var files: Int = 0
    var directories: Int = 0

    static func + (lhs: TreeStats, rhs: TreeStats) -> TreeStats {
        TreeStats(
            bytes: lhs.bytes + rhs.bytes,
            files: lhs.files + rhs.files,
            directories: lhs.directories + rhs.directories
        )
    }
}

/// One thing that went wrong, kept so a long operation can report at the end instead of
/// stopping at the first failure.
struct OperationFailure: Sendable, Identifiable {
    let id = UUID()
    let url: URL
    let message: String
}

/// Walks trees to total them up. Shared with step 6's directory sizes.
enum FileTreeScanner {
    /// Logical bytes, which is what a cross-volume copy actually has to write.
    static func stats(of urls: [URL]) -> TreeStats {
        urls.reduce(TreeStats()) { $0 + stats(of: $1) }
    }

    static func stats(of url: URL) -> TreeStats {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return TreeStats() }

        // A symlink counts as one small file; following it could double-count or loop.
        if values.isSymbolicLink == true {
            return TreeStats(bytes: 0, files: 1, directories: 0)
        }
        guard values.isDirectory == true else {
            return TreeStats(bytes: Int64(values.fileSize ?? 0), files: 1, directories: 0)
        }

        var total = TreeStats(bytes: 0, files: 0, directories: 1)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []
        for child in children {
            total = total + stats(of: child)
        }
        return total
    }

    /// Disk footprint rather than logical size — what `du` reports and what the Size column
    /// should show for a directory.
    static func allocatedSize(of url: URL, isCancelled: () -> Bool = { false }) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard !isCancelled(), let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        if values.isSymbolicLink == true { return 0 }
        guard values.isDirectory == true else {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }

        var total: Int64 = 0
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []
        for child in children {
            if isCancelled() { break }
            total += allocatedSize(of: child, isCancelled: isCancelled)
        }
        return total
    }
}
