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

    @Test func clickFlagsSetTheCommandBitOnlyForBackgroundApps() {
        #expect(BackgroundPoster.clickFlags(appIsActive: true) == [])
        #expect(BackgroundPoster.clickFlags(appIsActive: false) == CGEventFlags(rawValue: 0x0010_0000))
    }

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
        #expect(event.getIntegerValueField(.mouseEventSubtype) == 3)
        #expect(event.getIntegerValueField(CGEventField(rawValue: 91)!) == 4242)
        #expect(event.getIntegerValueField(CGEventField(rawValue: 92)!) == 4242)
        #expect(event.location == screenPoint) // screen-space at CGEvent level
        // The protected field numbers from the research summary are populated by CGEvent itself
        // (event type, source…); the recipe only demands we never overwrite them, which the
        // mouseEvent code honors by touching exactly the five fields asserted above.
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

        let prior = BackgroundPoster.windowLocationResolver
        defer { BackgroundPoster.windowLocationResolver = prior }

        BackgroundPoster.windowLocationResolver = FakeResolver(isAvailable: false, box: box)
        #expect(BackgroundPoster.targetingSupported == false)

        BackgroundPoster.windowLocationResolver = FakeResolver(isAvailable: true, box: box)
        #expect(BackgroundPoster.targetingSupported == true)

        let window = BackgroundPoster.Window(id: 1, bounds: CGRect(x: 10, y: 20, width: 100, height: 80))
        let event = BackgroundPoster.mouseEvent(.leftMouseDown, button: .left, clickCount: 1,
                                                screenPoint: CGPoint(x: 110, y: 120), window: window)
        #expect(event != nil)
        #expect(box.recorded == [CGPoint(x: 100, y: 100)]) // window-local point passed through
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
                               clickCount: 1, window: window, pid: 1, appIsActive: false)

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
                               pid: 1234, appIsActive: false)
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
