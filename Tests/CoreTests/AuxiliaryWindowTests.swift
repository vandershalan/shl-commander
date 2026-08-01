import AppKit
import Testing

@testable import ShlCommander

@MainActor
@Suite("Auxiliary windows")
struct AuxiliaryWindowTests {
    private func window(_ rect: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        // A programmatically created NSWindow releases itself on close by default, which
        // over-releases anything ARC is still holding — that crashed the whole test host.
        window.isReleasedWhenClosed = false
        return window
    }

    @Test("a panel is centred on the window it belongs to, not on the screen")
    func centresOverReference() {
        // Deliberately off-centre, so screen-centring and window-centring cannot be confused.
        let reference = window(NSRect(x: 60, y: 80, width: 1000, height: 620))
        let panel = window(NSRect(x: 0, y: 0, width: 400, height: 300))

        AuxiliaryWindow.centre(panel, over: reference)

        #expect(abs(panel.frame.midX - reference.frame.midX) < 1)
        #expect(abs(panel.frame.midY - reference.frame.midY) < 1)
    }

    @Test("with nothing to centre over it falls back to the screen")
    func fallsBackToScreen() {
        let panel = window(NSRect(x: 0, y: 0, width: 400, height: 300))
        AuxiliaryWindow.centre(panel, over: nil)

        let screen = try? #require(NSScreen.main?.frame)
        if let screen {
            // NSWindow.center places a window slightly above the exact middle, by design.
            #expect(abs(panel.frame.midX - screen.midX) < 2)
        }
    }

    @Test("a panel is kept on screen even when its window sits at the edge")
    func clampsToVisibleFrame() throws {
        let visible = try #require(NSScreen.main?.visibleFrame)
        // A window jammed into the bottom-left corner would otherwise push a large panel's title
        // bar off screen, where it cannot be grabbed.
        let reference = window(
            NSRect(x: visible.minX, y: visible.minY, width: 300, height: 200))
        let panel = window(NSRect(x: 0, y: 0, width: 620, height: 700))

        AuxiliaryWindow.centre(panel, over: reference)

        #expect(panel.frame.minX >= visible.minX - 1)
        #expect(panel.frame.minY >= visible.minY - 1)
        #expect(panel.frame.maxX <= visible.maxX + 1)
        #expect(panel.frame.maxY <= visible.maxY + 1)
    }

    @Test("the reference window is never the panel itself")
    func referenceExcludesThePanel() {
        // Not ordered front: a test has no business rearranging the host app's windows, and
        // creating one is enough for it to appear in NSApp.windows.
        let panel = window(NSRect(x: 0, y: 0, width: 400, height: 300))

        // Centring a panel over itself would leave it exactly where it already was.
        #expect(AuxiliaryWindow.referenceWindow(excluding: panel) !== panel)
    }
}
