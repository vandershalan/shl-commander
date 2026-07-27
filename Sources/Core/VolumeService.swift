import AppKit
import Observation

/// Mounted volumes, kept current as disks come and go.
@MainActor
@Observable
final class VolumeService {
    struct Volume: Identifiable, Hashable, Sendable {
        let url: URL
        let name: String
        let isRemovable: Bool
        let isEjectable: Bool
        let totalCapacity: Int64
        let availableCapacity: Int64

        var id: URL { url }
        /// Removable and ejectable are distinct: an external SSD is ejectable but not
        /// removable media, and both should offer Eject.
        var canEject: Bool { isEjectable || isRemovable }
    }

    private(set) var volumes: [Volume] = []

    /// `@ObservationIgnored` keeps the macro from wrapping it in a computed property, which
    /// `nonisolated(unsafe)` cannot be applied to. `nonisolated(unsafe)` in turn lets `deinit`,
    /// which is never actor-isolated, unregister. Written once in `init` and read once in
    /// `deinit`, both outside any concurrency.
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            )
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeIsRemovableKey,
        .volumeIsEjectableKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeIsBrowsableKey,
    ]

    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)),
                values.volumeIsBrowsable != false
            else { return nil }
            return Volume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                totalCapacity: Int64(values.volumeTotalCapacity ?? 0),
                availableCapacity: Int64(values.volumeAvailableCapacity ?? 0)
            )
        }
    }

    /// Returns an error message on failure.
    func eject(_ volume: Volume) -> String? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            refresh()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The volume a path lives on, used to label the pane's volume picker.
    func volume(containing url: URL) -> Volume? {
        guard
            let mount = try? url.resourceValues(forKeys: [.volumeURLKey]).volume?
                .standardizedFileURL
        else { return nil }
        return volumes.first { $0.url.standardizedFileURL.path == mount.path }
    }
}
