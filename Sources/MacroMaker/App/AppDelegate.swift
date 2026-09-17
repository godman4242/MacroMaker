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
        // Info.plist claims BOTH document types, but every URL used to be decoded as a Macro —
        // and Macro.init(from:) requires a format key no profile file carries, so double-clicking
        // a .macromakerprofile always failed. Iterating rather than taking `.first` also stops
        // a multi-file selection in Finder silently dropping all but one.
        for url in urls {
            if url.pathExtension == Profile.fileExtension {
                AppModel.shared.profiles.importFile(at: url)
            } else {
                AppModel.shared.openMacro(at: url)
            }
        }
    }
}
