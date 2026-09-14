import AppKit
import UniformTypeIdentifiers

/// Opening files and folders in a named application.
@MainActor
enum AppOpener {
    /// Apps the system would offer for these items, followed by the ones the user has picked
    /// before, with duplicates dropped.
    ///
    /// The system list is empty for folders — nothing claims `public.folder` except the Finder —
    /// which is exactly why the remembered list exists.
    static func candidates(
        for urls: [URL],
        remembered: [OpenWithApp] = OpenWithStore.shared.available
    ) -> [OpenWithApp] {
        var seen = Set<String>()
        var result: [OpenWithApp] = []

        for url in urls.prefix(1) {
            for application in applications(toOpen: url) {
                let app = OpenWithApp(url: application)
                if seen.insert(app.path).inserted { result.append(app) }
            }
        }
        for app in remembered where seen.insert(app.path).inserted {
            result.append(app)
        }
        return result
    }

    /// Apps for one item, asked by name when there is no file at that path.
    ///
    /// A row inside an archive has a synthetic URL — nothing is on disk until it is extracted —
    /// and the system answers nothing for a path that does not exist. Its extension still names
    /// a type, and the apps for that type are exactly the right list to offer.
    private static func applications(toOpen url: URL) -> [URL] {
        let direct = NSWorkspace.shared.urlsForApplications(toOpen: url)
        guard direct.isEmpty, !FileManager.default.fileExists(atPath: url.path),
            let type = UTType(filenameExtension: url.pathExtension)
        else { return direct }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    /// The app the system would use by default, so the menu can mark it.
    static func defaultApplication(for url: URL) -> OpenWithApp? {
        if let application = NSWorkspace.shared.urlForApplication(toOpen: url) {
            return OpenWithApp(url: application)
        }
        guard !FileManager.default.fileExists(atPath: url.path),
            let type = UTType(filenameExtension: url.pathExtension),
            let application = NSWorkspace.shared.urlForApplication(toOpen: type)
        else { return nil }
        return OpenWithApp(url: application)
    }

    /// Opens everything in one app, remembering the choice.
    ///
    /// One call with every URL rather than one per file: an editor handed three folders at once
    /// opens three windows, where three separate launches can race and open one.
    static func open(
        _ urls: [URL],
        with application: URL,
        remember: Bool = true,
        store: OpenWithStore = .shared
    ) {
        guard !urls.isEmpty else { return }
        if remember { store.remember(application) }

        let name = application.deletingPathExtension().lastPathComponent
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            // The completion arrives off the main thread, and nothing but the message crosses
            // back — a closure passed in from the caller would not be sendable.
            guard let error else { return }
            let message = "\(name) could not open this: \(error.localizedDescription)"
            Task { @MainActor in
                OperationPrompts.report([
                    OperationFailure(url: application, message: message)
                ])
            }
        }
    }

    /// Opens panel rows, extracting any that live inside an archive first.
    ///
    /// The extracted copy is what the app is handed, so edits to it are never written back into
    /// the archive — the same bargain every other way of opening a member makes.
    static func open(_ targets: [FileEntry], with application: URL) {
        Task {
            var urls: [URL] = []
            for entry in targets {
                guard let origin = entry.archive else {
                    urls.append(entry.url)
                    continue
                }
                do {
                    urls.append(
                        try await ArchiveStore.shared.materialise(
                            member: origin.member, from: origin.archive))
                } catch ArchiveReader.Failure.cancelled {
                    // The password dialog was dismissed; nothing to report.
                    return
                } catch {
                    OperationPrompts.report([
                        OperationFailure(url: entry.url, message: error.localizedDescription)
                    ])
                    return
                }
            }
            open(urls, with: application)
        }
    }

    /// The "Other…" item: pick an app from /Applications and open with it.
    ///
    /// Returns the chosen app so the caller can act on it, or nil when the panel was cancelled.
    static func chooseApplication(prompt: String = "Open With") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = prompt
        panel.message = "Choose an application. It will be remembered under Open With."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
