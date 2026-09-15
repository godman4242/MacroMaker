import AppKit
import Testing
@testable import MacroMaker

/// Exercises the AppleScript bridge without touching any browser.
@MainActor @Suite struct BrowserScriptingTests {
    private func compile(_ source: String) throws -> NSAppleScript {
        let script = try #require(NSAppleScript(source: source))
        var errorInfo: NSDictionary?
        let compiled = script.compileAndReturnError(&errorInfo)
        #expect(compiled, "compile failed: \(String(describing: errorInfo))")
        return script
    }

    @Test func handlerArgumentsArriveVerbatim() throws {
        let script = try compile("""
        on echo_args(selectorText, otherText)
            return selectorText & "|" & otherText
        end echo_args
        """)
        let tricky = #"a[title="it's"] \ "# + "\nline two ✓"
        #expect(try BrowserScripting.call("echo_args", in: script, arguments: ["#buy", tricky]) == "#buy|" + tricky)
    }

    @Test func scriptErrorsCarryNumberAndMessage() throws {
        let script = try compile("""
        on fail_now()
            error "boom" number 1234
        end fail_now
        """)
        #expect(throws: BrowserScripting.AppleScriptFailure(number: 1234, message: "boom")) {
            try BrowserScripting.call("fail_now", in: script, arguments: [])
        }
    }

    @Test func safariScriptCompiles() throws {
        _ = try compile(BrowserScripting.source(for: .safari))
    }

    @Test(.enabled(if: NSWorkspace.shared.urlForApplication(withBundleIdentifier: Browser.chrome.bundleIdentifier) != nil,
                   "Google Chrome isn't installed"))
    func chromeScriptCompiles() throws {
        _ = try compile(BrowserScripting.source(for: .chrome))
    }

    @Test func errorMapping() {
        func map(_ number: Int, _ message: String, _ browser: Browser = .safari) -> BrowserScriptError {
            BrowserScripting.error(from: .init(number: number, message: message), browser: browser)
        }
        #expect(map(-1743, "Not authorized to send Apple events to Safari.") == .automationDenied(.safari))
        #expect(map(-600, "Application isn't running.") == .notRunning(.safari))
        #expect(map(8, "Safari got an error: You must enable the 'Allow JavaScript from Apple Events' option in Safari's Develop menu to use 'do JavaScript'.") == .javaScriptDisabled(.safari))
        #expect(map(12, "Google Chrome got an error: Executing JavaScript through AppleScript is turned off.", .chrome) == .javaScriptDisabled(.chrome))
        #expect(map(1, "Something else") == .failed("Something else"))
    }
}
