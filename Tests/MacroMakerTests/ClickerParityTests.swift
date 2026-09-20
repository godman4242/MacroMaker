import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import MacroMaker

@Suite struct IntervalUnitTests {
    @Test func convertsBothWays() {
        #expect(IntervalUnit.seconds.toMilliseconds(2) == 2_000)
        #expect(IntervalUnit.minutes.toMilliseconds(2) == 120_000)
        #expect(IntervalUnit.hours.toMilliseconds(0.5) == 1_800_000)
        #expect(IntervalUnit.minutes.fromMilliseconds(120_000) == 2)
        #expect(IntervalUnit.milliseconds.fromMilliseconds(120_000) == 120_000)
    }

    @Test func displayRangesNeverExceedTheCeiling() {
        for unit in IntervalUnit.allCases {
            #expect(unit.toMilliseconds(unit.displayRange.upperBound) <= IntervalUnit.maximumIntervalMs)
            #expect(unit.displayRange.lowerBound > 0)
        }
    }
}

@Suite struct ClickRateTests {
    @Test func fastRatesUseClicksPerSecond() {
        #expect(ClickRate.describe(intervalMs: 100) == "About 10 clicks per second.")
        // Burst of 3 at 100 ms → 30 CPS.
        #expect(ClickRate.describe(intervalMs: 100, burstSize: 3) == "About 30 clicks per second.")
    }

    @Test func slowRatesUseIntervalAndCPS() {
        let twoMinutes = ClickRate.describe(intervalMs: 120_000)
        #expect(twoMinutes.hasPrefix("One click every 2 min"))
        #expect(twoMinutes.contains("0.0083"))
        #expect(twoMinutes.hasSuffix("CPS."))
    }

    @Test func intervalDescriptionsPickReadableUnits() {
        #expect(ClickRate.describeInterval(500) == "500 ms")
        #expect(ClickRate.describeInterval(2_000) == "2 s")
        #expect(ClickRate.describeInterval(120_000) == "2 min")
        #expect(ClickRate.describeInterval(90_000) == "1.5 min")
        #expect(ClickRate.describeInterval(3_600_000) == "1 hr")
    }
}

@Suite struct ClickGeometryTests {
    @Test func randomPointStaysInsideTheRect() {
        let rect = CGRect(x: 100, y: 200, width: 300, height: 150)
        // CGRect.contains excludes the maxX/maxY edges, so assert min/max bounds instead;
        // out-of-range uniforms clamp onto the boundary, never outside.
        for (u1, u2) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (-0.5, 1.5)] {
            let point = ClickGeometry.randomPoint(in: rect, u1: u1, u2: u2)
            #expect(point.x >= rect.minX && point.x <= rect.maxX)
            #expect(point.y >= rect.minY && point.y <= rect.maxY)
        }
        #expect(ClickGeometry.randomPoint(in: rect, u1: 0.5, u2: 0.5) == CGPoint(x: 250, y: 275))
    }

    @Test func jitterKeepsPointsWithinReach() {
        let point = CGPoint(x: 500, y: 500)
        for (u1, u2) in [(0.0, 1.0), (0.5, 0.5), (1.0, 0.0), (2.0, -1.0)] {
            let moved = ClickGeometry.jitter(point, amount: 5, u1: u1, u2: u2)
            #expect(abs(moved.x - 500) <= 5)
            #expect(abs(moved.y - 500) <= 5)
        }
        #expect(ClickGeometry.jitter(point, amount: 0, u1: 0, u2: 1) == point)
        #expect(ClickGeometry.jitter(point, amount: 5, u1: 1, u2: 0) == CGPoint(x: 505, y: 495))
    }

    /// H5: jitter can push a direct-app click point outside the window it must land in — the
    /// delivery point is clamped back inside the window's bounds. The max edges are exclusive
    /// (a point ON the boundary is the neighbouring surface's to click), so clamp steps one
    /// ULP inside instead of clamping onto `rect.maxX`.
    @Test func clampPullsAPointBackInsideTheRect() {
        let rect = CGRect(x: 100, y: 200, width: 300, height: 150)
        #expect(ClickGeometry.clamp(CGPoint(x: 50, y: 150), to: rect) == CGPoint(x: 100, y: 200))
        #expect(ClickGeometry.clamp(CGPoint(x: 900, y: 900), to: rect)
                == CGPoint(x: 400.nextDown, y: 350.nextDown))
        #expect(ClickGeometry.clamp(CGPoint(x: 250, y: 275), to: rect) == CGPoint(x: 250, y: 275))
        // An empty rect has nothing to clamp into — the point passes through unchanged.
        #expect(ClickGeometry.clamp(CGPoint(x: 250, y: 275), to: CGRect.null) == CGPoint(x: 250, y: 275))
    }
}

@Suite struct RunRulesTests {
    @Test func frontmostChangeRequiresTwoSnapshots() {
        #expect(!FrontmostStopRule.changed(from: "com.a", to: "com.a"))
        #expect(FrontmostStopRule.changed(from: "com.a", to: "com.b"))
        #expect(!FrontmostStopRule.changed(from: nil, to: "com.b"))
        #expect(!FrontmostStopRule.changed(from: "com.a", to: nil))
    }

    @Test func delayedStartAddsAndClamps() {
        #expect(DelayedStart.total(base: 3, extra: 9.6) == 13)
        #expect(DelayedStart.total(base: 3, extra: 0) == 3)
        #expect(DelayedStart.total(base: 3, extra: -5) == 3)
        #expect(DelayedStart.total(base: 0, extra: 2) == 2)
    }
}

@Suite struct AutoClickerSettingsTests {
    @Test func v1SettingsBlobStillDecodes() throws {
        let json = """
        {"button":"right","intervalMs":250,"randomizeInterval":true,"randomOffsetMs":30,
         "target":"fixedPoint","x":12,"y":34,"stopAfterClicks":true,"maxClicks":42,
         "stopAfterDuration":false,"maxDurationSeconds":60}
        """
        let decoded = try JSONDecoder().decode(AutoClickerSettings.self, from: Data(json.utf8))
        #expect(decoded.button == .right)
        #expect(decoded.intervalMs == 250)
        #expect(decoded.target == .fixedPoint)
        // v2 fields fall back to defaults.
        #expect(decoded.burstSize == 1)
        #expect(decoded.clickCountPerEvent == .single)
        #expect(decoded.intervalUnit == .milliseconds)
        #expect(!decoded.holdToClick)
        #expect(!decoded.restoreCursor)
        #expect(decoded.delayedStartSeconds == 0)
    }

    @Test func v2RoundTrips() throws {
        var settings = AutoClickerSettings()
        settings.burstSize = 4
        settings.clickCountPerEvent = .triple
        settings.intervalUnit = .minutes
        settings.intervalMs = 120_000
        settings.jitterEnabled = true
        settings.jitterPx = 7
        settings.stopOnFrontmostChange = true
        settings.holdToClick = true
        settings.delayedStartSeconds = 5
        settings.restoreCursor = true
        settings.target = .region
        settings.region = ClickRegion(x: 1, y: 2, width: 30, height: 40)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AutoClickerSettings.self, from: data)
        #expect(decoded == settings)
    }

    @Test func clickCountMapsToCGClickState() {
        #expect(AutoClickerSettings.ClickCount.single.rawValue == 1)
        #expect(AutoClickerSettings.ClickCount.double.rawValue == 2)
        #expect(AutoClickerSettings.ClickCount.triple.rawValue == 3)
    }

    @Test func regionFromOppositeCornersNormalizes() {
        let region = ClickRegion(corner1: CGPoint(x: 300, y: 400), corner2: CGPoint(x: 100, y: 200))
        #expect(region.x == 100 && region.y == 200)
        #expect(region.width == 200 && region.height == 200)
        // A click without moving = 1×1 region, not zero-size.
        let tiny = ClickRegion(corner1: CGPoint(x: 50, y: 60), corner2: CGPoint(x: 50, y: 60))
        #expect(tiny.width == 1 && tiny.height == 1)
    }
}

@Suite struct HotkeyActionTests {
    @Test func builtinCodableStringsMatchV1Storage() throws {
        // v1 stored "toggleAutoClicker" etc.; the case-name encoding must reproduce it exactly.
        let legacy = Data("\"toggleAutoClicker\"".utf8)
        let decoded = try JSONDecoder().decode(HotkeyAction.self, from: legacy)
        #expect(decoded == .toggleAutoClicker)
        #expect(try JSONDecoder().decode(HotkeyAction.self, from: legacy).storageName == "toggleAutoClicker")
    }

    @Test func macroActionsRoundTrip() throws {
        let id = UUID()
        let action = HotkeyAction.macro(id)
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(HotkeyAction.self, from: data)
        #expect(decoded == action)
        #expect(action.storageName == "macro:\(id.uuidString)")
    }

    @Test func unknownActionNamesAreRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HotkeyAction.self, from: Data("\"bogus\"".utf8))
        }
    }

    @Test func slotIDsAreUniqueAcrossKinds() {
        var seen = Set<UInt32>()
        for action in BuiltinHotkeyAction.allCases {
            let slot = HotkeyAction.builtin(action).slotID
            #expect(seen.insert(slot).inserted)
        }
        for _ in 0..<20 {
            let slot = HotkeyAction.macro(UUID()).slotID
            #expect(slot >= HotkeyAction.macroIDBase)
        }
    }

    @Test func comboMatchingToleratesExtraModifiers() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: [.control, .option])
        #expect(combo.matches(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: [.control, .option]))
        #expect(combo.matches(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: [.control, .option, .shift]))
        #expect(!combo.matches(keyCode: CGKeyCode(kVK_ANSI_C), modifiers: [.control]))
        #expect(!combo.matches(keyCode: CGKeyCode(kVK_ANSI_K), modifiers: [.control, .option]))
    }

    @Test func legacyV1HotkeysBlobDecodes() throws {
        // The v1 wire format: a Dictionary with a non-String Codable key encodes as an
        // alternating [key, value] JSON array; cleared shortcuts are null elements.
        let json = """
        ["toggleAutoClicker",{"keyCode":8,"modifiers":3},
         "toggleKeyPresser",null,"toggleWebTarget",null,"toggleRecording",null,
         "togglePlayback",null,"stopAll",{"keyCode":1,"modifiers":3}]
        """
        let decoded = try JSONDecoder().decode([HotkeyAction: KeyCombo?].self, from: Data(json.utf8))
        #expect(decoded.count == 6)
        #expect(decoded[.toggleAutoClicker]??.keyCode == 8)
        #expect(decoded[.stopAll]??.keyCode == 1)
        #expect(decoded[.togglePlayback]! == nil)
    }

    @Test func hotkeysBlobRoundTripsThroughTheV1Shape() throws {
        let blob: [HotkeyAction: KeyCombo?] = [
            .toggleAutoClicker: KeyCombo(keyCode: 8, modifiers: [.control, .option]),
            .toggleKeyPresser: nil,
            .macro(UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!): KeyCombo(keyCode: 3, modifiers: [.command]),
        ]
        let data = try JSONEncoder().encode(blob)
        // Macro actions appear under their "macro:<uuid>" name in the same array format.
        #expect(String(decoding: data, as: UTF8.self).contains("00000000-0000-0000-0000-0000000000AB"))
        #expect(try JSONDecoder().decode([HotkeyAction: KeyCombo?].self, from: data) == blob)
    }
}

/// A time-limited run that is paused and resumed. Clicks already done survive a pause (`begin`
/// passes `skipping:` from `clicksDone`) but elapsed time did not: each resume built a fresh
/// worker whose deadline was `now + maxDuration`, so "stop after 60 s" could run for 60 s *per
/// resume*, without bound.
@Suite("Run time budget")
struct RunTimeBudgetTests {
    private static let start: UInt64 = 1_000_000_000

    @Test func aResumeKeepsSpendingTheSameBudgetRatherThanAFreshOne() {
        // 60s limit with 50s already spent: only 10s left, not another 60.
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: 60, alreadyElapsed: 50)
                == Self.start + 10_000_000_000)
    }

    @Test func anExhaustedBudgetStopsImmediatelyInsteadOfGoingNegative() {
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: 60, alreadyElapsed: 60) == Self.start)
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: 60, alreadyElapsed: 90) == Self.start,
                "over budget must not wrap around UInt64")
    }

    @Test func aFreshRunIsUnchanged() {
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: 60, alreadyElapsed: 0)
                == Self.start + 60_000_000_000)
    }

    @Test func noLimitMeansNoDeadline() {
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: nil, alreadyElapsed: 0) == .max)
    }

    /// The same `UInt64(Double)` trap guarded elsewhere this session: it must not be reachable
    /// from a settings value either.
    @Test func aNonFiniteOrAbsurdLimitCannotTrap() {
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: .infinity, alreadyElapsed: 0) > Self.start)
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: .nan, alreadyElapsed: 0) == Self.start)
        #expect(AutoClicker.runDeadlineNanos(start: Self.start, maxDuration: 1e30, alreadyElapsed: 0) > Self.start)
    }
}
