import Foundation

/// iCloud Drive as the Finder presents it.
///
/// On disk iCloud Drive is two things side by side under `~/Library/Mobile Documents`: the
/// drive proper, `com~apple~CloudDocs`, and one container per app — `iCloud~com~elf-audio~koala`
/// and so on — whose `Documents` folder the Finder (and Files on an iPad) shows *inside* the drive
/// as a folder named after the app. This puts those app folders back where a person expects them.
///
/// Which containers are public is recorded by iCloud itself: a container an app keeps private, or
/// one whose `Documents` it does not share, carries the hidden flag. The Finder goes by the same
/// flag, so honouring it lists exactly the folders the Finder lists.
enum ICloudDrive {
    static let defaultMobileDocuments = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents", isDirectory: true)

    /// The drive's own folder within `Mobile Documents`.
    static let driveFolderName = "com~apple~CloudDocs"

    static let displayName = "iCloud Drive"

    static func root(in mobileDocuments: URL = defaultMobileDocuments) -> URL {
        mobileDocuments.appendingPathComponent(driveFolderName, isDirectory: true)
    }

    static func isRoot(_ url: URL, in mobileDocuments: URL = defaultMobileDocuments) -> Bool {
        Self.path(url) == Self.path(root(in: mobileDocuments))
    }

    /// The container `url` is the shared folder of, when it is exactly
    /// `Mobile Documents/<container>/Documents` for some app's container.
    static func appContainer(
        of url: URL, in mobileDocuments: URL = defaultMobileDocuments
    ) -> URL? {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent == "Documents" else { return nil }
        let container = standardized.deletingLastPathComponent()
        guard
            Self.path(container.deletingLastPathComponent()) == Self.path(mobileDocuments),
            container.lastPathComponent != driveFolderName
        else { return nil }
        return container
    }

    /// The app's name as the Finder shows it, from the container's localised display name.
    static func appName(ofContainer container: URL) -> String {
        let name = FileManager.default.displayName(atPath: container.path)
        // Some apps ship a name led by a left-to-right mark, which is invisible but would sort
        // the folder ahead of everything else.
        let trimmed = name.trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{200E}\u{200F}").union(.whitespaces))
        return trimmed.isEmpty ? container.lastPathComponent : trimmed
    }

    /// One row per app container with a shared `Documents` folder, to be listed alongside the
    /// drive's own contents. Containers the Finder hides only appear with hidden files shown.
    static func appFolders(
        in mobileDocuments: URL = defaultMobileDocuments, includeHidden: Bool
    ) -> [FileEntry] {
        let containers =
            (try? FileManager.default.contentsOfDirectory(
                at: mobileDocuments,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                // Not `.skipsHiddenFiles`: private containers carry the hidden flag and are still
                // wanted when hidden files are shown. Only dotfiles like `.Trash` are noise.
                options: []
            )) ?? []

        return containers.compactMap { container -> FileEntry? in
            let folder = container.lastPathComponent
            guard folder != driveFolderName, !folder.hasPrefix(".") else { return nil }
            let documents = container.appendingPathComponent("Documents", isDirectory: true)
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isHiddenKey, .contentModificationDateKey,
            ]
            guard
                let values = try? documents.resourceValues(forKeys: keys),
                values.isDirectory == true
            else { return nil }
            let containerHidden =
                (try? container.resourceValues(forKeys: [.isHiddenKey]).isHidden) ?? false
            let isHidden = containerHidden || values.isHidden == true
            guard includeHidden || !isHidden else { return nil }

            let name = appName(ofContainer: container)
            return FileEntry(
                url: documents,
                name: name,
                baseName: name,
                ext: "",
                isDirectory: true,
                isSymlink: false,
                isHidden: isHidden,
                isPackage: false,
                size: 0,
                modified: values.contentModificationDate ?? .distantPast,
                isParent: false,
                isCloudAppFolder: true
            )
        }
    }

    /// Where `..` leads from an app folder: the drive it is shown in, not the container.
    static func parent(of url: URL, in mobileDocuments: URL = defaultMobileDocuments) -> URL? {
        appContainer(of: url, in: mobileDocuments) == nil ? nil : root(in: mobileDocuments)
    }

    /// The name `url` goes by in the drive, for an app folder or the drive itself.
    static func title(of url: URL, in mobileDocuments: URL = defaultMobileDocuments) -> String? {
        if isRoot(url, in: mobileDocuments) { return displayName }
        return appContainer(of: url, in: mobileDocuments).map(appName(ofContainer:))
    }

    /// `iCloud Drive/koala/Songs` for anything inside the drive or one of its app folders, nil
    /// for anywhere else.
    static func friendlyPath(
        of url: URL, in mobileDocuments: URL = defaultMobileDocuments
    ) -> String? {
        let path = Self.path(url)
        let rootPath = Self.path(root(in: mobileDocuments))
        if path == rootPath { return displayName }
        if path.hasPrefix(rootPath + "/") {
            return displayName + path.dropFirst(rootPath.count)
        }

        let base = Self.path(mobileDocuments) + "/"
        guard path.hasPrefix(base) else { return nil }
        let components = path.dropFirst(base.count).split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2, components[1] == "Documents" else { return nil }
        let container = mobileDocuments.appendingPathComponent(String(components[0]))
        guard appContainer(of: container.appendingPathComponent("Documents"), in: mobileDocuments) != nil
        else { return nil }
        let rest = components.dropFirst(2).joined(separator: "/")
        let app = displayName + "/" + appName(ofContainer: container)
        return rest.isEmpty ? app : app + "/" + rest
    }

    /// The path without a trailing slash, so a directory URL and a plain one compare equal.
    private static func path(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
