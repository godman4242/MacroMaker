# MacroMaker Macro File Schema

## v1 (current, shipped — format name `macromaker`, `version: 1`)

Top level (all required): `format: "macromaker"`, `version: 1`, `name: string`,
`createdAt: ISO8601 string`, `events: array`.
Encoding: `.prettyPrinted`, `.sortedKeys`, `.withoutEscapingSlashes`.

Per event: `t: Double` (seconds, required), `type: "mouseDown"|"mouseUp"|"keyDown"|"keyUp"` (required),
`flags: UInt64` (optional, default 0). Mouse events add `button: "left"|"right"|"middle"`,
`x: Double`, `y: Double` (global screen points, macOS top-left origin of main display),
`clickCount: Int` (optional, default 1). keyDown adds `keyCode: UInt16` (**macOS virtual
key code** — see below), `repeat: Bool` (optional, default false); keyUp adds `keyCode`.

Since app 2.0, key events may also carry `text: String` (optional): the step editor's
typed-text input attaches the character to a placeholder key transition (`keyCode: 0`)
and playback types it as a Unicode string instead of pressing key 0. Older readers
ignore the field entirely (unknown-field rule below), so files stay openable in v1.

Decoder accepts v1 files with missing optional fields (defaults above); rejects
`version` outside `1...current`; unknown fields dropped on round-trip except `text`
which round-trips losslessly.
Writes are atomic; files capped at 16 MB on read.

## v2 (cross-platform, planned — shared by the Swift app and the Tauri sibling)

Additive changes only; decoders accept v1 and v2, writers emit v2:

1. **Key identity**: new `key` field = canonical key name (e.g. `"space"`, `"enter"`,
   `"a"`, `"f5"`) from the KeyCodes names vocabulary. Optional per-platform hints
   `macKeyCode`, `winVK`. v1 files keep `keyCode` (macOS virtual code) — readable
   on macOS via the existing KeyCodes table; best-effort warning elsewhere.
2. **Modifiers**: new `modifiers: ["ctrl"|"alt"|"shift"|"meta", ...]` array per event.
   `rawFlags` (UInt64) stays optional for lossless macOS round-trip. v1 decoders
   synthesize the array from CGEventFlags. `meta` = Cmd on macOS, Super on Linux;
   meta+letter hotkeys are OS-reserved on Windows/Linux.
3. **Coordinates**: optional `coords: {"space": "global-main-display"|"virtual-desktop"|"cursor-relative", "dpiHint": n}`.
   Point-macros are machine-local artifacts; keys and timing are the portable parts.
4. **Editing support (future)**: `.wait` event type for explicit waits.

## Non-portable macOS-only subsystems (Tauri port = rewrite)

- `BrowserScripting`/`WebClicker` (NSAppleScript) → Chrome DevTools Protocol, Safari excluded
- `EventSynthesizer` → enigo; `MacroRecorder` → per-OS input hook (rdev; listen-only
  global hooks need admin on Windows); `HotkeyService` → global-hotkey crate
- `KeyboardLayout` (UCKeyTranslate) → enigo layout-independent keys
- `PermissionService` → per-OS stubs; `MacroFiles` panels → Tauri dialogs
- Self-event exclusion via `eventSourceUserData` tag has no enigo equivalent —
  port must suppress by timestamp window or hook-level injection flag
- Hold-mode auto-repeat reads NSEvent.keyRepeatDelay/Interval → configurable constants

## Portable as-is

TickSchedule, RecordingCleaner, RunSession, WorkerThread logic, KeyStrokeParser
(CharacterKeyMap protocol seam), settings JSON shapes (5 keys: autoClicker,
keyPresser, webTarget, playback, hotkeys → tauri-plugin-store same keys).

## Persistence notes (from review)

- Hotkey settings blob decodes tolerantly per-platform; do NOT share hotkey
  settings across platforms (raw keycodes) — re-derive defaults from action names.
- Settings structs have no schema version yet; unknown-enum-key decode failure
  resets the whole blob (documented, fix queued for v1.1).