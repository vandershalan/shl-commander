import Darwin
import Foundation

extension URL {
    /// The fully resolved path, through `realpath(3)`.
    ///
    /// Neither Foundation option gives one spelling per file. `standardizedFileURL` does not
    /// resolve symlinks at all, and `resolvingSymlinksInPath()` *strips* a leading `/private`
    /// rather than resolving `/var` to `/private/var`. Directory listings hand back the resolved
    /// form, so anything that has to match against them — archive identity, event paths, cache
    /// keys — needs the same form or the same file ends up with two identities.
    ///
    /// Falls back to `path` for something that does not exist, which cannot be resolved.
    var canonicalPath: String {
        withUnsafeFileSystemRepresentation { pointer -> String in
            guard let pointer, let resolved = realpath(pointer, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    var canonicalFileURL: URL {
        URL(fileURLWithPath: canonicalPath)
    }
}
