import Foundation
import Testing

@testable import ShlCommander

@Suite("iCloud Drive app folders")
struct ICloudDriveTests {
    /// A fake `Mobile Documents`: the drive, one public app container, one private one, and one
    /// whose `Documents` is not shared.
    private func layout(_ tree: TempTree) throws -> URL {
        try tree.directory("Mobile Documents/com~apple~CloudDocs/Notes")
        try tree.directory("Mobile Documents/iCloud~com~example~koala/Documents/Songs")
        let hidden = try tree.directory("Mobile Documents/iCloud~com~example~secret/Documents")
        try hide(hidden.deletingLastPathComponent())
        let unshared = try tree.directory("Mobile Documents/iCloud~com~example~vault/Documents")
        try hide(unshared)
        return tree.root.appendingPathComponent("Mobile Documents")
    }

    private func hide(_ url: URL) throws {
        var values = URLResourceValues()
        values.isHidden = true
        var url = url
        try url.setResourceValues(values)
    }

    @Test("public app containers are listed by name, pointing at their Documents")
    func appFolders() throws {
        let tree = try TempTree("icloud-apps")
        defer { tree.remove() }
        let documents = try layout(tree)

        let shown = ICloudDrive.appFolders(in: documents, includeHidden: false)
        #expect(shown.count == 1)
        #expect(shown.first?.url.lastPathComponent == "Documents")
        #expect(shown.first?.url.deletingLastPathComponent().lastPathComponent
            == "iCloud~com~example~koala")
        #expect(shown.first?.isCloudAppFolder == true)

        let all = ICloudDrive.appFolders(in: documents, includeHidden: true)
        #expect(all.count == 3, "hidden containers appear with hidden files shown")
        #expect(all.filter(\.isHidden).count == 2)
    }

    @Test("an app folder leads back to the drive, and reads as part of it")
    func parentAndPath() throws {
        let tree = try TempTree("icloud-parent")
        defer { tree.remove() }
        let documents = try layout(tree)
        let drive = ICloudDrive.root(in: documents)
        let app = documents.appendingPathComponent("iCloud~com~example~koala/Documents")
        let name = ICloudDrive.appName(ofContainer: app.deletingLastPathComponent())

        #expect(ICloudDrive.parent(of: app, in: documents)?.path == drive.path)
        #expect(ICloudDrive.parent(of: app.appendingPathComponent("Songs"), in: documents) == nil)
        #expect(ICloudDrive.parent(of: drive.appendingPathComponent("Documents"), in: documents)
            == nil, "a folder called Documents inside the drive is just a folder")

        #expect(ICloudDrive.friendlyPath(of: drive, in: documents) == "iCloud Drive")
        #expect(ICloudDrive.friendlyPath(of: drive.appendingPathComponent("Notes"), in: documents)
            == "iCloud Drive/Notes")
        #expect(ICloudDrive.friendlyPath(of: app.appendingPathComponent("Songs"), in: documents)
            == "iCloud Drive/\(name)/Songs")
        #expect(ICloudDrive.friendlyPath(of: tree.root, in: documents) == nil)

        #expect(ICloudDrive.title(of: drive, in: documents) == "iCloud Drive")
        #expect(ICloudDrive.title(of: app, in: documents) == name)
    }
}
