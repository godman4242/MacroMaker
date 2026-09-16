import Carbon.HIToolbox
import SwiftUI

/// Shows a global shortcut; click it and press new keys to change it.
struct HotkeyField: View {
    let action: HotkeyAction
    @Environment(AppModel.self) private var model

    private var captureID: String { "hotkey.\(action.storageName)" }
    private var isCapturing: Bool { model.keyCapture.owner == captureID }

    var body: some View {
        HStack(spacing: 6) {
            if model.hotkeys.unavailable.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Another app already uses this shortcut. Pick a different one.")
            }
            Button {
                isCapturing ? model.keyCapture.end() : beginCapture()
            } label: {
                Text(isCapturing ? "Press keys…" : model.hotkeys.label(for: action) ?? "None")
                    .frame(minWidth: 90)
            }
            .help(isCapturing ? "Press a shortcut including ⌃, ⌥ or ⌘. Esc cancels, Delete removes." : "Click to change")
            if model.hotkeys.combos[action] != nil, !isCapturing {
                Button {
                    model.hotkeys.setCombo(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onDisappear {
            if isCapturing { model.keyCapture.end() }
        }
    }

    private func beginCapture() {
        let hotkeys = model.hotkeys
        let action = action
        // Otherwise pressing an existing shortcut would trigger it instead of being captured.
        hotkeys.suspend()
        model.keyCapture.begin(owner: captureID, onKey: { event in
            let code = CGKeyCode(event.keyCode)
            let modifiers = KeyModifiers(event.modifierFlags)
            if modifiers.isEmpty, Int(code) == kVK_Escape { return true }
            if modifiers.isEmpty, [kVK_Delete, kVK_ForwardDelete].contains(Int(code)) {
                hotkeys.setCombo(nil, for: action)
                return true
            }
            // Shift alone would hijack normal typing everywhere, so require ⌃, ⌥ or ⌘ (F-keys excepted).
            guard !modifiers.subtracting(.shift).isEmpty || KeyCodes.isFunctionKey(code) else {
                NSSound.beep()
                return false
            }
            hotkeys.setCombo(KeyCombo(keyCode: UInt32(code), modifiers: modifiers), for: action)
            return true
        }, onEnd: {
            hotkeys.resume()
        })
    }
}
