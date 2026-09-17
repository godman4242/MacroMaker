import AppKit
import SwiftUI
import Testing
@testable import MacroMaker

/// Regression tests for the v2.0.2 blank-sidebar bug. That build used an
/// `NSHostingController` with `sizingOptions = []`, cutting the hosting view loose from the
/// window's content bounds: in the field the NavigationSplitView was laid out 2734pt tall
/// inside a 1050pt window (measured live via System Events), so the sidebar rows rendered in
/// invisible space and the detail's top sat under the titlebar.
///
/// Windows are now built from an `NSHostingView` pinned to the window frame by autoresizing —
/// the hosting view can never be a different size than the window's content area, which is
/// the invariant the bug violated. These tests pin that contract directly: the binding
/// mechanism (no content view controller, `.width,.height` autoresizing), the frame equality
/// at several window sizes including the field-measured 851x1050, and the window metadata
/// that must not regress (autosave names, min size, settings non-resizable).
@Suite(.serialized)
struct WindowLayoutTests {
    @MainActor
    @Test func mainWindowHostingIsPinnedToWindowBounds() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        defer { UserDefaults.standard.removeObject(forKey: "hasSeenOnboarding") }

        let window = WindowCoordinator.shared.makeWindow(.main)
        #expect(window.frameAutosaveName == "MacroMaker.main")
        #expect(window.contentMinSize == NSSize(width: 560, height: 560))

        // The binding mechanism the fix relies on: no detached hosting controller, and the
        // hosting view tracks the window's own size changes by autoresizing.
        #expect(window.contentViewController == nil,
                "a contentViewController with sizingOptions = [] is what let content grow past the window")
        let hosting = try #require(window.contentView)
        #expect(String(describing: type(of: hosting)).contains("NSHostingView"),
                "content must be an NSHostingView, got \(type(of: hosting))")
        #expect(hosting.autoresizingMask == [.width, .height],
                "hosting view must autoresize with the window, mask was \(hosting.autoresizingMask)")

        // Content fills the window's content area at the default size, at the exact size from
        // the field measurement, and at a large size: SwiftUI must never see a proposal other
        // than the window's real bounds.
        for size in [NSSize(width: 620, height: 760), NSSize(width: 851, height: 1050), NSSize(width: 1400, height: 900)] {
            try expectContentFillsWindow(window, size: size)
        }
    }

    @MainActor
    @Test func settingsWindowStaysFixedAndHostingFills() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let window = WindowCoordinator.shared.makeWindow(.settings)
        #expect(window.frameAutosaveName == "MacroMaker.settings")
        // The settings Form is ~1050pt tall while the window is fixed at 640pt. The no-grow
        // guarantee is the window being non-resizable plus the hosting view adopting the
        // window's size — never the other way round.
        #expect(!window.styleMask.contains(.resizable))
        try expectContentFillsWindow(window, size: NSSize(width: 560, height: 640))
    }

    @MainActor
    private func expectContentFillsWindow(_ window: NSWindow, size: NSSize) throws {
        window.setContentSize(size)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(window.contentView)
        let rect = window.contentLayoutRect
        #expect(abs(content.frame.minX - rect.minX) < 0.5 && abs(content.frame.minY - rect.minY) < 0.5,
                "content origin \(content.frame.origin) != contentLayoutRect origin \(rect.origin)")
        #expect(abs(content.frame.width - rect.width) < 0.5,
                "content width \(content.frame.width) != window content width \(rect.width)")
        #expect(abs(content.frame.height - rect.height) < 0.5,
                "content height \(content.frame.height) != window content height \(rect.height)")
    }
}
