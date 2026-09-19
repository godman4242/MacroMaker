# Adversarial review — `geometry` scope (ClickGeometry, Humanizer, directApp capture flow, coordinate conversions)

Scope: `Sources/MacroMaker/Utilities/ClickGeometry.swift`, `Sources/MacroMaker/Utilities/Humanizer.swift`,
the pick/countdown capture flow for `directAppX/Y` (`AutoClicker.swift`, `AutoClickerView.swift`, `TargetAppPicker.swift`),
and every coordinate conversion touching directApp mode (`BackgroundPoster.windowPoint`, `BackgroundPoster.appKitY`,
`BackgroundPoster.mouseEvent`, `EventSynthesizer.cursorLocation`).

Executive answer to the headline question first: **the capture space and the window-bounds space are consistent**
(top-left CG global on both sides — details under "Verified-consistent" below), so a plain flipped-capture-Y is NOT
the root cause. The plausible root causes inside this scope are the space `CGEventSetWindowLocation` expects
(H1), the silent nil path when the NSEvent-seeded conversion fails off the main thread (H3), and the fact that no
test anywhere validates the chain against a real window — the suite only proves the code agrees with itself.

---

## Findings

### H1. `CGEventSetWindowLocation` may expect bottom-left (AppKit window) Y — a mirrored window-local Y delivers every click at the vertically mirrored spot
- Severity: **HIGH** (candidate root cause of the "clicks never arrive" symptom)
- Evidence: `Sources/MacroMaker/Services/BackgroundPoster.swift:159-162`
  ```swift
  /// Screen point → window-local point (translate by the negative window origin).
  static func windowPoint(fromScreenPoint point: CGPoint, window: Window) -> CGPoint {
      CGPoint(x: point.x - window.bounds.origin.x, y: point.y - window.bounds.origin.y)
  }
  ```
  and `BackgroundPoster.swift:246`:
  ```swift
  windowLocationResolver.setWindowLocation(of: event, to: windowPoint(fromScreenPoint: screenPoint, window: window))
  ```
  `windowPoint` produces a **top-down** Y (0 at the window's top edge) because both the captured point
  (`CGEvent.location`) and `kCGWindowBounds` are in top-left CG global space. But a window's *own* coordinate
  system in AppKit — what `NSEvent.locationInWindow`, the field the target app actually hit-tests, is expressed
  in — has origin at the window's **bottom-left, Y up**. If the private setter stores the point in that space,
  every background click lands mirrored vertically inside the window (y → height − y). A user aiming at a
  toolbar/button near the window top delivers a click near the window bottom — dead space — which reads exactly
  as "clicks never arrive".
- Why it's a problem: nothing in the repo distinguishes the two spaces. `BackgroundPosterTests.swift:48-55`
  pins only the arithmetic ("A point before the window's origin is allowed to go negative"), and the seam test
  (`BackgroundPosterTests.swift:102-106`) records whatever point the code computes — both are self-consistency
  checks, not ground truth. The event's *global* location IS round-trip-verified
  (`BackgroundPosterTests.swift:75`, `event.location == screenPoint`), which is exactly why a wrong window-local
  space would be invisible to the suite while still mis-aiming every click.
- Confidence: **possible** (cannot be settled from code; the recipe comment cites external research but no
  empirical window-side verification exists in the repo).
- Direction: falsify empirically — one Test Click aimed at TextEdit's top ruler vs the bottom of the page
  settles which space the private symbol wants; also assert the window-local point against a real window once.

### H2. "Clicks move with the window" is false — the implementation pins clicks to the captured absolute screen point
- Severity: **HIGH** (certain logic defect; becomes CRITICAL for any user who moves/resizes the target window)
- Evidence: the UI promises re-anchoring — `Sources/MacroMaker/Views/AutoClickerView.swift:45`:
  ```swift
  Text("The point is remembered as a spot inside the app's window — if the window moves, clicks move with it.")
  ```
  and again `AutoClickerView.swift:196`: "…aimed at whichever of its windows is on top, **re-aimed if the window
  moves**". `Sources/MacroMaker/Services/AutoClicker.swift:486-488` repeats it: "captured in screen coordinates
  and re-anchored to the window's live bounds on every click".
  But what is stored is the fixed global point (`FeatureSettings.swift:41-45`: "the captured *screen* point"),
  and each click re-derives the local point as `L = S − O_live`
  (`AutoClicker.swift:398-400` → `BackgroundPoster.swift:161`). The on-screen landing spot of the click is
  therefore `O_live + L = S` — the **original** screen position, always. When the window moves by Δ, the
  delivered window-local point shifts by −Δ and the click lands Δ outside where the user aimed — the opposite
  of the promise. Once `S` falls outside the moved window's bounds, `windowPoint` yields a local point outside
  `[0,w]×[0,h]` and the app hit-tests nothing: clicks silently stop arriving, while `directClickOnce` still
  returns `true` and the run counts them (`AutoClicker.swift:401-405`).
- Why it's a problem: two defects in one — (1) documented behavior is the inverse of actual behavior;
  (2) the "clicks that reached the target" counter promise (`AutoClicker.swift:296-299`: "Undelivered click:
  never counted") is broken whenever the window moves: every click is counted as delivered regardless of where
  it lands.
- Confidence: **certain** for the geometry; **likely** that out-of-window locals get dropped by the target's
  hit-testing.
- Direction: store the window-local offset captured at pick time and reuse it (plus live origin for the global
  location), which is what "re-anchor" requires.

### H3. The conversion calls AppKit (`NSEvent.mouseEvent`, `NSScreen.screens`) on the worker thread; a nil there silently swallows every click
- Severity: **HIGH** (candidate root cause; total silent failure)
- Evidence: `BackgroundPoster.swift:232-239`:
  ```swift
  let appKitPoint = CGPoint(x: screenPoint.x,
                            y: appKitY(fromScreenY: screenPoint.y, screenFrames: NSScreen.screens.map(\.frame)))
  guard let nsType = nsEventType(type),
        let event = NSEvent.mouseEvent(with: nsType, location: appKitPoint, modifierFlags: [],
                                       ... pressure: button == .left ? 1 : 0)?.cgEvent
  else { return nil }
  ```
  This runs inside `directClickOnce` on the `WorkerThread` (`AutoClicker.swift:162-163`, `394-405`) — not the
  main thread. `NSScreen.screens` and `NSEvent.mouseEvent` are AppKit with no documented off-main guarantee.
  If either misbehaves off-main and `NSEvent.mouseEvent` returns `nil`, `mouseEvent` returns `nil`,
  `post(_ event: CGEvent?...)` guards it away (`BackgroundPoster.swift:265-266`: `guard let event else { return }`),
  and `click` posts nothing (`BackgroundPoster.swift:251-260`) — **no error, no warning, counter still
  increments** (`directClickOnce` returns `true` unconditionally at `AutoClicker.swift:405` after the window
  resolve). That is byte-for-byte the reported symptom: clicks never arrive, UI says everything is fine.
- Why it's a problem: fail-open on the one path whose entire purpose is delivery; the loud-UI contract
  (`directAppProblem`, `runWarning`) never sees it.
- Confidence: **possible** (whether NSEvent actually fails off-main on this build is unverified; the silent
  nil-handling itself is certain).
- Direction: capture `NSScreen.screens` (or just the flip constant) on main before the run starts, and make a
  nil event a reported failure instead of a swallow.

### H4. Capture flow never validates that the picked point lies inside any window of the chosen app
- Severity: **MEDIUM** (broken edge case likely to be hit; feeds the "not arriving" symptom)
- Evidence: `AutoClicker.swift:520-524`:
  ```swift
  case .directAppPoint:
      updated.directAppX = location.x.rounded()
      updated.directAppY = location.y.rounded()
      updated.target = .directApp
  ```
  No check that a target app is chosen, that it's running, or that the point is inside one of its windows.
  The status line then happily displays the resulting out-of-window local point as success —
  `AutoClicker.swift:420-422`:
  ```swift
  let point = BackgroundPoster.windowPoint(
      fromScreenPoint: CGPoint(x: settings.directAppX, y: settings.directAppY), window: window)
  return "Window \(Int(window.bounds.width))×\(Int(window.bounds.height)) — clicks land at (\(Int(point.x)), \(Int(point.y))) inside it."
  ```
  A negative or beyond-bounds `(x, y)` is printed as "inside it" with no warning. The user can pick a point
  over a *different* app entirely (or pick before choosing an app at all) and the settings show a plausible
  status while every click aims outside the window.
- Why it's a problem: the one flow whose entire job is "capture a good point" accepts bad input silently, and
  the one UI line whose job is "tell the truth about where clicks land" affirms it.
- Confidence: **certain** (validation absence); **likely** that out-of-window points are dropped by the target.
- Direction: at pick time, resolve the app's windows and reject/warn when the point is in none of them; flag
  out-of-bounds coordinates in `directAppStatus`.

### H5. Position jitter can push the click outside the window — unclamped, unvalidated, counted as delivered
- Severity: **MEDIUM**
- Evidence: `AutoClicker.swift:397-400`:
  ```swift
  let screenPoint = plan.positionJitterPx == 0 ? plan.directScreenPoint
      : ClickGeometry.jitter(plan.directScreenPoint, amount: plan.positionJitterPx,
                             u1: .random(in: 0...1), u2: .random(in: 0...1))
  ```
  with `jitterPx` user-configurable up to 200 (`AutoClickerView.swift:59-60`: `range: 0...200`). The jittered
  screen point is converted with the raw translate (`BackgroundPoster.swift:161`) — the unit test even pins
  that out-of-window results are allowed (`BackgroundPosterTests.swift:52-54`: "A point before the window's
  origin is allowed to go negative"). A user who enables "Vary the point by up to ± N px" (a control presented
  for the cursor/fixed modes, `AutoClickerView.swift:57-61`) gets some fraction of directApp clicks aimed
  outside the window — those clicks do nothing but still count.
- Why it's a problem: silent partial failure indistinguishable from the feature being broken; nothing clamps
  jitter to the window bounds, and `directClickOnce` returns `true` regardless of where the point landed.
- Confidence: **likely**.
- Direction: clamp the jittered point to the resolved window bounds (or its content inset) before posting.

### H6. Multiple windows: the pick captures over one window, delivery goes to the front-most window of the pid
- Severity: **MEDIUM**
- Evidence: the pick captures wherever the cursor is (`AutoClicker.swift:507`, `EventSynthesizer.cursorLocation`),
  but delivery resolves "the app's front-most usable window" — `BackgroundPoster.swift:54-56`:
  ```swift
  static func primaryWindow(ofPID pid: pid_t, in list: [[String: Any]]) -> Window? {
      list.lazy.compactMap { window(fromInfo: $0, ownerPID: pid) }.first
  }
  ```
  For an app with several layer-0 windows (Safari, Finder, Preview…), a user hovering a background window of
  the target app captures a point outside the front-most window's bounds; `windowPoint` yields an out-of-window
  local point and the click misses, with the status line still reporting "clicks land at (…) inside it"
  computed against that same wrong window.
- Why it's a problem: the capture flow and the delivery flow resolve windows by different rules; nothing checks
  they agree.
- Confidence: **likely** (certain that the two rules differ; likely that the mismatch drops clicks).
- Direction: at pick time record which window id was under the cursor, or resolve the window containing the
  captured point rather than the front-most one.

### H7. No test validates any part of the directApp coordinate chain against a real window — the suite proves only self-consistency
- Severity: **MEDIUM** (this is why the broken feature shipped green)
- Evidence: every relevant test asserts the code's own formulas — `BackgroundPosterTests.swift:48-55`
  (translate arithmetic), `:62-79` (fields set; `event.location == screenPoint` pins only the global flip),
  `:81-107` (the seam records the point the code computed), `:145-153` (the primary-flip choice). Nothing
  anywhere checks that a `CGEventSetWindowLocation` point, posted via `postToPid`, lands where a real app
  says it landed. Per the repo's own harness rule, a gate that can only echo its inputs cannot catch H1/H2.
- Why it's a problem: the feature's core delivery path has zero ground-truth coverage, and the verified
  facts the owner has (symbol present, tests green) are exactly the facts that cannot detect the failure.
- Confidence: **certain** (about the coverage gap).
- Direction: one end-to-end assertion against a real test-host window (posted point vs. app-reported
  `locationInWindow`) would have caught H1 and H2.

### H8. `setWindowLocation`'s return value is ignored — a false at runtime posts a mis-aimed click while the UI reports "supported"
- Severity: **LOW**
- Evidence: `BackgroundPoster.swift:246` — the `@discardableResult` Bool is dropped:
  ```swift
  windowLocationResolver.setWindowLocation(of: event, to: windowPoint(fromScreenPoint: screenPoint, window: window))
  ```
  `targetingSupported` gates availability up front (`AutoClicker.swift:38-40`), so a runtime `false` "can't
  happen" — but if it ever did, the event posts with only a global location and no window-local aim, silently.
- Confidence: **certain** (the ignore); **unlikely** to fire in practice.
- Direction: fail the click (return `false`) when the setter reports false.

### H9. `EventSynthesizer.cursorLocation` falls back to `.zero` — a failed probe captures the pick at the main display's top-left corner
- Severity: **LOW**
- Evidence: `EventSynthesizer.swift:16-18`:
  ```swift
  static var cursorLocation: CGPoint {
      CGEvent(source: nil)?.location ?? .zero
  }
  ```
  `completePick` (`AutoClicker.swift:507`) stores whatever this returns, rounded, into `directAppX/Y`
  (`:521-522`) with no sanity check; a nil probe silently sets the click point to global (0,0) — outside
  virtually every window.
- Confidence: **possible** (nil is rare); the silent-zero handling is certain.
- Direction: fail the pick loudly if the probe returns nil.

### H10. `WindowResolver`'s 300 ms cache serves stale window bounds after a move
- Severity: **LOW**
- Evidence: `BackgroundPoster.swift:72-96` — window identity/bounds are cached for 300 ms including for
  occluded windows. Combined with H2's math, a window moved within the last 300 ms gets clicks computed from
  its old origin, landing offset by exactly the move delta.
- Confidence: **certain** (staleness window); minor in effect.
- Direction: invalidate on bounds change or re-read bounds on hit-failure.

### H11. Multi-display note on `appKitY`: the flip constant is right, but the "measured" evidence doesn't cover the case the comment says it fixed
- Severity: **LOW**
- Evidence: `BackgroundPoster.swift:226-228`:
  ```swift
  static func appKitY(fromScreenY y: CGFloat, screenFrames: [CGRect]) -> CGFloat {
      (screenFrames.first?.maxY ?? 0) - y
  }
  ```
  Flipping about the primary's height is the mathematically correct global conversion (both CG and AppKit
  global spaces are anchored at the primary's origin, so a screen *above* has negative CG Y / AppKit Y > h,
  and the primary-height flip maps both correctly) — the earlier union-based flip would have been wrong. But
  the comment's justification ("measured directly: on a 1920x1080 primary, appKitY + cgY == 1080.0 for every
  input") was measured on a single-display layout, where primary and union coincide — the measurement cannot
  distinguish the two, and no test pins `NSEvent.cgEvent`'s flip with a display above the primary
  (`BackgroundPosterTests.swift:145-153` tests the pure function, not NSEvent).
- Why it matters: if NSEvent's actual flip is per-screen or union-based on multi-display builds, the pre-flip
  here offsets every secondary-display click. Given the geometry of the two spaces the current choice is
  right, but it rests on argument, not the cited measurement.
- Confidence: **possible** (only for multi-display layouts with screens above/below the primary).
- Direction: one dlsym probe or unit test on a two-display layout would pin NSEvent's flip constant for real.

---

## Verified-consistent (explicitly checked, no defect found)

- **Capture space:** `directAppX/Y` is captured from `CGEvent.location` (`EventSynthesizer.swift:16-18`,
  `AutoClicker.swift:507`) — top-left CG global. `kCGWindowBounds` (`BackgroundPoster.swift:44-48`) are the
  same space, so `windowPoint`'s negative-origin translate is the right *space* on every display, primary or
  secondary. A flipped or wrong-origin capture Y is **not** the bug.
- **Event global location:** the NSEvent-seeded flip round-trips on the primary (`BackgroundPosterTests.swift:75`),
  so the posted event's global location equals the captured screen point.
- **Fixed-point and region modes:** capture (`AutoClicker.swift:510-519`, CG top-left) and delivery
  (`EventSynthesizer.click` → `CGEvent(mouseEventSource:mouseCursorPosition:)`, same space) are consistent,
  including negative coordinates on displays left of/above the primary; `ClickRegion(corner1:corner2:)`
  (`ClickRegion.swift:19-24`) normalizes correctly.
- **ClickGeometry:** `randomPoint` clamps uniforms inside the rect (`ClickGeometry.swift:7-10`); `jitter` maps
  uniforms to ±amount inclusive (`:13-18`); no out-of-range output is possible from the math itself.
- **Humanizer:** purely temporal — no spatial component; `boxMuller`'s `log(0)` is guarded
  (`Humanizer.swift:47`), gaussian offset clamped to ±3σ (`:51-53`), delays floored (`:71-75`). It cannot
  displace a click; only `positionJitterPx` does (see H5).
- **`TargetAppPicker.swift`** touches no coordinates; its only defect is a stale list, out of scope.

## Root-cause ranking for the owner's symptom (clicks never arrive)

1. **H3** — nil NSEvent off-main → silently swallowed posts (total failure, zero diagnostics). Possible.
2. **H1** — wrong Y space expected by `CGEventSetWindowLocation` → mirrored clicks into dead space. Possible.
3. **H2/H4/H5/H6** — real defects, but each requires the user to have moved the window, picked a bad point,
   enabled jitter, or targeted a multi-window app; they amplify and mimic the symptom rather than explain a
   from-the-first-click total failure.

The single most valuable next measurement: one **Test Click** into a TextEdit window with the click aimed near
the window's top, observed against where the caret/scroll actually reacts — it discriminates H1 vs H3 vs
flag-space causes in one shot, and no amount of further code reading can.