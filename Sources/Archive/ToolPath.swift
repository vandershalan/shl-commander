import Foundation

/// Where to look for the command-line tools the archive code drives.
///
/// An app launched from the Finder inherits no login shell, so its `PATH` is the bare system
/// one. bsdtar handles gzip, bzip2 and xz itself but pipes zstd through an external `zstd`,
/// which macOS does not ship — and without Homebrew's prefixes on the path it cannot find an
/// installed one, so a `.tar.zst` would fail to open on a machine that has zstd right there.
enum ToolPath {
    static let directories = [
        "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin",
    ]

    static var value: String { directories.joined(separator: ":") }

    /// True when `name` is installed in one of those directories.
    static func has(_ name: String) -> Bool {
        directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
    }

    /// The current environment with that path substituted in, plus anything extra.
    static func environment(adding extras: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = value
        for (key, item) in extras { environment[key] = item }
        return environment
    }
}
