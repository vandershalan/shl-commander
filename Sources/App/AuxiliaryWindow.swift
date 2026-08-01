import AppKit

/// Shared behaviour for the app's secondary windows — the shortcut list and the internal viewer.
///
/// These are real windows rather than sheets so they can be left open beside the panes, but a
/// window that opens in the middle of the screen and cannot be dismissed with Escape does not
/// behave like part of the app.
@MainActor
enum AuxiliaryWindow {
    /// Centres `window` over `reference`, or over the screen when there is nothing to centre on.
    ///
    /// `NSWindow.center()` centres on the screen, which puts a panel nowhere near the window it
    /// belongs to as soon as that window is off to one side.
    static func centre(_ window: NSWindow, over reference: NSWindow?) {
        guard let frame = reference?.frame, frame.width > 0 else {
            window.center()
            return
        }
        let size = window.frame.size
        var origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )

        // Kept on screen: centring over a window near an edge can otherwise push the panel's
        // title bar out of reach.
        if let visible = reference?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        window.setFrameOrigin(origin)
    }

    /// The window a panel should appear over: whatever is frontmost that is not the panel itself.
    static func referenceWindow(excluding window: NSWindow? = nil) -> NSWindow? {
        if let key = NSApp.keyWindow, key !== window, key.isVisible { return key }
        if let main = NSApp.mainWindow, main !== window, main.isVisible { return main }
        return NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeKey }
    }

    /// Closes the window when Escape is pressed anywhere inside it.
    ///
    /// A local monitor rather than an `NSResponder` override: the search field inside the shortcut
    /// list is first responder, and a text field swallows Escape before the window ever sees
    /// `cancelOperation`. The monitor is scoped to this one window and removed when it closes, so
    /// it never intercepts Escape meant for the panes.
    static func closeOnEscape(_ window: NSWindow) {
        EscapeCloser.install(on: window)
    }
}

/// Holds the monitor and observer tokens for one window's Escape handling.
///
/// A class rather than locals in a function: the two closures both have to reach the same tokens
/// to tear them down, and captured `var`s cannot cross into a `@Sendable` closure.
@MainActor
private final class EscapeCloser {
    /// Kept alive until the window closes; nothing else owns these.
    private static var live: Set<ObjectIdentifier> = []
    private static var instances: [ObjectIdentifier: EscapeCloser] = [:]

    private var monitor: Any?
    private var observer: (any NSObjectProtocol)?

    static func install(on window: NSWindow) {
        let closer = EscapeCloser()
        let id = ObjectIdentifier(closer)
        live.insert(id)
        instances[id] = closer
        closer.start(window: window, id: id)
    }

    private func start(window: NSWindow, id: ObjectIdentifier) {
        // The handler is already main-actor isolated, and NSEvent is not Sendable, so it must not
        // be carried across an isolation boundary.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                event.window === window
            else { return event }
            window.performClose(nil)
            return nil
        }

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { EscapeCloser.tearDown(id) }
        }
    }

    private static func tearDown(_ id: ObjectIdentifier) {
        guard let closer = instances[id] else { return }
        if let monitor = closer.monitor { NSEvent.removeMonitor(monitor) }
        if let observer = closer.observer {
            NotificationCenter.default.removeObserver(observer)
        }
        closer.monitor = nil
        closer.observer = nil
        instances[id] = nil
        live.remove(id)
    }
}
