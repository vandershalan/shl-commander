import Darwin
import Foundation

/// The actual byte moving.
///
/// Fast paths first: on one APFS volume `clonefile(2)` copies a file or an entire tree
/// instantly by sharing blocks, and `rename(2)` moves one instantly. Only when the operation
/// crosses volumes does anything have to be read and written, and only then is progress
/// meaningful.
enum CopyEngine {
    enum Failure: Error, LocalizedError {
        case posix(code: Int32, path: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .posix(let code, let path):
                return "\(String(cString: strerror(code))): \(path)"
            case .cancelled:
                return "Cancelled"
            }
        }
    }

    /// Errors that mean "the fast path does not apply here", as opposed to a real failure.
    private static let fastPathRejections: Set<Int32> = [
        EXDEV,  // different volume
        ENOTSUP, EOPNOTSUPP,  // not APFS
        EPERM,  // cloning not permitted for this file
        EINVAL,
    ]

    // MARK: - Fast paths

    /// Returns nil on success, otherwise `errno`.
    @discardableResult
    static func clone(from source: URL, to destination: URL) -> Int32? {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else { return EINVAL }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else { return EINVAL }
                return clonefile(sourcePath, destinationPath, UInt32(CLONE_NOFOLLOW))
            }
        }
        return result == 0 ? nil : errno
    }

    /// Returns nil on success, otherwise `errno`.
    @discardableResult
    static func moveInPlace(from source: URL, to destination: URL) -> Int32? {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else { return EINVAL }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else { return EINVAL }
                return rename(sourcePath, destinationPath)
            }
        }
        return result == 0 ? nil : errno
    }

    static func isFastPathRejection(_ code: Int32) -> Bool {
        fastPathRejections.contains(code)
    }

    // MARK: - Copy

    /// Copies a file, directory tree, or symlink, cloning when possible.
    ///
    /// `progress` receives byte deltas, throttled by the caller's chunk size, and is only
    /// called meaningfully on the slow path — a clone reports its whole size at once.
    static func copy(
        from source: URL,
        to destination: URL,
        isCancelled: @escaping () -> Bool,
        progress: (Int64) -> Void
    ) throws {
        if isCancelled() { throw Failure.cancelled }

        if let code = clone(from: source, to: destination) {
            guard isFastPathRejection(code) else {
                throw Failure.posix(code: code, path: source.path)
            }
            try copySlowly(from: source, to: destination, isCancelled: isCancelled, progress: progress)
        } else {
            // Cloned whole. Credit the full size so the bar advances.
            progress(FileTreeScanner.stats(of: source).bytes)
        }
    }

    /// Moves a file or tree, renaming when possible and otherwise copying then deleting.
    static func move(
        from source: URL,
        to destination: URL,
        isCancelled: @escaping () -> Bool,
        progress: (Int64) -> Void
    ) throws {
        if isCancelled() { throw Failure.cancelled }

        if let code = moveInPlace(from: source, to: destination) {
            guard isFastPathRejection(code) else {
                throw Failure.posix(code: code, path: source.path)
            }
            // Across volumes a move is a copy followed by a delete. The delete only happens
            // once the copy has fully succeeded, so a failure never loses the original.
            try copySlowly(from: source, to: destination, isCancelled: isCancelled, progress: progress)
            try FileManager.default.removeItem(at: source)
        } else {
            progress(FileTreeScanner.stats(of: source).bytes)
        }
    }

    // MARK: - Slow path

    private static func copySlowly(
        from source: URL,
        to destination: URL,
        isCancelled: @escaping () -> Bool,
        progress: (Int64) -> Void
    ) throws {
        if isCancelled() { throw Failure.cancelled }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let values = try source.resourceValues(forKeys: keys)

        if values.isSymbolicLink == true {
            // Recreated rather than followed, so a link keeps pointing where it pointed.
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
            return
        }

        guard values.isDirectory == true else {
            try copyFileContents(from: source, to: destination, isCancelled: isCancelled, progress: progress)
            return
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: Array(keys),
            options: []
        )
        for child in children {
            if isCancelled() { throw Failure.cancelled }
            try copySlowly(
                from: child,
                to: destination.appendingPathComponent(child.lastPathComponent),
                isCancelled: isCancelled,
                progress: progress
            )
        }
        copyMetadata(from: source, to: destination)
    }

    private static let chunkSize = 1 << 20  // 1 MiB

    private static func copyFileContents(
        from source: URL,
        to destination: URL,
        isCancelled: @escaping () -> Bool,
        progress: (Int64) -> Void
    ) throws {
        let input = open(source.path, O_RDONLY)
        guard input >= 0 else { throw Failure.posix(code: errno, path: source.path) }
        defer { close(input) }

        let output = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard output >= 0 else { throw Failure.posix(code: errno, path: destination.path) }
        var succeeded = false
        defer {
            close(output)
            // A partial file is worse than no file: it looks like a completed copy.
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 4096)
        defer { buffer.deallocate() }

        while true {
            if isCancelled() { throw Failure.cancelled }

            let bytesRead = read(input, buffer, chunkSize)
            if bytesRead == 0 { break }
            guard bytesRead > 0 else { throw Failure.posix(code: errno, path: source.path) }

            var written = 0
            while written < bytesRead {
                let result = write(output, buffer.advanced(by: written), bytesRead - written)
                guard result > 0 else { throw Failure.posix(code: errno, path: destination.path) }
                written += result
            }
            progress(Int64(bytesRead))
        }

        succeeded = true
        copyMetadata(from: source, to: destination)
    }

    /// Mode, timestamps, extended attributes and ACLs. Best-effort: losing a timestamp is not
    /// worth failing a copy whose bytes arrived intact.
    private static func copyMetadata(from source: URL, to destination: URL) {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return }
                _ = copyfile(sourcePath, destinationPath, nil, copyfile_flags_t(COPYFILE_METADATA))
            }
        }
    }
}
