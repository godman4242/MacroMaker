import Foundation

/// Per-field tolerant decoding (review N4): a decoded settings blob is untrusted — one
/// type-mismatched or out-of-range field in a hand-edited defaults plist or an imported
/// profile must cost that field alone. Throwing through used to meet `Persistence.load`'s
/// `try?`, which reset the WHOLE blob to defaults — permanent, silent loss of every sibling
/// setting. Each helper below makes one field's failure local:
/// - `decoded` defaults the field when absent, null, or the wrong shape;
/// - `clamped` additionally bounds a Double/Int to the range the UI's fields enforce
///   (Swift's min/max propagate NaN, so a non-finite value falls back rather than to a bound).
private func decoded<K: CodingKey, V: Decodable>(_ c: KeyedDecodingContainer<K>, _ key: K,
                                                 fallback: V) -> V {
    ((try? c.decodeIfPresent(V.self, forKey: key)) ?? nil) ?? fallback
}

private func clamped<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K,
                                   fallback: Double, in range: ClosedRange<Double>) -> Double {
    guard let raw = ((try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil), raw.isFinite
    else { return fallback }
    return min(max(raw, range.lowerBound), range.upperBound)
}

/// The Int twin of the Double clamp (review N7): `maxClicks`, `burstSize` and playback's
/// `repeatCount` decoded unbounded, outside the discipline every decoded Double already had.
/// A value beyond Int's representation throws inside `decode` — the `try?` turns that into
/// the field's fallback, never the whole blob's.
private func clamped<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K,
                                   fallback: Int, in range: ClosedRange<Int>) -> Int {
    guard let raw = ((try? c.decodeIfPresent(Int.self, forKey: key)) ?? nil) else { return fallback }
    return min(max(raw, range.lowerBound), range.upperBound)
}

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
    /// Pause when the user's own keyboard/mouse input is seen (pause-on-real-input).
    var pauseOnRealInput = false
    /// Seconds of user idle before a paused run starts itself again.
    var autoResumeSeconds: Double = 5
    /// "Repeat until the stop shortcut": the run has no count/duration bound — the stop-run
    /// hotkey (Settings ▸ Keyboard shortcuts, default F6) ends it (F-11).
    var stopOnHotkey = false

    init() {}

    /// Tolerant decoding: v2 fields default when missing, so a v1 settings blob still loads.
    /// Every decoded field is local to its own failure (see the helpers above) and every
    /// numeric value is bounded so a hostile or corrupt value can never reach the
    /// `Int`/`UInt64` conversions in the run paths.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        button = decoded(c, .button, fallback: .left)
        intervalMs = clamped(c, .intervalMs, fallback: 100, in: 1...IntervalUnit.maximumIntervalMs)
        randomizeInterval = decoded(c, .randomizeInterval, fallback: false)
        randomOffsetMs = clamped(c, .randomOffsetMs, fallback: 20, in: 0...60_000)
        target = decoded(c, .target, fallback: .cursor)
        x = clamped(c, .x, fallback: 500, in: -20_000...20_000)
        y = clamped(c, .y, fallback: 500, in: -20_000...20_000)
        stopAfterClicks = decoded(c, .stopAfterClicks, fallback: false)
        maxClicks = clamped(c, .maxClicks, fallback: 100, in: 1...10_000_000)
        stopAfterDuration = decoded(c, .stopAfterDuration, fallback: false)
        maxDurationSeconds = clamped(c, .maxDurationSeconds, fallback: 60, in: 0.1...86_400)
        intervalUnit = decoded(c, .intervalUnit, fallback: .milliseconds)
        burstSize = clamped(c, .burstSize, fallback: 1, in: 1...10)
        clickCountPerEvent = decoded(c, .clickCountPerEvent, fallback: .single)
        region = decoded(c, .region, fallback: ClickRegion())
        jitterEnabled = decoded(c, .jitterEnabled, fallback: false)
        jitterPx = clamped(c, .jitterPx, fallback: 5, in: 0...200)
        stopOnFrontmostChange = decoded(c, .stopOnFrontmostChange, fallback: false)
        holdToClick = decoded(c, .holdToClick, fallback: false)
        delayedStartSeconds = clamped(c, .delayedStartSeconds, fallback: 0, in: 0...600)
        restoreCursor = decoded(c, .restoreCursor, fallback: false)
        humanizer = decoded(c, .humanizer, fallback: HumanizerSettings())
        directAppBundleID = decoded(c, .directAppBundleID, fallback: "")
        directAppX = clamped(c, .directAppX, fallback: 400, in: -20_000...20_000)
        directAppY = clamped(c, .directAppY, fallback: 300, in: -20_000...20_000)
        pauseOnRealInput = decoded(c, .pauseOnRealInput, fallback: false)
        autoResumeSeconds = clamped(c, .autoResumeSeconds, fallback: 5, in: 1...600)
        stopOnHotkey = decoded(c, .stopOnHotkey, fallback: false)
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
        keyText = decoded(c, .keyText, fallback: "space")
        mode = decoded(c, .mode, fallback: .autoPress)
        intervalMs = clamped(c, .intervalMs, fallback: 100, in: 1...IntervalUnit.maximumIntervalMs)
        humanizer = decoded(c, .humanizer, fallback: HumanizerSettings())
        sendToBundleID = decoded(c, .sendToBundleID, fallback: "")
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

    init() {}

    /// Tolerant decoding: absent or unreadable fields default per field (one bad value costs
    /// itself, never the blob — review N4), and the Doubles are bounded like every other
    /// decoded setting (the UI NumberFields enforce these ranges on the way in).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browser = decoded(c, .browser, fallback: .safari)
        urlMatch = decoded(c, .urlMatch, fallback: "")
        locatorKind = decoded(c, .locatorKind, fallback: .css)
        cssSelector = decoded(c, .cssSelector, fallback: "")
        xpath = decoded(c, .xpath, fallback: "")
        x = clamped(c, .x, fallback: 100, in: 0...100_000)
        y = clamped(c, .y, fallback: 100, in: 0...100_000)
        intervalMs = clamped(c, .intervalMs, fallback: 1000,
                             in: Double(WebClicker.minimumIntervalMs)...IntervalUnit.maximumIntervalMs)
    }
}

struct PlaybackSettings: Codable, Equatable, Sendable {
    var repeatCount = 1
    var loopForever = false
    var speed: Double = 1
    var humanizer = HumanizerSettings()
    /// "Repeat until the stop shortcut": the stop-run hotkey (default F6) ends the playback,
    /// ignoring the repeat count and the loop toggle (F-11).
    var stopOnHotkey = false
    /// "Follow the window" (F-14): anchored mouse steps replay translated by the window's
    /// move since recording. ON by default — the common case is wanting the clicks to land
    /// where the window now is; turning it off is the escape hatch to pure absolute replay.
    var followWindow = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repeatCount = clamped(c, .repeatCount, fallback: 1, in: 1...10_000)
        loopForever = decoded(c, .loopForever, fallback: false)
        speed = clamped(c, .speed, fallback: 1, in: 0.25...4)
        humanizer = decoded(c, .humanizer, fallback: HumanizerSettings())
        stopOnHotkey = decoded(c, .stopOnHotkey, fallback: false)
        followWindow = decoded(c, .followWindow, fallback: true)
    }
}
