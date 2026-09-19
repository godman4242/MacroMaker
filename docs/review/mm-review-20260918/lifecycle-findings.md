# Adversarial review — `lifecycle` scope

**Files in scope:** `Sources/MacroMaker/App/AppDelegate.swift`, `AppModel.swift`, `MacroMakerApp.swift`, `WindowCoordinator.swift`, `Sources/MacroMaker/Services/RunSession.swift`, `Sources/MacroMaker/Utilities/WorkerThread.swift`, `TickSchedule.swift`, `RunRules.swift`, `ScheduleRules.swift`, `Tests/MacroMakerTests/ScheduleAndPauseTests.swift`.

**Method:** read-only; every hunt-list item was traced through its callers (`AutoClicker.swift`, `RealInputMonitor.swift`, `TargetSnapshot.swift`, `BackgroundPoster.swift`, `FeatureSettings.swift`, `SettingsView.swift`, `RunControls.swift`, `WindowLayoutTests.swift`). Hunt hypotheses that turned out sound are listed under "Verified non-issues" so a dead end is distinguishable from an unexplored one.

---

## Contribution to the headline symptom ("direct-app clicks never arrive")

Nothing in the lifecycle files blocks delivery: `RunSession` → `AutoClicker.begin` → `WorkerThread` → `clickLoop` → `directClickOnce` reaches `BackgroundPoster.click` correctly on every code path I traced (pause/resume, stop, scheduled start, hold). The recipe itself is another agent's scope. What **is** in my scope's neighborhood is the *accounting* around it (see X1): the loop counts a click as delivered merely because `postToPid` was called — it returns `Void`, so a recipe the WindowServer silently drops produces exactly the owner's symptom shape: a run that shows "running, N clicks", zero feedback, no error. Whatever the root cause turns out to be, the lifecycle layer is why it fails *silently*.

---

## Findings

### F1 — Panic-stop and hold-release bypass `endRun`, leaking the pause watcher permanently (debug: crash on next start)
- **Severity:** HIGH · **Confidence:** certain
- **Evidence:** `AppModel.swift:263-268`:
  ```swift
  func stopAll() {
      autoClicker.session.stop()
      keyPresser.session.stop()
      ...
  ```
  and `AutoClicker.swift:456-460` (hold-to-click release):
  ```swift
  hotkeys?.onRelease = { [weak self] action, combo in
      ...
      self.session.stop()
  }
  ```
  Both call `RunSession.stop()` directly. The *only* paths that call `tearDownPauseWatching()` are `endRun` (`AutoClicker.swift:134-141`) and the natural-finish report (`AutoClicker.swift:176`). `RunSession` has no stop-observer, so an external `stop()` skips teardown entirely.
- **Why it's a problem:** when `pauseOnRealInput` is on, `startPauseWatching()` (`AutoClicker.swift:225-240`) has already installed `RealInputMonitor` (subscribers 1) and a 1 Hz `resumeTimer`. "Stop Everything" (hotkey `.stopAll`, `MenuBarView.swift:76`; also `applyProfile`, `shutdown`) or releasing a hold-to-click shortcut leaves:
  - the 1 Hz `resumeTimer` firing a no-op `Task` forever (until a *new* run start invalidates it);
  - `RealInputMonitor` at subscribers == 1 forever, so `stop()` (`RealInputMonitor.swift:66-70`) never removes the global key/mouse-down monitors — they stay installed for the rest of the process, watching all input with nothing running;
  - `runWarning`, `clicksDone`, `elapsedBefore` stale after the stop (the AutoClicker tab can keep showing the dead run's warning banner);
  - and on the **next** run start, the debug assert `RealInputMonitor.swift:38-39` (`assert(subscribers == 0, ...)`) fires — a reproducible debug crash for any developer toggling pause-on-input + Stop Everything. In release the imbalance is permanent but the feature still works (the callback is idempotent), which is exactly why it will never be noticed in the field.
- **Direction:** route every stop of a feature with teardown through its `endRun` (or add a stop hook to `RunSession`).

### F2 — `fireSchedule` judges timeliness against the *current* deadline, not the timer that fired
- **Severity:** MEDIUM · **Confidence:** possible (narrow race, concrete consequence)
- **Evidence:** `AppModel.swift:160-165` — the timer's block hops through a `Task`:
  ```swift
  let timer = Timer(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.fireSchedule() }
  }
  ```
  and `fireSchedule` (`AppModel.swift:170-181`) then reads whatever `scheduleDeadline` holds *at execution time*:
  ```swift
  let deadline = scheduleDeadline
  scheduleDeadline = nil
  guard schedule.enabled else { return }
  ...
  guard ScheduleRules.isOnTime(deadline: deadline, now: Date()) else { return }
  ```
  with `ScheduleRules.isOnTime(deadline: nil, ...)` returning `true` (`ScheduleRules.swift:71-73`), and an *early* fire also passing (`now.timeIntervalSince(deadline) <= fireTolerance`).
- **Why it's a problem:** if the timer fires while the main actor is busy (countdown UI, the launch-time `runModal` alert, any jank) and the user edits/re-arms the schedule before the queued `Task` runs, the stale fire executes against the **new** deadline: it invalidates the new timer, disarms the schedule, and — because the new deadline is in the future, hence "early", hence on-time — **starts the feature immediately**. A stale fire after a disarm is saved by the `schedule.enabled` guard, but a disarm→re-arm or a time edit in that window produces a surprise start of an auto clicker plus a silently disarmed schedule.
- **Direction:** capture the deadline in the timer's closure at arm time and have `fireSchedule` compare that value.

### F3 — `cancelAndWait`'s timeout result is discarded: Stop is fail-open, and it blocks main up to 1 s per session
- **Severity:** MEDIUM · **Confidence:** possible (wedge), certain (the discard itself)
- **Evidence:** `WorkerThread.swift:40-44`:
  ```swift
  @discardableResult
  func cancelAndWait(timeout: TimeInterval = 1) -> Bool {
      cancel()
      return finished.wait(timeout: .now() + timeout) == .success
  }
  ```
  called as `return { worker.cancelAndWait() }` (`AutoClicker.swift:184`; same shape in `KeyPresser.swift:86`, `MacroPlayer.swift:64`) — the `Bool` is dropped, and `RunSession.stop()`/`pause()` invoke it synchronously on the main actor (`RunSession.swift:41-50`, `63-70`).
- **Why it's a problem:** the worker's loop only notices cancellation at tick boundaries; between checks it can sit inside `WindowResolver.window(ofPID:)` → `CGWindowListCopyWindowInfo` (twice, `.optionOnScreenOnly` then `.optionAll` — `BackgroundPoster.swift:59-65`), which is unbounded under window-server load. If the worker doesn't return within 1 s, `session.stop()` declares the run stopped while the worker is still live and can still post one or more clicks — and with a wedged window-server call, indefinitely. No retry, no log, no warning: main proceeds as if cleanup succeeded. This is precisely the "fail-open accounting — a dead agent and one that finished look identical" trap. Additionally, `applicationWillTerminate` → `stopAll()` (`AppDelegate.swift:10-13`) can block quit for up to 4 × 1 s, and `pauseIfNeeded` blocks main inside an input-monitor callback on *every* pause.
- **Direction:** at minimum, log/retry a timed-out cancel rather than dropping the result.

### F4 — Auto-resume fires while the user is still actively using the machine (scroll / held-button drag)
- **Severity:** MEDIUM · **Confidence:** likely (drag scenario)
- **Evidence:** `RealInputMonitor.swift:32`:
  ```swift
  static let watchedTypes: [NSEvent.EventTypeMask] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
  ```
  with `RealInputRules.idleEnough` (`RealInputMonitor.swift:89-91`) measuring from `lastRealInputAt`, stamped only by watched events.
- **Why it's a problem:** the user's mouse-down pauses the run, then they keep *dragging* — no further watched event fires — so after `autoResumeSeconds` the idle timer (`AutoClicker.swift:234-239`) resumes the run **mid-drag, while the physical button is still held**. Same for continuous scroll-wheel use: a paused run resumes under a scrolling user. The feature's copy promises "Your own key presses and clicks pause the run" (`AutoClickerView.swift:85`); resumed-under-use contradicts the spirit and, for `.cursor` targeting, resumes clicking wherever the pointer happens to be mid-interaction.
- **Direction:** add scrollWheel/dragged (or `flagsChanged`/mouseMoved while a button is down) to the idle-stamp set.

### F5 — Unbounded persisted numbers reach trapping integer conversions (profile import is a live vector)
- **Severity:** MEDIUM · **Confidence:** possible (needs a hand-edited blob or imported profile)
- **Evidence:** `AutoClickerSettings`' tolerant decoding applies **no numeric bounds** (`FeatureSettings.swift:57-66`, e.g. `intervalMs = try c.decodeIfPresent(Double.self, ...) ?? 100`), and the crash sites sit in this scope's callers:
  - `AutoClicker.swift:126`: `countdownExtra: Int(max(0, settings.delayedStartSeconds).rounded())` — `delayedStartSeconds = 1e20` → `Int(1e20)` traps on toggle;
  - `AutoClicker.swift:322`: `UInt64(delay * 1_000_000_000)` — `intervalMs = 1e300` survives the `max(minimumDelay, intervalMs/1000)` clamp (a floor, not a cap; `AutoClicker.swift:90`) and the humanizer's *disabled* path (`Humanizer.swift:103`) returns it unchanged → trap on the first tick. Same shape in `KeyPresser.swift:120`.
  The codebase already defends this class of bug elsewhere with explicit comments ("`UInt64(_:)` traps … measured: exit 133", `AutoClicker.swift:256`, `MacroPlayer.swift:157`) — these two paths were missed.
- **Why it's a problem:** the UI clamps (`NumberField` ranges), but **profile import does not**: `applyProfile` assigns the decoded settings wholesale (`AppModel.swift:84`), so a malformed or hostile `.macromakerprofile` crashes the app at the next Start. No data loss, but a supported input path to a hard crash.
- **Direction:** bound the decoded values (or the `Plan` conversions) like `dueOffsetNanos` does.

### F6 — Stale natural-finish report can resurrect `runWarning` after the run was stopped
- **Severity:** LOW · **Confidence:** possible
- **Evidence:** `AutoClicker.swift:174-180`:
  ```swift
  if finished, !self.session.isPaused {
      self.runWarning = warning
      self.tearDownPauseWatching()
      self.session.finish(token)
  }
  ```
  guarded only by `runID` and `isPaused` — not by "the session was stopped since this report was enqueued". `endRun()` (`AutoClicker.swift:134-141`) clears `runWarning = nil`.
- **Why it's a problem:** a worker that finished naturally (limit reached) enqueues its final `performOnMain` report; if the user presses Stop before main drains it, `endRun` clears the warning, then the stale report executes with `runID` still matching (stop doesn't bump `runID`) and `!isPaused` true, re-setting `runWarning` and `clicksDone` for a run the user already dismissed. The UI comment claims "nothing goes stale" (`AutoClickerView.swift:118`) — it can. Harm is cosmetic (a stale banner; `clicksDone` is reset on next toggle), hence LOW.
- **Direction:** make the finish branch also require `token == session.generation`-equivalent state (or bump `runID` on stop).

### F7 — `fitted(inside:)` re-centers BOTH axes when only one overflows
- **Severity:** LOW · **Confidence:** certain (behavior), LOW impact
- **Evidence:** `WindowCoordinator.swift:116-121`:
  ```swift
  let size = NSSize(width: min(width, area.width), height: min(height, area.height))
  guard size == self.size else {
      return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, ...)
  ```
  A 2000×400 frame on a 1440-wide screen loses its valid Y origin and gets vertically centered too.
- **Why it's a problem:** the clamp's stated contract is "changing as little as possible" and the load-bearing case is "don't discard where the user dragged it" (`WindowCoordinator.swift:110-114`) — but one-axis overflow discards the *other* axis. `WindowLayoutTests.aFrameWiderThanTheScreenIsCappedOnThatAxisOnly` (`WindowLayoutTests.swift:123-128`) pins only the resulting *size*, not the origin, so the test blesses the recenter. Minor UX on multi-display setups (window saved on a wider secondary display).
- **Direction:** center only the overflowing axis.

### F8 — Scheduled playback with no macro silently disarms at fire time
- **Severity:** LOW · **Confidence:** certain
- **Evidence:** `AppModel.swift:193`:
  ```swift
  case .playback:
      if macro != nil, !player.session.phase.isActive { togglePlayback(.hotkey) }
  ```
  while the disarm at `AppModel.swift:174-176` happens unconditionally before it.
- **Why it's a problem:** the user armed "Play Macro at 19:00"; if the macro was cleared (or never loaded after relaunch), the deadline arrives, the schedule quietly disarms itself, nothing happens, and there is no beep, status message, or menu-bar trace — the feature looks simply broken. Every other armed-but-unstartable case (`directAppProblem`, permissions) at least beeps via `toggle`.
- **Direction:** surface a "scheduled start skipped: no macro" status.

### F9 — `ScheduleRow` keeps invalid typed text, silently diverging from the armed time
- **Severity:** LOW · **Confidence:** certain
- **Evidence:** `SettingsView.swift:135-141`:
  ```swift
  private func commitTime() {
      guard let seconds = ScheduleRules.parseClock(clockText) else { return }
      ...
  }
  ```
  On an unparseable field ("99:99", "ten"), both `.onSubmit` and focus-loss commit return without reverting `clockText` (`SettingsView.swift:106-116`).
- **Why it's a problem:** the text field continues to *display* a time that is not what's armed; only the secondary "in N min" label tells the truth. The old bugs this control fixed (documented at `SettingsView.swift:108-112`) were exactly of this silent-divergence class.
- **Direction:** revert the field to `clockString(seconds: model.schedule.seconds)` on parse failure.

### F10 — Idle-rule semantics disagree about `autoResumeSeconds == 0`
- **Severity:** LOW · **Confidence:** certain
- **Evidence:** `RealInputMonitor.swift:90` (`max(1, afterSeconds)` — 0 means "1 second") vs `AutoClicker.swift:236` (`self.settings.autoResumeSeconds > 0` — 0 means "never"). The UI range starts at 1 (`AutoClickerView.swift:83-84`), so only a hand-edited blob can hit it, but then the two layers interpret the same value oppositely. Direction: define 0 once (clamp at decode).

### F11 — Sleep-wake inside the 120 s tolerance produces exactly the "surprise fire" the gate says it prevents
- **Severity:** LOW · **Confidence:** certain (logic), debatable intent
- **Evidence:** `ScheduleRules.swift:71-74` (`now.timeIntervalSince(deadline) <= fireTolerance`) with `fireTolerance = 120` (`ScheduleRules.swift:63`), and the reasoning at `AppModel.swift:177-181`.
- **Why it's a problem:** lid closed at 18:59:30, opened at 19:01:30 → the overdue timer fires on wake, is "on time", and the clicker starts **the moment the user opens the lid**, with no countdown (`.hotkey` trigger, `AppModel.swift:187`). The comment frames the tolerance as only absorbing normal lateness, but any wake within 2 minutes of the deadline yields the surprise-start behavior it calls unacceptable. Discontinuous (130 s sleep → refused), and untested at the boundary inside the tolerance.
- **Direction:** either shrink the tolerance or refuse fires where the deadline passed while asleep.

### F12 — Test-suite gaps in this scope (would have caught F1/F2/F5)
- **Severity:** LOW · **Confidence:** certain
- **Evidence:** `ScheduleAndPauseTests.swift` covers `ScheduleRules` math and `RunSession` pause transitions well, but:
  - zero tests for `AppModel.fireSchedule`/`setSchedule` behavior at all (the start-only guard at `AppModel.swift:186-193`, disarm-on-fire, the on-time gate) — all of `fireSchedule`'s carefully-commented bug fixes are unpinned;
  - no test that stopping via `stopAll()` leaves `AutoClicker`'s pause watcher torn down (would have caught F1; the `RealInputMonitor` assert is the only tripwire and only in debug);
  - no test of `RealInputRules.idleEnough(afterSeconds: 0)` (F10) or of unbounded-decode crash sites (F5);
  - cosmetic: test named `afireAtItsDeadlineIsOnTime` (`ScheduleAndPauseTests.swift:234`).
- **Direction:** pin `fireSchedule` semantics and the stop-path teardown with tests.

---

## Cross-scope observations for the orchestrator (headline symptom)

- **X1 — No delivery feedback anywhere in the direct pipeline (the silent-failure enabler).** `directClickOnce` (`AutoClicker.swift:293-299`) returns `true` — and `count += 1` — whenever a window resolved and `BackgroundPoster.click` was *called*; `eventPoster` (`BackgroundPoster.swift:263`, `$0.postToPid($1)`) has no error channel. If the constructed event is dropped by the WindowServer (wrong field recipe, wrong window id, flags), the UI reports a healthy run with a rising counter. When triaging "clicks never arrive", treat "the counter climbs but nothing lands" vs "counter stuck at 0 + window-not-found warning" as the fork that localizes the fault: the owner should be asked which one they see.
- **X2 — Scheduled/hotkey starts deliver `.hotkey` trigger → no countdown** (`AppModel.swift:185-194`): background direct-app runs are unaffected, but `.cursor`-mode scheduled starts click at the cursor's position at the fire instant. Deliberate (comment says so) but worth the orchestrator knowing when reproducing.

---

## Verified non-issues (hunt hypotheses that did not survive)

- **Timer retain cycles: none.** Every timer hops through `[weak self]` (`AppModel.swift:160-163`, `AutoClicker.swift:234-239`, `PermissionService.swift:32-34`, `TargetSnapshot.swift:41-43`), and the objects owning timers are process-lifetime singletons. The only *orphaned* timer is the F1 leak.
- **Stale-worker posting after end/pause: guarded.** Dual guard — `self.runID == run` (`AutoClicker.swift:165`, `KeyPresser.swift:71`, `MacroPlayer.swift:59`) and `token == generation` (`RunSession.swift:54`) — drops every stale report. Pause's `cancelAndWait` runs on main *before* `pause()` returns, and the worker's final `report` is enqueued via `performOnMain` (`WorkerThread.swift:61-65`, FIFO dispatch) before `finished.signal()`, so the authoritative final count is always queued ahead of any subsequent user action: resume's `skip = clicksDone` cannot miss clicks, and an old worker's report can never land after a new worker's. (The one residual is F3's wedged-worker case and F6's cosmetic resurrection.)
- **Countdown-task cancellation: works, but by side effect.** `try? await Task.sleep` (`RunSession.swift:34`) swallows the cancellation error; the loop is actually ended by the `generation == token` check (`RunSession.swift:32,36`) — correct, just cancellation-by-accident. Worth a comment, not a bug.
- **`@MainActor` / `Sendable` violations: none found.** `performOnMain`'s `MainActor.assumeIsolated` rides the dispatch-main-queue ≡ main-actor equivalence (standard, safe pattern). `TargetSnapshot`'s `nonisolated(unsafe)` fields are NSLock-guarded on every access. `Plan`, `DirectRun`, `EventSource`, `WorkerThread` are Sendable-sound (`@unchecked` where a class, with the exclusivity argument documented at `AutoClicker.swift:331-337`). The two `nonisolated(unsafe)` statics in `BackgroundPoster` (`windowLocationResolver:152`, `eventPoster:263`) are test seams — only unsafe if swapped mid-run, which only tests do.
- **Clock-time DST math: correct and test-pinned.** Wall-clock via `date(bySettingHour:)` rather than midnight+seconds (`ScheduleRules.swift:35-45`), pinned across the European spring-forward by `ScheduleAndPauseTests.swift:212-224`; launch re-arm rule pinned at `:188-206`; late-fire gate pinned at `:231-250`.
- **`fireSchedule` start-only semantics: correct.** The `!…isActive` guards (`AppModel.swift:186-193`) genuinely prevent the documented "toggle stops the running feature" bug (untested, though — see F12).
- **WindowCoordinator layout gate: matches its pinned contracts.** Hosting-view mechanism, autosave names, min sizes, non-resizable settings window all agree with `WindowLayoutTests`; the every-open clamp is a no-op for fitting frames (`WindowCoordinator.swift:115-125`, pinned by `ScreenFitTests`). Residuals: F7's one-axis recenter, plus a cosmetic one-turn flash of an oversized restored frame before the async re-clamp (`WindowCoordinator.swift:48-54`).
- **Pause banking across resumes: correct.** `elapsedBefore` banking (`AutoClicker.swift:202-205`) plus `runDeadlineNanos`' `alreadyElapsed` (`AutoClicker.swift:257-263`) keeps time budgets honest across pause/resume; the NaN/overflow clamp there is exactly what `AutoClicker.swift:322` lacks (F5).
- **`TickSchedule` / `RunRules`: clean.** Drift-free deadline math resyncs after a whole-tick stall without catch-up bursts (`TickSchedule.swift:16-19`); `FrontmostStopRule.changed` never stops on a missing sample (`RunRules.swift:5-9`); `DelayedStart.total` clamps negatives.
- **AppDelegate / MacroMakerApp: nothing wrong.** Multi-URL open iterates and dispatches by extension (`AppDelegate.swift:27-33`); Dock-reopen shows main (`:16-19`); `MenuBarExtra(.window)` + adaptor is standard. `applicationWillTerminate`'s up-to-4 s block is folded into F3.