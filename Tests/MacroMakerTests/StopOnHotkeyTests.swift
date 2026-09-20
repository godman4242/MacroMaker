import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing

@testable import MacroMaker

/// Wave 7, feature 1 — "repeat until keypress" stop condition (features.json F-11).
/// One global, configurable hotkey (new builtin action, default F6) stops any active run;
/// Auto Clicker and Playback get a "repeat until the stop shortcut" stop condition that
/// turns off their count/duration bounds, exactly like the frontmost-stop option is a
/// settings bool that changes the run's plan.
@Suite("Stop-on-hotkey", .serialized, .seamSerialized)
@MainActor
struct StopOnHotkeyTests {

    // MARK: The hotkey action and its default combo

    /// The new builtin exists, is listed (Settings shows it automatically), and its default
    /// is F6 bare — no clash with the ⌃⌥-letter defaults every other builtin uses.
    @Test func theStopRunActionDefaultsToBareF6AndClashesWithNothing() {
        #expect(BuiltinHotkeyAction.allCases.contains(.stopRun))
        let combo = BuiltinHotkeyAction.stopRun.defaultCombo
        #expect(combo.keyCode == UInt32(kVK_F6), "the default is F6")
        #expect(combo.modifiers.isEmpty, "bare F6 — no modifiers held")
        let others = BuiltinHotkeyAction.allCases.filter { $0 != .stopRun }
        #expect(!others.contains { $0.defaultCombo == combo },
                "the stop shortcut must not share a default with any other action")
    }

    /// The stop action is stored/decoded by name like every builtin (a defaults blob written
    /// by this build names it "stopRun").
    @Test func theStopRunActionRoundTripsThroughStorage() {
        #expect(HotkeyAction(rawValue: "stopRun") == .builtin(.stopRun))
        let stored: [HotkeyAction: KeyCombo?] = [.stopRun: KeyCombo(keyCode: 97, modifiers: [])]
        let decoded = HotkeyAction.storedCombos(from: try! JSONEncoder().encode(stored))
        #expect(decoded[.stopRun].flatMap { $0 }?.keyCode == 97)
    }

    // MARK: The stop condition option (settings → run bounds)

    /// Auto Clicker: "repeat until the stop shortcut" turns the count/duration bounds OFF —
    /// the run's stop condition is the hotkey, not a number.
    @Test func autoClickerUntilHotkeyDisablesTheCountAndDurationBounds() {
        var s = AutoClickerSettings()
        s.stopAfterClicks = true
        s.maxClicks = 5
        s.stopAfterDuration = true
        s.maxDurationSeconds = 10
        #expect(AutoClicker.stopLimits(s).clicks == 5)
        #expect(AutoClicker.stopLimits(s).duration == 10)
        s.stopOnHotkey = true
        #expect(AutoClicker.stopLimits(s).clicks == nil,
                "an until-hotkey run has no click bound")
        #expect(AutoClicker.stopLimits(s).duration == nil,
                "an until-hotkey run has no time bound")
    }

    /// Playback: "repeat until the stop shortcut" ignores the repeat count and the loop
    /// toggle — the pass count is unbounded, ended by the hotkey.
    @Test func playbackUntilHotkeyIgnoresRepeatCountAndLoop() {
        var s = PlaybackSettings()
        s.repeatCount = 3
        #expect(MacroPlayer.playbackRepeats(s) == 3)
        s.loopForever = true
        #expect(MacroPlayer.playbackRepeats(s) == nil)
        s.loopForever = false
        s.stopOnHotkey = true
        #expect(MacroPlayer.playbackRepeats(s) == nil,
                "an until-hotkey playback loops until the shortcut ends it")
    }

    /// The new settings fields decode with the Wave-6 tolerance (absent → default false)
    /// and survive a profile round-trip.
    @Test func theNewSettingsFieldsDecodeTolerantlyAndRoundTrip() throws {
        let s = try JSONDecoder().decode(AutoClickerSettings.self, from: Data("{}".utf8))
        #expect(s.stopOnHotkey == false)
        let p = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        #expect(p.stopOnHotkey == false)
        var a = AutoClickerSettings(); a.stopOnHotkey = true
        var b = PlaybackSettings(); b.stopOnHotkey = true
        #expect(try JSONDecoder().decode(AutoClickerSettings.self, from: JSONEncoder().encode(a)).stopOnHotkey == true)
        #expect(try JSONDecoder().decode(PlaybackSettings.self, from: JSONEncoder().encode(b)).stopOnHotkey == true)
    }

    // MARK: The hotkey stops any active run

    /// Pressing the stop shortcut stops a live Auto Clicker run — the same teardown as the
    /// in-app Stop (the run's worker is cancelled through the session's stop hook).
    @Test func pressingTheStopShortcutStopsAnActiveAutoClickerRun() {
        let model = AppModel.shared
        let clicker = model.autoClicker
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: AutoClicker.storageKey)
        let savedSettings = clicker.settings
        let savedPoster = BackgroundPoster.eventPoster
        model.permissions.forceAccessibilityTrusted = true
        BackgroundPoster.eventPoster = { _, _ in }
        defer {
            BackgroundPoster.eventPoster = savedPoster
            model.permissions.forceAccessibilityTrusted = false
            model.perform(BuiltinHotkeyAction.stopAll, trigger: .hotkey)
            clicker.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: AutoClicker.storageKey) }
            else { defaults.removeObject(forKey: AutoClicker.storageKey) }
        }
        var settings = savedSettings
        settings.target = .directApp
        settings.directAppBundleID = "com.apple.finder"
        clicker.settings = settings

        clicker.toggle(.hotkey)   // no countdown: running immediately
        #expect(clicker.session.phase == .running)

        model.perform(BuiltinHotkeyAction.stopRun, trigger: .hotkey)
        #expect(clicker.session.phase == .idle,
                "the stop shortcut must stop a running Auto Clicker run")
    }

    /// And a live Key Presser run — the hotkey stops every feature's run, not just the clicker.
    @Test func pressingTheStopShortcutStopsAnActiveKeyPresserRun() {
        let model = AppModel.shared
        let presser = model.keyPresser
        let defaults = UserDefaults.standard
        let savedSettingsBlob = defaults.data(forKey: "keyPresser")
        let savedSettings = presser.settings
        let savedPoster = EventSynthesizer.eventPoster
        model.permissions.forceAccessibilityTrusted = true
        EventSynthesizer.eventPoster = { _ in }
        defer {
            EventSynthesizer.eventPoster = savedPoster
            model.permissions.forceAccessibilityTrusted = false
            model.perform(BuiltinHotkeyAction.stopAll, trigger: .hotkey)
            presser.settings = savedSettings
            if let savedSettingsBlob { defaults.set(savedSettingsBlob, forKey: "keyPresser") }
            else { defaults.removeObject(forKey: "keyPresser") }
        }
        var settings = savedSettings
        settings.keyText = "f5"   // a key no test asserts on
        presser.settings = settings

        presser.toggle(.hotkey)
        #expect(presser.session.phase == .running)

        model.perform(BuiltinHotkeyAction.stopRun, trigger: .hotkey)
        #expect(presser.session.phase == .idle,
                "the stop shortcut must stop a running Key Presser run")
    }
}