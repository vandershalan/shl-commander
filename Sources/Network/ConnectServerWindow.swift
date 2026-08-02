import AppKit
import Observation
import SwiftUI

/// The Connect to Server window: type an address, or pick one that was saved earlier.
///
/// Built imperatively like the shortcut list, because it is opened from `CommandDispatcher`,
/// which is not a View.
@MainActor
enum ConnectServerWindow {
    private static var window: NSWindow?

    /// `onMounted` receives the mount point, which is what the active pane should open.
    static func show(onMounted: @escaping (URL) -> Void) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let reference = AuxiliaryWindow.referenceWindow()
        let scale = UIScale(factor: AppSettings.shared.uiScale)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: scale(520), height: scale(420)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        let model = ConnectServerModel(
            onMounted: onMounted,
            onFinished: { [weak panel] in panel?.performClose(nil) }
        )
        panel.title = "Connect to Server"
        panel.contentView = NSHostingView(rootView: ConnectServerView(model: model).appZoom())
        panel.isReleasedWhenClosed = false
        AuxiliaryWindow.centre(panel, over: reference)
        AuxiliaryWindow.closeOnEscape(panel)
        panel.makeKeyAndOrderFront(nil)
        window = panel

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { window = nil }
        }
    }
}

@MainActor
@Observable
final class ConnectServerModel {
    var address = ""
    var username = ""
    var password = ""
    /// Off once the password came out of the Keychain: it is already there.
    var savePassword = true
    var status: String?
    var isConnecting = false

    let store: ServerStore
    private let onMounted: (URL) -> Void
    private let onFinished: () -> Void

    init(
        store: ServerStore = .shared,
        onMounted: @escaping (URL) -> Void,
        onFinished: @escaping () -> Void
    ) {
        self.store = store
        self.onMounted = onMounted
        self.onFinished = onFinished
    }

    /// Fills the fields from a saved server, pulling its password out of the Keychain when one
    /// was kept, so connecting again is one keystroke.
    func select(_ bookmark: ServerBookmark) {
        address = bookmark.address
        username = bookmark.username
        let scheme = bookmark.url?.scheme ?? "smb"
        if let saved = ServerKeychain.password(
            host: bookmark.host, account: bookmark.username, scheme: scheme)
        {
            password = saved
            savePassword = false
        } else {
            password = ""
            savePassword = true
        }
        status = nil
    }

    func remove(_ bookmark: ServerBookmark) {
        store.remove(bookmark)
    }

    var canConnect: Bool {
        !isConnecting && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func connect() async {
        guard canConnect else { return }
        guard let parsed = NetworkMounter.address(from: address) else {
            status = NetworkMounter.MountError.malformedAddress.message
            return
        }
        // `user@host` in the address is as good as typing it in the field.
        let user = username.isEmpty ? parsed.username : username

        // Already mounted: take them there rather than stacking a second mount point.
        if let mounted = NetworkMounter.existingMount(for: parsed) {
            finish(with: mounted, address: parsed, username: user)
            return
        }

        isConnecting = true
        status = "Connecting to \(parsed.host)…"
        defer { isConnecting = false }

        var secret = password
        if secret.isEmpty, !user.isEmpty {
            secret =
                ServerKeychain.password(host: parsed.host, account: user, scheme: parsed.scheme)
                ?? ""
        }

        do {
            let mountPoint = try await NetworkMounter.mount(
                parsed, username: user, password: secret)
            if savePassword, !secret.isEmpty, !user.isEmpty {
                ServerKeychain.save(
                    password: secret, host: parsed.host, account: user, scheme: parsed.scheme)
            }
            finish(with: mountPoint, address: parsed, username: user)
        } catch {
            status = error.message
        }
    }

    private func finish(with mountPoint: URL, address: NetworkMounter.Address, username: String) {
        store.remember(address: address.text, username: username)
        onMounted(mountPoint)
        onFinished()
    }
}

struct ConnectServerView: View {
    @Bindable var model: ConnectServerModel

    @Environment(\.uiScale) private var scale
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: scale(12)) {
            field("Address", placeholder: "smb://host/share", text: $model.address)
                .focused($addressFocused)
            HStack(spacing: scale(10)) {
                field("Name", placeholder: "optional", text: $model.username)
                secureField("Password", text: $model.password)
            }
            Toggle("Remember the password in the Keychain", isOn: $model.savePassword)
                .toggleStyle(.checkbox)
                .font(.system(size: scale(11)))

            if !model.store.servers.isEmpty { saved }

            if let status = model.status {
                Text(status)
                    .font(.system(size: scale(11)))
                    .foregroundStyle(model.isConnecting ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: scale(10)) {
                Text("SMB, AFP, NFS, FTP and WebDAV addresses all work.")
                    .font(.system(size: scale(10)))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: scale(8))
                if model.isConnecting { ProgressView().controlSize(.small) }
                Button("Connect") { Task { await model.connect() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConnect)
            }
        }
        .padding(scale(20))
        .font(.system(size: scale(12)))
        .task {
            await Task.yield()
            addressFocused = true
        }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: scale(4)) {
            Text("SAVED")
                .font(.system(size: scale(10), weight: .bold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.store.servers) { bookmark in
                        row(bookmark)
                    }
                }
            }
            .frame(maxHeight: scale(140))
            .background(
                Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
        }
    }

    private func row(_ bookmark: ServerBookmark) -> some View {
        HStack(spacing: scale(6)) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(bookmark.name).font(.system(size: scale(12)))
                Text(bookmark.username.isEmpty ? bookmark.address : "\(bookmark.username)@\(bookmark.address)")
                    .font(.system(size: scale(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, scale(8))
        .padding(.vertical, scale(4))
        .contentShape(Rectangle())
        // One click fills the fields, so the address can still be edited before connecting;
        // two connects outright.
        .onTapGesture(count: 2) {
            model.select(bookmark)
            Task { await model.connect() }
        }
        .onTapGesture { model.select(bookmark) }
        .contextMenu {
            Button("Connect") {
                model.select(bookmark)
                Task { await model.connect() }
            }
            Button("Forget") { model.remove(bookmark) }
        }
    }

    private func field(
        _ label: String, placeholder: String, text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: scale(3)) {
            Text(label)
                .font(.system(size: scale(10)))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: scale(12), design: .monospaced))
        }
    }

    private func secureField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: scale(3)) {
            Text(label)
                .font(.system(size: scale(10)))
                .foregroundStyle(.secondary)
            SecureField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: scale(12)))
        }
    }
}
