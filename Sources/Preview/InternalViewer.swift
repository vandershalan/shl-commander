import AppKit

/// A plain read-only viewer for files Quick Look renders poorly or not at all — logs, config
/// files with unusual extensions, and binaries, which are shown as a hex dump.
@MainActor
enum InternalViewer {
    /// Read at most this much: the viewer is for looking, not for loading a DVD image.
    private static let byteLimit = 1 << 20  // 1 MiB

    private static var windows: [NSWindow] = []

    static func show(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            OperationPrompts.report([
                OperationFailure(url: url, message: "Could not open the file for reading.")
            ])
            return
        }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: byteLimit)) ?? Data()
        let truncated = data.count == byteLimit
        let body = render(data)

        present(
            title: url.lastPathComponent + (truncated ? " (first 1 MB)" : ""),
            text: body
        )
    }

    /// Text if it decodes as UTF-8, hex otherwise.
    static func render(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        return hexDump(data)
    }

    /// `00000000  48 65 6c 6c 6f 00 01 02  |Hello...|`
    static func hexDump(_ data: Data, bytesPerLine: Int = 16) -> String {
        var lines: [String] = []
        lines.reserveCapacity(data.count / bytesPerLine + 1)

        for offset in stride(from: 0, to: data.count, by: bytesPerLine) {
            let chunk = data[offset..<min(offset + bytesPerLine, data.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let padding = String(
                repeating: "   ",
                count: max(0, bytesPerLine - chunk.count)
            )
            let ascii = String(
                chunk.map { byte in
                    (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "."
                }
            )
            lines.append(String(format: "%08x  ", offset) + hex + padding + "  |\(ascii)|")
        }
        return lines.joined(separator: "\n")
    }

    private static func present(title: String, text: String) {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = text
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        // Same treatment as the shortcut list: centred on the window it came from, and Escape
        // closes it.
        AuxiliaryWindow.centre(window, over: AuxiliaryWindow.referenceWindow())
        AuxiliaryWindow.closeOnEscape(window)
        window.makeKeyAndOrderFront(nil)

        // Held so the window is not deallocated the moment this function returns, and dropped
        // again once the user closes it.
        windows.append(window)
        // The window is captured directly rather than read back off the notification, which
        // is not Sendable and cannot cross into the main-actor closure.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [window] _ in
            MainActor.assumeIsolated {
                windows.removeAll { $0 === window }
            }
        }
    }
}
