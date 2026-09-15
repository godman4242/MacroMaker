# Macro Maker

A native macOS menu bar app that clicks, presses keys, clicks inside web pages, and records and replays macros.
Written in Swift and SwiftUI. Needs macOS 14 (Sonoma) or later, and runs natively on Apple Silicon and Intel.

| Tab | What it does |
|---|---|
| **Auto Clicker** | Left, right or middle clicks every N ms, with an optional random offset. Clicks at the cursor or at a fixed screen point. Can stop by itself after N clicks or a time limit. |
| **Key Presser** | Presses any key: letters, digits, `!@#$`, space, enter, tab, arrows, F1–F20, or combos like `cmd+shift+z`. **Auto press** repeats it on an interval. **Hold down** keeps it pressed, with key repeat, like a finger on the key. |
| **Web Target** | Clicks an element in a Safari or Chrome tab, found by CSS selector, XPath or page coordinates. It works by running JavaScript inside the tab, so the tab can be in the background while you use other apps. |
| **Macro Recorder** | Records mouse clicks (with positions) and key presses (with timing), then replays them with the original timing. Replays can repeat, loop, or run at 0.25×–4× speed. Save and open macros as `.macromaker` files. |

Every feature has a **global keyboard shortcut**: a key combo that works while any app is in front. Everything can also be started from the **menu bar icon**.

---

## Build

### Option A: no Xcode needed (Command Line Tools only)

```bash
xcode-select --install          # once, if `swift --version` doesn't work
./scripts/build-app.sh
open "build/Macro Maker.app"
```

This produces `build/Macro Maker.app`, a universal binary (Apple Silicon + Intel), plus `build/MacroMaker.zip` for sharing. The first build takes about 2 minutes.

### Option B: Xcode

```bash
brew install xcodegen           # once
xcodegen generate               # (re)creates MacroMaker.xcodeproj from project.yml
xcodebuild -scheme MacroMaker -configuration Release -derivedDataPath build/xcode build
open "build/xcode/Build/Products/Release/MacroMaker.app"
```

You can also just `open MacroMaker.xcodeproj` and press ⌘R. `project.yml` is the source of truth for the project: after adding or removing files, run `xcodegen generate` again.

### Tests

```bash
./scripts/test.sh               # or ⌘U in Xcode
```

The tests cover:

- the key parser
- the `.macromaker` file format (a pinned version-1 sample must keep opening)
- recording clean-up
- click timing
- the JavaScript that gets injected, run against a fake page in JavaScriptCore (the JavaScript engine built into macOS)
- the AppleScript bridge

---

## First launch: permissions

macOS blocks apps from controlling your computer until you allow them. Macro Maker shows a banner and has buttons that open the right Settings page for each permission.

| Permission | Needed for | Where |
|---|---|---|
| **Accessibility** | Clicking and pressing keys (all tabs except Web Target) | System Settings ▸ Privacy & Security ▸ Accessibility |
| **Input Monitoring** | Recording macros | System Settings ▸ Privacy & Security ▸ Input Monitoring |
| **Automation** | Web Target (macOS asks the first time it controls a browser) | System Settings ▸ Privacy & Security ▸ Automation |

**Web Target also needs a one-time browser setting:**

- **Safari:** Settings ▸ Advanced ▸ tick *Show features for web developers* (older Safari: *Show Develop menu in menu bar*). Then Develop ▸ Developer Settings… ▸ *Allow JavaScript from Apple Events* (older Safari: the item is directly in the Develop menu).
- **Chrome:** View ▸ Developer ▸ *Allow JavaScript from Apple Events*.

> **Rebuilt the app and a permission stopped working even though its switch is on?**
> macOS ties each permission to one exact build of the app. Unsigned builds count as a new app after every rebuild.
> Fix: select Macro Maker in that list, remove it with **−**, then add it again (or relaunch and allow again).
> Signing with a real certificate (see Distribution) makes permissions survive rebuilds.

---

## Using it

- **Start buttons count down 3 seconds** before starting, so you can move the cursor or switch to the target app. **Shortcuts start instantly.**
- Default shortcuts (change them in Settings or on each tab):

  | Action | Shortcut |
  |---|---|
  | Auto Clicker start/stop | ⌃⌥C |
  | Key Presser start/stop | ⌃⌥K |
  | Web Target start/stop | ⌃⌥W |
  | Record start/stop | ⌃⌥R |
  | Playback start/stop | ⌃⌥P |
  | **Stop everything** | ⌃⌥S |

- **Fixed point:** click *Pick with Cursor…* and hover over the target for 3 seconds. Coordinates are screen points measured from the top-left corner of the main display.
- **Finding a CSS selector:** in the browser, right-click the element ▸ Inspect. Then right-click the highlighted code ▸ Copy ▸ *Copy selector* (Chrome) or *Selector Path* (Safari).
- **Recording:** clicks and typing inside Macro Maker's own windows are not recorded. The shortcut you use to start and stop recording is trimmed out automatically.
- **Dock icon:** hidden by default; Macro Maker lives in the menu bar. Turn the Dock icon on in Settings.
- Your last recording is kept automatically in `~/Library/Application Support/Macro Maker/`.

### `.macromaker` file format (version 1)

```json
{ "format": "macromaker", "version": 1, "name": "Login", "createdAt": "2026-09-16T10:00:00Z",
  "events": [
    { "t": 0,    "type": "mouseDown", "button": "left", "x": 512, "y": 384, "clickCount": 1, "flags": 256 },
    { "t": 0.08, "type": "mouseUp",   "button": "left", "x": 512, "y": 384, "clickCount": 1, "flags": 256 },
    { "t": 1.5,  "type": "keyDown",   "keyCode": 0, "repeat": false, "flags": 256 },
    { "t": 1.6,  "type": "keyUp",     "keyCode": 0, "flags": 256 } ] }
```

The fields:

- `t`: seconds from the first event
- `x`, `y`: screen points from the top-left of the main display
- `keyCode`: macOS virtual key code (the number macOS assigns to each physical key)
- `flags`: which modifier keys were held (raw `CGEventFlags` value)

---

## Distribution

| Goal | What to do |
|---|---|
| Run on **your own Mac** | `./scripts/build-app.sh`, then drag `build/Macro Maker.app` to `/Applications`. |
| Give to **a friend, unsigned** | Send `build/MacroMaker.zip`. macOS will block it at first ("can't be opened"). They go to System Settings ▸ Privacy & Security ▸ **Open Anyway**, or run `xattr -dr com.apple.quarantine "/Applications/Macro Maker.app"`. |
| Distribute **properly** (no warnings) | Needs an [Apple Developer Program](https://developer.apple.com/programs/) membership ($99/year) and a *Developer ID Application* certificate. Then sign and notarize (upload to Apple's automated malware scan) with the commands below. |

```bash
# once: save notarization credentials (use an app-specific password from appleid.apple.com)
xcrun notarytool store-credentials macro-maker --apple-id YOU@EXAMPLE.COM --team-id TEAMID

SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
xcrun notarytool submit build/MacroMaker.zip --keychain-profile macro-maker --wait
xcrun stapler staple "build/Macro Maker.app"
ditto -c -k --keepParent "build/Macro Maker.app" build/MacroMaker.zip   # re-zip the stapled app
```

For an Xcode build, set `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in `project.yml` instead.

---

## Project structure

```
Sources/MacroMaker/
  App/         Entry point, app delegate, shared AppModel, window management
  Models/      Settings, Macro + file format, key/modifier/hotkey types
  Services/    Event posting, hotkeys, permissions, the four features, AppleScript bridge, file I/O
  Views/       SwiftUI tabs, menu bar panel, settings, reusable components
  Utilities/   Key parsing, keyboard layout lookup, timing, worker thread, recording clean-up, JS builder
Tests/MacroMakerTests/   Unit tests (Swift Testing)
Support/       Info.plist, entitlements, app icon
scripts/       build-app.sh, test.sh, make-icon.swift
project.yml    XcodeGen spec  →  MacroMaker.xcodeproj
Package.swift  SwiftPM manifest (build without Xcode)
```

How the main pieces work:

- **Clicks and key presses** use `CGEvent` (the macOS API for creating mouse and keyboard events). They run on a dedicated high-priority thread with drift-free timing, and pressing Stop wakes that thread immediately. Every stop path (Stop, limits, Stop Everything, quitting the app) releases any key or button that is still held down.
- **Key presser** looks up characters in your *current* keyboard layout, so `!` or `@` presses the right key on US, AZERTY, Dvorak and other layouts. Characters that aren't on your layout are typed as text instead.
- **Global shortcuts** use Carbon `RegisterEventHotKey`. It needs no permission and works while any app is in front.
- **Web Target** compiles one AppleScript per browser once. Each click calls a handler with the selector and JavaScript passed as parameters, so no escaping is needed. The script runs on the main thread because `NSAppleScript` isn't thread-safe. The injected JavaScript fires `pointerdown → mousedown → pointerup → mouseup → click` on the element.
- **Recorder** uses a listen-only event tap: it watches input without being able to block it.

## Limitations

- **Web Target** clicks are synthetic JavaScript events (`isTrusted = false`), and a few sites ignore those. It clicks in the top-level page only, not inside iframes. Only Safari and Google Chrome are supported.
- **Recorder** captures clicks and key presses, not cursor movement or scrolling. A drag is replayed as press at the start point, then release at the end point.
- Replayed clicks land at the same screen positions as when recorded, so a different display arrangement or window position changes where they land.
- Rebuilding an unsigned app resets its permissions (see *First launch*).

## License

[MIT](LICENSE) © 2026 Kheshav
