import Foundation

struct AutoClickerSettings: Codable, Equatable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable {
        case cursor, fixedPoint
    }

    var button: MouseButton = .left
    var intervalMs: Double = 100
    var randomizeInterval = false
    var randomOffsetMs: Double = 20
    var target: Target = .cursor
    var x: Double = 500
    var y: Double = 500
    var stopAfterClicks = false
    var maxClicks = 100
    var stopAfterDuration = false
    var maxDurationSeconds: Double = 60
}

struct KeyPresserSettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case autoPress, hold
    }

    var keyText = "space"
    var mode: Mode = .autoPress
    var intervalMs: Double = 100
}

enum Browser: String, Codable, CaseIterable, Identifiable, Sendable {
    case safari, chrome

    var id: Self { self }

    var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        }
    }

    /// Where the browser's "allow scripts to run JavaScript" switch lives.
    var javaScriptSettingPath: String {
        switch self {
        case .safari: "Safari ▸ Settings ▸ Advanced ▸ tick “Show features for web developers”, then Develop ▸ Developer Settings ▸ “Allow JavaScript from Apple Events”"
        case .chrome: "Chrome menu bar ▸ View ▸ Developer ▸ “Allow JavaScript from Apple Events”"
        }
    }
}

/// How the Web Target finds the element to click inside the page.
enum ElementLocator: Equatable, Sendable {
    case css(String)
    case xpath(String)
    /// Viewport coordinates in CSS pixels (what `document.elementFromPoint` expects).
    case point(x: Double, y: Double)
}

struct WebTargetSettings: Codable, Equatable, Sendable {
    enum LocatorKind: String, Codable, CaseIterable, Sendable {
        case css, xpath, coordinates
    }

    var browser: Browser = .safari
    var urlMatch = ""
    var locatorKind: LocatorKind = .css
    var cssSelector = ""
    var xpath = ""
    var x: Double = 100
    var y: Double = 100
    var intervalMs: Double = 1000

    var locator: ElementLocator {
        switch locatorKind {
        case .css: .css(cssSelector)
        case .xpath: .xpath(xpath)
        case .coordinates: .point(x: x, y: y)
        }
    }
}

struct PlaybackSettings: Codable, Equatable, Sendable {
    var repeatCount = 1
    var loopForever = false
    var speed: Double = 1
}
