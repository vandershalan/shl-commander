import Foundation
import Observation

/// A cloud folder that behaves like an ordinary directory: OneDrive, Google Drive, Dropbox,
/// iCloud Drive, or anything else that installs a File Provider.
///
/// Nothing here talks to a cloud API. macOS puts every File Provider's root under
/// `~/Library/CloudStorage`, and iCloud Drive under `~/Library/Mobile Documents`, so a file
/// manager only has to know where to look — the provider's own daemon does the syncing.
struct CloudPlace: Identifiable, Hashable, Sendable {
    /// The provider, as it names itself: "OneDrive", "GoogleDrive", "Dropbox".
    let provider: String
    /// Which account or library this root belongs to, empty when the provider has only one.
    let account: String
    let url: URL

    var id: URL { url }

    /// What the menu shows. The account is what distinguishes two roots of one provider, so it
    /// leads; the provider name is the group heading above it.
    var title: String { account.isEmpty ? provider : account }
}

@MainActor
@Observable
final class CloudService {
    private(set) var places: [CloudPlace] = []

    private let cloudStorage: URL
    private let mobileDocuments: URL
    /// Providers come and go while the app is open — a OneDrive account added in its
    /// preferences creates a new root without any user action here.
    @ObservationIgnored private var watcher: FSEventsWatcher?

    /// The directories are injectable so tests can point at a fixture tree rather than at
    /// whatever the machine running them happens to have installed.
    init(
        cloudStorage: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true),
        mobileDocuments: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    ) {
        self.cloudStorage = cloudStorage
        self.mobileDocuments = mobileDocuments
        refresh()
        watcher = FSEventsWatcher(watching: cloudStorage) { [weak self] in
            self?.refresh()
        }
    }

    func refresh() {
        var found: [CloudPlace] = []

        // iCloud Drive first: it is the one every Mac has, and it does not live with the rest.
        let iCloud = mobileDocuments.appendingPathComponent(
            "com~apple~CloudDocs", isDirectory: true)
        if Self.isDirectory(iCloud) {
            found.append(CloudPlace(provider: "iCloud Drive", account: "", url: iCloud))
        }

        let roots =
            (try? FileManager.default.contentsOfDirectory(
                at: cloudStorage,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        found += roots
            .filter(Self.isDirectory)
            .map { url in
                let (provider, account) = Self.split(url.lastPathComponent)
                return CloudPlace(provider: provider, account: account, url: url)
            }
            // Grouped by provider, then by account, so the order does not shuffle between
            // launches the way `contentsOfDirectory` does.
            .sorted {
                ($0.provider, $0.account) < ($1.provider, $1.account)
            }

        places = found
    }

    /// `OneDrive-Personal` → `("OneDrive", "Personal")`.
    ///
    /// macOS builds these names as provider, a hyphen, then the account or shared library, and
    /// strips the spaces out of both halves. The account half can itself contain hyphens, so
    /// only the first one separates.
    static func split(_ folderName: String) -> (provider: String, account: String) {
        guard let separator = folderName.firstIndex(of: "-") else {
            return (folderName, "")
        }
        let provider = String(folderName[folderName.startIndex..<separator])
        let account = String(folderName[folderName.index(after: separator)...])
        return (provider.isEmpty ? folderName : provider, account)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The places grouped for a menu, in the order they should appear.
    var byProvider: [(provider: String, places: [CloudPlace])] {
        var order: [String] = []
        var groups: [String: [CloudPlace]] = [:]
        for place in places {
            if groups[place.provider] == nil { order.append(place.provider) }
            groups[place.provider, default: []].append(place)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}
