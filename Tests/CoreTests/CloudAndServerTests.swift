import Foundation
import Testing

@testable import ShlCommander

@MainActor
@Suite("Cloud folders")
struct CloudServiceTests {
    /// A fake `~/Library` layout, so the test does not depend on what the machine running it
    /// happens to have installed.
    private func service(in tree: TempTree) throws -> CloudService {
        let storage = tree.root.appendingPathComponent("CloudStorage")
        let documents = tree.root.appendingPathComponent("Mobile Documents")
        try tree.directory("CloudStorage/OneDrive-Osobisty")
        try tree.directory("CloudStorage/OneDrive-LPPS.A")
        try tree.directory("CloudStorage/GoogleDrive-someone@example.com")
        try tree.directory("Mobile Documents/com~apple~CloudDocs")
        return CloudService(cloudStorage: storage, mobileDocuments: documents)
    }

    @Test("every provider under CloudStorage is found, plus iCloud Drive")
    func discovery() throws {
        let tree = try TempTree("cloud-discovery")
        defer { tree.remove() }
        let cloud = try service(in: tree)

        #expect(cloud.places.count == 4)
        #expect(cloud.places.first?.provider == "iCloud Drive", "iCloud Drive leads")
        #expect(cloud.places.contains { $0.provider == "GoogleDrive" })
        #expect(cloud.places.filter { $0.provider == "OneDrive" }.count == 2)
    }

    @Test("providers group together, in a stable order")
    func grouping() throws {
        let tree = try TempTree("cloud-grouping")
        defer { tree.remove() }
        let cloud = try service(in: tree)

        let groups = cloud.byProvider
        #expect(groups.map(\.provider) == ["iCloud Drive", "GoogleDrive", "OneDrive"])
        #expect(groups.last?.places.map(\.title) == ["LPPS.A", "Osobisty"])
    }

    @Test("a folder name splits into provider and account on the first hyphen")
    func splitting() {
        #expect(CloudService.split("OneDrive-Osobisty") == ("OneDrive", "Osobisty"))
        // Account halves carry hyphens of their own; only the first one separates.
        #expect(
            CloudService.split("Box-team-eu") == ("Box", "team-eu"))
        #expect(CloudService.split("Dropbox") == ("Dropbox", ""))
    }

    @Test("files sitting in CloudStorage are not offered as places")
    func ignoresFiles() throws {
        let tree = try TempTree("cloud-files")
        defer { tree.remove() }
        let storage = tree.root.appendingPathComponent("CloudStorage")
        try tree.directory("CloudStorage")
        try tree.file("CloudStorage/.DS_Store", bytes: 4)
        let cloud = CloudService(
            cloudStorage: storage,
            mobileDocuments: tree.root.appendingPathComponent("nothing-here")
        )
        #expect(cloud.places.isEmpty)
    }
}

@Suite("Server addresses")
struct NetworkMounterTests {
    @Test("a bare host is taken as SMB")
    func bareHost() throws {
        let address = try #require(NetworkMounter.address(from: "nas.local/media"))
        #expect(address.text == "smb://nas.local/media")
        #expect(address.host == "nas.local")
        #expect(address.scheme == "smb")
    }

    @Test("Windows-style //host/share works too")
    func uncStyle() throws {
        let address = try #require(NetworkMounter.address(from: "//192.168.0.5/Backup"))
        #expect(address.text == "smb://192.168.0.5/Backup")
    }

    @Test("another scheme is left alone")
    func otherSchemes() throws {
        #expect(NetworkMounter.address(from: "afp://mac.local/Files")?.scheme == "afp")
        #expect(NetworkMounter.address(from: "https://dav.example.com/dir")?.scheme == "https")
    }

    @Test("a user in the address is pulled out of it")
    func userInfo() throws {
        let address = try #require(NetworkMounter.address(from: "smb://shalan@nas.local/media"))
        #expect(address.username == "shalan")
        // Stripped from the address itself, so two logins to one share stay one saved server.
        #expect(address.text == "smb://nas.local/media")
    }

    @Test("spaces in a share name survive")
    func spaces() throws {
        let address = try #require(NetworkMounter.address(from: "smb://nas.local/Time Machine"))
        #expect(address.url.path == "/Time Machine")
    }

    @Test("a trailing slash does not make a second spelling of one share")
    func trailingSlash() throws {
        let withSlash = try #require(NetworkMounter.address(from: "smb://nas.local/media/"))
        let without = try #require(NetworkMounter.address(from: "smb://nas.local/media"))
        #expect(withSlash == without)
    }

    @Test("nonsense is refused rather than guessed at")
    func rejectsJunk() {
        #expect(NetworkMounter.address(from: "") == nil)
        #expect(NetworkMounter.address(from: "   ") == nil)
        #expect(NetworkMounter.address(from: "smb://") == nil)
    }

    @Test("an address with no share is refused before anything is mounted")
    func needsAShare() async throws {
        let address = try #require(NetworkMounter.address(from: "smb://nas.local"))
        await #expect(throws: NetworkMounter.MountError.noShareGiven) {
            try await NetworkMounter.mount(address, username: "", password: "")
        }
    }

    @Test("an unmounted share reports no existing mount point")
    func noExistingMount() throws {
        let address = try #require(
            NetworkMounter.address(from: "smb://nowhere.invalid/share"))
        #expect(NetworkMounter.existingMount(for: address) == nil)
    }

    @Test("failures are described in words, not error numbers")
    func errorMessages() {
        #expect(NetworkMounter.describe(Int32(EACCES)).contains("credentials"))
        #expect(NetworkMounter.describe(Int32(ETIMEDOUT)).contains("did not answer"))
    }
}

@MainActor
@Suite("Saved servers")
struct ServerStoreTests {
    private func store(_ label: String) -> (ServerStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shl-servers-\(label)-\(UUID().uuidString).json")
        return (ServerStore(fileURL: url), url)
    }

    @Test("a remembered server survives a reload")
    func persistence() {
        let (store, url) = store("persist")
        defer { try? FileManager.default.removeItem(at: url) }

        store.remember(address: "smb://nas.local/media", username: "shalan")
        #expect(store.servers.count == 1)

        let reloaded = ServerStore(fileURL: url)
        #expect(reloaded.servers.first?.address == "smb://nas.local/media")
        #expect(reloaded.servers.first?.username == "shalan")
    }

    @Test("connecting again updates the entry rather than adding a second one")
    func deduplicates() {
        let (store, url) = store("dedupe")
        defer { try? FileManager.default.removeItem(at: url) }

        store.remember(address: "smb://nas.local/media", username: "shalan")
        store.remember(address: "smb://nas.local/media", username: "someone-else")

        #expect(store.servers.count == 1)
        #expect(store.servers.first?.username == "someone-else")
    }

    @Test("the default name drops the scheme, which is the same on every row")
    func naming() {
        #expect(ServerBookmark.defaultName(for: "smb://nas.local/media") == "nas.local/media")
        #expect(ServerBookmark.defaultName(for: "smb://nas.local") == "nas.local")
    }

    @Test("forgetting a server removes it")
    func removal() {
        let (store, url) = store("remove")
        defer { try? FileManager.default.removeItem(at: url) }

        let bookmark = store.remember(address: "smb://nas.local/media", username: "")
        store.remove(bookmark)
        #expect(store.servers.isEmpty)
        #expect(ServerStore(fileURL: url).servers.isEmpty)
    }
}
