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
            // straddles the menu bar, which then hides the title bar. `fitted(inside:)` caps
            // and centers only a frame that is too BIG, and otherwise nudges or leaves it —
            // see its doc comment for why "otherwise leaves it" matters. AppKit's own
            // center()/cascadePosition work on the cascade rect and won't do this, and
            // centerClip() clips without moving.
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
        // NSHostingView pinned to the content bounds by autoresizing; sizingOptions = [] so
        // SwiftUI's intrinsic size never sizes the WINDOW. Necessary but not sufficient: what
        // actually keeps the NavigationSplitView inside the window is the shape of the detail
        // column — see the comment on ContentView's `detail:` closure.
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

extension NSRect {
    /// This frame placed inside the screen's visible area (the screen minus the menu bar and Dock).
    func fittedToVisibleScreen(of screen: NSScreen?) -> NSRect {
        guard let area = screen?.visibleFrame else { return self }
        return fitted(inside: area)
    }

    /// Placed inside `area`, changing as little as possible:
    ///   - bigger than the area on either axis -> capped to it and centered. This is the v2.0.3
    ///     rescue for a frame poisoned by a pre-fix build's unbounded layout (2742pt tall), which
    ///     must be RESIZED — origin-only recentring just hides the overflow.
    ///   - fits but hangs off an edge -> slid back by the smallest offset that works.
    ///   - already inside -> returned untouched.
    ///
    /// That last case is load-bearing. `show()` runs this clamp on EVERY open, not only on first
    /// creation, and the main window is opened from the menu bar, a hotkey, a Dock reopen and the
    /// permission prompt. Centering unconditionally therefore threw the window back to the middle
    /// of the screen every single time it was opened, discarding wherever the user had dragged it
    /// and defeating the `MacroMaker.main` frame autosave. Covered by `ScreenFitTests`.
    func fitted(inside area: NSRect) -> NSRect {
        let size = NSSize(width: min(width, area.width), height: min(height, area.height))
        guard size == self.size else {
            return NSRect(x: area.midX - size.width / 2,
                          y: area.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        return NSRect(x: min(max(minX, area.minX), area.maxX - size.width),
                      y: min(max(minY, area.minY), area.maxY - size.height),
                      width: size.width, height: size.height)
    }
}
