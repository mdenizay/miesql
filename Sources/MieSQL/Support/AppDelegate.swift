import AppKit

/// SwiftUI's `defaultSize` is a hint, and on a fresh launch the window can still come up
/// narrower than the layout needs. Setting the frame and the minimum size directly is the
/// reliable way to get a first-run window that fits the sidebar and a result grid.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let preferredSize = NSSize(width: 1240, height: 800)
    private static let minimumSize = NSSize(width: 900, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The window exists by the next runloop turn, not yet at this point.
        DispatchQueue.main.async { self.configureMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        window.minSize = Self.minimumSize

        // Leave a window the user has already sized alone; only grow one that came up small.
        let current = window.frame.size
        guard current.width < Self.preferredSize.width || current.height < Self.preferredSize.height else { return }

        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = NSSize(
            width: min(Self.preferredSize.width, visible.width - 40),
            height: min(Self.preferredSize.height, visible.height - 40)
        )
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }
}
