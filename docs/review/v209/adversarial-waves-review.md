# Adversarial review — the four v2.0.9 fix waves

Reviewed hostile, 2026-09-19. Scope: commits 043fc50 (w1), d749cb6 (w2), 7f13767 (w3), 2e5a100 (w4) —
diff `bdc0289..2e5a100` (docs/review/v209/full-v209.diff). Everything below was verified against the
CURRENT tree, not the diff text. The original findings in docs/review/mm-review-20260918/*.md are the
spec; each required one is graded at the end. Read-only review: no source files were touched.

**Test run (hunt 9):** `./scripts/test.sh` → **213 tests, 40 suites, exit 0**. The "0 warnings" claim
verified: every case-insensitive "warning" hit in the full output is a test *name* (14 lines, all
`◇/✔ …Warning…` pass lines); zero compiler or runtime warnings.

## Verdict up front

**SHIP-WITH-FOLLOWUPS.** No HIGH findings. The four waves genuinely fixed what they claim; the
lifecycle (stop-path) wave is complete and well-tested. What remains is (a) one half-finished
fix — `cancelAndWait`'s fail-open was patched in AutoClicker only, KeyPresser and MacroPlayer still
ship the exact bug — (b) one edge where the W2 window fix + W2 clamp *together* turn a previously
dropped click into a deterministically wrong-window click, and (c) the already-known runtime A/B
items (subtype 3, Y direction, re-anchoring), which are the owner's manual job and were never claimed
as code fixes.

---

## New / residual findings (ranked)

### N1. MED — `cancelAndWait` fail-open survived the fix in two of its three call sites
**Confidence:** HIGH (code, both lines read this session)
**Evidence:** `Sources/MacroMaker/Services/KeyPresser.swift:86` and `Sources/MacroMaker/Services/MacroPlayer.swift:64`
both read `return { worker.cancelAndWait() }` — the timeout result discarded, Stop fail-open, main
thread blocked up to 1 s per session. W1 wired `cancelAndWait(onOverrun:)` with the retry-once-off-main
machinery in **AutoClicker only**. This is lifecycle F3 (and player-recorder #8) verbatim, still live
in the other two services.
**Why it matters:** it's the finding the wave claimed to fix, surviving in two products a user runs
concurrently (a key presser + a macro replay both stopping = up to 2 s of frozen UI, and a hung worker
never surfaces).
**Direction:** lift AutoClicker's `begin()`-closure pattern (retry once off-main, then
`cancelAndWait(onOverrun:)`) into a shared helper on WorkerThread or a small extension, so the third
call site can't silently regress. Two-line change per site plus the shared helper; a seam test per
service mirroring `aStopThatOutrunsItsBudgetSurfacesAWarning`.

### N2. MED — on-screen-first window listing + the new clamp = deterministic wrong-window click
**Confidence:** HIGH on the mechanism (code path traced); the trigger needs a multi-window app whose
picked window is off-screen.
**Evidence:** `BackgroundPoster.swift:68-74` — `resolveWindowLive` iterates
`[.optionOnScreenOnly, .optionAll]` and **returns from the first listing that yields any window**.
`window(ofPID:in:containing:)` (:62-66) checks containment *within that listing*; if no on-screen
window contains the point it falls back to `windows.first` — the app's first-listed **on-screen**
window. So when the picked window is minimized or on another Space and the app has another visible
window, the `.optionAll` listing (which *would* contain-match the picked window) never runs, and the
click is aimed at the wrong window. `AutoClicker.swift:433-434` then **clamps the picked point into
that wrong window's bounds** (the H5 fix).
**Why it matters:** pre-W2 this scenario produced a click aimed at a point outside the target window —
likely a miss. Post-W2 the clamp guarantees it lands *inside a window the user didn't pick*. The fix
pair converted a dropped click into a silently delivered wrong-window click — the worst failure mode
for a clicker, because it looks like success.
**Direction:** in `resolveWindowLive`, don't early-return from a listing that produced no
*containment* hit when a point was supplied — fall through to `.optionAll` before accepting the
front-most fallback (the `.optionAll` fallback at :80 already exists for the zero-window case). One
condition, plus a test with a seeded two-listing seam (on-screen list = one window not containing the
point; all-windows list = the containing one).

### N3. MED-LOW — `event.flags` is still written before `setSource`, violating the file's own measured rule
**Confidence:** MEDIUM (ordering is code-verified; whether setSource actually rewrites flags is unmeasured)
**Evidence:** `BackgroundPoster.swift:349` `event.flags = .maskNonCoalesced` precedes `event.setSource(fresh)`
at :358. The comment block at :359-363 states the rule: "setSource resets source-owned per-event data …
one proven wipe is enough to put everything delivery depends on … on the safe side of the call." The
W2 fix moved subtype, fields 91/92, windowLocation and the self-tag after setSource (:364-374) —
flags, the one remaining delivery-visible field, stayed on the unsafe side. (The builder's windowNumber
seed is also pre-setSource, but :366-367 re-assert the window id after, so that one is covered.)
**Why it matters:** if setSource re-homes flags from the fresh source's current state (analogous to the
measured `.eventSourceUserData` wipe), a user holding modifiers while a background click posts could get
a modifier-riding click — and the existing seam test asserts `flags == .maskNonCoalesced` only in a
no-held-modifiers process, so it cannot catch this.
**Direction:** move the flags write to the after-setSource block (one line), or measure whether setSource
preserves flags and pin that with a test run under held modifiers. Given the file's own standard, moving
the line is the cheaper closure.

### N4. LOW — models F3's other half is unfixed: a corrupt region still resets the entire clicker settings
**Confidence:** HIGH
**Evidence:** `Sources/MacroMaker/Models/ClickRegion.swift` still has strict synthesized Codable (no
custom `init(from:)`), and `Persistence.load` is still a silent `try?` — so a type-mismatched value inside
one region (or in `WebTargetSettings`) throws through `decodeIfPresent` at the settings level and resets
the WHOLE `AutoClickerSettings` blob to defaults, silently. The W3 tolerance work made *sibling* entries
tolerant (profiles, hotkeys) but the nested-strict-type hole F3 named is open for the settings family.
**Why it matters:** a single corrupt region from a hand-edited defaults file silently wipes every other
setting — permanent, invisible data loss, the same shape as models F1.
**Direction:** a `clamped()`-style custom `init(from:)` for ClickRegion (and the WebTargetSettings
nested types), tolerating per-field failures the way `HotkeyAction.storedCombos` now does.

### N5. LOW — persistence fail-loud has two logged-only stragglers and one stale-error path
**Confidence:** HIGH
**Evidence:**
- `HotkeyService.swift:155` — `Persistence.save(stored, key: Self.storageKey)` discards the Bool; a
  failed hotkey write is invisible to the user (models F8 residual; the save channel exists, nothing
  consumes it here).
- `MacroLibrary.swift:109` — `try? FileManager.default.removeItem(...)` in `delete`: an undeletable
  record folder is silent (index and disk then disagree about storage footprint; the record is already
  gone from the index, so it's noise-level, but it's the same fail-open shape).
- `ProfileService.persist()` (ProfileService.swift:112-117) sets `lastError` on failure but never
  clears it on a later success — `lastError = nil` exists only in `exportWithPanel` (:135). A stale
  "Couldn't save your profiles" can outlive a successful save.
**Direction:** consume the save Bool in HotkeyService (surface via the existing error/warning channel
the other services use); log-or-warn on the removeItem failure; clear `lastError` inside `persist()` on
the success path.

### N6. LOW — tolerant hotkey decode can desync the stream and swallow a neighbour combo
**Confidence:** MEDIUM
**Evidence:** `HotkeyAction.storedCombos(from:)` decodes `let name = try? u.decode(String.self)` inside
an unkeyed container. If the *name* fails to decode, `try?` returns nil but the container's index has
already advanced past the failed element — the subsequent decodes read the NEXT combo's fields as this
one's, so one corrupt entry can swallow its neighbour instead of only itself.
**Why it matters:** tolerance was the point of the fix (models F11); a fix that can eat a healthy
sibling under one corruption shape is a weaker version of the same bug.
**Direction:** decode the whole entry into a temporary keyed container first, or `catch` at the entry
level and `break` to skip the remainder — a torn unkeyed stream can't be reliably re-synced mid-array;
stopping at the tear is the honest limit (document it).

### N7. LOW — three decoded Ints are still unbounded
**Confidence:** HIGH
**Evidence:** `maxClicks`, `burstSize` and playback `repeatCount` decode as plain `Int` with no clamp;
the W3 `clamped()` helper covers Doubles only, and the UI Steppers max at 10,000,000 / 10,000. A crafted
defaults blob with `Int.max` values flows into counters/loops unchecked. No trap was found on these
paths (they feed comparisons, not UInt64 conversions), hence LOW — it's range-hygiene, not a crash.
**Direction:** clamp at decode like the Doubles, or document why these three are safe unbounded.

### N8. LOW — the `stamp == 0` arrival fallback is untested
**Confidence:** HIGH
**Evidence:** `MacroRecorder.swift:110-113` — the timestamp conversion's unstamped-event branch
(`stamp > 0 ? … : arrival-time fallback`) has no test; the recorder tests drive stamped TapEvents only.
The branch is one line and the surrounding arithmetic is tested, so this is a coverage note, not a
suspected bug.
**Direction:** one test injecting a TapEvent with `timestampNanos == 0`.

### N9. NOTE — the runtime-verification bets are still open (known, deferred, correctly labelled)
Not re-litigated here — they are the owner's manual job per project memory: bg-poster F3/H2
(no re-anchoring; clicks don't follow a moved window, and stale-bounds clicks now land at the cached
window's edge via the clamp), F7/H1 (the launch round-trip validates *storage*, not top-down-vs-bottom-up
Y — only a real Test Click can), F9 (subtype 3, runtime A/B pending), and F4 (fake-⌘ removal is a
deliberate bet that F1's windowNumber seeding is the real delivery fix). Until the runtime A/B runs,
"directApp works" remains unproven end-to-end; the code now fails loud when it can't aim, which is the
right posture for that uncertainty.

---

## VERIFIED-FIXED — every required original finding, graded

### lifecycle (mm-review-20260918/lifecycle-findings.md)
| Finding | Verdict | Evidence |
|---|---|---|
| F1 — panic-stop/hold-release bypass endRun → watcher leak, assert crash | **actually fixed** | Every stop path funnels `session.stop()` (AutoClicker.swift:116 toggle, :522 hold-release, :534 hotkey-reassigned; AppModel stopAll/applyProfile/shutdown) → `onStop` (AutoClicker.swift:64) → `tearDownRun` (:147). RunSession.swift:47/57 fires the hook only when `wasActive`. Tests: `stopEverythingRemovesThePauseWatcherAndTheNextRunStartsClean`, `stoppingAnActiveSessionRunsTheStopHookOnce` — both pass. |
| F3 — `cancelAndWait` timeout discarded; fail-open; blocks main 1 s | **partially fixed** | AutoClicker's cancel closure retries once off-main and uses `cancelAndWait(onOverrun:)` (surfacing `runWarning`); test `aStopThatOutrunsItsBudgetSurfacesAWarning` passes. **KeyPresser.swift:86 and MacroPlayer.swift:64 still discard it** — see N1. |
| F6 — stale natural-finish report resurrects `runWarning` | **actually fixed** | `tearDownRun` bumps `runID`; `handleWorkerReport` (AutoClicker.swift:198) guards `runID == run`. Test `aFinishReportQueuedBeforeAStopResurrectsNothingAfterIt` passes. |

### bg-poster (bg-poster-report.md)
| Finding | Verdict | Evidence |
|---|---|---|
| F1 — `windowNumber: 0`, event never names a window | **fixed (code)** | Window id seeded via the NSEvent builder (BackgroundPoster.swift:310-311) and re-asserted in fields 91/92 after setSource (:366-367). Runtime verification still owed (N9). |
| F2 — setSource after every delivery-critical write | **partially fixed** | Subtype/91/92/windowLocation/self-tag moved after setSource (:364-374); `flags` remains before it (:349 vs :358) — N3. |
| F3 — global vs window-local point contradict on window move | **not fixed** (deferred) | No re-anchoring; clamp now pins stale-bounds clicks to the cached window's edge. N9. |
| F4 — fake ⌘ visible to the target app | **fixed (code)** | `NX_COMMANDMASK` gone; `event.flags = .maskNonCoalesced` only (:349). A bet on F1 — runtime A/B owed (N9). |
| F5 — nil `NSEvent.mouseEvent` silently counted as delivered | **actually fixed** | `mouseEvent` returns nil → `post` logs (`targetingLog.warning`) and returns false → `click` not counted (:342-346). Test `anUndeliverableClickSurfacesAWarningInsteadOfCounting` passes. |
| F6 — front-most window, never the containing one | **partially fixed** | Containment preference added (`window(ofPID:in:containing:)`, :62-66) — but the on-screen-first short-circuit still delivers to a wrong window when the picked one is off-screen — N2. |
| F7 — top-down Y fed to the private API, direction never verified | **partially fixed** | `validateWindowTargeting` round-trips set→get at launch (validates storage, NOT the Y direction); `setWindowLocation` false now fails loud (:368-371). The direction question needs a runtime Test Click — N9. |
| F8 — AppKit (`NSEvent.mouseEvent`, `NSScreen.screens`) on the worker thread | **not fixed** | `mouseEvent()` (:302-311) is nonisolated and calls both on the caller's (worker) thread, unchanged from the original finding. |
| F9 — subtype 3 is not a public mouse subtype | **not fixed** (deferred) | `event.setIntegerValueField(.mouseEventSubtype, value: 3)` (:364). Runtime A/B pending — N9. |
| F14 — private symbol `unsafeBitCast`-ed with no validation | **actually fixed** | Launch-time symbol presence + set→get round-trip; missing symbol disables targeting with a user-visible reason. Test `missingSymbolDisablesTargetingWithAWarning` passes. |

### geometry (geometry-report.md)
| Finding | Verdict | Evidence |
|---|---|---|
| H1 — mirrored Y delivers every click at the mirrored spot | **not fixed** (as a *verification*) | Same as F7: the gate validates storage, not direction — it structurally cannot catch mirroring. N9. |
| H4 — capture never validates the point lies in a window of the app | **actually fixed** | Pick validates against all the app's windows (`resolveWindowsLive`, AutoClicker.swift:470/593 `pickWarning`); out-of-window picks are refused with a reason, not silently aimed. |
| H8 — `setWindowLocation` return ignored while UI says "supported" | **actually fixed** | Per-click: false → logged, not posted (:368-371). At launch: round-trip gates `targetingSupported`; `directAppProblem` carries `windowTargetingProblem` so the UI says WHY (hunt 4 ✓). |

### models (models-findings.md)
| Finding | Verdict | Evidence |
|---|---|---|
| F1 — one undecodable profile entry destroys the whole list | **actually fixed** | Per-entry tolerant decode in `ProfileService.entries(fromStored:)` + `os_fault` log. ProfileTests additions pass. |
| F2 — non-finite doubles trap in Int/UInt64 | **actually fixed** | `clamped()` bounds on decoded Doubles; NonFiniteInputTests pass. |
| F8 — fail-open `try?` on every persistence write | **partially fixed** | `Persistence.save`→Bool, `MacroFiles.autosave`→warning + destination seam, ProfileService/MacroLibrary `persist()`→`lastError` — all wired and tested (`aFailedProfileWriteSurfacesAWarning`, `aFailedIndexWriteSurfacesAWarning`, `aFailedAutosaveSurfacesAWarning`, `aSuccessfulAutosaveStaysSilentAndClearsAStaleWarningPath`). Stragglers: HotkeyService.save:155, MacroLibrary.delete:109, stale `lastError` — N5. |
| F10 — rename's swallowed move desyncs index from disk | **actually fixed** | do/catch with early return keeps the index intact; MacroLibraryTests cover it. |
| F11 — one corrupt hotkey entry resets all hotkeys | **actually fixed** | `HotkeyAction.storedCombos(from:)` tolerant decoder (both stored shapes); HotkeyStorageTests pass. Residual stream-desync edge — N6. |
| F12 — case-variant name replaces a different profile; duplicate display names | **actually fixed** | Exact-name match for updates; case-variant clash → `uniqueDisplayName` + `lastError` message (:63); `importFile` dedupes display names. |

### player-recorder (player-recorder-report.md)
| Finding | Verdict | Evidence |
|---|---|---|
| #1 — timestamps are main-run-loop arrival times | **actually fixed** | `TapEvent.timestampNanos` from `CGEvent.timestamp` (MacroRecorder.swift:150) + overflow-safe run-relative conversion (:110-113); sound across midnight/sleep (both clocks are mach-uptime — hunt 6 ✓). Untested `stamp == 0` branch — N8. |
| #5 — cleaner drops trailing keys but not trailing buttons | **actually fixed** | Trailing held buttons dropped, including interleaved runs; RecordingCleanerTests additions pass. |
| #6 — drags record as down/up, replay fabricates one `dragged` | **partially fixed** | The replay no longer fabricates a `dragged` event (MacroPlayer.swift:132-137) and the per-pass `defer` release (:84) defends a hand-edited down-with-no-up file (hunt 7 ✓). The recorder's tap mask still lacks dragged/mouseMoved (MacroRecorder.swift:30-31), so a recorded drag still replays as a down/up jump — recording the drag stream was not attempted. |
| #7 — cancelled run reports `finished: true` | **actually fixed** | `cancelled` flag set on every worker-sleep break (:79, :97, :110); `report(progress, !cancelled)` (:117). |

### appkit-accept (appkit-accept-report.md)
| Finding | Verdict | Evidence |
|---|---|---|
| #1 — RealInputMonitor subscriber leak + debug assert crash on second resume | **actually fixed** | Idempotent start/stop (`subscribers = 1/0`), observable `subscribers`; `aSecondStartOfTheSameWatcherDoesNotCrashOrDoubleCount` passes. |
| #2 — `testClick` posts without Accessibility check; unconditional success | **actually fixed** | `ensureAccessibility` guard; report sent only for a delivered, well-aimed event. `testClickReportsSentOnlyForADeliveredWellAimedEvent` passes. |
| #6 — hold-to-click release ends the run without teardown | **actually fixed** | Release path calls `session.stop()` (AutoClicker.swift:522) → onStop → tearDownRun — the hook covers exactly this hole. |

---

## Hunt-list answers (the 10 assigned probes)

1. **Stop paths really tear down; onStop never fires on pause.** ✓ All six paths (stopAll, hold-release,
   applyProfile, shutdown, toggle-stop, hotkey-reassigned) route through `session.stop()` → `onStop` →
   `tearDownRun`. `pause()` and `finish(token:)` never touch the hook (RunSession.swift:47/57 gates on
   `wasActive` in `stop()` only). Natural finish tears down via the `runID` guard. Caveat: no test
   *asserts the negative* (that pause leaves onStop unfired) — listed under coverage.
2. **Delivery validation can't reject legitimate clicks; W1 test intact.** No rejection risk from odd
   geometry: containment falls back to front-most, clamp passes empty rects through, negative multi-display
   coords flow unchanged. `aStopThatOutrunsItsBudgetSurfacesAWarning` passes (2.06 s) against the current
   code. The one real edge is N2 — not a rejection, the opposite: a guaranteed wrong-window acceptance.
3. **Post-setSource writes: everything except flags.** Subtype, fields 91/92, windowLocation and the tag
   are after setSource (:364-374); the tag measurement gap is closed. `flags` (:349) and the builder's
   location/windowNumber seed are before — windowNumber is re-asserted after, flags and location are not
   (N3).
4. **Disabled targeting says why.** ✓ `windowTargetingProblem` flows into `directAppProblem` and the UI;
   `missingSymbolDisablesTargetingWithAWarning` pins it.
5. **Numeric bounds match the UI.** Every Double clamp matches its UI range exactly, including the
   speed Picker's fixed 0.25–4 set and the coordinate fields' ±20,000. Residuals: three unbounded Ints
   (N7) and the ClickRegion strict-decode hole (N4).
6. **Event-native timestamps are sound.** Both `CGEvent.timestamp` and `DispatchTime.now().uptimeNanoseconds`
   are mach-uptime clocks — no midnight, no wall-clock, no sleep discontinuity beyond what uptime itself
   has (and a sleep during recording stretches event times exactly as it stretched the user's actions).
   `stamp - min(stamp, startUptime)` can't underflow; `stamp == 0` takes the arrival fallback. Untested
   branch (N8).
7. **Down-without-up is defended at both layers.** A *recording* can't produce it (cleaner drops trailing
   held buttons/keys); a *hand-edited file* can, and the player's per-pass `defer { release(...) }`
   (MacroPlayer.swift:84) releases whatever is held when the pass ends. No dangling press survives.
8. **No concurrency violations found.** `onStop`/`tearDownRun` are MainActor; the retry-once path hops
   to a global queue and back via `performOnMain`; the onOverrun warning is guarded on `phase == .idle`
   (deliberate suppression when a new run already started — defensible); the recorder tap callback uses
   `MainActor.assumeIsolated` correctly for a main-run-loop source.
9. **213 pass, 0 warnings** (verified above, twice — the second run grepped the full output: every
   "warning" line is a test name). Uncovered/under-covered fixed lines: KeyPresser/MacroPlayer
   cancelAndWait (unchanged, and their seam untested), AppModel.launch→validateWindowTargeting wiring,
   AppModel fileError←autosave-warning wiring, pause-doesn't-fire-onStop, the `stamp == 0` branch,
   flags survival of setSource under held modifiers, ProfileService delete/rename/setFavorite
   persist-failure paths.
10. **Persistence `try?` hunt: mostly clean, three stragglers** — HotkeyService.save:155 (Bool
    discarded), MacroLibrary.delete:109 (silent removeItem), and the silent `Persistence.load` `try?`
    feeding the N4 whole-blob reset. Named paths (autosave, library index, profile list) all fail loud
    now.

---

## Bottom line

The waves did what their commit messages say, and the test wall is real (213 green, genuinely covering
the new seams — these are not green-by-construction tests). The followups, in priority order:

1. **N1** — wire `cancelAndWait(onOverrun:)` into KeyPresser and MacroPlayer (the fix exists; copy it).
2. **N2** — fall through to `.optionAll` in `resolveWindowLive` before accepting a non-containing
   on-screen window.
3. **N3** — move the flags write after setSource.
4. **N4/N5** — ClickRegion tolerant decode; consume HotkeyService's save Bool; clear stale `lastError`.
5. **Runtime A/B** (owner's manual job, already tracked): subtype 3, Y direction, re-anchoring, and the
   directApp end-to-end click.

**Verdict: SHIP-WITH-FOLLOWUPS** — nothing here blocks the build; N1 and N2 should be the next wave.