#if DEBUG
    import AppKit

    /// Development aid: dumps the window as a PNG plus an indented view tree with frames.
    ///
    /// Exists because verifying layout otherwise needs Screen Recording permission, which a
    /// terminal-driven build cannot grant itself. Inert unless `SHL_PROBE_PNG` is set, and
    /// compiled out of Release entirely.
    ///
    ///     SHL_PROBE_PNG=/tmp/panel.png ./shl-commander.app/Contents/MacOS/shl-commander
    ///
    /// Note that SwiftUI-drawn content (`Text`, `Divider`) has no backing `NSView` and does
    /// not appear in either the PNG or the tree — only its reserved space does.
    enum RenderProbe {
        static func run() {
            guard let path = ProcessInfo.processInfo.environment["SHL_PROBE_PNG"] else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let view = NSApp.windows.first?.contentView else {
                    NSLog("PROBE no window")
                    return
                }
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                }
                NSLog("PROBE content=%@", NSStringFromRect(view.bounds))
                dump(view, depth: 0)
            }
        }

        private static func dump(_ view: NSView, depth: Int) {
            guard depth < 14 else { return }
            let label = (view as? NSTextField).map { " text=\u{22}\($0.stringValue)\u{22}" } ?? ""
            NSLog(
                "PROBE %@%@ %@%@",
                String(repeating: "  ", count: depth),
                view.className,
                NSStringFromRect(view.frame),
                label
            )
            for sub in view.subviews { dump(sub, depth: depth + 1) }
        }
    }
#endif
