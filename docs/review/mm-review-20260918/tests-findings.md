# Adversarial review — agent `tests` (Tests/MacroMakerTests/)

Scope: all 15 files under `Tests/MacroMakerTests/` (2,008 lines), read against the direct-app
delivery code they nominally cover (`BackgroundPoster`, `AutoClicker` direct branch,
`TargetSnapshot`, `EventSynthesizer`).

## Headline verdict

**Yes — the suite passes green with background clicking completely broken.** This is the central
finding. Every test that touches delivery runs against the `eventPoster` fake or a pure helper; the
real path (`NSEvent.mouseEvent` → field writes → `setSource` → `CGEventPostToPid`) is never executed
against a real process, and no test anywhere observes an event *arriving* in a target app. The
owner's symptom (clicks never arrive, symbol confirmed present) lives entirely inside the gap this
suite cannot see. Deleting the `CGEventPostToPid` call — or WindowServer silently dropping every
event these fields produce on macOS 26 — leaves 100% of `BackgroundPosterTests` green (confidence:
certain).

---

## Findings

### T-1. CRITICAL — The delivery path is green-by-construction; zero tests exercise real posting
**Evidence:** `BackgroundPoster.swift:263` — `nonisolated(unsafe) static var eventPoster: (CGEvent, pid_t) -> Void = { $0.postToPid($1) }`; every delivery test swaps it: `BackgroundPosterTests.swift:118` (`BackgroundPoster.eventPoster = { event, _ in box.events.append(event) }`), `:170`, `:188`. No test calls `testClick()`, `AutoClicker.toggle`, or any path with the default poster installed.
**Why it's a problem:** the seam was added for testability, but no test ever crosses it. The
feature that is broken in the field is exactly the code the suite never runs. The suite proves the
*fakes* behave, not the app.
**Confidence:** certain.
**Direction:** one integration test that posts to a real helper process (the repo already runs
real-appleScript and JavaScriptCore integration tests — `BrowserScriptingTests`, `WebClickScriptTests` — so the capability exists).

### T-2. HIGH — The ⌘-flag bypass (the load-bearing delivery trick) has no end-to-end assertion
**Evidence:** pure-function test only — `BackgroundPosterTests.swift:57-60`:
```swift
#expect(BackgroundPoster.clickFlags(appIsActive: false) == CGEventFlags(rawValue: 0x0010_0000))
```
The wiring is at `BackgroundPoster.swift:269` — `event.flags = clickFlags(appIsActive: appIsActive).union(.maskNonCoalesced)` — inside `post()`, which is only ever invoked in tests through the fake. No test asserts a *captured posted event's* `.flags` contain `maskCommand` when `appIsActive: false`.
**Why it's a problem:** delete the line at `BackgroundPoster.swift:269` and every test stays green — and clicks get dropped by AppKit's background filter, which is precisely the reported symptom ("clicks never arrive"). The one trick the recipe says is mandatory for delivery is the one nobody asserts on the posted event.
**Confidence:** certain (about the missing assertion; the flag rule itself is unverified — see T-3).
**Direction:** assert `.flags` on the events captured by the `eventPoster` fake for both active and inactive targets.

### T-3. MEDIUM — Tests are circular on the recipe's magic constants, so they cannot catch a wrong recipe
**Evidence:** `BackgroundPosterTests.swift:70-74`:
```swift
#expect(event.getIntegerValueField(.mouseEventButtonNumber) == CGMouseButton.left.rawValue)
#expect(event.getIntegerValueField(.mouseEventSubtype) == 3)
#expect(event.getIntegerValueField(CGEventField(rawValue: 91)!) == 4242)
#expect(event.getIntegerValueField(CGEventField(rawValue: 92)!) == 4242)
```
Each asserts the code wrote the value the code writes (`mouseEvent` sets exactly these at `BackgroundPoster.swift:241-245`). Likewise the "12 auto-filled fields" assumption — the entire reason the recipe routes through `NSEvent.mouseEvent` — is asserted nowhere; it is stated as an article of faith in a comment (`BackgroundPosterTests.swift:76-78`), and `BackgroundPoster.protectedFields` (`BackgroundPoster.swift:32`) is a declared constant that no code path reads and no test checks.
**Why it's a problem:** if field numbers 91/92 or subtype 3 mean something else on macOS 26 (Tahoe), or `NSEvent.mouseEvent(...).cgEvent` no longer populates fields 0/1/2/41/…, WindowServer misroutes or drops every event — and this suite cannot notice, because it validates internal consistency, not semantics. Given the verified fact that the symbol is present, the recipe constants themselves are the prime suspects, and they are exactly what unit tests cannot validate.
**Confidence:** certain that the assertions are circular; possible that the constants are wrong (only an integration test can settle it).
**Direction:** assert the 12 protected fields are non-zero after `NSEvent.mouseEvent(...).cgEvent`, and add the arrival test from T-1.

### T-4. HIGH — `postedClicksCarryNoSharedSourceState` certifies the shared HID state as "private"
**Evidence:** `BackgroundPosterTests.swift:124-127`:
```swift
for event in box.events {
    #expect(event.getIntegerValueField(.eventSourceStateID) != 0,
            "background clicks must post from a private event source, not the shared HID state")
```
against `BackgroundPoster.swift:276` — `let fresh = CGEventSource(stateID: .hidSystemState)`. `.hidSystemState` (stateID 1) **is** the shared HID system state; the code only creates a fresh source *object* wrapping it. The assertion `!= 0` merely rules out `combinedSessionState` — it cannot distinguish the shared HID state from a genuinely private source, so the regression the test name and comment claim to guard (cumulative modifier/button state wedging ⌘ as held) is not actually guarded. If posting through `hidSystemState` sources still pollutes or mis-stamps state — a live suspect for the delivery symptom, since the system HID state is shared with real input — this test passes anyway.
**Why it's a problem:** the test encodes a wrong expected behavior: "stateID != 0" is treated as proof of isolation when it proves no such thing.
**Confidence:** certain about the assertion being unable to verify the claim; likely that the "private source" comment does not match what the code does.
**Direction:** either post from a source whose state ID is the private one and assert that exact value, or re-word the test to assert what is actually claimed.

### T-5. HIGH — No test asserts the pid, the event types, or the down/up ordering of posted events
**Evidence:** every `eventPoster` fake discards the pid — `BackgroundPosterTests.swift:118` (`{ event, _ in box.events.append(event) }`), `:170-172`, `:188-190`. The click-path tests assert only `count == 2` (`:123`), tags (`:177-179`), and stateID (`:125`). No test asserts the first captured event is `.leftMouseDown` and the second `.leftMouseUp`, that both carry the same window id, or that the pid is the one passed to `click(...)`.
**Why it's a problem:** `post()` sending events to the wrong pid, posting two downs, or reversing down/up — each a total delivery failure — leaves the suite green. `mouseEventCarriesTheRecipeFields` checks field values on a single hand-built `.leftMouseDown` event, never on the pair `click()` actually produces.
**Confidence:** certain.
**Direction:** assert (type, window id, pid) per captured event, in order.

### T-6. MEDIUM — `ClickerParityTests` proves a spec-checklist, not any parity
**Evidence:** the file (`ClickerParityTests.swift:1-250`) contains `IntervalUnitTests`, `ClickRateTests`, `ClickGeometryTests`, `RunRulesTests`, `AutoClickerSettingsTests`, `HotkeyActionTests`, `RunTimeBudgetTests` — exactly the Stage-A test list in `docs/V2_SPEC.md` ("interval-unit conversion, burst counting, click-count mapping, region random point generation, frontmost-change stop predicate, delayed-start total").
**Why it's a problem:** the name reads as behavioral parity (direct-app path vs HID path, or app vs reference implementation); what it actually proves is that a list of pure helpers each have a test. No test anywhere compares the direct-app click's event shape against the HID click's (`EventSynthesizer`), which is the parity that would catch a direct-app divergence — and the file's presence makes the clicker look "parity tested" when the delivery path has none. Also note `EventSynthesizer` has zero direct tests (it appears only incidentally via `eventTag`).
**Confidence:** certain.
**Direction:** rename, or add an actual parity test asserting the direct-app down/up pair matches the HID pair on (type, button, clickState) apart from the targeting fields.

### T-7. HIGH — The entire direct-app orchestration has zero tests
**Evidence (all untested, verified by grep over `Tests/` — no references):**
- `AutoClicker.clickLoop` direct branch — `AutoClicker.swift:279-302` (dead/alive dispatch, undelivered-click warning, `direct = directRun` re-assignment between burst iterations).
- `DirectRun.verifyTarget` pid-reuse guard — `AutoClicker.swift:348-358`.
- `BackgroundPoster.WindowResolver` TTL cache — `BackgroundPoster.swift:72-96`, **including the negative-cache branch** (`lastWindow` stores a miss, `:88`'s `let window = lastWindow` returns `.some(nil)`): a run started while the window is momentarily unresolvable silently emits the "window not found" warning for up to 300 ms windows of clicks, and no test pins that as intended.
- `TargetSnapshot` — cold-start path `TargetSnapshot.swift:82-85` returns `(pid: nil, isActive: false)` and only schedules an *asynchronous* re-resolve. The run's `prewarm` (`AutoClicker.swift:160`) does populate the cache synchronously (it calls `resolveFromMain` directly, `TargetSnapshot.swift:91-93`), so the pid race is mitigated — but nothing tests that mitigation, nor that `isActive` (derived from `_frontmostBundleID`, nil until the first `refreshFromMain`, `TargetSnapshot.swift:61`) doesn't force the ⌘ bit onto clicks at an app that is actually active. `TargetSnapshot` has zero test references.
- `resolveWindowLive` occlusion fallback (`BackgroundPoster.swift:59-65`), `directAppProblem` gating (`AutoClicker.swift:36-46`), `directAppStatus` (`:411-423`), `testClick` (`:426-442`).
**Why it's a problem:** every one of these sits between "user picked an app" and "click arrives"; the feature is broken somewhere in that chain and the chain is dark.
**Confidence:** certain (about absence of tests); the cold-`isActive` mis-flag is possible as a real bug, not proven.
**Direction:** extract `DirectRun`/`WindowResolver` decision logic into injectable-clock pure functions like the suite already does elsewhere.

### T-8. MEDIUM — `mouseEvent` ignores a failing `setWindowLocation`; no test covers the per-event failure path
**Evidence:** `BackgroundPoster.swift:246` — `windowLocationResolver.setWindowLocation(of: event, to: ...)` — result discarded (`@discardableResult` protocol method, `BackgroundPoster.swift:131`). The seam test only exercises `return isAvailable` as a flag (`BackgroundPosterTests.swift:86-89`); no test builds an event through a resolver whose `setWindowLocation` returns `false` and asserts what happens (today: the event is still built and posted with only fields 91/92 — a half-targeted click that WindowServer may drop or misroute, with no warning anywhere).
**Why it's a problem:** the UI gate (`targetingSupported`) checks availability once at startup, but per-event failure is fail-open — and the test suite pins the fail-open behavior by omission.
**Confidence:** certain.
**Direction:** decide and pin: either `mouseEvent` returns nil when the window location can't be set, or the failure is surfaced in the run warning.

### T-9. LOW/`possible` — Out-of-window aiming is pinned as intended behavior
**Evidence:** `BackgroundPosterTests.swift:52-54`:
```swift
// A point before the window's origin is allowed to go negative: the recipe is a raw translate.
#expect(BackgroundPoster.windowPoint(fromScreenPoint: CGPoint(x: 50, y: 150), window: window)
        == CGPoint(x: -50, y: -50))
```
combined with editable unclamped point fields (`AutoClickerView.swift:179-180`, range −20000…20000) and `directAppStatus` happily reporting "clicks land at (−50, −50) inside it" (`AutoClicker.swift:420-422`).
**Why it's a problem:** the picked point is stored in *screen* space and re-anchored per click; if the window moves (or the user typed a stale coordinate), every click is aimed outside the target window. If WindowServer/AppKit discards events whose window-local point is outside the window's bounds, this pinned "raw translate" behavior is itself a delivery killer for moved windows — a very common real-world case for "click in a specific app."
**Confidence:** possible (behavior is pinned deliberately; whether it breaks delivery is unverified).
**Direction:** an integration test clicking a moved window, or clamp-and-warn.

### T-10. LOW — `mouseEventCarriesTheRecipeFields` is machine-coupled
**Evidence:** `BackgroundPosterTests.swift:75` — `#expect(event.location == screenPoint)` — holds only when `NSScreen.screens.first?.maxY` equals NSEvent's internal flip constant on the test machine (`BackgroundPoster.swift:226-233` reads live `NSScreen.screens`). On a headless CI host (the `appKitY` fallback is `0 - y`, `BackgroundPoster.swift:227`), the round-trip assertion's meaning changes or fails.
**Why it's a problem:** the single assertion that touches NSEvent's real output is environment-dependent; the suite cannot be trusted as CI evidence for the one non-circular claim it makes.
**Confidence:** likely.
**Direction:** inject screen frames into `mouseEvent` (like `appKitY` already accepts) instead of reading `NSScreen` inside it.

### T-11. LOW — `noScreensYieldsAFiniteNumber` pins "finite", not "sane"
**Evidence:** `BackgroundPosterTests.swift:157-159` asserts only `isFinite`. With no screens the code flips about `0` (`BackgroundPoster.swift:227`), silently mirroring every Y — clicks land at `(x, −y)`-derived coordinates rather than failing loudly, and the test blesses it.
**Confidence:** certain (about what is asserted).
**Direction:** pin the intended fallback explicitly or make no-screens a loud failure.

---

## Missing-test inventory for the direct-app path (hunt item 4, consolidated)

| Path | Coverage |
|---|---|
| Pick flow (`beginPick`/`completePick(.directAppPoint)`, `AutoClicker.swift:492-528`) | none — including that the pick stores `cursorLocation` (top-left CG space) into `directAppX/Y` and flips `target = .directApp` |
| Screen → window-local conversion *composition* (settings point → jitter → `mouseEvent` → resolver point) | unit pieces only; the composition is never asserted end-to-end |
| Snapshot cold-start / prewarm race | none (`TargetSnapshot` has zero test references) |
| Window-resolution failure → uncounted click + warning | none |
| `WindowResolver` TTL incl. negative caching | none |
| `DirectRun.verifyTarget` dead/alive/pid-reuse | none |
| `directAppProblem` gating + `toggle` beep-and-refuse path | none |
| `testClick` result strings | none |
| Real delivery (`postToPid`) to any process | none — T-1 |

## Answers to the specific hunt questions

- **Do the tests only exercise the fakes?** Yes. `eventPoster` and `windowLocationResolver` are swapped in every delivery test; the default `postToPid` poster and the real `CGEventSetWindowLocation` symbol are never on a code path that a test asserts through.
- **Do BackgroundPosterTests validate the field values a real WindowServer needs?** Only on one hand-built `.leftMouseDown` event (`:62-79`), and those assertions are circular (T-3). The down/up pair produced by `click()` is never field-checked (T-5), and the ⌘ flag is never checked on a posted event (T-2).
- **What does `ClickerParityTests` actually prove?** That the V2_SPEC Stage-A checklist of pure helpers each has a test. It establishes no parity between the direct-app and HID click paths and no behavioral equivalence of any kind (T-6).
- **Would the suite pass if background clicking were completely broken?** **Yes, with every test green** (T-1). The one machine-level fact this report can state with certainty: nothing in `Tests/MacroMakerTests/` can fail because of a delivery defect.