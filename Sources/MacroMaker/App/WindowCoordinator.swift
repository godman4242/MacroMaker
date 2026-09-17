import AppKit
import SwiftUI

/// Owns Macro Maker's windows. AppKit-managed rather than SwiftUI scenes so they can be opened
/// from anywhere — a hotkey, the menu bar, a Finder double-click — even with no Dock icon.
@MainActor
final class WindowCoordinator {
    enum Kind {
        case main, settings
    }

    /// A window showing the given tab (main) or just the settings pane.
    func show(_ kind: Kind, tab: AppTab? = nil) {
        if let tab { AppModel.shared.selectedTab = tab }
        show(kind)
    }

    static let shared = WindowCoordinator()
    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind) {
        let window: NSWindow
        if let existing = windows[kind] {
            window = existing
        } else {
            window = makeWindow(kind)
            // A saved frame can exceed this screen (saved on a bigger display, or grown by
            // a pre-fix build's unbounded layout): a 1050pt-tall window on a 1050pt screen
            // straddles the menu bar, which then hides the title bar. Re-center the frame
            // inside the VISIBLE area — this is a move, not a resize, so nothing later
            // pushes it back. center()/cascadePosition alone won't do it (they work on
            // AppKit's cascade rect), and centerClip() clips without recentering.
            let recentered = window.frame.recenteredInVisibleScreen(of: window.screen)
            if recentered != window.frame {
                window.setFrameOrigin(recentered.origin)
            }
        }
        windows[kind] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow(_ kind: Kind) -> NSWindow {
        switch kind {
        case .main:
            let window = makeWindow(title: "Macro Maker", size: NSSize(width: 620, height: 760), resizable: true, content: ContentView())
            window.contentMinSize = NSSize(width: 560, height: 560)
            window.setFrameAutosaveName("MacroMaker.main")
            return window
        case .settings:
            let window = makeWindow(title: "Macro Maker Settings", size: NSSize(width: 560, height: 640), resizable: false, content: SettingsView())
            window.setFrameAutosaveName("MacroMaker.settings")
            return window
        }
    }

    private func makeWindow(title: String, size: NSSize, resizable: Bool, content: some View) -> NSWindow {
        let hosting = NSHostingController(rootView: content.environment(AppModel.shared))
        // Not .preferredContentSize: the settings Forms are ~1050pt tall — far past a sane
        // window — and the detail columns scroll (ContentView) instead of sizing the window.
        hosting.sizingOptions = []
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

private extension NSRect {
    /// Same size, re-centered inside the screen's visible frame.
    func recenteredInVisibleScreen(of screen: NSScreen?) -> NSRect {
        guard let area = screen?.visibleFrame else { return self }
        return NSRect(x: area.midX - width / 2, y: area.midY - height / 2,
                      width: width, height: height)
    }
}
