import AppKit
import Carbon

struct BrowserTab: Identifiable, Hashable, Sendable {
    let id: Int
    let url: String
    let title: String
}

enum BrowserScriptError: LocalizedError, Equatable {
    case notInstalled(Browser)
    case notRunning(Browser)
    case automationDenied(Browser)
    case javaScriptDisabled(Browser)
    case tabNotFound(String)
    case timedOut(Browser)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(browser):
            "\(browser.displayName) isn't installed."
        case let .notRunning(browser):
            "\(browser.displayName) isn't running. Open it and load the page first."
        case let .automationDenied(browser):
            "Macro Maker isn't allowed to control \(browser.displayName). Turn it on in System Settings ▸ Privacy & Security ▸ Automation."
        case let .javaScriptDisabled(browser):
            "\(browser.displayName) is blocking scripts. Enable it: \(browser.javaScriptSettingPath)."
        case let .tabNotFound(fragment):
            "No open tab's URL contains “\(fragment)”."
        case let .timedOut(browser):
            "\(browser.displayName) didn't respond in time (is a dialog open?)."
        case let .failed(message):
            message
        }
    }
}

/// Runs JavaScript inside a specific Safari, Chrome or Brave tab through AppleScript.
///
/// Main-actor only: `NSAppleScript` is not thread-safe. Each browser's script is compiled once;
/// every click then calls one of its handlers with arguments passed as Apple Event parameters
/// (no string splicing, so selectors can contain any character).
@MainActor
final class BrowserScripting {
    static let noTabMarker = "__MACROMAKER_NO_TAB__"
    private var compiled: [Browser: NSAppleScript] = [:]

    func runJavaScript(_ javaScript: String, inTabMatching urlFragment: String,
                       browser: Browser) throws(BrowserScriptError) -> String {
        let result = try callHandler("run_js", arguments: [urlFragment, javaScript], browser: browser)
        if result == Self.noTabMarker { throw .tabNotFound(urlFragment) }
        return result
    }

    func openTabs(in browser: Browser) throws(BrowserScriptError) -> [BrowserTab] {
        let output = try callHandler("list_tabs", arguments: [], browser: browser)
        return output.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return BrowserTab(id: index, url: String(parts[0]), title: String(parts[1]))
        }
    }

    private func callHandler(_ name: String, arguments: [String], browser: Browser) throws(BrowserScriptError) -> String {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) != nil else {
            throw .notInstalled(browser)
        }
        // Checked up front: a `tell` would otherwise silently launch the browser.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).isEmpty else {
            throw .notRunning(browser)
        }
        do {
            return try Self.call(name, in: try script(for: browser), arguments: arguments)
        } catch let failure as AppleScriptFailure {
            throw Self.error(from: failure, browser: browser)
        } catch let error as BrowserScriptError {
            throw error
        } catch {
            throw .failed(error.localizedDescription)
        }
    }

    struct AppleScriptFailure: Error, Equatable {
        let number: Int
        let message: String

        init(number: Int, message: String) {
            self.number = number
            self.message = message
        }

        init(_ info: NSDictionary?) {
            number = info?[NSAppleScript.errorNumber] as? Int ?? 0
            message = info?[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
        }
    }

    /// Calls a handler (`on name(a, b)`) of a compiled script. Arguments travel as Apple Event
    /// parameters, so they never need escaping. Handler names must be lowercase.
    static func call(_ handler: String, in script: NSAppleScript, arguments: [String]) throws(AppleScriptFailure) -> String {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            parameters.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        var errorInfo: NSDictionary?
        // Swift imports this as non-optional, but it returns nil on failure — keep it optional.
        let result: NSAppleEventDescriptor? = script.executeAppleEvent(event, error: &errorInfo)
        if errorInfo != nil || result == nil { throw AppleScriptFailure(errorInfo) }
        return result?.stringValue ?? ""
    }

    private func script(for browser: Browser) throws(BrowserScriptError) -> NSAppleScript {
        if let script = compiled[browser] { return script }
        guard let script = NSAppleScript(source: Self.source(for: browser)) else {
            throw .failed("Couldn't create the \(browser.displayName) script.")
        }
        var errorInfo: NSDictionary?
        guard script.compileAndReturnError(&errorInfo) else {
            throw .failed("Couldn't compile the \(browser.displayName) script: \(AppleScriptFailure(errorInfo).message)")
        }
        compiled[browser] = script
        return script
    }

    static func error(from failure: AppleScriptFailure, browser: Browser) -> BrowserScriptError {
        switch failure.number {
        case -1743: return .automationDenied(browser)
        case -600: return .notRunning(browser)
        case -1712: return .timedOut(browser)
        default:
            let mentionsScripting = failure.message.contains("Apple Events") || failure.message.contains("AppleScript")
            if failure.message.contains("JavaScript"), mentionsScripting { return .javaScriptDisabled(browser) }
            return .failed(failure.message)
        }
    }

    /// Safari and Chrome name things differently: Safari runs `do JavaScript … in tab` and calls a
    /// tab's title `name`; Chrome uses `execute tab … javascript` and `title`. Brave is Chromium
    /// and speaks Chrome's dictionary (compile-checked against Brave's own in the tests).
    static func source(for browser: Browser) -> String {
        let (runInTab, titleProperty) = switch browser {
        case .safari: ("do JavaScript js in tab i of w", "name")
        case .chrome, .brave: ("execute (tab i of w) javascript js", "title")
        }
        return """
        on run_js(urlFragment, js)
            tell application id "\(browser.bundleIdentifier)"
                with timeout of 5 seconds
                    repeat with w in windows
                        set tabURLs to {}
                        try
                            set tabURLs to URL of every tab of w
                        end try
                        repeat with i from 1 to count of tabURLs
                            set tabURL to item i of tabURLs
                            if tabURL is not missing value and tabURL contains urlFragment then
                                return \(runInTab)
                            end if
                        end repeat
                    end repeat
                end timeout
            end tell
            return "\(noTabMarker)"
        end run_js

        on list_tabs()
            set fieldSeparator to character id 9
            set lineSeparator to character id 10
            set output to ""
            tell application id "\(browser.bundleIdentifier)"
                with timeout of 5 seconds
                    repeat with w in windows
                        try
                            set tabURLs to URL of every tab of w
                            set tabTitles to \(titleProperty) of every tab of w
                            repeat with i from 1 to count of tabURLs
                                set tabURL to item i of tabURLs
                                if tabURL is not missing value then
                                    set output to output & tabURL & fieldSeparator & (item i of tabTitles) & lineSeparator
                                end if
                            end repeat
                        end try
                    end repeat
                end timeout
            end tell
            return output
        end list_tabs
        """
    }
}
