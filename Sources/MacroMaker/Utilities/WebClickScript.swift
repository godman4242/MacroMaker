import Foundation

/// Builds the JavaScript injected into the browser tab, and decodes what it returns.
enum WebClickScript {
    /// JavaScript that finds the element, fires a realistic pointer → mouse → click sequence at
    /// it, and returns a JSON string describing what happened.
    static func javaScript(for locator: ElementLocator) -> String {
        let find: String
        let point: String
        switch locator {
        case let .css(selector):
            find = "document.querySelector(\(jsString(selector)))"
            point = "null"
        case let .xpath(expression):
            find = "document.evaluate(\(jsString(expression)), document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue"
            point = "null"
        case let .point(x, y):
            find = "document.elementFromPoint(\(x), \(y))"
            point = "[\(x), \(y)]"
        }
        return """
        (function () {
          try {
            var el = \(find);
            if (el && el.nodeType !== 1) { el = el.parentElement; }
            if (!el) { return JSON.stringify({ ok: false, error: "not-found" }); }
            var at = \(point);
            if (!at) { var r = el.getBoundingClientRect(); at = [r.left + r.width / 2, r.top + r.height / 2]; }
            var base = { bubbles: true, cancelable: true, composed: true, view: window, clientX: at[0], clientY: at[1], button: 0 };
            var fire = function (Type, name, buttons) {
              var init = Object.assign({}, base, { buttons: buttons, pointerId: 1, pointerType: "mouse", isPrimary: true });
              try { el.dispatchEvent(new Type(name, init)); } catch (e) { el.dispatchEvent(new MouseEvent(name, init)); }
            };
            fire(window.PointerEvent || MouseEvent, "pointerdown", 1);
            fire(MouseEvent, "mousedown", 1);
            fire(window.PointerEvent || MouseEvent, "pointerup", 0);
            fire(MouseEvent, "mouseup", 0);
            fire(MouseEvent, "click", 0);
            var label = String(el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || "").trim().slice(0, 40);
            return JSON.stringify({ ok: true, tag: el.tagName.toLowerCase(), label: label });
          } catch (e) {
            return JSON.stringify({ ok: false, error: "script-error", message: String(e && e.message || e) });
          }
        })()
        """
    }

    /// A JSON string literal is also a valid JavaScript string literal, so this escapes quotes,
    /// backslashes and newlines in user input safely.
    static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    struct Result: Decodable, Equatable {
        var ok: Bool
        var error: String?
        var message: String?
        var tag: String?
        var label: String?

        var isElementMissing: Bool { error == "not-found" }

        var description: String {
            if ok {
                let name = (label ?? "").isEmpty ? "" : " “\(label!)”"
                return "Clicked <\(tag ?? "element")>\(name)"
            }
            switch error {
            case "not-found": return "No element matches — check the selector, or the page may still be loading."
            case "script-error": return "The page rejected the selector: \(message ?? "unknown error")"
            default: return "Unexpected response from the page."
            }
        }
    }

    static func decodeResult(_ raw: String) -> Result? {
        try? JSONDecoder().decode(Result.self, from: Data(raw.utf8))
    }
}
