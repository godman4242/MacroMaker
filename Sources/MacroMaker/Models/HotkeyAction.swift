import Carbon.HIToolbox

/// A global keyboard shortcut: a key plus at least one modifier (or a function key on its own).
struct KeyCombo: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: KeyModifiers
}

enum HotkeyAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case toggleAutoClicker
    case toggleKeyPresser
    case toggleWebTarget
    case toggleRecording
    case togglePlayback
    case stopAll

    var id: Self { self }

    var title: String {
        switch self {
        case .toggleAutoClicker: "Start/stop Auto Clicker"
        case .toggleKeyPresser: "Start/stop Key Presser"
        case .toggleWebTarget: "Start/stop Web Target"
        case .toggleRecording: "Start/stop recording"
        case .togglePlayback: "Start/stop playback"
        case .stopAll: "Stop everything"
        }
    }

    /// Defaults use ⌃⌥ plus a mnemonic letter — a combination almost no app claims.
    var defaultCombo: KeyCombo {
        let key: Int = switch self {
        case .toggleAutoClicker: kVK_ANSI_C
        case .toggleKeyPresser: kVK_ANSI_K
        case .toggleWebTarget: kVK_ANSI_W
        case .toggleRecording: kVK_ANSI_R
        case .togglePlayback: kVK_ANSI_P
        case .stopAll: kVK_ANSI_S
        }
        return KeyCombo(keyCode: UInt32(key), modifiers: [.control, .option])
    }
}
