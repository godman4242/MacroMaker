import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

// .serialized: one test swaps the process-wide windowLocationResolver seam.
@Suite("BackgroundPoster", .serialized)
struct BackgroundPosterTests {

    private static func info(pid: Int32, layer: Int = 0, number: Int = 42,
                             bounds: [String: CGFloat]? = ["X": 100, "Y": 200, "Width": 800, "Height": 600]) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowOwnerPID as String: Int(pid),
            kCGWindowLayer as String: layer,
            kCGWindowNumber as String: number,
        ]
        if let bounds { dict[kCGWindowBounds as String] = bounds }
        return dict
    }

    @Test func acceptsALayerZeroWindowOfTheOwner() {
        let window = BackgroundPoster.window(fromInfo: Self.info(pid: 1234), ownerPID: 1234)
        #expect(window == BackgroundPoster.Window(id: 42, bounds: CGRect(x: 100, y: 200, width: 800, height: 600)))
    }

    @Test func rejectsOtherOwners() {
        #expect(BackgroundPoster.window(fromInfo: Self.info(pid: 999), ownerPID: 1234) == nil)
    }

    @Test func rejectsNonLayerZeroLikeMenuBarsAndFloatingWidgets() {
        #expect(BackgroundPoster.window(fromInfo: Self.info(pid: 1234, layer: 25), ownerPID: 1234) == nil)
        #expect(BackgroundPoster.window(fromInfo: Self.info(pid: 1234, layer: -1), ownerPID: 1234) == nil)
    }

    @Test func rejectsMissingOrDegenerateData() {
        var noBounds = Self.info(pid: 1234)
        noBounds[kCGWindowBounds as String] = nil
        #expect(BackgroundPoster.window(fromInfo: noBounds, ownerPID: 1234) == nil)

        let zeroSize = Self.info(pid: 1234, bounds: ["X": 0, "Y": 0, "Width": 0, "Height": 0])
        #expect(BackgroundPoster.window(fromInfo: zeroSize, ownerPID: 1234) == nil)

        let noNumberLayer = Self.info(pid: 1234, number: -1)
        #expect(BackgroundPoster.window(fromInfo: noNumberLayer, ownerPID: 1234) == nil)
    }

    @Test func convertsScreenPointsToWindowLocalWithTheNegativeOrigin() {
        let window = BackgroundPoster.Window(id: 7, bounds: CGRect(x: 100, y: 200, width: 800, height: 600))
        #expect(BackgroundPoster.windowPoint(fromScreenPoint: CGPoint(x: 350, y: 500), window: window)
                == CGPoint(x: 250, y: 300))
        // A point before the window's origin is allowed to go negative: the recipe is a raw translate.
        #expect(BackgroundPoster.windowPoint(fromScreenPoint: CGPoint(x: 50, y: 150), window: window)
                == CGPoint(x: -50, y: -50))
    }

    // MARK: Wave 2 — directApp delivery (docs/review/mm-review-20260918)

    /// F1: a mouse event whose windowNumber is 0 names NO window to the target app's AppKit —
    /// `sendEvent:` then has nothing to route the click to, the classic silently-dropped case.
    /// The built event must carry the target window's number.
    @Test func mouseEventsNameTheTargetWindowNumber() {
        let window = BackgroundPoster.Window(id: 4242, bounds: CGRect(x: 100, y: 200, width: 800, height: 600))
        guard let event = BackgroundPoster.mouseEvent(.leftMouseDown, button: .left, clickCount: 1,
                                                      screenPoint: CGPoint(x: 350, y: 500), window: window) else {
            Issue.record("CGEvent creation failed")
            return
        }
        #expect(NSEvent(cgEvent: event)?.windowNumber == 4242,
                "the posted event must name the window it is aimed at, not window 0")
    }

    /// F4: the fake-⌘ trick is gone. The old NX_COMMANDMASK bit made every delivered background
    /// click a ⌘-click — selection toggles, open-in-new-tab, canvas deselects — mis-delivering
    /// the wrong gesture wherever delivery worked at all.
    @Test func backgroundPostedClicksCarryNoModifierFlags() {
        let box = PostedEventBox()
        let prior = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = prior }
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }

        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                               clickCount: 1,
                               window: BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                               pid: 1)

        #expect(box.events.count == 2, "a click is a down and an up, got \(box.events.count)")
        for event in box.events {
            #expect(event.flags == .maskNonCoalesced,
                    "background clicks must not pretend modifiers are held: \(event.flags)")
        }
    }

    /// F2's missing gate: everything delivery depends on must be on the event at post time —
    /// PAST the `setSource` call this codebase measured to reset source-owned data (userData
    /// read back 0 when written first). The aim probe records the event's source state at aim
    /// time: 0 means the aim rode the shared source (pre-setSource); a private state id means
    /// the aim was applied after re-homing. The fields are then read off the event again at
    /// the poster seam, past `setSource`.
    @Test func windowTargetingIsAppliedAfterSetSourceAndSurvivesToPost() {
        final class AimBox: @unchecked Sendable { var stateIDs: [Int64] = [] }
        struct AimProbe: BackgroundPoster.WindowLocationResolver {
            let box: AimBox
            var isAvailable: Bool { true }
            @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool {
                box.stateIDs.append(event.getIntegerValueField(.eventSourceStateID))
                return true
            }
        }
        let aimBox = AimBox()
        let aim = AimProbe(box: aimBox)
        let box = PostedEventBox()
        let priorResolver = BackgroundPoster.windowLocationResolver
        let priorPoster = BackgroundPoster.eventPoster
        defer {
            BackgroundPoster.windowLocationResolver = priorResolver
            BackgroundPoster.eventPoster = priorPoster
        }
        BackgroundPoster.windowLocationResolver = aim
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }

        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 350, y: 500), holdFor: 0,
                               clickCount: 2,
                               window: BackgroundPoster.Window(id: 4242, bounds: CGRect(x: 100, y: 200, width: 800, height: 600)),
                               pid: 1234)

        #expect(box.events.count == 2)
        #expect(aimBox.stateIDs.allSatisfy { $0 != 0 },
                "the window aim must be applied after setSource (private source state), saw \(aimBox.stateIDs)")
        for event in box.events {
            #expect(event.getIntegerValueField(CGEventField(rawValue: 91)!) == 4242)
            #expect(event.getIntegerValueField(CGEventField(rawValue: 92)!) == 4242)
            #expect(event.getIntegerValueField(.mouseEventSubtype) == 3)
            #expect(event.getIntegerValueField(.eventSourceUserData) == EventSynthesizer.eventTag)
        }
    }

    /// F6/H6: with more than one window of the target app, the click must aim at the window
    /// that CONTAINS the captured point — the front-most window is only the fallback.
    @Test func windowChoicePrefersTheWindowContainingThePoint() {
        let pid: Int32 = 1234
        let front = Self.info(pid: pid, number: 42, bounds: ["X": 100, "Y": 200, "Width": 800, "Height": 600])
        let side = Self.info(pid: pid, number: 43, bounds: ["X": 900, "Y": 200, "Width": 800, "Height": 600])
        let list = [front, side]
        #expect(BackgroundPoster.window(ofPID: pid, in: list, containing: CGPoint(x: 350, y: 500))?.id == 42)
        // Inside only the second window: must pick THAT one, not the front-most one.
        #expect(BackgroundPoster.window(ofPID: pid, in: list, containing: CGPoint(x: 1000, y: 500))?.id == 43)
        // In neither (occluded, another Space, moved since capture): fall back to the front-most.
        #expect(BackgroundPoster.window(ofPID: pid, in: list, containing: CGPoint(x: 50, y: 50))?.id == 42)
    }

    /// F14: the private symbol is validated once — a missing symbol must disable directApp
    /// targeting with an explicit "not supported" warning, not post mis-aimed events.
    @Test func missingSymbolDisablesTargetingWithAWarning() {
        let priorLookup = BackgroundPoster.SystemWindowLocationResolver.symbolLookup
        let priorProblem = BackgroundPoster.windowTargetingProblem
        defer {
            BackgroundPoster.SystemWindowLocationResolver.symbolLookup = priorLookup
            BackgroundPoster.windowTargetingProblem = priorProblem
        }
        BackgroundPoster.SystemWindowLocationResolver.symbolLookup = { _ in nil }
        let resolver = BackgroundPoster.SystemWindowLocationResolver()
        #expect(resolver.isAvailable == false, "a nil dlsym must read as unavailable")
        #expect(BackgroundPoster.validateWindowTargeting(resolver: resolver) == false)
        #expect(BackgroundPoster.windowTargetingProblem?.contains("not supported") == true,
                "the warning must say targeting is not supported, got: \(BackgroundPoster.windowTargetingProblem ?? "nil")")
    }

    /// F14's fail-closed half: a symbol that exists but doesn't behave as (event, point) is
    /// just as unusable as a missing one.
    @Test func aSymbolThatFailsItsSignatureRoundTripDisablesTargeting() {
        struct BogusResolver: BackgroundPoster.WindowLocationResolver {
            var isAvailable: Bool { true }
            func signatureRoundTrips() -> Bool { false }
            @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool { true }
        }
        let priorProblem = BackgroundPoster.windowTargetingProblem
        defer { BackgroundPoster.windowTargetingProblem = priorProblem }
        #expect(BackgroundPoster.validateWindowTargeting(resolver: BogusResolver()) == false)
        #expect(BackgroundPoster.windowTargetingProblem != nil,
                "a failed signature round-trip must leave an explicit problem line")
    }

    @Test func aValidatedResolverClearsTheProblemAndSupportsTargeting() {
        struct GoodResolver: BackgroundPoster.WindowLocationResolver {
            var isAvailable: Bool { true }
            func signatureRoundTrips() -> Bool { true }
            @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool { true }
        }
        let priorProblem = BackgroundPoster.windowTargetingProblem
        let priorResolver = BackgroundPoster.windowLocationResolver
        defer {
            BackgroundPoster.windowTargetingProblem = priorProblem
            BackgroundPoster.windowLocationResolver = priorResolver
        }
        #expect(BackgroundPoster.validateWindowTargeting(resolver: GoodResolver()) == true)
        #expect(BackgroundPoster.windowTargetingProblem == nil)
        BackgroundPoster.windowLocationResolver = GoodResolver()
        #expect(BackgroundPoster.targetingSupported == true)
    }

    /// The base event mouseEvent builds: AppKit-seeded (12 protected fields), window NUMBER,
    /// button and click count. The window-target payload (91/92, subtype, window location,
    /// self-tag) is applied at post time — after setSource — and is asserted by
    /// `windowTargetingIsAppliedAfterSetSourceAndSurvivesToPost`.
    @Test func mouseEventCarriesTheRecipeFields() {
        let window = BackgroundPoster.Window(id: 4242, bounds: CGRect(x: 100, y: 200, width: 800, height: 600))
        let screenPoint = CGPoint(x: 350, y: 500)
        guard let event = BackgroundPoster.mouseEvent(.leftMouseDown, button: .left, clickCount: 2,
                                                      screenPoint: screenPoint, window: window) else {
            Issue.record("CGEvent creation failed")
            return
        }
        #expect(event.getIntegerValueField(.mouseEventButtonNumber) == CGMouseButton.left.rawValue)
        #expect(event.getIntegerValueField(.mouseEventClickState) == 2)
        #expect(event.location == screenPoint) // screen-space at CGEvent level
        #expect(NSEvent(cgEvent: event)?.windowNumber == 4242)
        // The protected field numbers from the research summary are populated by CGEvent itself
        // (event type, source…); the recipe only demands we never overwrite them, which the
        // mouseEvent code honors by touching exactly the fields asserted above.
    }

    /// F5: a click whose AppKit conversion dies must be reported undelivered — nothing posted.
    @Test func aFailedNSEventConversionFailsTheClickWithoutPosting() {
        let priorBuilder = BackgroundPoster.nsMouseEventBuilder
        let priorPoster = BackgroundPoster.eventPoster
        defer {
            BackgroundPoster.nsMouseEventBuilder = priorBuilder
            BackgroundPoster.eventPoster = priorPoster
        }
        let box = PostedEventBox()
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }
        BackgroundPoster.nsMouseEventBuilder = { _, _, _, _, _ in nil }

        let delivered = BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                                               clickCount: 1,
                                               window: BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                                               pid: 1)
        #expect(delivered == false, "a click whose event never materialized must report undelivered")
        #expect(box.events.isEmpty, "nothing may be posted when the event is nil")
    }

    /// The aim half of fail-loud delivery: a resolver that refuses must fail the click, not
    /// post a mis-aimed event.
    @Test func aRefusedWindowAimFailsTheClickWithoutPosting() {
        struct RefusingResolver: BackgroundPoster.WindowLocationResolver {
            var isAvailable: Bool { true }
            @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool { false }
        }
        let priorResolver = BackgroundPoster.windowLocationResolver
        let priorPoster = BackgroundPoster.eventPoster
        defer {
            BackgroundPoster.windowLocationResolver = priorResolver
            BackgroundPoster.eventPoster = priorPoster
        }
        let box = PostedEventBox()
        BackgroundPoster.windowLocationResolver = RefusingResolver()
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }

        let delivered = BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                                               clickCount: 1,
                                               window: BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                                               pid: 1)
        #expect(delivered == false)
        #expect(box.events.isEmpty, "an unaimed click must never reach the poster")
    }

    @Test func windowLocationResolverSeamDrivesTheSupportFlagAndCallsThrough() {
        final class Box: @unchecked Sendable { var recorded: [CGPoint] = [] }
        struct FakeResolver: BackgroundPoster.WindowLocationResolver {
            let isAvailable: Bool
            let box: Box
            @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool {
                box.recorded.append(point)
                return isAvailable
            }
        }
        let box = Box()

        let priorResolver = BackgroundPoster.windowLocationResolver
        let priorPoster = BackgroundPoster.eventPoster
        defer {
            BackgroundPoster.windowLocationResolver = priorResolver
            BackgroundPoster.eventPoster = priorPoster
        }

        BackgroundPoster.windowLocationResolver = FakeResolver(isAvailable: false, box: box)
        #expect(BackgroundPoster.targetingSupported == false)

        BackgroundPoster.windowLocationResolver = FakeResolver(isAvailable: true, box: box)
        #expect(BackgroundPoster.targetingSupported == true)

        // The aim now happens at post time (after setSource), so the seam is driven by a click.
        BackgroundPoster.eventPoster = { _, _ in }
        let window = BackgroundPoster.Window(id: 1, bounds: CGRect(x: 10, y: 20, width: 100, height: 80))
        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 110, y: 120), holdFor: 0,
                               clickCount: 1, window: window, pid: 1)
        #expect(box.recorded == [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 100)],
                "each transition's window-local point, passed through: \(box.recorded)")
    }

    @Test func postedClicksCarryNoSharedSourceState() {
        // Regression (can't-switch-apps-after-a-run): a recipe event built via NSEvent.cgEvent
        // rides the shared default event source, whose cumulative modifier/button state travels
        // to the window server on every post and can wedge (⌘ reads as held until the app
        // quits). postToPid must fire the event off a fresh private source instead.
        let window = BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let box = PostedEventBox()
        let prior = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = prior }
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }

        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                               clickCount: 1, window: window, pid: 1)

        #expect(box.events.count == 2)  // down + up
        for event in box.events {
            #expect(event.getIntegerValueField(.eventSourceStateID) != 0,
                    "background clicks must post from a private event source, not the shared HID state")
        }
    }

    /// Captures events instead of delivering them (see BackgroundPoster.eventPoster).
    private final class PostedEventBox: @unchecked Sendable { var events: [CGEvent] = [] }

    // MARK: Delivery defects found in the v2.0.5 sweep
    //
    // These live in THIS suite, not a sibling one: `.serialized` only orders tests within a
    // suite, and posting a click drives the same process-wide `windowLocationResolver` seam
    // that `windowLocationResolverSeamDrivesTheSupportFlagAndCallsThrough` swaps and records.
    // As a separate suite they ran concurrently and corrupted each other (observed).

    /// `NSEvent.mouseEvent(...).cgEvent` does its own top-left/bottom-left flip, and it measures
    /// that flip against the PRIMARY screen's maxY. Measured on a 1920x1080 primary: for every
    /// input, appKitY + cgY == 1080.0 exactly. Flipping about the UNION of all screens therefore
    /// offsets every background click by however far another display extends above the primary.
    /// `MacroRecorder` already flips about `NSScreen.screens.first` for the inverse conversion.
    @Test func flipIsMeasuredAgainstThePrimaryScreenNotTheUnionOfAllScreens() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 400)   // external display on top
        // Union maxY would be 1480 -> 980. The flip NSEvent actually applies is about 1080.
        #expect(BackgroundPoster.appKitY(fromScreenY: 500, screenFrames: [primary, above]) == 580)
        // Order must not matter: `screens.first` is the primary, and a union is order-free too,
        // so this case pins that the fix reads the primary rather than "the first listed".
        #expect(BackgroundPoster.appKitY(fromScreenY: 500, screenFrames: [primary]) == 580)
    }

    /// With no screens at all (display asleep, session switched) the union is `CGRect.null`,
    /// whose maxY is +infinity — every click would be posted at an infinite coordinate.
    @Test func noScreensYieldsAFiniteNumber() {
        #expect(BackgroundPoster.appKitY(fromScreenY: 500, screenFrames: []).isFinite)
    }

    /// Every synthesized event carries `eventTag` in `.eventSourceUserData` so Macro Maker's own
    /// output is recognisable — that is what stops "pause when I use the mouse" from pausing on
    /// the clicker's own clicks, and what stops the recorder capturing them. `setSource` RESETS
    /// that field to the new source's user data, so writing the tag before `setSource` erases it.
    /// Measured directly: userData 305419896 -> 0 across `setSource`.
    @Test func backgroundPostedClicksStillCarryTheSelfTag() {
        let previous = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = previous }
        nonisolated(unsafe) var tags: [Int64] = []
        BackgroundPoster.eventPoster = { event, _ in
            tags.append(event.getIntegerValueField(.eventSourceUserData))
        }
        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 300, y: 400), holdFor: 0,
                               clickCount: 1,
                               window: BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
                               pid: 1234)
        #expect(tags.count == 2, "a click is a down and an up, got \(tags.count)")
        #expect(tags.allSatisfy { $0 == EventSynthesizer.eventTag },
                "posted clicks lost the self-tag: \(tags) != \(EventSynthesizer.eventTag)")
    }

    /// The keyboard path has the identical ordering bug, and it was not even reachable from a
    /// test until `postKey` was routed through the same delivery seam as the mouse path.
    @Test func backgroundPostedKeysStillCarryTheSelfTag() {
        let previous = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = previous }
        nonisolated(unsafe) var tags: [Int64] = []
        BackgroundPoster.eventPoster = { event, _ in
            tags.append(event.getIntegerValueField(.eventSourceUserData))
        }
        BackgroundPoster.keyEvent(0, down: true, flags: [], pid: 1234)
        #expect(tags == [EventSynthesizer.eventTag],
                "posted keys lost the self-tag: \(tags) != [\(EventSynthesizer.eventTag)]")
    }
}

@Suite("Direct-app settings")
struct DirectAppSettingsTests {
    @Test func v1AndV2BlobsWithoutDirectAppFieldsDefaultCleanly() throws {
        let json = Data(#"{"button":"left","intervalMs":100,"target":"cursor","x":500,"y":500}"#.utf8)
        let settings = try JSONDecoder().decode(AutoClickerSettings.self, from: json)
        #expect(settings.target == .cursor)
        #expect(settings.directAppBundleID == "")
        #expect(settings.directAppX == 400 && settings.directAppY == 300)
    }

    @Test func directAppTargetRoundTrips() throws {
        var settings = AutoClickerSettings()
        settings.target = .directApp
        settings.directAppBundleID = "com.apple.Safari"
        settings.directAppX = 321
        settings.directAppY = 123
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AutoClickerSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func keyPresserSendToBundleIDRoundTripsAndDefaultsEmpty() throws {
        let old = Data(#"{"keyText":"space","mode":"autoPress","intervalMs":100}"#.utf8)
        #expect(try JSONDecoder().decode(KeyPresserSettings.self, from: old).sendToBundleID == "")

        var settings = KeyPresserSettings()
        settings.sendToBundleID = "com.apple.Terminal"
        let decoded = try JSONDecoder().decode(KeyPresserSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.sendToBundleID == "com.apple.Terminal")
    }
}
