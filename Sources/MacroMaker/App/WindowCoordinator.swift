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
            let fixed = window.frame.fittedToVisibleScreen(of: window.screen)
            if fixed.size != window.frame.size {
                window.setFrame(fixed, display: true)
            } else if fixed.origin != window.frame.origin {
                window.setFrameOrigin(fixed.origin)
            }
        }
        windows[kind] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Frame autosave restores asynchronously AFTER orderFront, so neither clamp above
        // sees the poisoned frame — re-check on the next runloop turn, once the restore
        // has landed. This is what actually rescues a frame saved oversized by an old build.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            let settled = window.frame.fittedToVisibleScreen(of: window.screen)
            if settled != window.frame {
                window.setFrame(settled, display: true)
            }
        }
    }

    // Internal (not private) so the WindowLayoutTests suite can build windows without showing them.
    func makeWindow(_ kind: Kind) -> NSWindow {
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
        // NSHostingView pinned by autoresizing, NOT an NSHostingController as
        // contentViewController. v2.0.2 set the controller's sizingOptions = [], which cut the
        // hosting view loose from the window's content bounds: in the field the
        // NavigationSplitView was laid out at an intrinsic height unrelated to the window
        // (measured live via System Events: 2734pt tall inside a 1050pt window, vertically
        // centered, top at y=-790) — the sidebar rows rendered in invisible space above the
        // window. Pinning the view to the frame makes that state structurally impossible:
        // SwiftUI proposals derive from the hosting view's frame, so ScrollViews get a
        // bounded proposal and scroll instead of overflowing, at every window size.
        // The settings window's no-grow guarantee doesn't depend on the hosting mechanism at
        // all: it is non-resizable, so nothing ever proposes the Form's ~1050pt intrinsic
        // height to the window.
        let hosting = NSHostingView(rootView: content.environment(AppModel.shared))
        hosting.sizingOptions = []            // never drive the window from SwiftUI intrinsic size
        hosting.autoresizingMask = [.width, .height]
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.setContentSize(size)
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.title = title
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }
}

private extension NSRect {
    /// Clamped to the screen's visible frame: size capped to the area, then centered.
    /// A frame taller than the screen (saved by a pre-fix build) must be RESIZED,
    /// not just moved — origin-only recentring keeps the overflow invisible.
    func fittedToVisibleScreen(of screen: NSScreen?) -> NSRect {
        guard let area = screen?.visibleFrame else { return self }
        let size = NSSize(width: min(width, area.width), height: min(height, area.height))
        return NSRect(x: area.midX - size.width / 2,
                      y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
