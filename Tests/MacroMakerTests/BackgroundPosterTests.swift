import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// One background click is FIVE posted events, not two: a stamped `mouseMoved`, an off-screen
/// primer down/up, then the real down/up. MEASURED 2026-09-20 on macOS 26.5.2 — without the
/// primer pair a Chromium-class target whose app is in the background drops the click entirely,
/// while the same click lands pixel-exact with it. See `BackgroundPoster.click`.
private let eventsPerClick = 5

// .serialized: one test swaps the process-wide windowLocationResolver seam.
@Suite("BackgroundPoster", .serialized, .seamSerialized)
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

        #expect(box.events.count == eventsPerClick, "a click is move + primer pair + down/up, got \(box.events.count)")
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
        final class AimBox: @unchecked Sendable { var stateIDs: [Int64] = []; var flagsAtAim: [CGEventFlags] = [] }
        struct AimProbe: BackgroundPoster.WindowLocationResolver {
            let box: AimBox
            var isAvailable: Bool { true }
            @discardableResult func setWindowLocation(of event: CGEvent, to point: CGPoint) -> Bool {
                box.stateIDs.append(event.getIntegerValueField(.eventSourceStateID))
                // N3: the aim runs strictly after setSource, so the flags read here are the
                // ones the event carries on the after-setSource side. Measured in this
                // process: setSource does NOT rewrite flags when no modifiers are held —
                // so this pin can't distinguish write order, only the surviving invariant
                // (explicit no-modifier flags reach delivery). The order itself follows the
                // file's rule: one proven wipe class is enough to keep flags after the call.
                box.flagsAtAim.append(event.flags)
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

        #expect(box.events.count == eventsPerClick)
        #expect(aimBox.stateIDs.allSatisfy { $0 != 0 },
                "the window aim must be applied after setSource (private source state), saw \(aimBox.stateIDs)")
        #expect(aimBox.flagsAtAim.allSatisfy { $0 == .maskNonCoalesced },
                "flags must already be the explicit no-modifier set on the after-setSource side: \(aimBox.flagsAtAim)")
        for event in box.events {
            #expect(event.getIntegerValueField(CGEventField(rawValue: 91)!) == 4242)
            #expect(event.getIntegerValueField(CGEventField(rawValue: 92)!) == 4242)
            #expect(event.getIntegerValueField(.mouseEventSubtype) == 3)
            #expect(event.getIntegerValueField(.eventSourceUserData) == EventSynthesizer.eventTag)
        }
    }

    /// F6/H6: with more than one window of the target app, the click must aim at the window
    /// that CONTAINS the captured point — the front-most window is only the fallback. Driven
    /// through the seeded listing seam (`resolveWindowLive` is the live entry point).
    @Test func windowChoicePrefersTheWindowContainingThePoint() {
        let pid: Int32 = 1234
        let front = Self.info(pid: pid, number: 42, bounds: ["X": 100, "Y": 200, "Width": 800, "Height": 600])
        let side = Self.info(pid: pid, number: 43, bounds: ["X": 900, "Y": 200, "Width": 800, "Height": 600])
        let priorLister = BackgroundPoster.windowListCopy
        defer { BackgroundPoster.windowListCopy = priorLister }
        BackgroundPoster.windowListCopy = { _ in [front, side] }
        #expect(BackgroundPoster.resolveWindowLive(ofPID: pid, containing: CGPoint(x: 350, y: 500))?.id == 42)
        // Inside only the second window: must pick THAT one, not the front-most one.
        #expect(BackgroundPoster.resolveWindowLive(ofPID: pid, containing: CGPoint(x: 1000, y: 500))?.id == 43)
        // In neither (occluded, another Space, moved since capture): fall back to the front-most.
        #expect(BackgroundPoster.resolveWindowLive(ofPID: pid, containing: CGPoint(x: 50, y: 50))?.id == 42)
    }

    /// N2: with a captured point, containment must be settled across BOTH listings before any
    /// window is accepted. The picked window can be minimized or on another Space — visible
    /// only to `.optionAll` — while the app's other window is front-most in the on-screen
    /// listing. Accepting that one aimed the click at (and the W2 clamp kept it inside) a
    /// window the user never picked — the worst failure mode for a clicker, because it looks
    /// like success.
    @Test func anOffScreenPickedWindowWinsOverAnOnScreenSibling() {
        let pid: Int32 = 1234
        // The app has two windows; the picked one (43) is on another Space. The on-screen
        // listing sees only the sibling (42); the all-windows listing carries both.
        let onScreen = [Self.info(pid: pid, number: 42, bounds: ["X": 0, "Y": 0, "Width": 800, "Height": 600])]
        let all = onScreen + [Self.info(pid: pid, number: 43, bounds: ["X": 1000, "Y": 0, "Width": 800, "Height": 600])]
        let priorLister = BackgroundPoster.windowListCopy
        defer { BackgroundPoster.windowListCopy = priorLister }
        BackgroundPoster.windowListCopy = { options in
            options == .optionOnScreenOnly ? onScreen : all
        }
        // The captured point lies inside window 43, the one only `.optionAll` can see.
        #expect(BackgroundPoster.resolveWindowLive(ofPID: pid, containing: CGPoint(x: 1200, y: 300))?.id == 43,
                "the window containing the point must win — not the first one the on-screen listing yields")
        // Nothing contains the point anywhere (occluded, moved since capture): the front-most
        // on-screen fallback still applies, unchanged.
        #expect(BackgroundPoster.resolveWindowLive(ofPID: pid, containing: CGPoint(x: -50, y: -50))?.id == 42,
                "with no containment hit in either listing, the front-most on-screen fallback wins")
        // No point supplied: front-most of the first listing that yields windows, unchanged.
        #expect(BackgroundPoster.resolveWindowLive(ofPID: pid)?.id == 42)
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
        // The move and the real down/up carry the window-local aim (110,120) - (10,20) =
        // (100,100). The two primers carry a literal (-1,-1) instead: a primer that inherited
        // the aim's window-local point would be a second real click on the page.
        #expect(box.recorded == [CGPoint(x: 100, y: 100),
                                 BackgroundPoster.primerPoint, BackgroundPoster.primerPoint,
                                 CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 100)],
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

        #expect(box.events.count == eventsPerClick)  // move + primer down/up + real down/up
        for event in box.events {
            #expect(event.getIntegerValueField(.eventSourceStateID) != 0,
                    "background clicks must post from a private event source, not the shared HID state")
        }
    }

    // MARK: SkyLight delivery (background clicking that Chromium-class targets accept)

    /// The default poster tries SLEventPostToPid first; when the symbol is absent it falls
    /// back to the public postToPid. Both must see a fully-stamped event.
    /// Records which delivery route the mock SkyLight/postToPid posters took.
    private final class DeliveryBox: @unchecked Sendable { var route = ""; var events: [CGEvent] = [] }

    @Test func deliveryTriesSkyLightThenFallsBackToPostToPid() {
        let box = DeliveryBox()
        Self.activeDeliveryBox = box
        let priorResolver = BackgroundPoster.skylightPostResolver
        let priorPoster = BackgroundPoster.eventPoster
        defer {
            Self.activeDeliveryBox = nil
            BackgroundPoster.skylightPostResolver = priorResolver
            BackgroundPoster.eventPoster = priorPoster
        }

        // Route 1: the SkyLight symbol resolves — the event goes through it, postToPid never runs.
        // A @convention(c) closure cannot capture Swift context, so the mock posts through a
        // global trampoline that forwards into the test's box (installed just below, cleared
        // in the defer above).
        BackgroundPoster.skylightPostResolver = { Self.skyLightTrampoline }
        BackgroundPoster.eventPoster = { event, pid in
            if BackgroundPoster.skylightPostToPid(pid, event) { return }
            event.postToPid(pid)
        }
        let window = BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                               clickCount: 1, window: window, pid: 4242)
        #expect(box.route == "skylight(pid:4242)", "delivery must prefer the SkyLight route, got \(box.route)")
        #expect(box.events.count == eventsPerClick, "every event of the gesture goes via SkyLight, got \(box.events.count)")

        // Route 2: the symbol is absent — the public postToPid fallback runs.
        box.route = ""
        box.events.removeAll()
        BackgroundPoster.skylightPostResolver = { nil }
        BackgroundPoster.eventPoster = { event, pid in
            if BackgroundPoster.skylightPostToPid(pid, event) { return }
            box.route = "postToPid"
            box.events.append(event)
        }
        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                               clickCount: 1, window: window, pid: 4242)
        #expect(box.route == "postToPid", "an absent SkyLight symbol must fall back to postToPid, got \(box.route)")
        #expect(box.events.count == eventsPerClick)
    }

    /// The measured Chromium recipe, pinned event by event. The bug this closes: with only a
    /// down/up pair, a background Brave dropped every click silently (measured 2026-09-20,
    /// four variants incl. a forced-correct window); with the move + off-screen primer in
    /// front of it the same click landed pixel-exact with another app frontmost. A primer is
    /// needed on EVERY click — skipping it after one primed click went back to being dropped.
    @Test func everyClickCarriesTheMoveAndOffScreenPrimerChromiumNeeds() {
        let box = PostedEventBox()
        let prior = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = prior }
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }

        let window = BackgroundPoster.Window(id: 7, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 300, y: 400), holdFor: 0,
                               clickCount: 1, window: window, pid: 1234)

        let phaseField = CGEventField(rawValue: 0)!
        let groupField = CGEventField(rawValue: 58)!
        let phases = box.events.map { $0.getIntegerValueField(phaseField) }
        let types = box.events.map(\.type)

        #expect(types == [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp],
                "the gesture is move -> primer down/up -> real down/up, got \(types)")
        #expect(phases == [BackgroundPoster.Phase.move,
                           BackgroundPoster.Phase.primerDown,
                           BackgroundPoster.Phase.primerUp,
                           BackgroundPoster.Phase.real,
                           BackgroundPoster.Phase.real],
                "Chromium tells the primer from the real click by field 0, got \(phases)")

        // The primer must land OFF the window: on it, it would click the page for real.
        #expect(box.events[1].location == BackgroundPoster.primerPoint)
        #expect(box.events[2].location == BackgroundPoster.primerPoint)
        // ...and the real pair at the point the caller asked for.
        #expect(box.events[3].location == CGPoint(x: 300, y: 400))
        #expect(box.events[4].location == CGPoint(x: 300, y: 400))

        // One click-group id across the whole gesture, and never 0 (0 reads as "no group").
        let groups = Set(box.events.map { $0.getIntegerValueField(groupField) })
        #expect(groups.count == 1, "one gesture must carry one click-group id, got \(groups)")
        #expect(groups.first != 0, "a zero click-group id is indistinguishable from unset")
    }

    /// Chromium's renderer filter reads the target pid (f40) off the event; the click must
    /// carry it beside the existing 91/92 pair. (The bridge window number, f51, is left to
    /// NSEvent.mouseEvent — it is on `protectedFields` and already set via windowNumber:.)
    @Test func chromiumFilteredClicksCarryTheTargetPidField() {
        let box = PostedEventBox()
        let prior = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = prior }
        BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }

        BackgroundPoster.click(.left, screenPoint: CGPoint(x: 50, y: 50), holdFor: 0,
                               clickCount: 1,
                               window: BackgroundPoster.Window(id: 77, bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                               pid: 9182)
        #expect(box.events.count == eventsPerClick)
        for event in box.events {
            #expect(event.getIntegerValueField(CGEventField(rawValue: 40)!) == 9182,
                    "the target pid must ride field 40 (Chromium's synthetic-event filter)")
            #expect(event.getIntegerValueField(CGEventField(rawValue: 51)!) == 77,
                    "NSEvent's own window number (field 51) is untouched")
        }
    }

    /// Captures events instead of delivering them (see BackgroundPoster.eventPoster).
    private final class PostedEventBox: @unchecked Sendable { var events: [CGEvent] = [] }

    /// C-compatible trampoline for mocking `SLEventPostToPid` in tests: a @convention(c)
    /// closure cannot capture context, so the current test's DeliveryBox is parked in this
    /// global and the C function forwards into it. Cleared by the test's defer.
    private nonisolated(unsafe) static var activeDeliveryBox: DeliveryBox?
    private nonisolated static let skyLightTrampoline: @convention(c) (pid_t, CGEvent) -> Void = { pid, event in
        activeDeliveryBox?.route = "skylight(pid:\(pid))"
        activeDeliveryBox?.events.append(event)
    }

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
        #expect(tags.count == eventsPerClick, "every event of the gesture carries the tag, got \(tags.count)")
        #expect(tags.allSatisfy { $0 == EventSynthesizer.eventTag },
                "posted clicks lost the self-tag: \(tags) != \(EventSynthesizer.eventTag)")
    }

    /// The keyboard path has the identical ordering bug, and it was not even reachable from a
    /// test until `postKey` was routed through the same delivery seam as the mouse path.
    /// The flags pin mirrors the mouse path's: the write must survive to the post seam as
    /// the explicit no-modifier set, never the user's held keys.
    @Test func backgroundPostedKeysStillCarryTheSelfTag() {
        let previous = BackgroundPoster.eventPoster
        defer { BackgroundPoster.eventPoster = previous }
        nonisolated(unsafe) var tags: [Int64] = []
        nonisolated(unsafe) var flags: [CGEventFlags] = []
        BackgroundPoster.eventPoster = { event, _ in
            tags.append(event.getIntegerValueField(.eventSourceUserData))
            flags.append(event.flags)
        }
        BackgroundPoster.keyEvent(0, down: true, flags: [], pid: 1234)
        #expect(tags == [EventSynthesizer.eventTag],
                "posted keys lost the self-tag: \(tags) != [\(EventSynthesizer.eventTag)]")
        #expect(flags == [.maskNonCoalesced],
                "posted keys must carry explicit flags only, saw \(flags)")
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
