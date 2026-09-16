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
