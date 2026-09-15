import AppKit
import SwiftUI

/// Owns Macro Maker's windows. AppKit-managed rather than SwiftUI scenes so they can be opened
/// from anywhere — a hotkey, the menu bar, a Finder double-click — even with no Dock icon.
@MainActor
final class WindowCoordinator {
    enum Kind {
        case main, settings
    }

    static let shared = WindowCoordinator()
    private var windows: [Kind: NSWindow] = [:]

    func show(_ kind: Kind) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow(_ kind: Kind) -> NSWindow {
        let window: NSWindow
        switch kind {
        case .main:
            window = makeWindow(title: "Macro Maker", size: NSSize(width: 620, height: 760), resizable: true, content: ContentView())
            window.contentMinSize = NSSize(width: 560, height: 560)
        case .settings:
            window = makeWindow(title: "Macro Maker Settings", size: NSSize(width: 560, height: 640), resizable: false, content: SettingsView())
        }
        window.center()
        window.setFrameAutosaveName("MacroMaker.\(kind)")
        return window
    }

    private func makeWindow(title: String, size: NSSize, resizable: Bool, content: some View) -> NSWindow {
        let hosting = NSHostingController(rootView: content.environment(AppModel.shared))
        hosting.sizingOptions = []
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }
}
