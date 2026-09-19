# bg-poster — BackgroundPoster.swift adversarial review

**Scope:** `Sources/MacroMaker/Services/BackgroundPoster.swift` (line by line) + `Tests/MacroMakerTests/BackgroundPosterTests.swift` for context. Callers in `AutoClicker.swift` and the spec `docs/V2_SPEC.md:35-48` read for grounding only.

**Verified against local SDK headers** (`MacOSX.sdk .../CoreGraphics.framework/Headers/CGEventTypes.h`, `IOKit.framework .../IOLLEvent.h`):
- `kCGMouseEventWindowUnderMousePointer = 91`, `...ThatCanHandleThisEvent = 92` — real public constants. Field numbers are correct.
- `NX_COMMANDMASK = 0x00100000` — the ⌘ bit value is correct.
- `NX_NONCOALSESCEDMASK = 0x00000100` — `.maskNonCoalesced` value is correct and sits outside the device-independent modifier range, so it cannot collide with modifier semantics.
- Public mouse subtypes: `kCGEventMouseSubtypeDefault = 0`, `TabletPoint = 1`, `TabletProximity = 2` — **3 is not a public value** (see F9).

Web searches for the background-click recipe returned nothing usable; everything below is grounded in the code, the SDK headers, and the repo's own spec.

---

## Root-cause hunt for "clicks never arrive in the target app"

Ranked candidates, all inside this file. None is provable without runtime evidence, so each is marked honestly.

**Candidate #1 — the event never names a window at the AppKit level (windowNumber: 0). CRITICAL, possible.**
`BackgroundPoster.swift:237`:
```swift
let event = NSEvent.mouseEvent(with: nsType, location: appKitPoint, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: 0, context: nil, eventNumber: 0,
                               clickCount: clickCount, pressure: button == .left ? 1 : 0)?.cgEvent
```
The hardcoded `windowNumber: 0` means the synthesized NSEvent resolves to **no window** (`NSEvent.window == nil`). When `CGEventPostToPid` delivers the event to the target process, AppKit's `-[NSApplication sendEvent:]` routes mouse events by the event's window; an event whose window number is 0/unknown to that process is the classic silently-dropped case. Fields 91/92 are *window-server bookkeeping* fields (their public names describe what the server *stamps* onto real events — "window under mouse pointer"), and nothing in the public headers says AppKit uses them to re-route a posted event to an NSWindow. If AppKit dispatch requires a resolvable window number, every background click is dropped exactly as the owner describes, regardless of the 91/92/subtype/⌘ machinery. The spec (`V2_SPEC.md:39`) only demands 91/92 — it never says to pass a window number — so the code faithfully implements a recipe that may be missing its most important ingredient. Direction: resolve the real `windowNumber` and seed it here.

**Candidate #2 — `setSource` may clobber the delivery payload written before it. CRITICAL, possible.**
`BackgroundPoster.swift:269-284`:
```swift
event.flags = clickFlags(appIsActive: appIsActive).union(.maskNonCoalesced)
...
let fresh = CGEventSource(stateID: .hidSystemState)
fresh?.localEventsSuppressionInterval = 0
event.setSource(fresh)
...
event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.eventTag)
eventPoster(event, pid)
```
The codebase's own comment (line 279-282) records a **measured** fact: `setSource` resets `.eventSourceUserData` to the new source's value — i.e. `setSource` copies source-owned fields *into* the event and erases pre-set ones. The fake-⌘ flags (line 269), fields 91/92 (lines 244-245), and the private window-location (line 246) are **all written before `setSource`** and never re-verified after it. If `setSource` refreshes anything else source-derived — or resets flags the way it resets userData — the event goes out with no ⌘ trick and/or no window targeting, and background clicks drop. Critically, **no test asserts flags/91/92/windowLocation integrity after the full `post()` path**: `mouseEventCarriesTheRecipeFields` (tests line 62-79) checks fields before `post()`; `postedClicksCarryNoSharedSourceState` checks only `eventSourceStateID`; `backgroundPostedClicksStillCarryTheSelfTag` checks only userData. The one field they proved `setSource` wipes is the one field they re-write after it; everything the delivery depends on is on the *unprotected* side of that ordering. Direction: re-assert 91/92, flags, and window location after `setSource`.

**Candidate #3 — global location vs window-local point: two competing targeting signals that disagree in every flagship scenario. HIGH, likely.**
`BackgroundPoster.swift:232-247` + `AutoClicker.swift:396-404`:
```swift
let appKitPoint = CGPoint(x: screenPoint.x, y: appKitY(...))     // captured screen point
...
windowLocationResolver.setWindowLocation(of: event, to: windowPoint(fromScreenPoint: screenPoint, window: window))
```
`event.location` (the global field) is always the **originally captured screen point** (`plan.directScreenPoint`), while fields 91/92 + the window-local point name the target window using its **live** bounds. They agree only while the window hasn't moved since capture. They disagree when:
- the window **moved** (global point now over another app's window or empty space);
- the window is **occluded** — which the `.optionAll` fallback (`BackgroundPoster.swift:60-62`) explicitly supports, and whose doc comment (line 53) advertises ("an occluded app is no excuse to drop its clicks"): the global point sits over the *occluder*, so a window server that hit-tests the global location stamps field 92 ("window that can handle this event") with the occluder, or drops the event as unhandleable;
- the window is on **another Space** ("or on another Space" is promised in the file header, line 6).
The feature's advertised headline cases are precisely the cases where the two location representations in the same event contradict each other. Direction: recompute the global point from the live window origin.

**Candidate #4 — subtype 3 is not a public subtype; may be rejected outright on this OS. MEDIUM, possible.** See F9.

**Candidate #5 — AppKit calls on the worker thread; nil results swallowed silently. MEDIUM, possible.** See F8/F5.

Outside my file but relevant to the symptom (flagged for the coordinator): accessibility/sandbox constraints on `CGEventPostToPid` belong to the tcc-build reviewer; `CGWindowListCopyWindowInfo` permission behavior likewise.

---

## Findings

### F1 — `windowNumber: 0`: the posted event never names a window to AppKit
- **Severity: CRITICAL** (root-cause candidate #1) · **Confidence: possible** (AppKit internals not verifiable from code)
- Evidence: `BackgroundPoster.swift:237` (quoted above under Candidate #1).
- Why: a mouse event delivered into the target process whose window number resolves to nothing is the classic case for `sendEvent:` to drop it silently. Nothing else in the file ever sets the NSEvent-level window number, nor `kCGEventTargetProcessSerialNumber` (field 39). The code bets everything on the private 91/92 fields doing AppKit's routing, which the public headers do not support.
- Direction: seed the real window number (and/or field 39) and re-test delivery.

### F2 — `setSource` runs after every delivery-critical write; only userData is re-written after it
- **Severity: CRITICAL** (root-cause candidate #2) · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:269-284` (quoted under Candidate #2); the code's own measured note at lines 279-282 (`"Measured: the tag read back as 0 when written first"`).
- Why: the codebase has direct evidence that `setSource` resets at least one pre-existing field. Flags (the ⌘ trick), fields 91/92, and the private window-location are all on the "before" side. The test suite deliberately covers stateID and userData after `setSource` — never the fields the feature actually depends on. This is exactly the shape of bug the project's own harness-engineering rule ("a claim about a source is resolved by a gate") exists to catch, and the gate is missing.
- Direction: assert flags/91/92/window-location after `setSource` in a test; move the writes after if they don't survive.

### F3 — Global location and window-local point contradict each other whenever the window moves, is occluded, or is on another Space
- **Severity: HIGH** · **Confidence: likely**
- Evidence: `BackgroundPoster.swift:232-233, 246` (quoted under Candidate #3); `AutoClicker.swift:398` (`plan.directScreenPoint` is the frozen captured point); the file header's promises at `BackgroundPoster.swift:6` and the occlusion fallback at lines 60-62.
- Why: two targeting signals in one event, only one of which tracks the live window. Whichever the window server trusts, the other is wrong in the feature's advertised scenarios; if the server hit-tests the global location, occlusion/other-Space/moved-window clicks get stamped with the wrong "can handle" window (field 92) or dropped.
- Direction: derive the global point from live window origin + local point so both agree.

### F4 — The fake ⌘ is visible to the target app: every working background click is a cmd-click
- **Severity: HIGH** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:166, 168-170, 269`:
```swift
static let backgroundClickFlag = CGEventFlags(rawValue: 0x0010_0000)
static func clickFlags(appIsActive: Bool) -> CGEventFlags {
    appIsActive ? [] : backgroundClickFlag
}
...
event.flags = clickFlags(appIsActive: appIsActive).union(.maskNonCoalesced)
```
- Why: the event the app receives carries `modifierFlags` containing `.command`. Apps read `NSApp.currentEvent.modifierFlags` at mouseDown: Finder/browser list views **toggle selection**, links **open in new tabs**, canvas apps deselect, games interpret ⌘-click as a different action. So even where delivery works, it delivers the *wrong gesture*, silently. Additionally, apps that track "currently held modifiers" from mouse-event flags (games, custom input loops) will believe ⌘ is stuck held until a real modifier transition arrives. The trick is correctly applied to **both down and up** (post() runs for both, `BackgroundPoster.swift:253-259`) — the task's specific question — but "applied consistently" ≠ "semantically invisible".
- Direction: none within the trick itself; needs documentation or an after-click compensating event.

### F5 — A nil `NSEvent.mouseEvent` result is silently swallowed and the click is still counted as delivered
- **Severity: HIGH** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:234-239` (`guard let ... else { return nil }`), `BackgroundPoster.swift:265-266` (`guard let event else { return }`), `BackgroundPoster.swift:251` (`click(...) -> Void`), and the caller `AutoClicker.swift:401-405`:
```swift
BackgroundPoster.click(plan.button, screenPoint: screenPoint, ...,
                       window: window, pid: pid, appIsActive: isActive)
return true
```
- Why: `directClickOnce` returns true whenever a *window* resolved — the comment "Undelivered clicks aren't counted" (`AutoClicker.swift:392`) is false at the event level. If `NSEvent.mouseEvent` returns nil (it is documented to be able to) or `post` bails, nothing is posted, no warning, no log, and the counter ticks up. Total failure is indistinguishable from success in the UI — which matches the owner's experience of a feature that "does not work" with no signal why.
- Direction: make `click`/`mouseEvent` failure observable and let it count as undelivered.

### F6 — The window is chosen as "front-most layer-0 window of the pid", never the window containing the picked point
- **Severity: HIGH** · **Confidence: likely**
- Evidence: `BackgroundPoster.swift:54-56`:
```swift
static func primaryWindow(ofPID pid: pid_t, in list: [[String: Any]]) -> Window? {
    list.lazy.compactMap { window(fromInfo: $0, ownerPID: pid) }.first
}
```
- Why: for any multi-window app (Finder, browsers, IDEs), the user picks a point inside one specific window, but the code translates the point against the front-most window of that *process*. If the picked window isn't that one, the window-local point is computed against the wrong bounds and lands outside the window or in the wrong window. No containment check exists anywhere (`windowPoint` even blesses negative local points — test at `BackgroundPosterTests.swift:52-54`). An out-of-bounds local point is a strong candidate for the server/AppKit rejecting the event — i.e., "clicks never arrive" for every multi-window target.
- Direction: pick the window whose bounds contain the captured point.

### F7 — `windowPoint` feeds `CGEventSetWindowLocation` top-down Y; the private API's expected Y direction has never been verified
- **Severity: HIGH** · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:160-162, 246`:
```swift
static func windowPoint(fromScreenPoint point: CGPoint, window: Window) -> CGPoint {
    CGPoint(x: point.x - window.bounds.origin.x, y: point.y - window.bounds.origin.y)
}
...
windowLocationResolver.setWindowLocation(of: event, to: windowPoint(...))
```
- Why: `kCGWindowBounds` is top-left-origin (CG global), so this produces **y-down** window-local coordinates. AppKit window coordinates are **y-up from the window's bottom edge**; if `CGEventSetWindowLocation` expects an AppKit-space point, every click lands vertically mirrored inside the window (a click near the title bar lands near the bottom edge) — wrong target or dead space. The only "verification" is a fake resolver in tests (`BackgroundPosterTests.swift:81-107`) that records the point without knowing the expected space. The symbol exists (verified via dlsym) but its contract is untested.
- Direction: one ground-truth runtime check (known point → observed hit location) pins the direction.

### F8 — `NSEvent.mouseEvent` and `NSScreen.screens` are called on the worker thread, off the main actor
- **Severity: MEDIUM** · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:232-238` runs inside `clickLoop` (`AutoClicker.swift:264`, `nonisolated`), on a `WorkerThread`; `NSScreen.screens` is not documented as thread-safe for background callers.
- Why: if AppKit returns an empty screen list or nil event off-main, the code degenerates: empty screens → `appKitY = 0 - y` (line 226-228's `?? 0` fallback) → the NSEvent location is *negative* AppKit Y → the posted event's global location is mirrored above the primary screen → guaranteed no window under it → dropped. And per F5, all silently. No test exercises the mouse-build path on a non-main thread.
- Direction: pre-read `NSScreen.screens` on main per tick, or verify the worker-thread behavior.

### F9 — Subtype 3 is not a public mouse subtype; the event may be treated as malformed
- **Severity: MEDIUM** · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:243`: `event.setIntegerValueField(.mouseEventSubtype, value: 3)`; public constants in `CGEventTypes.h`: `Default = 0, TabletPoint = 1, TabletProximity = 2`.
- Why: 3 comes from the spec's "research summary" (`V2_SPEC.md:39`) with no in-repo evidence. A subtype the OS doesn't recognize is a plausible reason for the window server to reject the event at post time on macOS 26 — and the recipe may simply be stale for this OS. Cannot be verified from code; needs a runtime A/B (subtype 0 vs 3).
- Direction: runtime A/B the subtype value against a real target.

### F10 — Keyboard path: no background-flag analog, no `flagsChanged` for modifier keys, no intrinsic flags
- **Severity: MEDIUM** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:291-315`:
```swift
guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
postKey(event, flags: flags, pid: pid)
...
private static func postKey(_ event: CGEvent, flags: CGEventFlags, pid: pid_t) {
    event.flags = flags.union(.maskNonCoalesced)
```
- Why: (a) modifier keys are posted as `keyDown` events — `EventSynthesizer.postKey` converts them to `.flagsChanged` and unions their intrinsic flags (`EventSynthesizer.swift:75,77`); this path does neither, so a modifier keystroke sent to a background app posts an event AppKit doesn't expect and carries flags missing the modifier's own bit — corrupted modifier state in the target. (b) the file's own doc (lines 289-290) admits keys need the app brought forward ("no windows involved — keys go to whatever has focus *inside* the app") — i.e. the "send to app" key feature is unreliable by the file's own documentation, with no UI honesty note like the mouse path's.
- Direction: reuse `EventSynthesizer`'s modifier handling.

### F11 — `appIsActive` is a point-in-time snapshot applied to both transitions of a click
- **Severity: MEDIUM** · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:251-260` — one `appIsActive` value captured before the down and reused for the up after a `Thread.sleep` (up to `pressDuration`); the snapshot updates on NSWorkspace notifications + a 500 ms timer (`TargetSnapshot.swift:33-43`).
- Why: if the user activates the target app mid-click (down carried fake ⌘, up doesn't) or deactivates it mid-click, the down/up pair carries *different* flags — apps that pair transitions can mis-handle it, and the "⌘ trick" correctness flips mid-click. Notification latency is small but nonzero.
- Direction: re-read active state between down and up.

### F12 — 300 ms window cache: a moved or closed window gets clicks translated against stale bounds
- **Severity: MEDIUM** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:73, 88-95` — the TTL cache returns the previous `Window` (id + bounds) for up to 300 ms; window ids are also recycled, so a window closed within the TTL gets a click addressed to a possibly dead/reused id.
- Why: a window dragged (or animated closed) mid-run receives clicks whose local point is up to 300 ms stale — wrong spot inside the window, or an event naming a dead window (silently dropped per F5). Deliberate tradeoff (the comment explains the re-query storm), but the staleness cost is unbilled anywhere.
- Direction: re-resolve on bounds-change signals or shorten TTL for moved windows.

### F13 — The file's own protected-fields contract is violated, and the constant is dead code
- **Severity: LOW** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:32, 242`:
```swift
static let protectedFields: [UInt32] = [0, 1, 2, 41, 43, 44, 50, 51, 55, 59, 102, 108]
...
event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))  // field 1 — in the protected list
```
- Why: field 1 (`kCGMouseEventClickState`) is in the "must not overwrite" list (per the spec, `V2_SPEC.md:39`, which only authorizes 3, 7, 91, 92), and line 242 overwrites it. Today it's harmless (NSEvent already wrote the same clickCount), but the code contradicts its own documented contract, and `protectedFields` is referenced nowhere (grep: only its declaration) — a rule that exists as data but enforces nothing.
- Direction: delete the constant or assert the writes in a test.

### F14 — The private symbol's C signature is assumed, then `unsafeBitCast`-ed with no validation
- **Severity: LOW** · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:135-140`:
```swift
private typealias CFunction = @convention(c) (CGEvent, CGPoint) -> Void
...
return unsafeBitCast(symbol, to: CFunction.self)
```
- Why: the symbol's *existence* is verified (dlsym), but its *signature* is pure assumption from the research summary. If `CGEventSetWindowLocation` actually takes (event, window-local point in a different space) or a different parameter order, every call mis-targets or corrupts the event with no error — the `-> Void` return discards any failure signal. RTLD_DEFAULT `-2` is correct for darwin; the signature is the unverified half.
- Direction: runtime-verify via `CGEventGetWindowLocation` (present per symcheck) round-tripping the point.

### F15 — Left mouse-up events carry pressure 1 (button pressed) while the button is released
- **Severity: LOW** · **Confidence: possible**
- Evidence: `BackgroundPoster.swift:238` — `pressure: button == .left ? 1 : 0` is the same for the down and the up transition.
- Why: real hardware mouse-up events report pressure 0. An up event claiming pressure 1 is internally inconsistent (field 2, "protected") and is the kind of anomaly a strict event consumer or tablet-adjacent code path could reject.
- Direction: pressure 1 on down, 0 on up.

### F16 — `textEvent` ignores the CGEvent Unicode-string cap
- **Severity: LOW** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:299-304` — `event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)` with arbitrary-length input.
- Why: `CGEventKeyboardSetUnicodeString` caps the stored string (~20 UTF-16 units); longer text is silently truncated, so a background-typed string longer than the cap delivers only its head, with no error.
- Direction: chunk long text at the cap.

### F17 — A fresh `CGEventSource` per event: down and up ride different source IDs, at real allocation cost
- **Severity: LOW** · **Confidence: certain**
- Evidence: `BackgroundPoster.swift:276-278` (fresh source per `post()`, i.e. per transition) vs `EventSynthesizer.swift:20-30`, which deliberately reuses one source per run ("making one per posted event costs a round-trip at click rates").
- Why: at a 1 ms interval the mouse path allocates ~2000 sources/second, against the project's own measured perf practice; and each down/up pair arrives from distinct source IDs, which consumers that pair events by source may mis-handle. The wedge rationale in the comment is plausible but the fix overshoots — one fresh source per *run* would satisfy both.
- Direction: one private source per run, like the HID path.

---

## What checked out (verified, not wrong — recorded so the coordinator can rule these out)

- Fields 91/92 are the correct public constants with the right value kind (a `CGWindowID` from `kCGWindowNumber` is what those fields hold on real events).
- The ⌘ bit value `0x00100000` is exactly `NX_COMMANDMASK`, and the flag is applied consistently to both down and up (`post()` runs for both).
- `.maskNonCoalesced` (0x100) does not collide with modifier-flag semantics (outside the device-independent mask range).
- The tag-after-`setSource` ordering (line 283) is correct by the project's own measurement, and the double-optional cache in `WindowResolver` (lines 88-95) handles negative results correctly.
- The primary-screen Y flip (lines 226-233) is self-consistent for the primary display and the tests pin its union-vs-primary behavior (tests lines 145-159) — assuming the "measured on a 1920x1080 primary" NSEvent flip holds on all configs, which is untested beyond that one configuration.

## Test-suite gaps (in-scope context)

- No test exercises the **real** `SystemWindowLocationResolver` or the real `CGEventSetWindowLocation` contract (F7/F14); only fakes.
- No test asserts **flags, fields 91/92, or window-location integrity after `setSource`/`post()`** — the entire delivery payload on the far side of the one call the project has measured to be destructive (F2).
- No test runs the mouse-build path on a non-main thread (F8), and no test covers `keyEvent` modifier semantics (F10).

**Bottom line:** the single most likely explanation for "clicks never arrive" inside this file is F1 (the event never names a window at the AppKit level — `windowNumber: 0`), closely followed by F2 (`setSource` potentially stripping the ⌘-flag/91/92/window-location payload written before it, exactly as it provably strips userData) and F3 (the global location contradicting the window fields in every occluded/moved/other-Space scenario — the feature's own advertised cases). F6 (wrong window picked for multi-window apps) produces the same symptom for that class of targets. All four are testable with one runtime experiment each against a real target app.

Sources: no usable web sources were returned by search; constant values verified against local SDK headers `.../CoreGraphics.framework/Headers/CGEventTypes.h` and `.../IOKit.framework/Headers/hidsystem/IOLLEvent.h` as quoted above.