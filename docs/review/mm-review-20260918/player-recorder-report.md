# Adversarial review — player-recorder scope

**Scope:** `Services/MacroPlayer.swift`, `Services/MacroRecorder.swift`, `Services/EventSynthesizer.swift`, `Services/RealInputMonitor.swift`, `Utilities/RecordingCleaner.swift`
**Reviewer:** player-recorder · READ-ONLY · 2026-09-18

---

## 0. Top-priority symptom: "Click in a specific app" (`.directApp`) never delivers

**Verdict from this scope: none of my five files are on the `.directApp` code path.** The path is
`AutoClicker.directClickOnce` → `BackgroundPoster.click` → `BackgroundPoster.post` → `eventPoster` (`CGEventPostToPid`, `BackgroundPoster.swift:263`). `EventSynthesizer` (the only event factory in my scope) is *not* used by it — direct-app events are built by `BackgroundPoster.mouseEvent` from `NSEvent.mouseEvent`. So the root cause lives in the bg-poster agent's files, not mine. Two scope-derived leads for whoever owns `BackgroundPoster.swift`:

1. **`setSource` demonstrably clears per-event fields — and the window-target fields are written *before* it.**
   `BackgroundPoster.swift:283`'s own comment is the evidence: *"Measured: the tag read back as 0 when written first"* — i.e. `event.setSource(fresh)` (`BackgroundPoster.swift:278`) **resets `kCGEventSourceUserData`**. But the fields that make the click arrive at the window — subtype 3, fields 91/92, and the `CGEventSetWindowLocation` point — are all set *earlier*, inside `mouseEvent(...)` (`BackgroundPoster.swift:243-246`), and only the tag is re-written after `setSource`. If `setSource` resets *any* per-event data (which the tag measurement proves it does for at least one field), the window targeting written at lines 243–246 may be wiped at line 278 — leaving a ⌘-flagged click with no window binding, which AppKit drops for a background app. This exactly matches "symbol present, clicks never arrive." Confidence: **possible** (one measured data point, the 91/92 wipe is unmeasured). Direction: re-write fields 91/92/subtype/windowLocation *after* `setSource`, mirroring the tag fix.

2. **`backgroundClickFlag` (0x00100000) is literally `kCGEventFlagMaskCommand`** (`BackgroundPoster.swift:166`). Every background click is delivered as a ⌘-click. Even once delivery works, apps that special-case ⌘-click (tabs, multi-select, dock icons) get the wrong click. That's a correctness landmine, though it does not explain "never arrive."

From my own hunt list, confirmed: **the MacroPlayer never uses `postToPid` — playback is global-posting only** (finding 2 below), so macro playback cannot click in the background either; the *only* background-delivery mechanism in the app is `BackgroundPoster`.

---

## Findings (ranked)

### 1. HIGH — Recorded timestamps are main-run-loop arrival times, not input times

`MacroRecorder.swift:36` and `MacroRecorder.swift:101`:
```swift
CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)   // :36
...
let time = Double(DispatchTime.now().uptimeNanoseconds - startUptime) / 1_000_000_000  // :101
```
The tap callback runs on the **main run loop**, and `time` is stamped when `handle(_:)` executes — not when the input happened. `liveEvents` is `@Observable` (`MacroRecorder.swift:10`) and the Recorder view re-renders its table per event (`Views/RecorderView.swift:138`), so during a recording the main thread is periodically busy repainting exactly when events arrive. Any main-thread stall inflates the recorded inter-event gaps: a fast typing burst under UI load records as a clump of near-identical timestamps. The accurate value — `CGEvent.timestamp`, stamped by the window server at tap time — is captured in `TapEvent` but never used. The `.tapDisabledByTimeout` re-enable branch at `MacroRecorder.swift:70-72` is evidence the tap already falls behind in practice. Severity: HIGH (timing *is* the product for a macro recorder; distortion is load-dependent and silent). Confidence: **certain** mechanics, **likely** user-visible impact. Direction: stamp from `event.timestamp` (uptime nanoseconds) instead of `DispatchTime.now()`.

### 2. MEDIUM — Macro playback is global-posting only; no background delivery, cursor hijack guaranteed

`MacroPlayer.swift:95` → `EventSynthesizer.swift:139`:
```swift
post(event, heldKeys: &heldKeys, heldButtons: &heldButtons, source: source)  // MacroPlayer
...
event.post(tap: .cghidEventTap)   // EventSynthesizer.post — the ONLY post call in the file
```
Every replayed mouse event goes to the HID tap: the **real cursor moves**, clicks land on whatever is frontmost, and keys type into the focused app. There is no `postToPid` branch for playback (verified: the only `postToPid` in the codebase is `BackgroundPoster.swift:263`). So the owner's stated goal — "work in other apps while it clicks in the background" — is structurally impossible for macros even if `.directApp` clicking is fixed: a playing macro fights the user for the mouse and focus. Not a regression, but a gap that will resurface immediately after the directApp fix. Confidence: **certain** (code). Direction: decide whether playback gets a `BackgroundPoster` delivery mode, and say so in the UI until it does.

### 3. MEDIUM — Shared `hidSystemState` source for a whole run contradicts BackgroundPoster's own measured wedge

`EventSynthesizer.swift:24-30` (used for an entire run at `MacroPlayer.swift:76`, `AutoClicker.swift:277`):
```swift
final class EventSource: @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)
    init() {
        source?.localEventsSuppressionInterval = 0
    }
```
versus `BackgroundPoster.swift:270-274`, which documents a **measured failure** from reusing one source at click rates:
> *"posting through that source at click rates wedges its cumulative modifier/button state — ⌘ then reads as physically held to the window server (fake-⌘-clicking every window you touch, defeating ⌘Tab's app switch) and no key-up ever clears it; only quitting the poster does."*

BackgroundPoster fixed it with a **fresh source per posted event**; `EventSynthesizer` deliberately reuses one source per run (MacroPlayer, AutoClicker, KeyPresser all do this) with a comment asserting only that the suppression interval behaves the same. If the wedge applies to reused `.hidSystemState` sources generally — not just the `NSEvent.cgEvent` shared source BackgroundPoster hit — then a long KeyPresser/AutoClicker/MacroPlayer run can leave the system believing a modifier is physically held, until the app quits. The two files carry opposite assumptions with no test settling which is true. Confidence: **possible**. Direction: measure whether a reused `hidSystemState` source wedges at click rates; if yes, per-post fresh sources in `EventSynthesizer` too.

### 4. MEDIUM — Pause/resume leaks the RealInputMonitor permanently (and asserts on the next run)

`RealInputMonitor.swift:37-45` + `AutoClicker.swift:128` and `AutoClicker.swift:215`:
```swift
assert(subscribers == 0, "RealInputMonitor is single-subscriber; ...")  // RealInputMonitor :38
subscribers += 1
guard monitors.isEmpty else { return true }
...
func stop() {
    subscribers = max(0, subscribers - 1)      // :67
    guard subscribers == 0 else { return }     // :68 — monitors removed only at zero
```
`startPauseWatching()` runs after **every** `begin` — including the resume after a pause (`AutoClicker.swift:213-217`) — but `tearDownPauseWatching()` runs only once per finished run. Count a run that pauses once: start (+1 → 1), resume's start (+1 → 2, early-return keeps monitors), finish's stop (−1 → 1, **monitors stay installed forever**). Every later run re-trips the debug `assert(subscribers == 0)` at `:38` — a debug-build crash on the second run after any paused run — and in release the global+local monitors stay installed for the life of the process, firing `onRealInput` on every keystroke system-wide (a no-op only because `pauseIfNeeded` guards on `.running`). The `:21-22` comment ("a stop imbalance still leaves the tap up") shows the hazard was known; the resume path is the imbalance. Confidence: **certain** on the counting, MEDIUM impact. Direction: make `start`/`stop` idempotent per subscriber (or stop re-arming on resume).

### 5. MEDIUM — RecordingCleaner drops trailing held *keys* but not trailing held *buttons*

`RecordingCleaner.swift:30`:
```swift
while let last = kept.last, case let .keyDown(code, _) = last.action, heldKeys.contains(code) {
    kept.removeLast()
}
```
The doc comment (`:6-8`) says the cleaner removes "the trailing run of keys still held when recording stopped" — and that's all it removes. A recording stopped while a mouse button is held (stop hotkey pressed with mouse down, or a down whose up arrived after `stop()` disabled the tap) keeps a **dangling `mouseDown`**. Each playback pass then ends with the player's `defer` releasing it (`MacroPlayer.swift:83`), producing a phantom down…(whole pass)…instant-up click on every loop iteration — the exact stuck-input artifact the cleaner exists to prevent, one input type over. Confidence: **certain** (code + `RecordingCleanerTests` covers only the key case). Direction: extend the trailing-run removal to `heldButtons`.

### 6. MEDIUM — Drags record as down/up and replay as one fabricated `dragged` event

`MacroRecorder.swift:23-24` (tap mask):
```swift
let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                            .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged]
```
No `mouseDragged`/`leftMouseDragged` in the mask, so a real drag records only its endpoints. `MacroPlayer.swift:123-126` then fabricates a single transition:
```swift
if let downPoint = heldButtons[button], downPoint != point {
    // The button moved while down: a drag. Tell apps before releasing.
    EventSynthesizer.postMouse(button.dragEventType, button: button, at: point, flags: flags, source: source)
}
```
A real drag is a stream of dragged events; apps that continuously track dragging (rubber-band selection, sliders, canvas pan) receive down → one dragged at the final point → up, which most will treat as a jump-click, not a drag. The feature silently misreplays an entire input class. Confidence: **certain** code, **likely** user-visible for drag-dependent apps. Direction: either record the dragged stream or document drags as unsupported.

### 7. LOW — A cancelled run still reports `finished: true`

`MacroPlayer.swift:94/106/108`:
```swift
guard worker.sleep(untilUptime: due) else { break playback }   // :94 — cancelled
...
guard worker.sleep(seconds: 0.01) else { break }               // :106 — cancelled
...
report(progress, true)                                          // :108 — reached after BOTH breaks
```
Every exit path — including cancellation — falls through to `report(progress, true)`, whose main-thread handler then calls `session.finish(token)` (`MacroPlayer.swift:60`). Today that's defused twice over (Stop bumps `generation` in `RunSession.stop()`; `finish` also requires `.running`), but it is the *exact* pattern AutoClicker had to patch after it bit (`AutoClicker.swift:171-180` documents the same cancelled-equals-finished reporting as a fixed structural bug). The player has the unguarded copy. Confidence: **certain** code, latent. Direction: only the natural-completion path should report `finished: true`.

### 8. LOW — `cancelAndWait`'s 1-second timeout result is discarded

`MacroPlayer.swift:64`:
```swift
return { worker.cancelAndWait() }
```
`WorkerThread.cancelAndWait(timeout:)` returns whether the worker actually finished (`WorkerThread.swift:41-44`); the result is `@discardableResult`-discarded. If the worker is wedged inside a CG post (window-server stall), the session reports idle and the UI re-enables Start while a zombie worker may still be posting events — and a new run's `runID` guard (`MacroPlayer.swift:58`) doesn't stop the *old* worker's posts from reaching apps. Confidence: **possible** (requires a stall to matter). Direction: surface a warning when the wait times out.

### 9. LOW — Keystrokes silently dropped whenever Macro Maker is the active app

`MacroRecorder.swift:91` and `:94`:
```swift
case .keyDown, .keyUp:
    // Typing into Macro Maker itself (e.g. the stop shortcut) is not part of the macro.
    guard !NSApp.isActive else { return }
case .flagsChanged:
    guard !NSApp.isActive, KeyCodes.modifierKey(for: event.keyCode) != nil else { return }
```
The filter is app-wide, not window-wide (mouse clicks get a precise `isOverOwnWindow` test at `:106-112`; keys get none). While any Macro Maker popover/panel is key — e.g. the user checks the live event table mid-recording — **every** keystroke, including ones intended for the macro, is dropped with no feedback. For a menu-bar app whose own UI is likely open during recording, this is a plausible "where did my keys go?" report. Confidence: **possible** edge. Direction: key-filter should be per-window like the mouse path, or at least the UI should indicate suppression is active.

### 10. LOW — `MacroLibrary.add` contradicts its own contract: re-saving duplicates instead of updating

(Adjacent scope, flagged for the MacroRecord-mismatch hunt.) `MacroLibrary.swift:63-77`:
```swift
/// Returns the record (same id is fine: a second save with the same id updates).
func add(_ macro: Macro, named proposedName: String) -> MacroRecord? {
    ...
    var record = MacroRecord(id: UUID(), name: name, createdAt: Date(), fileName: fileName)
```
The doc promises id-based update, but every call mints a fresh `UUID()`, a `-N`-suffixed unique file name, and `records.insert(record, at: 0)`. "Add Current" pressed twice yields two records and two files with identical content; per-macro hotkeys bound to the first id keep pointing at the stale copy after any edit-and-re-save. `MacroRecord` itself has no update path at all. Confidence: **certain** (code), LOW-MEDIUM impact.

### 11. LOW — Per-click `CGEvent` allocation just to read the cursor

`EventSynthesizer.swift:16-18`:
```swift
static var cursorLocation: CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}
```
`AutoClicker.clickOnce` (`AutoClicker.swift:377,385`) calls this twice per click when `restoreCursor` is on — a fresh `CGEvent` allocation per read at click rates. The right primitive is `CGEventSource(mouseType:stateID:).position`-style reads or `NSEvent.mouseLocation`. Confidence: **certain** code, LOW (perf only).

---

## Hunt-list answers (explicit)

- **Event tagging asymmetries (recorded vs posted):** none found. Every posting path in the app routes through `EventSynthesizer.post` (`EventSynthesizer.swift:134-140`, tag at `:138`) or `BackgroundPoster`'s tag-after-`setSource` (`BackgroundPoster.swift:283`); the recorder's `TapEvent.isOwnEvent` (`MacroRecorder.swift:134`) matches the same `eventTag`. The one asymmetry is informational: `setSource` clearing user data (BackgroundPoster's own measurement) implies custom per-event fields may not survive a late `setSource` — see §0 lead 1.
- **Self-event filtering holes (recorder recording its own playback):** no hole. Mutual exclusion is enforced at every entry point — `AppModel.toggleRecording` (guards `player.session.phase.isActive`), `AppModel.togglePlayback` and `playMacro(id:)` (both guard `recorder.isRecording`). The one legal concurrency (AutoClicker/KeyPresser running while recording) is safe *because* of the tag: synthetic events are filtered at `MacroRecorder.swift:74`.
- **Timestamp/delay math:** finding 1 (recorder stamps arrival time). The playback side is sound — `dueOffsetNanos` (`MacroPlayer.swift:157-161`) clamps NaN/negative/overflow (test-covered in `NonFiniteInputTests.swift:46-59`), `speed` is pre-clamped to 0.1–10 (`MacroPlayer.swift:48`), humanized times are monotonic by construction (`Humanizer.swift:145-153`), and `WorkerThread.sleep(untilUptime:)` handles past deadlines and the cancel race correctly (counted semaphore).
- **MacroRecord model mismatches:** finding 10. `eventCount`/`durationSeconds` (`MacroLibrary.swift:73-74`) are written consistently with `Macro.duration` (`Macro.swift:26`); `duration` trusts `events.last?.time`, which is wrong only for hand-unsorted files (the editor sorts before insert) — not worth a finding.
- **Playback in background apps:** finding 2 — the player is global-posting only; `postToPid` exists solely in `BackgroundPoster`.
- **Deadlock/blocking on the worker thread:** none. Workers never sync to main — progress hops via `performOnMain` (async, `WorkerThread.swift:61-65`), and window/app state comes from the lock-protected `TargetSnapshot` (whose whole purpose, per its header, was removing a main-queue sync). `cancelAndWait` blocks main ≤1 s against a worker that only ever sleeps or posts.
- **Unclean cancellation:** findings 7 and 8. Held keys/buttons *are* cleanly released on every exit (the per-pass `defer` at `MacroPlayer.swift:83` covers all breaks).

---

## Files in scope, checked and not flagged

- `RecordingCleaner.swift` — orphan-`up` dropping and time-rebasing verified correct against `RecordingCleanerTests.swift`; duplicate downs of one button dedup safely on replay via the `heldKeys`/`heldButtons` sets.
- `EventSynthesizer` keyboard paths — modifier-as-`flagsChanged` conversion, `intrinsicFlags` union, Caps-Lock exclusion (`MacroPlayer.swift:115`), and Unicode text events all round-trip consistently with what the recorder stores; the random per-launch, never-zero tag (`EventSynthesizer.swift:10-14`) correctly cannot collide with a real event's zero user data.

Nothing in this scope is the root cause of the `.directApp` symptom; §0 lead 1 (post-`setSource` field reset in `BackgroundPoster`) is the strongest pointer this review can hand to the bg-poster reviewer.