import Foundation

/// Reads archives by driving `/usr/bin/tar`, which on macOS is bsdtar over libarchive.
///
/// There is no public Foundation API for reading a zip. bsdtar ships with every macOS, reads
/// zip, tar and its compressed variants, 7z, rar, cpio and iso through one interface, and
/// refuses paths that escape the archive root. Shelling out to it beats vendoring an archive
/// library for each format.
enum ArchiveReader {
    enum Failure: Error, LocalizedError {
        case unsupported(String)
        case toolFailed(status: Int32, message: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\u{22}\(name)\u{22} is not an archive this app can open."
            case .toolFailed(_, let message):
                return message.isEmpty ? "The archive could not be read." : message
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    private static let tool = URL(fileURLWithPath: "/usr/bin/tar")

    // MARK: - Listing

    /// Lists an archive. Runs `tar` once and parses its long listing.
    static func index(of archive: URL) throws -> ArchiveIndex {
        guard let format = ArchiveFormat.detect(url: archive) else {
            throw Failure.unsupported(archive.lastPathComponent)
        }

        let output = try run(["-tvf", archive.path])
        let members = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(line: String($0)) }

        return ArchiveIndex(archive: archive, format: format, members: members)
    }

    /// Parses one `tar -tvf` line.
    ///
    /// Columns are mode, links, owner, group, size, then a three-part date, then the name.
    /// `LC_ALL=C` is forced when running so the month is always the English abbreviation, and
    /// the date comes in two shapes: `Jul 30 15:43` for something recent, `Jan  2  2020`
    /// otherwise. The name is whatever follows, so spaces in it survive.
    static func parse(line: String) -> ArchiveMember? {
        guard let match = listingPattern.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) else { return nil }

        func capture(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else {
                return nil
            }
            return String(line[swiftRange])
        }

        guard let mode = capture("mode"),
            let sizeText = capture("size"),
            let size = Int64(sizeText),
            var name = capture("name")
        else { return nil }

        let isSymlink = mode.hasPrefix("l")
        // A symlink line reads "link.txt -> target.txt"; only the link itself is the member.
        if isSymlink, let arrow = name.range(of: " -> ") {
            name = String(name[name.startIndex..<arrow.lowerBound])
        }

        let isDirectory = mode.hasPrefix("d") || name.hasSuffix("/")
        guard !ArchiveIndex.isUnsafe(name) else { return nil }

        return ArchiveMember(
            path: ArchiveIndex.normalise(name),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: isDirectory ? 0 : size,
            modified: parseDate(
                month: capture("month"), day: capture("day"), timeOrYear: capture("timeOrYear"))
        )
    }

    private static let listingPattern: NSRegularExpression = {
        // Mode letters, an optional ACL/xattr marker, then the fixed columns.
        let pattern = """
            ^(?<mode>[bcdlps-][rwxsStT-]{9}[@+]?)\\s+\\d+\\s+\\S+\\s+\\S+\\s+\
            (?<size>\\d+)\\s+(?<month>[A-Z][a-z]{2})\\s+(?<day>\\d{1,2})\\s+\
            (?<timeOrYear>\\d{1,2}:\\d{2}|\\d{4})\\s(?<name>.+)$
            """
        // Force-tried because the pattern is a compile-time constant covered by tests.
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Malformed archive listing pattern")
        }
        return expression
    }()

    private static let months = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    /// Rebuilds a date from the listing columns.
    ///
    /// bsdtar drops the year for recent entries and the time for older ones, so a year-less
    /// entry is assumed to be within the last twelve months — the same guess `ls` makes. A date
    /// that would land in the future is pulled back a year.
    static func parseDate(month: String?, day: String?, timeOrYear: String?) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        guard let month, let monthNumber = months[month],
            let day, let dayNumber = Int(day),
            let timeOrYear
        else { return .distantPast }

        var components = DateComponents()
        components.month = monthNumber
        components.day = dayNumber

        if timeOrYear.contains(":") {
            let parts = timeOrYear.split(separator: ":")
            components.hour = Int(parts.first ?? "0")
            components.minute = Int(parts.last ?? "0")
            let now = Date()
            components.year = calendar.component(.year, from: now)
            guard let candidate = calendar.date(from: components) else { return .distantPast }
            // More than a day ahead means the entry belongs to last year.
            if candidate.timeIntervalSince(now) > 86_400 {
                components.year = (components.year ?? 0) - 1
            }
        } else {
            components.year = Int(timeOrYear)
        }

        return calendar.date(from: components) ?? .distantPast
    }

    // MARK: - Extraction

    /// Extracts the named members into `directory`, keeping their paths inside the archive.
    ///
    /// Directories are passed through as-is: bsdtar pulls out everything beneath them, which is
    /// what selecting a folder inside an archive should do.
    static func extract(
        members: [String],
        from archive: URL,
        to directory: URL,
        isCancelled: () -> Bool = { false }
    ) throws {
        guard !members.isEmpty else { return }
        guard ArchiveFormat.detect(url: archive) != nil else {
            throw Failure.unsupported(archive.lastPathComponent)
        }
        let safe = members.filter { !ArchiveIndex.isUnsafe($0) }
        guard !safe.isEmpty else { return }
        if isCancelled() { throw Failure.cancelled }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // -C changes directory before extracting, so member paths stay relative to it.
        _ = try run(["-xf", archive.path, "-C", directory.path] + safe)
    }

    /// Extracts one member and returns where it landed.
    static func extractOne(
        member: String,
        from archive: URL,
        to directory: URL
    ) throws -> URL {
        try extract(members: [member], from: archive, to: directory)
        return directory.appendingPathComponent(ArchiveIndex.normalise(member))
    }

    // MARK: - Process

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        // The listing parser depends on English month names and the C column layout.
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Read before waiting: a large listing can fill the pipe buffer and deadlock a process
        // that is waiting for someone to drain it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.toolFailed(
                status: process.terminationStatus,
                message: String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
