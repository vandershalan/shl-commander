import AppKit
import SwiftUI

/// The Finder's ⌘I, for the pane's selection.
///
/// A window rather than a sheet, and one per selection: two files can be compared side by side,
/// which is the main thing the Finder's own panel is used for.
@MainActor
enum InfoWindow {
    private static var windows: [NSWindow] = []

    static func show(for entries: [FileEntry], in directory: URL) {
        let urls = entries.filter { !$0.isParent && !$0.isArchiveMember }.map(\.url)
        // Nothing selected, or a selection that has no path on disk: the folder itself is then
        // the only honest subject, which is also what ⌘I on an empty Finder window shows.
        let subjects = urls.isEmpty ? [directory] : urls

        let model = InfoModel(urls: subjects)
        let scale = UIScale(factor: AppSettings.shared.uiScale)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: scale(420), height: scale(520)),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.title
        window.contentView = NSHostingView(rootView: InfoView(model: model).appZoom())
        window.isReleasedWhenClosed = false
        AuxiliaryWindow.centre(window, over: AuxiliaryWindow.referenceWindow())
        AuxiliaryWindow.closeOnEscape(window)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [window] _ in
            MainActor.assumeIsolated {
                model.cancelMeasuring()
                windows.removeAll { $0 === window }
            }
        }
    }
}

@MainActor
@Observable
final class InfoModel {
    let urls: [URL]
    private(set) var items: [ItemInfo] = []
    /// Nil until the walk finishes; folders and multi-selections need one.
    private(set) var totals: TreeTotals?
    private(set) var isMeasuring = false

    @ObservationIgnored private var measuring: Task<Void, Never>?

    init(urls: [URL]) {
        self.urls = urls
        // Cheap enough to do synchronously: a dozen resource values per item, and the window
        // would otherwise open empty and flash into place.
        items = urls.map(ItemInfo.gather)
        measure()
    }

    var title: String {
        guard let single = items.first, items.count == 1 else { return "\(items.count) Items" }
        return single.name
    }

    var isSingleFile: Bool { items.count == 1 && items[0].isDirectory == false }

    /// True when the size shown has to come from walking a tree rather than from one stat call.
    var needsWalk: Bool { !isSingleFile }

    private func measure() {
        guard needsWalk else { return }
        isMeasuring = true
        let urls = self.urls
        measuring = Task { [weak self] in
            let totals = await Task.detached(priority: .utility) {
                TreeTotals.measure(urls, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            self?.totals = totals
            self?.isMeasuring = false
        }
    }

    func cancelMeasuring() {
        measuring?.cancel()
        measuring = nil
    }
}

struct InfoView: View {
    let model: InfoModel

    @Environment(\.uiScale) private var scale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scale(14)) {
                header
                Divider()
                if model.items.count == 1, let item = model.items.first {
                    single(item)
                } else {
                    many
                }
            }
            .padding(scale(18))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: scale(12)))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: scale(12)) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: scale(52), height: scale(52))
            VStack(alignment: .leading, spacing: scale(2)) {
                Text(model.title)
                    .font(.system(size: scale(15), weight: .semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let item = model.items.first, model.items.count == 1 {
                    Text(item.kind).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: NSImage {
        guard let first = model.items.first else { return NSImage() }
        let image = NSWorkspace.shared.icon(forFile: first.url.path)
        image.size = NSSize(width: 64, height: 64)
        return image
    }

    @ViewBuilder
    private func single(_ item: ItemInfo) -> some View {
        section("General") {
            row("Size", sizeText(for: item))
            if let children = item.childCount {
                row("Contains", "\(children) item\(children == 1 ? "" : "s") at the top level")
            }
            row("Where", item.location)
            row("Kind", item.kind)
            row("Type", item.typeIdentifier)
            if let target = item.symlinkTarget {
                row("Symlink to", target)
            }
            if let volume = item.volumeName {
                row("Volume", volume)
            }
        }

        section("Dates") {
            row("Created", Self.date(item.created))
            row("Modified", Self.date(item.modified))
            row("Last opened", Self.date(item.accessed))
        }

        section("Permissions") {
            row("Owner", "\(item.owner):\(item.group)")
            row("Mode", item.mode)
            row("Flags", flags(item))
        }

        section("Path") {
            Text(item.url.path)
                .font(.system(size: scale(11), design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var many: some View {
        section("Selection") {
            row("Items", "\(model.items.count)")
            row("Size", sizeText(for: nil))
            if let totals = model.totals {
                row("Files", "\(totals.files)")
                row("Folders", "\(totals.directories)")
            }
            if let first = model.items.first {
                row("Where", first.location)
            }
        }

        section("Items") {
            VStack(alignment: .leading, spacing: scale(2)) {
                ForEach(model.items, id: \.url) { item in
                    HStack(spacing: scale(6)) {
                        Text(item.name).lineLimit(1)
                        Spacer(minLength: scale(8))
                        Text(item.kind)
                            .font(.system(size: scale(10)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// One line for both the logical size and the disk footprint, the way the Finder shows
    /// "1,2 MB (1 234 567 bytes)" — the difference is what tells you a file is sparse or a
    /// folder is full of tiny files.
    private func sizeText(for item: ItemInfo?) -> String {
        if let item, let size = item.size {
            let onDisk = item.sizeOnDisk.map { " (\(Formatters.size($0)) on disk)" } ?? ""
            return "\(Formatters.size(size))\(onDisk), \(size) bytes"
        }
        guard let totals = model.totals else {
            return model.isMeasuring ? "Measuring…" : "—"
        }
        return "\(Formatters.size(totals.bytes))"
            + " (\(Formatters.size(totals.sizeOnDisk)) on disk), \(totals.bytes) bytes"
    }

    private func flags(_ item: ItemInfo) -> String {
        var parts: [String] = []
        if item.isDirectory { parts.append(item.isPackage ? "package" : "folder") }
        if item.isHidden { parts.append("hidden") }
        if item.symlinkTarget != nil { parts.append("symlink") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: scale(5)) {
            Text(title.uppercased())
                .font(.system(size: scale(10), weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: scale(8)) {
            Text(label)
                .frame(width: scale(90), alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return formatter.string(from: value)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
