import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
        WindowCoordinator.shared.show(.main)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Releases any held key or mouse button before the process exits.
        AppModel.shared.shutdown()
    }

    /// Clicking the Dock icon (when shown) reopens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowCoordinator.shared.show(.main)
        return false
    }

    /// Double-clicking a .macromaker file in Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        AppModel.shared.openMacro(at: url)
    }
}
