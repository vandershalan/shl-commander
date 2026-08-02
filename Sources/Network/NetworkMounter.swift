import Foundation
import NetFS

/// Mounts network shares through NetFS — the same machinery behind Finder's Connect to Server,
/// so anything Finder can mount (`smb://`, `afp://`, `nfs://`, `ftp://`, `dav://`) works here.
enum NetworkMounter {
    /// What the user typed, once it has been made into something NetFS can take.
    struct Address: Equatable, Sendable {
        /// Without any `user@`, so it is stable enough to key a saved server on.
        let url: URL
        /// Taken from `user@host` when it was typed that way, otherwise empty.
        let username: String

        var scheme: String { url.scheme ?? "smb" }
        var host: String { url.host ?? "" }
        var text: String { url.absoluteString }
    }

    enum MountError: Error, Equatable {
        case malformedAddress
        case noShareGiven
        case failed(code: Int32, message: String)

        var message: String {
            switch self {
            case .malformedAddress:
                return "That is not an address this can connect to."
            case .noShareGiven:
                return "Add the share to the address, as in smb://host/share."
            case .failed(_, let message):
                return message
            }
        }
    }

    /// Turns what was typed into an address.
    ///
    /// A bare `nas.local` or `//nas.local/media` is taken as SMB, which is what a Mac talks to
    /// a NAS or a Windows box with; anything with its own scheme is left alone.
    static func address(from text: String) -> Address? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("//") {
            trimmed = "smb:" + trimmed
        } else if !trimmed.contains("://") {
            trimmed = "smb://" + trimmed
        }

        // Spaces are legal in a share name and illegal in a URL, so they are encoded rather
        // than left to make `URL(string:)` return nil.
        let encoded =
            trimmed.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlQueryAllowed.union(
                    CharacterSet(charactersIn: "/:@[]#"))
            ) ?? trimmed

        guard var components = URLComponents(string: encoded), let host = components.host,
            !host.isEmpty
        else { return nil }

        let username = components.user ?? ""
        components.user = nil
        components.password = nil
        // A trailing slash makes two spellings of one share look like two servers.
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let url = components.url else { return nil }
        return Address(url: url, username: username.removingPercentEncoding ?? username)
    }

    /// Mounts the share and returns where it landed.
    ///
    /// Already-mounted shares come back with their existing mount point rather than an error,
    /// so reconnecting to something the user never ejected simply takes them there.
    static func mount(
        _ address: Address,
        username: String,
        password: String
    ) async throws(MountError) -> URL {
        // NFS aside, every scheme here needs a share: `smb://host` on its own has nothing to
        // mount, and NetFS reports that as an unhelpful generic failure.
        let path = address.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty || address.scheme == "nfs" else { throw MountError.noShareGiven }

        let url = address.url
        let user = username.isEmpty ? nil : username
        let secret = password.isEmpty ? nil : password

        let outcome = await Task.detached {
            Self.mountSync(url: url, user: user, password: secret)
        }.value

        switch outcome {
        case .success(let path):
            return URL(fileURLWithPath: path)
        case .failure(let error):
            throw error
        }
    }

    /// The blocking half, kept off the main actor: NetFS can sit on an unreachable host for
    /// the best part of a minute before giving up.
    private nonisolated static func mountSync(
        url: URL,
        user: String?,
        password: String?
    ) -> Result<String, MountError> {
        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            url as CFURL,
            nil,
            user as CFString?,
            password as CFString?,
            nil,
            nil,
            &mountpoints
        )

        let paths = mountpoints?.takeRetainedValue() as? [String] ?? []
        guard status == 0 else {
            return .failure(.failed(code: status, message: describe(status)))
        }
        guard let first = paths.first else {
            // A zero status with nothing mounted should not happen; treated as a failure
            // rather than returning a path that does not exist.
            return .failure(.failed(code: 0, message: "The share mounted nowhere."))
        }
        return .success(first)
    }

    /// NetFS reports POSIX errors for the ordinary failures, so `strerror` covers most of it;
    /// the few that read badly out of context are spelled out.
    static func describe(_ status: Int32) -> String {
        switch status {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
            return "The server refused those credentials."
        case Int32(ENOENT):
            return "The server has no share by that name."
        case Int32(ECANCELED):
            return "Connecting was cancelled."
        case Int32(ETIMEDOUT), Int32(EHOSTDOWN), Int32(EHOSTUNREACH), Int32(ENETUNREACH):
            return "The server did not answer."
        case Int32(ECONNREFUSED):
            return "The server refused the connection."
        default:
            let text = String(cString: strerror(status))
            return text.isEmpty ? "The mount failed (error \(status))." : text
        }
    }

    /// Where this address is already mounted, if it is.
    ///
    /// Checked before mounting so a reconnect does not stack a second mount point for the same
    /// share (`/Volumes/media-1`), which is what happens if NetFS is simply asked twice.
    static func existingMount(for address: Address) -> URL? {
        let share = address.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !share.isEmpty else { return nil }
        let host = address.host.lowercased()

        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeURLForRemountingKey],
                options: []
            ) ?? []

        return urls.first { url in
            guard
                let remount = try? url.resourceValues(forKeys: [.volumeURLForRemountingKey])
                    .volumeURLForRemounting,
                remount.host?.lowercased() == host
            else { return false }
            let mountedShare = remount.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return mountedShare.caseInsensitiveCompare(share) == .orderedSame
        }
    }
}
