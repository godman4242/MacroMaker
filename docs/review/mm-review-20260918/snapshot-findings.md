# Adversarial review — `snapshot` scope

**Files in scope:** `Sources/MacroMaker/Services/TargetSnapshot.swift`, `WindowResolver` in `Sources/MacroMaker/Services/BackgroundPoster.swift` (caller context read in `AutoClicker.swift`, `RunSession.swift`, `WorkerThread.swift`, `AppModel.swift`).

**Method:** read-only; every hunt-list item was traced through its callers. Where a hunt hypothesis turned out sound, it is listed under "Verified non-issues" so a dead end is distinguishable from an unexplored one.

---

## Root-cause contribution to "clicks never arrive" (ranked)

My scope contains one bug that is **certain** (F1), one mechanism that is a **likely contributor** to the headline symptom for multi-window targets (F2), and one semantics hole that can **reproduce the exact symptom** in a realistic timing window (F3). The snapshot's pid resolution itself is NOT the problem — prewarm timing is sound (see Verified non-issues). The strongest observation for the orchestrator: **nothing in the pipeline can detect a failing post** (F9, cross-scope), which is why whatever the true root cause is, it fails silently.

---

## Findings

### F1 — WindowResolver's negative cache never works (double-optional unwrap bug)
- **Severity:** HIGH · **Confidence:** certain
- **Evidence:** `BackgroundPoster.swift:79` and `:88-94`:
  ```swift
  nonisolated(unsafe) private var lastWindow: Window??   // line 79
  ...
  if let cacheDate, Date().timeIntervalSince(cacheDate) < Self.ttl, let window = lastWindow {
      return window
  }
  let window = BackgroundPoster.resolveWindowLive(ofPID: pid)
  self.cacheDate = Date()
  self.lastWindow = .some(window)
  ```
  `if let window = lastWindow` unwraps the **outer** optional only, binding `window: Window?`. After a miss the cache holds `.some(nil)`, so the condition fails and the resolver re-runs `resolveWindowLive` on **every call**.
- **Why it's a problem:** the doc comment (lines 67-71) claims exactly the opposite — "misses included, so a hidden-window run can't re-query the window server once per click (a 1 ms interval would otherwise mean ~300 listings/second)". With the bug, a target whose layer-0 windows are gone (app hidden via ⌘H, all windows closed) produces **two `CGWindowListCopyWindowInfo` calls per click** — at a 1 ms interval that is ~2,000 full window-server listings/second for as long as the run lasts, degrading the whole machine, plus the "Target window not found" warning on every tick. The documented protection does not exist.
- **Direction:** compare the outer optional (`if case .some(let cached) = lastWindow`) or carry a separate `hasResult` flag.

### F2 — Clicks are aimed at the app's globally-topmost window, never the window the point was picked on
- **Severity:** HIGH (direct contributor to the headline symptom) · **Confidence:** certain about the code behavior; likely as a symptom cause when the target has >1 window
- **Evidence:** `BackgroundPoster.swift:54-56`:
  ```swift
  static func primaryWindow(ofPID pid: pid_t, in list: [[String: Any]]) -> Window? {
      list.lazy.compactMap { window(fromInfo: $0, ownerPID: pid) }.first
  }
  ```
  `CGWindowListCopyWindowInfo` returns global front-to-back order, so `.first` is the target app's frontmost window — regardless of which window the user hovered over in `pickDirectAppPoint` (`AutoClicker.swift:488-523` stores only a screen point; no window id is ever captured). `directClickOnce` (`AutoClicker.swift:396-404`) then translates the picked screen point using that topmost window's bounds:
  ```swift
  guard let window = resolver.window(ofPID: pid) else { return false }
  ...
  BackgroundPoster.click(..., window: window, pid: pid, appIsActive: isActive)
  ```
- **Why it's a problem:** pick a point on a **secondary** window of any multi-window app (Safari, Finder, VS Code, Terminal): every click is aimed at the topmost window with a window-local coordinate computed from the wrong origin. If the translated point falls outside that window's bounds, AppKit drops the event — clicks "never arrive", and the counter still increments (the resolver succeeded; only the aim is wrong). The UI hint "clicks land at (x, y) inside it" (`AutoClicker.swift:420-422`) describes a window that may not be the one the user picked.
- **Direction:** capture the window id at pick time, or resolve the window whose bounds contain the picked screen point.

### F3 — The NX_COMMAND decision runs on a frontmost snapshot that can be stale ~500 ms (unbounded under main-thread load)
- **Severity:** MEDIUM (reproduces the exact symptom in a realistic window) · **Confidence:** certain about the staleness mechanism; likely about the consequence
- **Evidence:** `_frontmostBundleID` is written only in `refreshFromMain()` (`TargetSnapshot.swift:49-64`), driven by `didActivateApplicationNotification` plus a 500 ms timer whose fire hops through an unstructured `Task { @MainActor }` (`TargetSnapshot.swift:41-43`):
  ```swift
  Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshFromMain() }
  }
  ```
  `targetState` (`:77-87`) reads it under the lock but the value is only as fresh as the last refresh; the worker consumes it per click via `DirectRun.verifyTarget()` (`AutoClicker.swift:348-358`) and `clickFlags` (`BackgroundPoster.swift:168-170`) turns it into the NX_COMMAND bit:
  ```swift
  static func clickFlags(appIsActive: Bool) -> CGEventFlags {
      appIsActive ? [] : backgroundClickFlag
  }
  ```
- **Why it's a problem:** both stale directions are wrong. Stale-**active** (snapshot says the target is frontmost, the user just switched away): flags = `[]`, and per the file's own recipe (line 165-166, "Background-posted clicks are dropped by AppKit unless the event pretends ⌘ is held when the target app isn't the active one") **every click in that window is dropped — the reported symptom**. Stale-**inactive**: the target receives ⌘-clicks it shouldn't. The `Task { @MainActor }` hop means that under a busy main thread (a countdown, UI churn, many queued timer tasks) the staleness is unbounded, not 500 ms. Note `didActivateApplicationNotification` narrows the window on real switches — the exposure is the gap between a switch and the notification's main-queue dispatch, plus any load-induced timer-task delay.
- **Direction:** make `isActive` cheaply queryable at click time (e.g. `NSWorkspace.shared.frontmostApplication` is documented main-thread-only — but `CGWindowServer`-free alternatives exist), or refresh on a worker-visible signal before a burst.

### F4 — Pid-death / pid-reuse detection lags up to 500 ms, compounded by a 300 ms cached window id
- **Severity:** MEDIUM · **Confidence:** certain about the mechanics; the reuse hit is possible
- **Evidence:** the only pid liveness check is `refreshFromMain` (`TargetSnapshot.swift:55-59`):
  ```swift
  known.forEach { bundleID, app in
      if NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == bundleID {
          resolved[bundleID] = app
      }
  }
  ```
  which runs on the notification/500 ms cadence. Until the next refresh, `targetState` keeps reporting a dead pid as `alive`, and `WindowResolver` keeps serving the dead app's cached `Window` for a further 300 ms (`BackgroundPoster.swift:88`).
- **Why it's a problem:** after the target quits, up to ~500 ms of clicks go to `CGEventPostToPid` on a dead pid (silently failing, see F9) with event field 91/92 naming a window that no longer exists; worse, if the OS reuses the pid inside that gap, clicks are delivered to an **unrelated process** — precisely what the "pid-reuse guard" doc comment (`TargetSnapshot.swift:11-12, 46-48`) claims cannot happen. The guard's granularity is the refresh cadence, and nothing validates the pid at `verifyTarget()` time.
- **Direction:** liveness-check at verify time (worker-side) instead of relying on refresh cadence.

### F5 — `targetState`'s not-found re-resolve is dead code; one miss permanently ends the run and the doc comment misdescribes the design
- **Severity:** LOW (design smell + misleading contract) · **Confidence:** certain
- **Evidence:** `TargetSnapshot.swift:73-77` promises "reports not-found until the snapshot catches up", and `:82-85` enqueues a fix:
  ```swift
  guard let app else {
      Task { @MainActor [weak self] in self?.resolveFromMain(bundleID) }
      return (nil, false)
  }
  ```
  But the only caller, `DirectRun.verifyTarget` (`AutoClicker.swift:348-358`), latches `.gone` on the first miss and `clickLoop` returns immediately:
  ```swift
  guard let pid = target.pid else {
      state = .gone
      return .dead
  }
  ```
- **Why it's a problem:** the enqueued `resolveFromMain` can never affect the run it was issued for — the run is already dead. The comment's "until the snapshot catches up" describes a retry loop that does not exist; the actual contract is "first miss = run over". That is a defensible policy for a genuine quit, but the code and the comment tell two different stories, and the retry machinery is unreachable. (Prewarm does make the first-miss-cold case unreachable — see Verified non-issues — so in practice a miss means genuine death; the finding is the misleading contract, not a live bug.)
- **Direction:** delete the enqueue or implement the advertised catch-up retry.

### F6 — WindowResolver TTL is measured in wall-clock `Date()`
- **Severity:** LOW · **Confidence:** certain about the code; possible about the impact
- **Evidence:** `BackgroundPoster.swift:76` and `:88`:
  ```swift
  nonisolated(unsafe) private var cacheDate: Date?
  ...
  if let cacheDate, Date().timeIntervalSince(cacheDate) < Self.ttl, let window = lastWindow {
  ```
- **Why it's a problem:** a backward clock step (NTP correction, manual change) extends `timeIntervalSince` into the negative — the stale cached window id and bounds are then served for the entire size of the step (seconds to minutes) instead of 300 ms. A long unattended direct-app run is exactly the scenario where a clock correction can land. Sleep/wake behaves benignly (huge positive delta forces expiry).
- **Direction:** use an uptime clock (`DispatchTime`/mach) as the run loop already does (`AutoClicker.swift:269`).

### F7 — Cached window bounds make the "re-anchored to the window's live bounds on every click" promise wrong for up to 300 ms
- **Severity:** LOW · **Confidence:** certain
- **Evidence:** `AutoClicker.swift:487` claims "captured in screen coordinates and re-anchored to the window's live bounds on every click", but `WindowResolver.window(ofPID:)` (`BackgroundPoster.swift:85-95`) returns the cached `Window` (id **and** `bounds`) for 300 ms, and `windowPoint(fromScreenPoint:window:)` (`BackgroundPoster.swift:160-162`) translates using those cached bounds.
- **Why it's a problem:** a window that moves or closes inside the TTL receives clicks aimed at the old origin (offset by the move delta) or at a dead/replaced window id — delivered nowhere useful, still counted. Bounded at 300 ms, hence LOW, but the UI promise says "every click".
- **Direction:** re-read bounds (cheap) per click even when the id is cached, or weaken the promise.

### F8 — Eviction predicate cannot distinguish "pid dead" from "lookup failed"
- **Severity:** LOW · **Confidence:** possible
- **Evidence:** `TargetSnapshot.swift:56`:
  ```swift
  if NSRunningApplication(processIdentifier: app.pid)?.bundleIdentifier == bundleID {
  ```
- **Why it's a problem:** any transient failure of `NSRunningApplication(processIdentifier:)` to report a bundle id (very early launch, weird process wrappers) evicts a live target and — per F5's latch — ends the run with "quit or was replaced". Apps with a permanently nil bundle id cannot be picked (`targetableApps` compactMaps them out, `BackgroundPoster.swift:113-116`), so the steady-state case is covered; the transient case is not.
- **Direction:** distinguish `nil` (unknown) from mismatched-bundle (definitely dead).

---

## Cross-scope observations (for the poster/recipe agent — outside my strict scope, but decisive for the symptom)

### F9 — No delivery feedback anywhere: a systematically failing post is indistinguishable from success
- **Severity:** CRITICAL for diagnosability (not itself the delivery bug) · **Confidence:** certain about the seam, likely about the wrapper
- **Evidence:** `BackgroundPoster.swift:263-265`:
  ```swift
  nonisolated(unsafe) static var eventPoster: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }
  ```
  and `mouseEvent`/`click` return `nil`/`true` on *construction* success only (`BackgroundPoster.swift:394-405`): the worker counts a click whenever a window resolved — the post result is never checked, and the Swift `postToPid` overlay discards the `CGEventError` that the underlying `CGEventPostToPid` returns.
- **Why it matters:** the owner's symptom is "clicks never arrive" with **no error surfaced**. Whatever the actual root cause (the NX_COMMAND recipe's premise on this macOS build, the flag semantics, the posting path), this pipeline is structurally incapable of noticing it: `directClickOnce` returns `true`, `count` increments, and the UI reports a healthy run. Any root-cause hunt must add a delivery check first or it is debugging blind.

### F10 — `isActive` is only as right as the recipe's premise
- The NX_COMMAND bit (0x0010_0000, `BackgroundPoster.swift:166`) is applied solely on `frontmost == bundleID` (F3). `frontmostApplication` is a reasonable proxy for "app is active", but the aimed window being the app's **key window** is the property AppKit actually keys on; with multi-window apps the two diverge (target frontmost, aimed window = topmost non-key window → plain click still routes inside the app, so benign; but see F2 for where multi-window really bites). The flag logic itself belongs to the poster-scope agent; from the snapshot side the only defects are F3's staleness and this proxy nuance.

---

## Verified non-issues (hunt-list items checked and found sound)

These were specifically hunted and are **not** bugs; recorded so they are not re-hunted:

1. **Prewarm timing / cold snapshot:** `prewarm` is called in `begin()` on the main actor (`AutoClicker.swift:160`) **before** `WorkerThread.start` (`:162`), on every start path — button (after countdown), hotkey (no countdown, immediate `run` per `RunSession.start(withCountdown: false)`), and resume. The worker's first `verifyTarget` therefore always has a pid. The first batch cannot hit a cold snapshot from the prewarm side. (The countdown path can still see the app quit between `directAppProblem`'s toggle-time check and begin — handled: first miss → run stops with the quit warning, not silent.)
2. **Notification threads:** both `NSWorkspace` observers are registered with `queue: .main` (`TargetSnapshot.swift:35-38`), so `MainActor.assumeIsolated` inside is safe — the block is guaranteed on the main thread. The timer fires on the main run loop (scheduled from the `@MainActor` `start()`) and hops via `Task { @MainActor }` — also safe.
3. **Lock coverage / `nonisolated(unsafe)` fields:** every read and write of `_frontmostBundleID`, `_resolvedApps`, `_started` is under `lock` (verified all 8 access sites); all *mutations* additionally happen only on the main actor (`refreshFromMain`, `resolveFromMain`, `start` are all `@MainActor` and synchronous, so they cannot interleave). No lost-update race between `refreshFromMain`'s read-validate-write and `resolveFromMain`'s insert.
4. **Worker→main hops:** `targetState`'s not-found path uses an *async* `Task { @MainActor }`; nothing in scope ever blocks on main from a worker, so the `cancelAndWait` deadlock the class doc describes cannot recur through this file. `performOnMain` (`WorkerThread.swift:61-65`) is `DispatchQueue.main.async` — FIFO, non-blocking.
5. **Frontmost stop rule:** `FrontmostStopRule.changed` (`RunRules.swift:6-8) requires both samples non-nil, so the snapshot's nil-frontmost edge at launch can never spuriously stop a run.

---

## Bottom line for the orchestrator

In-scope, the certain defects are **F1** (negative-cache unwrap — perf/robustness, contradicts its own comment), **F4/F5/F6/F7/F8** (staleness and contract smells), and two symptom-relevant mechanisms: **F2** (multi-window targets get clicks aimed at the wrong window — plausible universal failure for apps like Safari/Finder) and **F3** (stale `isActive` drops clicks via the missing NX_COMMAND bit for a ~500 ms-or-worse window after every app switch). Neither F2 nor F3 is guaranteed universal. The single most important fact my scope contributes to the root-cause hunt is **F9**: the pipeline has no delivery feedback, so *whatever* the true root cause is, it was invisible by construction — and testing "did the event arrive in the target process?" must be added before any of these can be confirmed or excluded as the owner's actual failure.