import AppKit

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
            for application in NSWorkspace.shared.urlsForApplications(toOpen: url) {
                let app = OpenWithApp(url: application)
                if seen.insert(app.path).inserted { result.append(app) }
            }
        }
        for app in remembered where seen.insert(app.path).inserted {
            result.append(app)
        }
        return result
    }

    /// The app the system would use by default, so the menu can mark it.
    static func defaultApplication(for url: URL) -> OpenWithApp? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map(OpenWithApp.init(url:))
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
