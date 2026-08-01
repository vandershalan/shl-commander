import AppKit
import SwiftUI

/// Standalone window listing every binding, built from the live keymap.
///
/// A real window rather than a sheet, so it can be left open beside the panes while learning
/// the keys. Built imperatively because it is opened from `CommandDispatcher`, which is not a
/// View and so cannot reach SwiftUI's `openWindow` action.
@MainActor
enum ShortcutsWindow {
    private static var window: NSWindow?

    static func show(keymap: Keymap) {
        // Rebuilt on every open so a rebind made in Settings is reflected straight away.
        let hosting = NSHostingView(rootView: ShortcutsView(keymap: keymap).appZoom())

        if let existing = window {
            existing.contentView = hosting
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Captured before the panel exists, so it cannot end up centring over itself.
        let reference = AuxiliaryWindow.referenceWindow()

        // Sized for the zoom in force when it first opens; after that the user's own resizing
        // wins, so a later ⌘+ reflows the list inside whatever size the window has.
        let scale = UIScale(factor: AppSettings.shared.uiScale)
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: scale(620), height: scale(680)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard Shortcuts"
        panel.contentView = hosting
        panel.isReleasedWhenClosed = false
        AuxiliaryWindow.centre(panel, over: reference)
        // Centred only on creation: re-centring on every open would drag a window the user had
        // deliberately moved back under the pointer.
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

struct ShortcutsView: View {
    let keymap: Keymap

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            ScrollView {
                // Eager rather than lazy: the list is a few dozen fixed rows, so laziness buys
                // nothing and costs a layout pass that offscreen rendering does not perform.
                VStack(alignment: .leading, spacing: scale(18)) {
                    ForEach(sections, id: \.section) { group in
                        section(group.section, commands: group.commands)
                    }
                    if matchesNothing {
                        Text("No command matches \u{201C}\(query)\u{201D}.")
                            .font(.system(size: scale(12)))
                            .foregroundStyle(.secondary)
                            .padding(.top, scale(8))
                    }
                    if query.isEmpty { alsoWorth }
                }
                .padding(scale(16))
            }
        }
        .task {
            // Yielding first lets the window finish becoming key: a focus request made while the
            // window still cannot take focus is simply dropped, and the field stays inert.
            await Task.yield()
            isSearchFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: scale(6)) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter commands or keys", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: scale(13)))
                // Focused on open, so the window can be typed into straight away — which is the
                // point of having a search field on a list this long.
                .focused($isSearchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, scale(12))
        .frame(height: scale(34))
    }

    private func section(_ section: Command.Section, commands: [Command]) -> some View {
        VStack(alignment: .leading, spacing: scale(6)) {
            Text(section.title.uppercased())
                .font(.system(size: scale(10), weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(commands, id: \.self) { command in
                HStack(alignment: .firstTextBaseline, spacing: scale(10)) {
                    Text(command.title)
                        .font(.system(size: scale(12)))
                    Spacer(minLength: scale(12))
                    let chords = keymap.chords(for: command)
                    if chords.isEmpty {
                        Text("unbound")
                            .font(.system(size: scale(11)))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(chords, id: \.self) { chord in
                            keyCap(chord.displayName)
                        }
                    }
                }
            }
        }
    }

    /// Behaviour that has no chord of its own and so would otherwise go undocumented.
    private var alsoWorth: some View {
        VStack(alignment: .leading, spacing: scale(6)) {
            Text("ALSO")
                .font(.system(size: scale(10), weight: .bold))
                .foregroundStyle(.secondary)
            ForEach(Self.extras, id: \.0) { item in
                HStack(alignment: .firstTextBaseline, spacing: scale(10)) {
                    Text(item.1).font(.system(size: scale(12)))
                    Spacer(minLength: scale(12))
                    keyCap(item.0)
                }
            }
        }
    }

    private static let extras: [(String, String)] = [
        ("any letter", "Start the quick filter"),
        ("⌫", "Edit the quick filter while its bar is showing"),
        ("⎋", "Close the filter bar, or cancel a running operation"),
        ("click header", "Sort by that column; click again to reverse"),
        ("double-click", "Open"),
        ("drag", "Reorder a favourite, or move the pane divider"),
    ]

    private func keyCap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scale(11), weight: .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, scale(6))
            .padding(.vertical, scale(2))
            .background(
                Color.secondary.opacity(0.18),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )
            .fixedSize()
    }

    // MARK: - Filtering

    private var sections: [(section: Command.Section, commands: [Command])] {
        let matching = Set(commands(matching: query))
        return Command.Section.allCases.compactMap { section in
            let commands = Command.allCases.filter {
                $0.section == section && matching.contains($0)
            }
            return commands.isEmpty ? nil : (section, commands)
        }
    }

    private var matchesNothing: Bool {
        !query.isEmpty && sections.isEmpty
    }

    /// Commands a query matches, by name or by any of their keys — so both "trash" and "F8"
    /// find Move to Trash, and `cmd+backspace` does too.
    ///
    /// An unbound command still matches on its name, so it can be found here and then given a
    /// key in Settings.
    func commands(matching query: String) -> [Command] {
        guard !query.isEmpty else { return Command.allCases }
        let needle = query.lowercased()
        return Command.allCases.filter { command in
            if command.title.lowercased().contains(needle) { return true }
            if command.rawValue.lowercased().contains(needle) { return true }
            return keymap.chords(for: command).contains { chord in
                chord.displayName.lowercased().contains(needle)
                    || chord.canonicalName.lowercased().contains(needle)
            }
        }
    }
}
