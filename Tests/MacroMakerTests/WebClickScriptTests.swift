import JavaScriptCore
import Testing
@testable import MacroMaker

/// Runs the real injected script in JavaScriptCore against a tiny fake DOM.
@Suite struct WebClickScriptTests {
    private static let fakeDOM = """
    var window = this;
    var fired = [];
    var lastQuery = null;
    function MouseEvent(type, init) { this.type = type; this.init = init; }
    var XPathResult = { FIRST_ORDERED_NODE_TYPE: 9 };
    var button = {
      nodeType: 1, tagName: "BUTTON", innerText: "  Buy now  ",
      getAttribute: function () { return null; },
      getBoundingClientRect: function () { return { left: 10, top: 20, width: 100, height: 40 }; },
      dispatchEvent: function (e) { fired.push(e.type + "@" + e.init.clientX + "," + e.init.clientY); return true; }
    };
    var textNode = { nodeType: 3, parentElement: button };
    var document = {
      querySelector: function (s) {
        lastQuery = s;
        if (s === "!!bad") { throw new Error("'!!bad' is not a valid selector"); }
        return s === "#missing" ? null : button;
      },
      evaluate: function (xpath) { lastQuery = xpath; return { singleNodeValue: textNode }; },
      elementFromPoint: function (x, y) { return button; }
    };
    """

    private func run(_ locator: ElementLocator) throws -> (result: WebClickScript.Result, context: JSContext) {
        let context = try #require(JSContext())
        context.evaluateScript(Self.fakeDOM)
        let raw = try #require(context.evaluateScript(WebClickScript.javaScript(for: locator))?.toString())
        #expect(context.exception == nil, "script threw: \(String(describing: context.exception))")
        let result = try #require(WebClickScript.decodeResult(raw), "not JSON: \(raw)")
        return (result, context)
    }

    @Test func cssClickFiresFullSequenceAtElementCentre() throws {
        let (result, context) = try run(.css("#buy"))
        #expect(result == WebClickScript.Result(ok: true, tag: "button", label: "Buy now"))
        #expect(context.evaluateScript("fired.join('|')").toString()
            == "pointerdown@60,40|mousedown@60,40|pointerup@60,40|mouseup@60,40|click@60,40")
    }

    @Test func selectorWithQuotesAndBackslashesArrivesUnchanged() throws {
        let selector = #"a[title="it's \"quoted\""] > span\:hover"# + "\n\u{2028}"
        let (result, context) = try run(.css(selector))
        #expect(result.ok)
        #expect(context.evaluateScript("lastQuery").toString() == selector)
    }

    @Test func xpathTextNodeResolvesToParentElement() throws {
        let (result, context) = try run(.xpath("//button[text()='Buy']"))
        #expect(result.ok)
        #expect(context.evaluateScript("lastQuery").toString() == "//button[text()='Buy']")
    }

    @Test func coordinatesClickAtTheGivenPoint() throws {
        let (result, context) = try run(.point(x: 7, y: 9.5))
        #expect(result.ok)
        #expect(context.evaluateScript("fired[4]").toString() == "click@7,9.5")
    }

    @Test func missingElementAndInvalidSelectorAreReported() throws {
        let missing = try run(.css("#missing")).result
        #expect(!missing.ok)
        #expect(missing.isElementMissing)

        let invalid = try run(.css("!!bad")).result
        #expect(invalid.error == "script-error")
        #expect(invalid.message?.contains("not a valid selector") == true)
    }
}
