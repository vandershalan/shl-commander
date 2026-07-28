import AppKit
import SwiftUI

struct PreferencesView: View {
    let state: AppState

    var body: some View {
        TabView {
            GeneralPreferences(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            KeyboardPreferences(state: state)
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    let state: AppState
    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Restore the last session",
                    isOn: Binding(
                        get: { settings.restoreSession },
                        set: { settings.restoreSession = $0 }
                    )
                )
                LabeledContent("Left pane") {
                    directoryRow(
                        path: settings.leftStartDirectory,
                        set: { settings.leftStartDirectory = $0 }
                    )
                }
                LabeledContent("Right pane") {
                    directoryRow(
                        path: settings.rightStartDirectory,
                        set: { settings.rightStartDirectory = $0 }
                    )
                }
                .disabled(settings.restoreSession)
            }

            Section("Panels") {
                Toggle(
                    "Show hidden files by default",
                    isOn: Binding(
                        get: { settings.showHiddenByDefault },
                        set: { settings.showHiddenByDefault = $0 }
                    )
                )
            }

            Section("Editor") {
                LabeledContent("F4 opens files in") {
                    HStack {
                        Text(settings.editorName).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…", action: chooseEditor)
                        Button("System Default") { settings.editorBundleIdentifier = "" }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func directoryRow(path: String, set: @escaping (String) -> Void) -> some View {
        HStack {
            Text(path)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.directoryURL = URL(fileURLWithPath: path)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                set(url.path)
            }
        }
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
            let bundle = Bundle(url: url)?.bundleIdentifier
        else { return }
        AppSettings.shared.editorBundleIdentifier = bundle
    }
}

// MARK: - Keyboard

private struct KeyboardPreferences: View {
    let state: AppState

    @State private var selection: Command?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Recording replaces a command's bindings. A key already used elsewhere is taken from the other command."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            List(Command.allCases, id: \.self, selection: $selection) { command in
                HStack {
                    Text(command.title)
                    Spacer()
                    Text(
                        state.keymap.chords(for: command)
                            .map(\.displayName)
                            .joined(separator: "   ")
                    )
                    .foregroundStyle(.secondary)
                    .monospaced()
                }
                .tag(command)
            }
            .listStyle(.inset)

            HStack {
                Button(recording ? "Press a key…" : "Record Shortcut") { startRecording() }
                    .disabled(selection == nil || recording)
                Button("Clear") { rebind(to: []) }
                    .disabled(selection == nil || recording)
                Spacer()
                Button("Reset All to Defaults") { apply(.defaults) }
                Button("Reveal keymap.json") { revealKeymapFile() }
            }

            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        guard selection != nil else { return }
        recording = true
        status = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape abandons the recording rather than binding Escape itself.
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            rebind(to: [KeyChord(event: event)])
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func rebind(to chords: [KeyChord]) {
        guard let selection else { return }
        apply(state.keymap.rebinding(selection, to: chords))
    }

    private func apply(_ keymap: Keymap) {
        state.keymap = keymap
        let saved = keymap.writeToDisk()
        // Menu shortcuts are installed once at launch and SwiftUI does not rebuild them on
        // demand, so say so rather than letting the menu look out of date for no reason.
        status =
            saved
            ? "Saved. Keys work now; menu shortcuts update after a relaunch."
            : "Could not write keymap.json."
    }

    private func revealKeymapFile() {
        if !FileManager.default.fileExists(atPath: Keymap.userKeymapURL.path) {
            state.keymap.writeToDisk()
        }
        NSWorkspace.shared.activateFileViewerSelecting([Keymap.userKeymapURL])
    }
}
