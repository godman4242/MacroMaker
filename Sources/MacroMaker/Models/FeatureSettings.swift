import Foundation

struct AutoClickerSettings: Codable, Equatable, Sendable {
    enum Target: String, Codable, CaseIterable, Sendable {
        case cursor, fixedPoint, region
        /// Clicks posted straight to an app's process — the app can be behind other windows.
        case directApp
    }

    enum ClickCount: Int, Codable, CaseIterable, Identifiable, Sendable {
        case single = 1, double = 2, triple = 3

        var id: Self { self }
        var title: String { rawValue == 1 ? "Single" : rawValue == 2 ? "Double" : "Triple" }
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

    // MARK: v2
    var intervalUnit: IntervalUnit = .milliseconds
    var burstSize = 1
    var clickCountPerEvent: ClickCount = .single
    var region = ClickRegion()
    var jitterEnabled = false
    var jitterPx: Double = 5
    var stopOnFrontmostChange = false
    var holdToClick = false
    var delayedStartSeconds: Double = 0
    var restoreCursor = false
    var humanizer = HumanizerSettings()
    /// Direct-app mode: the target app's bundle id and the captured *screen* point
    /// (converted to window-local coordinates against the window's live bounds each click).
    var directAppBundleID = ""
    var directAppX: Double = 400
    var directAppY: Double = 300

    init() {}

    /// Tolerant decoding: v2 fields default when missing, so a v1 settings blob still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
        intervalMs = try c.decodeIfPresent(Double.self, forKey: .intervalMs) ?? 100
        randomizeInterval = try c.decodeIfPresent(Bool.self, forKey: .randomizeInterval) ?? false
        randomOffsetMs = try c.decodeIfPresent(Double.self, forKey: .randomOffsetMs) ?? 20
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .cursor
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 500
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 500
        stopAfterClicks = try c.decodeIfPresent(Bool.self, forKey: .stopAfterClicks) ?? false
        maxClicks = try c.decodeIfPresent(Int.self, forKey: .maxClicks) ?? 100
        stopAfterDuration = try c.decodeIfPresent(Bool.self, forKey: .stopAfterDuration) ?? false
        maxDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .maxDurationSeconds) ?? 60
        intervalUnit = try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .milliseconds
        burstSize = try c.decodeIfPresent(Int.self, forKey: .burstSize) ?? 1
        clickCountPerEvent = try c.decodeIfPresent(ClickCount.self, forKey: .clickCountPerEvent) ?? .single
        region = try c.decodeIfPresent(ClickRegion.self, forKey: .region) ?? ClickRegion()
        jitterEnabled = try c.decodeIfPresent(Bool.self, forKey: .jitterEnabled) ?? false
        jitterPx = try c.decodeIfPresent(Double.self, forKey: .jitterPx) ?? 5
        stopOnFrontmostChange = try c.decodeIfPresent(Bool.self, forKey: .stopOnFrontmostChange) ?? false
        holdToClick = try c.decodeIfPresent(Bool.self, forKey: .holdToClick) ?? false
        delayedStartSeconds = try c.decodeIfPresent(Double.self, forKey: .delayedStartSeconds) ?? 0
        restoreCursor = try c.decodeIfPresent(Bool.self, forKey: .restoreCursor) ?? false
        humanizer = try c.decodeIfPresent(HumanizerSettings.self, forKey: .humanizer) ?? HumanizerSettings()
        directAppBundleID = try c.decodeIfPresent(String.self, forKey: .directAppBundleID) ?? ""
        directAppX = try c.decodeIfPresent(Double.self, forKey: .directAppX) ?? 400
        directAppY = try c.decodeIfPresent(Double.self, forKey: .directAppY) ?? 300
    }
}

struct KeyPresserSettings: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable {
        case autoPress, hold
    }

    var keyText = "space"
    var mode: Mode = .autoPress
    var intervalMs: Double = 100
    var humanizer = HumanizerSettings()
    /// Optional direct-app delivery for the Key Presser (empty = synthesize to whatever is frontmost).
    var sendToBundleID = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyText = try c.decodeIfPresent(String.self, forKey: .keyText) ?? "space"
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .autoPress
        intervalMs = try c.decodeIfPresent(Double.self, forKey: .intervalMs) ?? 100
        humanizer = try c.decodeIfPresent(HumanizerSettings.self, forKey: .humanizer) ?? HumanizerSettings()
        sendToBundleID = try c.decodeIfPresent(String.self, forKey: .sendToBundleID) ?? ""
    }
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
    var humanizer = HumanizerSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        loopForever = try c.decodeIfPresent(Bool.self, forKey: .loopForever) ?? false
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        humanizer = try c.decodeIfPresent(HumanizerSettings.self, forKey: .humanizer) ?? HumanizerSettings()
    }
}
