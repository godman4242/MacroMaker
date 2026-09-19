# Adversarial review — `run-path` scope: AutoClicker `.directApp` run path

Repo: `~/Projects/macro-maker` · Reviewer: run-path · Read-only.
Files read: `Services/AutoClicker.swift`, `Services/RunSession.swift`, `Utilities/WorkerThread.swift`, plus collaborators `Services/BackgroundPoster.swift`, `Services/TargetSnapshot.swift`, `Services/RealInputMonitor.swift`, `Services/EventSynthesizer.swift`, `Services/HotkeyService.swift`, `Utilities/RunRules.swift`, `Utilities/TickSchedule.swift`, `Models/RunPhase.swift`, `Models/FeatureSettings.swift`, `Views/AutoClickerView.swift`, `App/AppModel.swift`.

## Verdict on the reported symptom ("clicks never arrive in the target app")

**With default settings the direct run path is structurally functional**: `toggle` → countdown → `begin` → prewarm → worker → `clickLoop` → `verifyTarget()` → `directClickOnce` → `BackgroundPoster.click` posts down/up to the pid. No default-on guard no-ops it (`stopOnFrontmostChange` and `pauseOnRealInput` both default **false**, and `directAppProblem` is a visible gate, not a silent one). So the plain "run starts and posts nothing" theory is **not** confirmed by the loop itself. The symptom must come from one of three observable families, each of which I found a concrete path for:

1. **Counter climbs, nothing lands** → delivery is fail-open (Finding 1) plus recipe-level coordinate/field assumptions (Findings 11–13, sibling scope).
2. **Counter frozen at 0, run stays "running" forever** → window resolution fails (Findings 2, 3) and the run can never reach its click limit.
3. **Run flips to "paused" immediately** → the clicker's own background clicks read as real input (Finding 4), which requires `pauseOnRealInput` on.

**Decisive triage for the owner (one observation, no code change):** watch the "N clicks" counter in the run controls during a direct-app run. Climbing → delivery recipe (BackgroundPoster scope). Frozen at 0 with the amber "Target window not found" line → resolution path (Findings 2/3). Instant "paused" → Finding 4. Also run **Test Click** (same posting seam, no run) — if Test Click lands but a run doesn't, the delta is in this scope; if Test Click also fails, the recipe is the prime suspect.

---

## Findings (severity-ordered)

### 1. HIGH — Direct delivery is fail-open: a "click" is counted with zero evidence it was built or delivered
**Confidence: certain (about the structure), likely (that it masks the live symptom).**
`Sources/MacroMaker/Services/AutoClicker.swift:393-405`:
```swift
guard let window = resolver.window(ofPID: pid) else { return false }
...
BackgroundPoster.click(plan.button, screenPoint: screenPoint, ...
                       window: window, pid: pid, appIsActive: isActive)
return true
```
`BackgroundPoster.click` → `post` (`BackgroundPoster.swift:265-267`) silently returns when `NSEvent.mouseEvent(...)?.cgEvent` is nil, and `eventPoster` (`BackgroundPoster.swift:263`) is `CGEventPostToPid` — a void API with no error channel. So `directClickOnce` returns `true` (and `count += 1`, AutoClicker.swift:293-295) even when both events failed to build, or the window server dropped them. The comment at AutoClicker.swift:296-297 claims "the counter must mean 'clicks that reached the target'", but the code cannot know that. This is exactly the failure shape of the reported symptom: **the run reports a healthy climbing count while zero clicks land**, and no warning ever appears. Direction: thread a delivery-acknowledgement (at minimum, event-construction success) out of `BackgroundPoster.click` and treat `false` like an undelivered click.

### 2. HIGH — Undelivered-click loop makes `stopAfterClicks` unreachable: a "running" run that posts nothing and never stops
**Confidence: certain.**
`Sources/MacroMaker/Services/AutoClicker.swift:296-299` (undelivered click: count unchanged, warning set) and `307/311`:
```swift
if directClickOnce(...) { count += 1 } else { lastWarning = "Target window not found — ..." }
...
if let maxClicks = plan.maxClicks, count >= maxClicks { break }
```
If window resolution fails persistently (target has no layer-0 window — minimized to nothing, menu-bar-only app, non-zero window layer, or Finding 3's wrong-window edge), `count` never increments, so a run with "After a number of clicks" enabled can **never satisfy its own stop condition** and loops forever doing nothing (the amber warning does show, but the run itself is unstoppable except by hand). This is a literal "reports running but posts nothing" path — one of the hunt items. Direction: stop (or hard-cap) the run after N consecutive undelivered clicks.

### 3. HIGH — Multi-window apps: clicks are aimed at the app's first-listed window, not the window the user picked the point in
**Confidence: certain (code behavior); likely (user impact).**
`Sources/MacroMaker/Services/BackgroundPoster.swift:54-56`:
```swift
static func primaryWindow(ofPID pid: pid_t, in list: [[String: Any]]) -> Window? {
    list.lazy.compactMap { window(fromInfo: $0, ownerPID: pid) }.first
}
```
The user picks a screen point inside a *specific* window (`pickDirectAppPoint`, AutoClicker.swift:520-524), but every click aims at whichever of the app's layer-0 windows comes first in the window-server listing. The saved point is then re-anchored via `windowPoint(fromScreenPoint:)` (`BackgroundPoster.swift:160-162`) against that *other* window's origin — the click lands at the translated position in the wrong window, frequently outside its bounds entirely, where AppKit drops it. Any multi-window app (Safari with 2 windows, IDEs, Terminal) hits this; the UI text "clicks land at (x, y) inside it" (AutoClicker.swift:422) confidently reports the wrong window. Direction: prefer the window whose bounds contain the picked screen point; fall back to first-listed only if none contains it.

### 4. HIGH — Pause-on-real-input can be triggered by the clicker's own background clicks: a pause loop that looks exactly like "clicks never arrive"
**Confidence: possible — the tag-after-`setSource` fix was evidently measured, but two unverified links remain.**
`Sources/MacroMaker/Services/RealInputMonitor.swift:44-47`:
```swift
if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
    guard RealInputRules.isReal(event) else { return }
    self?.fire()
```
and `RealInputRules.isReal` (`RealInputMonitor.swift:83-85`):
```swift
guard let cgEvent = event.cgEvent else { return true }
return cgEvent.getIntegerValueField(.eventSourceUserData) != EventSynthesizer.eventTag
```
A global monitor sees events dispatched to *other* apps — which is precisely what `CGEventPostToPid` produces. The whole self-pause defense rests on (a) `.eventSourceUserData` surviving the window-server hop into the monitoring process's copy of the event, and (b) the monitored `NSEvent.cgEvent` never being nil. The comment in `BackgroundPoster.swift:279-283` shows a tag-readback was measured — but "read back as 0 when written first" reads like a same-process readback; it does not prove cross-process monitor survival. And (b) is fail-open by construction: `cgEvent == nil` ⇒ treated as real input. If either link breaks, the sequence per click is: post → monitor fires → `pauseIfNeeded` (AutoClicker.swift:195-206) → `session.pause()` → worker cancelled → auto-resume after idle → first click → pause again. Net effect: **a direct-app run with `pauseOnRealInput` on delivers essentially nothing while the user works in other apps** — the exact reported symptom, phase shown as "paused". Direction: verify with a one-line log in `isReal` for `leftMouseDown` events while a direct run posts; or self-filter by window id/pid instead of the tag.

### 5. MEDIUM — A transient snapshot drop permanently ends the run as "The target app quit or was replaced mid-run"
**Confidence: possible.**
`Sources/MacroMaker/Services/TargetSnapshot.swift:54-59` (refresh drops entries):
```swift
known.forEach { bundleID, app in
    if NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == bundleID {
        resolved[bundleID] = app
    }
}
```
`NSRunningApplication` property values are documented as able to be nil/transient during app state changes; one such 500 ms refresh tick drops the target's entry, and `DirectRun.verifyTarget` (`AutoClicker.swift:348-358`) then returns `.dead` — a **sticky** state (`if case .gone = state { return .dead }`) — ending the run (AutoClicker.swift:288-291) with a message that claims the app quit when it didn't. The fail-closed direction is right; the trigger is spurious and the message is wrong. Direction: require the pid to miss on two consecutive refreshes (or re-resolve by bundle id in `verifyTarget`) before dropping.

### 6. MEDIUM — `initialFrontmost` is sampled from a possibly-stale snapshot; resume silently re-baselines it
**Confidence: possible (stale sample), certain (re-baseline drift).**
`Sources/MacroMaker/Services/AutoClicker.swift:143-147`:
```swift
if plan.stopOnFrontmostChange {
    plan = Plan(settings, initialFrontmost: TargetSnapshot.shared.frontmostBundleID)
}
```
The snapshot refreshes on notifications plus a 0.5 s timer (`TargetSnapshot.swift:41`). Two consequences:
- **Not instant death, but first-tick death:** the sample at `begin` can be up to ~0.5 s stale (notification/main-queue ordering race), so the baseline can be the app the user was in *before* arming; the first `FrontmostStopRule.changed` check (AutoClicker.swift:309-310) then stops a run during which the user never switched. The comment at AutoClicker.swift:74-76 ("sampled at begin — never at toggle") fixes the obvious case but not this one. For hotkey starts there is no countdown at all, so the baseline is wherever the user was at key-down — arming from Macro Maker's own window means switching away kills the run. Direct-app + this toggle is semantically self-defeating (the feature exists so you can be in another app).
- **Resume drifts:** `resume()` (AutoClicker.swift:209-218) passes the old plan back into `begin`, which *re-samples* `initialFrontmost` — so a stop-on-frontmost-change run that survived N pauses can tolerate N frontmost switches it was armed to stop on.
Direction: sample frontmost synchronously (`NSWorkspace.shared.frontmostApplication`) in `begin`, and carry the original baseline across resumes instead of re-sampling.

### 7. MEDIUM — Start refusal is beep-only: from the hotkey or menu bar, `directAppProblem` gives the user no explanation
**Confidence: certain.**
`Sources/MacroMaker/Services/AutoClicker.swift:111-114`:
```swift
guard directAppProblem == nil else {
    NSSound.beep()
    return
}
```
`directAppProblem` is recomputed live at toggle time — so a target app that was running when the panel was opened but has since quit (or is mid-relaunch) makes Start do nothing but beep. The textual reason exists (`AutoClicker.swift:36-46`) but is only rendered inside the settings form (`AutoClickerView.swift:174-177`); a user starting via the global hotkey or the menu bar sees no message at all. Reads as "clicks never arrive" from the user's chair. Direction: surface `directAppProblem` as `runWarning` on refusal instead of beeping.

### 8. MEDIUM — Stale `runWarning` resurrection after a manual stop
**Confidence: likely.**
`endRun` (`AutoClicker.swift:134-141`) clears `runWarning` and stops, but does **not** bump `runID`. The cancelled worker's final `report(count, true, lastWarning)` (AutoClicker.swift:325) is enqueued via `performOnMain` (async) and lands *after* the stop, with `self.runID == run` still true and `session.isPaused` false (phase is `.idle`), so the callback (AutoClicker.swift:174-180) takes the finished branch and re-sets `runWarning` — a warning line displayed over an idle UI the user already stopped, e.g. "Target window not found…" persisting with no run. (The `session.finish(token)` call is a no-op only because RunSession's generation was bumped — lucky, not designed.) Direction: bump `runID` in `endRun`, or gate the finished branch on `session.phase == .running`.

### 9. MEDIUM/LOW — A pause whose worker doesn't die within 1 s leaves a zombie poster; resume then double-posts
**Confidence: possible.**
`RunSession.pause` (`RunSession.swift:63-70`) calls `cancelWork` = `worker.cancelAndWait()` (AutoClicker.swift:184), and `cancelAndWait` gives up after 1 s (`WorkerThread.swift:41-44`). `RunSession.pause` ignores the result and sets `.paused` regardless. The direct worker can legitimately be inside `CGWindowListCopyWindowInfo` (the `.optionAll` fallback enumerates every window on the system) or a `Thread.sleep(holdFor)` when cancelled; if it outlives the second, `resume()` starts a **second** worker while the first still posts. The first worker's reports are then discarded by the `runID` guard (AutoClicker.swift:165) — its clicks are delivered but never counted. Direction: if `cancelAndWait` times out, treat the pause as failed (keep running) rather than half-paused.

### 10. MEDIUM/LOW — Resume can post one click past `maxClicks`
**Confidence: certain (code path), needs a pause at exactly the limit.**
`clickLoop` checks `count >= maxClicks` only *after* posting (AutoClicker.swift:285-311). If a pause lands with `clicksDone == maxClicks` (mid-burst, before the post-burst check), `resume()` starts a worker with `skip == maxClicks` whose first iteration posts once more before breaking. Direction: check the limit before the burst loop, not only after each click.

### 11. LOW — Position jitter is not clamped to the window; a jittered point can leave the window (and the click still counts — see Finding 1)
**Confidence: certain.**
`AutoClicker.swift:397-400` jitters `plan.directScreenPoint` by up to `jitterPx` with no containment check against `window.bounds` — the window-local point can fall outside the window, where the click is dropped by the target. The non-direct path at least stays on a screen; the direct path's whole accuracy promise is the window anchor. Direction: clamp the jittered window-local point to the bounds (minus a small margin).

### 12. LOW — "Double"/"Triple" in direct mode posts one isolated down/up pair with `clickState` 2/3 — probably not a real double-click
**Confidence: possible.**
`AutoClicker.swift:88` (`clickCountPerEvent`) flows to `mouseEvent`'s `clickState` field (`BackgroundPoster.swift:241-242`) as a single pair. AppKit's click coalescing keys on the *sequence* (state-1 pair then state-2 pair within the double-click threshold); a lone state-2 pair against no prior state may register as a single click or nothing in the background process. Direction: post 2/3 full down/up pairs with clickState 1…n.

### 13. LOW — Multi-display Y flip is anchored to the primary screen (documented, but wrong for windows off the primary)
**Confidence: certain (documented in-code).**
`BackgroundPoster.swift:226-228`: `appKitY = (screenFrames.first?.maxY ?? 0) - y`. Any target window on a display not aligned with the primary's top gets a wrong global Y in the posted event's location fields. The in-code comment covers this honestly; whether the window-server cares about the global location at all (vs. fields 91/92 + window location) is unknown — which is exactly why it deserves a test with the target on a secondary display. Related, sibling-scope but load-bearing for delivery: `windowPoint` (`BackgroundPoster.swift:160-162`) never flips Y for the window-local coordinate handed to `CGEventSetWindowLocation`; if that private API expects AppKit-style local coords (Y up from the window's bottom-left), every click lands mirrored vertically inside the window — clicks would visibly land at the wrong spot, not vanish, so this is a secondary suspect.

### 14. LOW — Hold-to-click release skips `endRun` bookkeeping
**Confidence: certain, cosmetic.**
The release hook (`AutoClicker.swift:456-460`) calls `self.session.stop()` directly rather than `endRun()` — `clickCount`, `clicksDone`, `elapsedBefore`, `workerStartedAt` stay stale until the next `toggle` resets them. Harmless today (toggle resets everything, AutoClicker.swift:117-120), but it's a second "run over" path that doesn't match the one documented at AutoClicker.swift:133 ("the only 'run over' path").

---

## Direct answers to the hunt questions

- **Does the direct loop actually resolve a window and post when the target is backgrounded, or does a guard silently no-op it?** It resolves and posts — `verifyTarget` → `resolver.window` → `BackgroundPoster.click` runs with the app inactive (`isActive` false just selects the NX_COMMAND flag, `BackgroundPoster.swift:168-170`). No default-on guard no-ops it. The silent failures are *downstream*: fail-open delivery (Finding 1), wrong-window aiming (Finding 3), and the unreachable click limit (Finding 2). `directAppProblem` is a real gate but a visible one — except its rejection is beep-only outside the settings form (Finding 7).
- **Does `initialFrontmost` sampled at `begin` kill a run armed from Macro Maker's own window with `stopOnFrontmostChange` on?** Not instantly: the button path samples after the 3 s countdown, so the user has left Macro Maker by then. But the hotkey path has no countdown (samples at key-down), and the sample can be up to ~0.5 s stale (Finding 6) — both can end the run at the first tick. And `resume()` re-baselines, silently weakening the rule (Finding 6).
- **Could the clicker's own background events be seen as real input and pause the run?** Yes, conditionally — the self-tag filter has two unverified links (cross-process `.eventSourceUserData` survival; `isReal` returning true when `cgEvent` is nil). If either breaks, direct mode + `pauseOnRealInput` is a perpetual pause loop (Finding 4).
- **Click-count bookkeeping across pause/resume:** correct in the normal case (dying worker's final report lands after `cancelAndWait` blocks main, `clicksDone` is exact, `skip` resumes from it, `elapsedBefore` banks the budget). Edge holes: 1 s `cancelAndWait` timeout leaves a zombie poster (Finding 9), and resume can overshoot `maxClicks` by one click (Finding 10).
- **`holdToClick`:** wiring is sound (release monitor matches combo or its modifiers; reassignment mid-hold ends the run via `onToggleReassignedWhileHolding`). Bookkeeping skips `endRun` cleanup (Finding 14) — cosmetic only.
- **`burstSize`:** clamped 1…10, no path makes it suppress clicks.
- **Any path where the run reports "running" but posts nothing?** Yes — Finding 2: persistent window-resolution failure posts nothing, freezes the count, and makes a click-limited run unfinishable.

## Scope statement

Everything in my assigned scope was read and analyzed; no file was skipped. The delivery recipe itself (NSEvent field population, flags 91/92, subtype 3, the `CGEventSetWindowLocation` calling convention and coordinate conventions, the NX_COMMAND flag) is BackgroundPoster's territory — I flagged only what the run path itself depends on from it (Findings 1, 3, 11, 12, 13). The verified fact that `CGEventSetWindowLocation` is present is accepted; nothing here blames a missing symbol.