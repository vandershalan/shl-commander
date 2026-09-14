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
        case missingTool(String)
        case passphraseNeeded(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\u{22}\(name)\u{22} is not an archive this app can open."
            case .toolFailed(_, let message):
                return message.isEmpty ? "The archive could not be read." : message
            case .missingTool(let name):
                return "\(name) is needed to open this file and is not installed."
            case .passphraseNeeded(let name):
                return
                    "\u{22}\(name)\u{22} is password-protected, and no accepted password was given."
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    private static let tool = URL(fileURLWithPath: "/usr/bin/tar")

    /// Handed to bsdtar whenever no password is known.
    ///
    /// Without `--passphrase` bsdtar meets an encrypted entry and asks for a password on its
    /// terminal — and with nothing attached to its input it asks again, and again, with the app
    /// waiting on a process that will never exit. A placeholder turns that hang into one clean
    /// "Incorrect passphrase" failure, which is what prompts the user for the real one.
    static let placeholderPassphrase = "\u{1}shl-commander-none\u{1}"

    // MARK: - Listing

    /// Lists an archive.
    ///
    /// The format comes from the file's content, so an archive whose name is wrong still opens.
    /// A single compressed stream has no table of contents to read, so its one payload is
    /// described directly.
    static func index(of archive: URL, passphrase: String? = nil) throws -> ArchiveIndex {
        guard let format = ArchiveProbe.format(of: archive) else {
            throw Failure.unsupported(archive.lastPathComponent)
        }
        if format.isSingleStream {
            return singleStreamIndex(of: archive, format: format)
        }

        let output = try run(["-tvf", archive.path], on: archive, passphrase: passphrase)
        let members = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parse(line: String($0)) }

        return ArchiveIndex(archive: archive, format: format, members: members)
    }

    /// Parses one `tar -tvf` line.
    ///
    /// Columns are mode, links, owner, group, size, then a three-part date, then the name.
    /// The time locale is forced to C when running so the month is always the English
    /// abbreviation, and the date comes in two shapes: `Jul 30 15:43` for something recent,
    /// `Jan  2  2020` otherwise. The name is whatever follows, so spaces in it survive.
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

    // MARK: - Single compressed streams

    /// Describes the one payload inside a compressed stream.
    static func singleStreamIndex(of archive: URL, format: ArchiveFormat) -> ArchiveIndex {
        let values = try? archive.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
        let member = ArchiveMember(
            path: payloadName(for: archive, format: format),
            isDirectory: false,
            isSymlink: false,
            size: uncompressedSize(of: archive, format: format),
            modified: values?.contentModificationDate ?? .distantPast
        )
        return ArchiveIndex(archive: archive, format: format, members: [member])
    }

    /// Names the payload by removing the compression suffix.
    ///
    /// When the name carries no such suffix — which is exactly the case for a stream misnamed
    /// `.zip` — the misleading extension is dropped instead, since it describes a format the file
    /// is not in.
    static func payloadName(for archive: URL, format: ArchiveFormat) -> String {
        let name = archive.lastPathComponent
        if let suffix = format.streamSuffix, name.lowercased().hasSuffix(suffix.lowercased()) {
            return String(name.dropLast(suffix.count))
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// Uncompressed size where the container records it cheaply, and -1 where it does not.
    ///
    /// gzip stores it in the last four bytes of the file, so it costs one seek. The value is
    /// modulo 2^32, so a payload over 4 GB reads low — which is why it is taken as a hint rather
    /// than promised as exact. bzip2, xz and the rest keep no such field, and decompressing the
    /// whole file just to count bytes is not worth it for a listing.
    static func uncompressedSize(of archive: URL, format: ArchiveFormat) -> Int64 {
        guard format == .gzipStream else { return FileEntry.unknownSize }
        guard let handle = try? FileHandle(forReadingFrom: archive) else {
            return FileEntry.unknownSize
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 4 else { return FileEntry.unknownSize }
        try? handle.seek(toOffset: size - 4)
        guard let footer = try? handle.read(upToCount: 4), footer.count == 4 else {
            return FileEntry.unknownSize
        }
        let bytes = Array(footer)
        let value =
            UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        return Int64(value)
    }

    /// Decompressors for the single-stream formats, first match on disk wins.
    ///
    /// gzip and bzip2 ship with macOS. xz and zstd do not, so a file in one of those formats
    /// reports what is missing rather than failing obscurely.
    private static func decompressor(for format: ArchiveFormat) throws -> (URL, [String]) {
        let candidates: (names: [String], flags: [String])
        switch format {
        case .gzipStream: candidates = (["/usr/bin/gzip"], ["-dc"])
        case .bzip2Stream: candidates = (["/usr/bin/bzip2"], ["-dc"])
        case .compressStream: candidates = (["/usr/bin/uncompress", "/usr/bin/gzip"], ["-dc"])
        case .xzStream:
            candidates = (["/usr/bin/xz", "/opt/homebrew/bin/xz", "/usr/local/bin/xz"], ["-dc"])
        case .zstdStream:
            candidates = (
                ["/usr/bin/zstd", "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"], ["-dc"]
            )
        default:
            throw Failure.unsupported(format.rawValue)
        }

        guard let tool = candidates.names.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw Failure.missingTool((candidates.names[0] as NSString).lastPathComponent)
        }
        return (URL(fileURLWithPath: tool), candidates.flags)
    }

    /// Decompresses the stream into `directory`, under the payload's name.
    static func extractStream(
        from archive: URL,
        format: ArchiveFormat,
        to directory: URL,
        isCancelled: () -> Bool = { false }
    ) throws {
        if isCancelled() { throw Failure.cancelled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(
            payloadName(for: archive, format: format))
        let (tool, flags) = try decompressor(for: format)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else {
            throw Failure.toolFailed(status: -1, message: "Could not write the decompressed file.")
        }
        defer { try? output.close() }

        let errors = Pipe()
        let process = Process()
        process.executableURL = tool
        process.arguments = flags + [archive.path]
        process.environment = ToolPath.environment()
        process.standardOutput = output
        process.standardError = errors

        var succeeded = false
        // A half-written file looks like a finished one, so it goes if this fails.
        defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }

        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.toolFailed(
                status: process.terminationStatus,
                message: String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        succeeded = true
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
        passphrase: String? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        guard !members.isEmpty else { return }
        guard let format = ArchiveProbe.format(of: archive) else {
            throw Failure.unsupported(archive.lastPathComponent)
        }
        // A single stream has one payload; there is nothing to select within it.
        if format.isSingleStream {
            try extractStream(
                from: archive, format: format, to: directory, isCancelled: isCancelled)
            return
        }
        let safe = members.filter { !ArchiveIndex.isUnsafe($0) }
        guard !safe.isEmpty else { return }
        if isCancelled() { throw Failure.cancelled }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // -C changes directory before extracting, so member paths stay relative to it.
        _ = try run(
            ["-xf", archive.path, "-C", directory.path] + safe, on: archive, passphrase: passphrase)
    }

    /// Extracts an archive whole, without listing it first.
    ///
    /// This is what unpacking an archive from the outside means: bsdtar with no member list
    /// takes everything, and the names inside stay as the archive recorded them.
    static func extractAll(
        from archive: URL,
        to directory: URL,
        passphrase: String? = nil,
        isCancelled: () -> Bool = { false }
    ) throws {
        guard let format = ArchiveProbe.format(of: archive) else {
            throw Failure.unsupported(archive.lastPathComponent)
        }
        if format.isSingleStream {
            try extractStream(
                from: archive, format: format, to: directory, isCancelled: isCancelled)
            return
        }
        if isCancelled() { throw Failure.cancelled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try run(["-xf", archive.path, "-C", directory.path], on: archive, passphrase: passphrase)
    }

    /// Extracts one member and returns where it landed.
    static func extractOne(
        member: String,
        from archive: URL,
        to directory: URL,
        passphrase: String? = nil
    ) throws -> URL {
        try extract(members: [member], from: archive, to: directory, passphrase: passphrase)
        return directory.appendingPathComponent(ArchiveIndex.normalise(member))
    }

    // MARK: - Process

    private static func run(
        _ arguments: [String],
        on archive: URL,
        passphrase: String?
    ) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = withPassphrase(arguments, passphrase)
        // Nothing to type into: a password prompt bsdtar writes here has to fail, never wait.
        process.standardInput = FileHandle.nullDevice
        process.environment = listingEnvironment

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
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if mentionsPassphrase(message) {
                throw Failure.passphraseNeeded(archive.lastPathComponent)
            }
            throw Failure.toolFailed(status: process.terminationStatus, message: message)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Places the password after the mode and its file, and before any member patterns — where
    /// bsdtar still reads it as an option rather than as something to extract.
    static func withPassphrase(_ arguments: [String], _ passphrase: String?) -> [String] {
        var arguments = arguments
        arguments.insert(
            contentsOf: ["--passphrase", passphrase ?? placeholderPassphrase],
            at: min(2, arguments.count)
        )
        return arguments
    }

    /// The environment bsdtar is run in.
    ///
    /// The character set matters as much as the path here. bsdtar writes member names through
    /// the locale, and in the C locale everything outside ASCII comes out escaped — `ł` as the
    /// four characters `\305\202` — which is neither a name to show nor a name that can be
    /// handed back to extract that member. A UTF-8 ctype keeps the real characters, while the
    /// time locale stays C so the listing's month is always the English abbreviation the parser
    /// expects. `LC_ALL` would override both, and the user's shell may well have set it, so it
    /// is cleared rather than merely not set.
    ///
    /// The path matters too: bsdtar shells out to `zstd` for a .tar.zst, and the app inherits
    /// no login shell PATH to find it on.
    static var listingEnvironment: [String: String] {
        var environment = ToolPath.environment(adding: [
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
            "LC_TIME": "C",
        ])
        environment.removeValue(forKey: "LC_ALL")
        return environment
    }

    /// True when bsdtar failed because the archive is encrypted.
    ///
    /// libarchive says "Incorrect passphrase" for a wrong password and "Passphrase required"
    /// when it has none; both mean the same thing here — ask the user and try again.
    static func mentionsPassphrase(_ message: String) -> Bool {
        message.lowercased().contains("passphrase")
    }
}
