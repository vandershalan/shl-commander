import Foundation

/// Creates archives with the same tool that reads them: `/usr/bin/tar`, which on macOS is
/// bsdtar over libarchive and writes zip as readily as it writes tar.
///
/// One tool for every format is the point — zip, gzip, bzip2, xz and zstd all come out of the
/// same call, with no second binary to be missing.
enum ArchiveWriter {
    /// The formats offered when packing. Deliberately fewer than the reader accepts: `rar` is
    /// proprietary and cannot be written, and `7z` needs a binary macOS does not ship.
    enum Format: String, CaseIterable, Sendable {
        case zip
        case tarGzip
        case tarBzip2
        case tarXZ
        case tarZstd
        case tar

        /// What the archive's name ends in.
        var suffix: String {
            switch self {
            case .zip: return ".zip"
            case .tarGzip: return ".tar.gz"
            case .tarBzip2: return ".tar.bz2"
            case .tarXZ: return ".tar.xz"
            case .tarZstd: return ".tar.zst"
            case .tar: return ".tar"
            }
        }

        /// The suffix without its dot, for prose that lists the formats.
        var rawValueSuffix: String { String(suffix.dropFirst()) }

        /// Shown in the format picker.
        var title: String {
            switch self {
            case .zip: return "zip"
            case .tarGzip: return "tar.gz"
            case .tarBzip2: return "tar.bz2"
            case .tarXZ: return "tar.xz"
            case .tarZstd: return "tar.zst"
            case .tar: return "tar (no compression)"
            }
        }

        /// Flags that put bsdtar in writing mode for this format.
        var creationFlags: [String] {
            switch self {
            case .zip: return ["--format", "zip", "-cf"]
            case .tarGzip: return ["-czf"]
            case .tarBzip2: return ["-cjf"]
            case .tarXZ: return ["-cJf"]
            case .tarZstd: return ["--zstd", "-cf"]
            case .tar: return ["-cf"]
            }
        }

        /// The format a name asks for, so typing `stuff.tar.gz` in the dialog is honoured
        /// rather than overridden by the picker.
        static func matching(name: String) -> Format? {
            let lowered = name.lowercased()
            // Longest suffix first: `.tar.gz` must not be read as `.gz`, which is not offered.
            return allCases
                .sorted { $0.suffix.count > $1.suffix.count }
                .first { lowered.hasSuffix($0.suffix) }
        }

        static let `default` = Format.zip
    }

    enum Failure: Error, LocalizedError, Equatable {
        case nothingToPack
        case alreadyExists(String)
        case missingTool(String)
        case toolFailed(status: Int32, message: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .nothingToPack:
                return "Nothing was selected to pack."
            case .alreadyExists(let name):
                return "\u{22}\(name)\u{22} already exists. Pick another name."
            case .missingTool(let name):
                return "\(name) is needed to write this format and is not installed."
            case .toolFailed(_, let message):
                return message.isEmpty ? "The archive could not be written." : message
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    private static let tool = URL(fileURLWithPath: "/usr/bin/tar")

    /// The external tool a format needs, if any.
    ///
    /// bsdtar compresses gzip, bzip2 and xz itself; only zstd is piped through a separate
    /// binary, and macOS does not ship one.
    static func requiredTool(for format: Format) -> String? {
        format == .tarZstd ? "zstd" : nil
    }

    /// False only when a format needs a tool that is not installed, which is why the pack
    /// dialog lists tar.zst on some machines and not others.
    static func canWrite(_ format: Format) -> Bool {
        guard let tool = requiredTool(for: format) else { return true }
        return ToolPath.has(tool)
    }

    /// The formats worth offering on this machine.
    static var writableFormats: [Format] { Format.allCases.filter(canWrite) }

    /// Suggests an archive name for a selection: the item's own name for one item, the folder's
    /// name for several — which is what both Finder and Total Commander do.
    static func suggestedName(for sources: [URL], in directory: URL, format: Format) -> String {
        let stem: String
        if sources.count == 1, let only = sources.first {
            // Only the last extension goes: "notes.tar.gz" is not a thing to pack, but
            // "archive.txt" packed as "archive.zip" reads better than "archive.txt.zip".
            stem = only.deletingPathExtension().lastPathComponent
        } else {
            stem = directory.lastPathComponent.isEmpty ? "Archive" : directory.lastPathComponent
        }
        return stem + format.suffix
    }

    /// Writes `sources` into `archive`.
    ///
    /// Every source has to sit in `directory`: bsdtar runs there and is handed bare names, so
    /// the archive holds `notes.txt` rather than `Users/…/notes.txt`. Anything else would make
    /// an archive that unpacks into a tower of empty folders.
    static func create(
        archive: URL,
        from names: [String],
        in directory: URL,
        format: Format,
        isCancelled: () -> Bool = { false }
    ) throws {
        guard !names.isEmpty else { throw Failure.nothingToPack }
        if let tool = requiredTool(for: format), !canWrite(format) {
            throw Failure.missingTool(tool)
        }
        guard !FileManager.default.fileExists(atPath: archive.path) else {
            throw Failure.alreadyExists(archive.lastPathComponent)
        }
        if isCancelled() { throw Failure.cancelled }

        let process = Process()
        process.executableURL = tool
        process.currentDirectoryURL = directory
        process.arguments = format.creationFlags + [archive.path] + names
        process.environment = ToolPath.environment()

        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        var succeeded = false
        // A half-written archive looks like a finished one, so it goes if this fails.
        defer { if !succeeded { try? FileManager.default.removeItem(at: archive) } }

        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        // Cancelling means killing the tool: bsdtar has no way to be asked to stop.
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                process.waitUntilExit()
                throw Failure.cancelled
            }
            usleep(50_000)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // bsdtar says "Can't launch external program: zstd …" when the compressor it wanted
            // to pipe through is missing, which is worth saying in plain words.
            if message.contains("Can't launch external program"),
                let tool = requiredTool(for: format)
            {
                throw Failure.missingTool(tool)
            }
            throw Failure.toolFailed(status: process.terminationStatus, message: message)
        }
        succeeded = true
    }
}
