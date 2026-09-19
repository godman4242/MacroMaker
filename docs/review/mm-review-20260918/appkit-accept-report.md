# Adversarial review — appkit-accept scope (permissions, input monitor, event synthesizer, entitlements, Info.plist)

**Scope:** `Sources/MacroMaker/Services/PermissionService.swift`, `RealInputMonitor.swift`, `EventSynthesizer.swift`, `Support/MacroMaker.entitlements`, `Support/Info.plist`.
**Verdict on the scope question ("does the app even have the right permissions/config for background event delivery?"): YES — the permission and packaging config is sufficient for `CGEventPostToPid`.** Accessibility covers posting; Input Monitoring is only needed for the recorder's event tap; nothing in these files needs Screen Recording; the entitlements/Info.plist are internally consistent. So the directApp symptom is almost certainly NOT a missing-permission problem — but the scope files contain one lifecycle bug (monitor leak), one fail-open UX hole that actively misleads diagnosis of this exact symptom (`testClick` reports success without checking AX), and one unverified assumption (tag survival across window-server delivery) that could stall directApp runs. Details below, ranked.

---

## Findings (ranked)

### 1. HIGH — RealInputMonitor subscriber counting leaks: the monitor is installed forever after any pause/resume, and the debug assert crashes on the second resume
**Evidence:** `Sources/MacroMaker/Services/RealInputMonitor.swift:37-42,66-71`
```swift
func start(onRealInput: @escaping () -> Void) -> Bool {
    assert(subscribers == 0, ...)
    self.onRealInput = onRealInput
    subscribers += 1
    guard monitors.isEmpty else { return true }
```
```swift
func stop() {
    subscribers = max(0, subscribers - 1)
    guard subscribers == 0 else { return }
    monitors.forEach(NSEvent.removeMonitor)
```
And the callers in `AutoClicker.swift:227` (`start`, inside `startPauseWatching`, called from **every** `begin` — initial start line 128 *and* every `resume` line 215) vs `AutoClicker.swift:245` (`stop`, only from `tearDownPauseWatching`, called only on `endRun`/finish — never on pause).

**Why it's a problem:** every pause→resume cycle does `start` (+1) with no matching `stop`. Sequence: start(+1) → user types → pause → idle-resume → start(+1, subscribers=2) → endRun → stop(−1, subscribers=1) → `guard subscribers == 0` fails → **monitors never removed for the rest of the process lifetime**. Each subsequent run adds another +1. Two consequences: (a) in debug builds the `assert(subscribers == 0)` at line 38 traps on the *second* `start` of the same launch — i.e. the first pause→resume of a debug build crashes; (b) in release, a leaked global NSEvent monitor runs `pauseIfNeeded` on every keystroke and mouse-down system-wide, for a menu-bar app that lives for weeks. Additionally the assert is *before* the callback assignment, so debug dies before even replacing the callback.
**Confidence:** certain (arithmetic follows directly from the code; no test exercises pause/resume through `RealInputMonitor` — `grep` shows zero test references).
**Direction:** stop()/start() should be reference-counted by run, or `start` should be idempotent per subscriber identity; the assert firing in debug is the loudest clue that this path is untested.

### 2. HIGH — `testClick` posts without checking Accessibility and reports "Test click sent." unconditionally; nothing in the permission/delivery layer can ever say "the click did not arrive"
**Evidence:** `AutoClicker.swift:426-442` (`testClick` calls `BackgroundPoster.click` with no `permissions.ensureAccessibility()` — compare `toggle` at `AutoClicker.swift:115` which does gate), plus `EventSynthesizer.swift:139` / `BackgroundPoster.swift:263,284` — `event.post(tap:)` and `$0.postToPid($1)` both return `Void`; no layer verifies delivery.
**Why it's a problem:** `CGEventPostToPid` fails *silently* when the caller isn't trusted (or the target refuses) — no error, no return code. If AX is granted to a different signature than the running binary (rebuilds flip between ad-hoc `-` in `project.yml` `CODE_SIGN_IDENTITY` and `"Kheshav Dev"` in `scripts/build-app.sh:22-26`, and TCC anchors to the signature — exactly the failure mode `SettingsView.swift`'s footer warns about), the run-start path beeps and shows the banner, but the *diagnostic* path the user will reach for ("Test click") lies with "Test click sent." This actively misleads the owner's investigation of the current symptom: a permission-side root cause is indistinguishable from a delivery-side one using only this app's own UI.
**Confidence:** certain that the check is absent and the message is unconditional; likely that this has already wasted diagnosis time.
**Direction:** `testClick` should call `ensureAccessibility()` first, and the report line should be honest about "sent, not verified".

### 3. MEDIUM — The eventTag's survival across window-server delivery is asserted but never verified; if `postToPid` scrubs `.eventSourceUserData`, directApp runs self-pause on their own clicks and the recorder records its own playback
**Evidence:** `EventSynthesizer.swift:10-14` (tag), `RealInputMonitor.swift:83-86`:
```swift
nonisolated static func isReal(_ event: NSEvent) -> Bool {
    guard let cgEvent = event.cgEvent else { return true }
    return cgEvent.getIntegerValueField(.eventSourceUserData) != EventSynthesizer.eventTag
}
```
`BackgroundPoster.swift:279-284` documents the `setSource` ordering fix ("Measured: the tag read back as 0 when written first") — but the only tests (`BackgroundPosterTests.swift:160-199`, `backgroundPostedClicksStillCarryTheSelfTag`) read the field **off the CGEvent object before posting**, via the `eventPoster` seam. No test observes the event after it has actually crossed the window server.
**Why it's a problem:** `pauseIfNeeded` (`AutoClicker.swift:195-206`) stamps `lastRealInputAt` and pauses *before* any phase guard, and auto-resume requires `settings.autoResumeSeconds > 0` (`AutoClicker.swift:236`). If background-posted clicks come back through Macro Maker's own global monitor untagged (userData not propagated cross-process), then with `pauseOnRealInput` enabled the clicker pauses on its own first click — and with auto-resume off (or the default 5s creating a click-pause-click-pause cadence), the user experiences exactly "clicks never arrive / the feature doesn't work" while the counter still increments. The same untagged event is recorded by `MacroRecorder.swift:134` (`isOwnEvent`), so recorded macros would contain their own playback.
**Confidence:** possible (the field may well survive — CGEvent fields generally do propagate — but it is unverified for the `postToPid` hop, and this is the one in-scope mechanism that can make *only* directApp mode stall while other modes work, which matches the symptom's shape).
**Direction:** one live two-process measurement (post to another app, read the field back from a session tap or the target-side AX observer) settles it; until then the claim in the comments is faith, not fact.

### 4. MEDIUM — RealInputMonitor's global monitor can install successfully yet silently receive nothing; `lastFailure` cannot detect this (fail-open)
**Evidence:** `RealInputMonitor.swift:44-51` — `NSEvent.addGlobalMonitorForEvents` returns a non-nil monitor object even when the process isn't entitled to receive key events; the handler just never fires for them. The failure string (line 62) is only set when both `addGlobalMonitor…` and `addLocalMonitor…` return `nil`.
```swift
if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { ... }) {
    monitors.append(global)
    lastFailure = nil
    return true
}
```
The doc comment (lines 8-11) claims "no extra permission is needed" for a passive `.keyDown` mask — mouse events are indeed always visible, but keyboard delivery to global monitors on modern macOS requires the app be trusted (AX, or IM); `PermissionService.canMonitorInput` (`CGPreflightListenEventAccess`, `PermissionService.swift:20`) is never consulted here.
**Why it's a problem:** fail-open by design: `start()` reports success and `runWarning` stays nil while "pause when I press a key" quietly does nothing for keys. The user believes their input will pause the run; it won't. It also means the in-scope answer to "is AX sufficient?" has a wrinkle: AX is sufficient for *posting*, but the pause-on-real-input half of directApp UX silently degrades in any trust edge case, and nothing measures it.
**Confidence:** likely that the failure mode exists as described (silent no-delivery); possible that it's reachable in practice given AX is required before any run starts.
**Direction:** probe once at `start()` — post a tagged synthetic key, see if the monitor observed it — or preflight trust before claiming the feature works.

### 5. MEDIUM — When the global monitor installs, no local monitor exists, so the user's input into Macro Maker's own windows never pauses a run
**Evidence:** `RealInputMonitor.swift:44-61` — the local monitor is only a *fallback* used when the global monitor fails to install. NSEvent global monitors by definition see only events destined for *other* apps.
**Why it's a problem:** during a directApp background run (the user's stated workflow: work in other apps while it clicks), clicking or typing into Macro Maker's own panel — the natural place to interact mid-run — is invisible to pause-on-real-input. The local monitor that would cover exactly that case exists in the code but is unreachable on the success path.
**Confidence:** certain of the control flow; medium user impact.
**Direction:** install both monitors always (they're disjoint event streams), not global-else-local.

### 6. MEDIUM — Hold-to-click release ends the run through `session.stop()` without `tearDownPauseWatching` — a second, simpler subscriber-leak path
**Evidence:** `AutoClicker.swift:456-460` (`hotkeys?.onRelease = { … self.session.stop() }`) vs the only teardown callers at `AutoClicker.swift:134-141` (`endRun`) and the finish branch (`AutoClicker.swift:174-177`).
**Why it's a problem:** every hold-to-click run that ends by key-release adds +1 subscriber with no matching `stop()` even *without* any pause/resume. Combined with finding 1, `subscribers` is a ratchet that only ever grows on these paths. It also leaves `runWarning`/`clicksDone` unreset for the next run's UI until the next `toggle` overwrites them.
**Confidence:** certain (direct call-graph reading).
**Direction:** route hold-release through the same teardown as `endRun`.

### 7. LOW — `didPromptForAccessibility` holes: consumed by any caller, never reset on revoke
**Evidence:** `PermissionService.swift:54-60`:
```swift
func requestAccessibility() {
    let options = ["AXTrustedCheckOptionPrompt": !didPromptForAccessibility] as CFDictionary
    didPromptForAccessibility = true
    isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
}
```
**Why it's a problem:** (a) the first caller of the launch — including a background `ensureAccessibility` from a hotkey toggle — burns the one system prompt; macOS's own once-per-process prompt plus this flag duplicate each other, which is fine, but (b) if the user *revokes* AX mid-session (removed from the list), the flag stays true, so the system prompt never re-appears this launch even after re-adding — recoverable only because the banner also calls `open(.accessibility)` (`PermissionBanner.swift:23-26`). (c) Minor race: the flag is set before the call, so a failed/queued prompt is still marked as "shown" — harmless in practice.
**Confidence:** certain about the code behavior; the impact is low because the pane-opening buttons cover recovery.
**Direction:** reset the flag in `refresh()` when trust transitions true→false.

### 8. LOW — `eventTag` dead check and per-call default `EventSource` allocations contradict the stated design
**Evidence:** `EventSynthesizer.swift:10-14` — `Int64.random(in: 1...Int64.max)` can never be 0, so `tag == 0 ? 1 : tag` is dead code. `EventSynthesizer.swift:45,68-70,121-123` — default parameters `source: EventSource = EventSource()` allocate a fresh `CGEventSource` per posted event whenever the caller omits the argument, defeating the documented purpose of the pooled `EventSource` ("making one per posted event costs a round-trip at click rates", lines 20-23).
**Why it's a problem:** misleading code more than a bug: the pooling only happens for callers that remember to pass a source (the AutoClicker loop does; `postKey`/`postText`/`keyUp` defaults don't, so a MacroPlayer stroke can build one source per transition).
**Confidence:** certain.
**Direction:** require the source explicitly at the call sites that have one; delete the dead ternary.

---

## Explicit answers to the scope questions

- **Is AX sufficient for `CGEventPostToPid`?** Yes. Posting synthetic events (HID tap or to-pid) is gated on Accessibility only. Input Monitoring is **not** needed for posting — it is needed only by the recorder's listen-only `CGEvent.tapCreate` (`MacroRecorder.swift:33`), which already has its own request-and-error path (`MacroRecorder.swift:40-43`) and its own Settings row. No permission gap exists for directApp mode.
- **Screen Recording?** Not needed. `BackgroundPoster.window(fromInfo:)` (`BackgroundPoster.swift:40-49`) reads only `kCGWindowOwnerPID`, `kCGWindowLayer`, `kCGWindowNumber`, `kCGWindowBounds` — all delivered without Screen Recording. Only `kCGWindowName` and window *contents* are SR-gated, and the code never reads names (verified: no `kCGWindowName` reference anywhere in Sources). No SR usage description is therefore required.
- **Entitlements:** correct for this feature. Sandbox explicitly off (`MacroMaker.entitlements:5-7`) — mandatory for posting into other apps; `com.apple.security.automation.apple-events` present and matched by `NSAppleEventsUsageDescription` in `Info.plist:31-32`; hardened runtime via `--options runtime` (`build-app.sh:54`). Nothing else is required for CGEvent posting, and `dlsym` of a linked framework's symbol needs no library-validation exception. No keychain groups are used anywhere (verified: no `SecItem`/Keychain references), so none are missing.
- **Info.plist:** consistent. `LSUIElement` true matches the accessory default, and `AppModel.applyActivationPolicy` (`AppModel.swift:350`) is the single runtime switch for the Dock-icon toggle — no contradiction. No `NSAppleEvents` usage beyond the declared one; hotkeys use Carbon `RegisterEventHotKey` (needs no TCC permission). One latent nit: `swift run` from SwiftPM ships no Info.plist at all, so the entitlements/plist contract only holds for the assembled `.app` — dev-only, not a shipped defect.
- **Tag consistency (HID path):** `EventSynthesizer.post` (`EventSynthesizer.swift:134-140`) writes the tag after construction and never calls `setSource`, so unlike the `BackgroundPoster` path there is no reset hazard; the recorder and `RealInputRules.isReal` both compare against the same `EventSynthesizer.eventTag` constant (single source of truth — no twin-value drift). The open question is delivery survival (finding 3), not construction.
- **Double counting:** none by design — global monitors only see other apps' events, local only the app's own, and only one is ever installed. The mask watches downs only (no key/mouse-ups), so one user action fires at most once. The real defect in this area is the lifecycle leak (finding 1), not double counting.
- **didPromptForAccessibility (v2.0.8):** functionally achieves "prompt once per launch" (tested in `PermissionServiceTests`), with the revoke-reset and first-caller-consumption holes in finding 7.

## Verified non-findings (checked adversarially, found sound)

- `PermissionService` polling (1.5 s timer, weak self, `@ObservationIgnored` correctly applied) — no retain cycle, no main-thread hazard.
- `RealInputRules.idleEnough` clamps to ≥1 s — no zero/negative auto-resume loop.
- `BackgroundPoster` tag-after-`setSource` ordering and its regression tests are internally consistent.
- Bundle-id/min-OS drift between `Info.plist` and `project.yml` is guarded by `build-app.sh:32-35`.

## What this scope contributes to the directApp root-cause hunt

Permissions/config are **excluded** as the root cause by this review: AX alone authorizes `CGEventPostToPid`, and everything the directApp path touches (window bounds, pid lookup, posting) is covered by grants the app already requires. The two in-scope lanes that could still explain "clicks never arrive" are (3) tag loss across delivery stalling runs via self-pause — only if the user enabled `pauseOnRealInput`, which defaults off (`FeatureSettings.swift:47`), so confirm the user's setting before investing there — and (2) a signature-mismatched TCC grant making *all* posting silent, which the owner can rule out in one glance at System Settings ▸ Privacy & Security ▸ Accessibility (which build of the app is listed, and does the non-directApp mode actually work). Everything else points at the delivery recipe in `BackgroundPoster` (fields 91/92, subtype, the fake-⌘ NX_COMMAND bit, coordinate flip) — other agents' scope.

Nothing for you to do beyond routing: the two file-writing obligations of this task (report file + stdout) are completed below.