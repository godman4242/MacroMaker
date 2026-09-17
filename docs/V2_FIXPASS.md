# Macro Maker v2.0.1 — Fix Pass (post adversarial review)

You are in the existing repo. v2.0 is committed at HEAD. A 5-lens adversarial review found real defects. Fix ALL Critical/High items below, then run `swift build` and `swift test` (both must pass; add regression tests for the logic bugs), then commit as "v2.0.1: adversarial review fixes".

## Critical/High fixes (mandatory)

1. DEADLOCK (perf H2, compliance): `DispatchQueue.main.sync` is called per tick from the click worker (AutoClicker frontmost-bundle-id check + BackgroundPoster targetState) while `cancelAndWait()` runs on main during stop/pause. Replace with a lock-free snapshot: a small `final class TargetSnapshot: @unchecked Sendable` holder with NSLock, refreshed on main via NSWorkspace notifications (didActivateApplicationNotification, didTerminateApplicationNotification) + a 500 ms timer; workers read the snapshot synchronously. No main.sync from worker threads anywhere — grep to confirm zero remain.

2. HUMANIZER FIRST-GAP BUG (quality H1, MacroPlayer.swift): `var previous = plan.events.first?.time ?? 0` deletes the opening gap when humanization is on. Fix to `var previous = 0.0` and feed all gaps. Add regression test asserting first recorded gap is preserved (jittered) not zeroed.

3. OCCLUDED WINDOW SILENT DROPS (correctness H1): BackgroundPoster.primaryWindow uses optionOnScreenOnly — a fully covered window vanishes and clicks silently no-op. Two fixes: (a) resolve the window with `CGWindowListCopyWindowInfo(.optionAll)` as fallback when on-screen lookup fails (layer-0 filter still applies); (b) surface target status in the UI — when the window can't be resolved, the run must show a warning state (e.g. status "target window not found — bring it on-screen at least once") and Test Click must report failure loudly. Never increment click counters for undelivered clicks (compliance MINOR: directClickOnce must not count skipped clicks).

4. NSEVENT RECIPE DEVIATION (compliance MAJOR, BackgroundPoster ~143): build mouse events via `NSEvent.mouseEvent(type:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:)?.cgEvent` per the spec recipe so the 12 auto-filled fields (0,1,2,41,43,44,50,51,55,59,102,108) are populated; then apply fields 3/7/91/92, window-local location via the dlsym seam, and the ⌘-flag background trick when the target is inactive.

5. PER-CLICK WINDOW LIST (perf H1): cache CGWindowListCopyWindowInfo result per run with a 300 ms TTL; re-resolve window only on expiry or failure.

6. RUNNING-APP ENUMERATION PER CLICK (perf H3): cache NSRunningApplication lookup the same way.

7. PID-REUSE (security F4): before each direct-post burst, verify NSRunningApplication(processIdentifier:) still exists AND its bundleIdentifier matches the plan's target bundleID (via the cached snapshot); abort the run with an error status on mismatch.

8. CGEVENTSOURCE PER EVENT (perf H4): EventSynthesizer.makeSource() creates a new CGEventSource per posted event. Cache one per click-loop run (thread-local or captured in the Plan closure) — keep localEventsSuppressionInterval behavior identical.

9. PROFILER FILE VERSION GATE (security F2 / correctness H2): Profile.init(from:) must reject formatVersion > currentFormatVersion with DecodingError.dataCorrupted. Test: v3 profile JSON fails import loudly.

10. importText UNPAIRED KEYUP (compliance MINOR, MacroRecord.typedTextEvents): the keyUp for a typed-text step must ALSO carry the textOverride/text payload marker (or a matching convention) so playback doesn't post a spurious "A" key-up and the table doesn't show "Key up A".

11. INFINITE-LOOP ALLOCATION (perf H5): MacroPlayer humanized timing array — allocate once per run and refill, not per loop iteration.

## High-quality fixes (do these too)

12. RealInputMonitor single-subscriber honesty (quality H2): make it explicitly single-subscriber — `debug assert` on double-subscribe, document it; ALSO add the local-monitor fallback when the global monitor returns nil (compliance MINOR) and a start-failure status path instead of silently never firing.

13. Hold-to-click combo release (correctness M6): releasing EITHER modifier of a multi-modifier combo ends hold mode — match on modifier-flags subset, not single keyCode.

14. DOUBLE REGION JITTER (correctness M7): region mode already picks random points; do not also apply positional jitter on top. One source of randomness per point.

15. slotID stability (quality + correctness M8): derive hotkey slot IDs from UUID bytes via FNV-1a (deterministic across launches), collision-handled by scanning for a free slot with a conflict status surfaced in the library UI.

16. HOTKEY REASSIGN MID-HOLD leak (correctness M9): on hotkey reassignment, if a hold-mode run is active, end it cleanly.

17. EVENTSORT after editTime (correctness H4): recorder step editor must keep events sorted by time after any edit (re-sort on apply).

18. insertText TIME SHIFT (correctness H3): inserting typed-text steps must shift subsequent event times so steps don't overlap the timeline (match insertWait behavior + duration of the typed text).

19. FRONTMOST SAMPLE TIMING (correctness L): sample the initial frontmost app at `begin(...)` (after countdown), not at toggle().

20. eventTag (security F6): make EventSynthesizer.eventTag a per-launch random Int64 (nonzero), so other tools' synthetic events can't mimic the self-tag. Keep the tag on every post path. Handle any test that hardcoded the old constant.

21. FILENAME SAFETY (security F3/F8): verify MacroLibraryRules.uniqueFileName strips/rejects '/', '\\', '..', NUL, dots-only names and caps length (fix if not); normalize extension handling so collision checks compare full filenames (with .macromaker); validate record.fileName on load/delete (reject names containing '/' or '..').

## Medium/Low deferred (do NOT implement — note in reply only)
- import review sheet/trust flow for shared profiles (F1 full UX) — owner decision pending; for now add ONE thing: on importing a profile containing any macro with textOverride/typed text, show a one-time alert listing that it contains typed text.
- main.sync guard elsewhere, pause-state consolidation, worker-loop test seams.

## Rules
- Zero new third-party deps. Keep all existing patterns (WorkerThread, RunSession, Persistence).
- Regression tests for items 2, 9, 14, 15, 17, 18 (pure logic), and at least compile-safe scaffolding for the rest.
- `swift build` && `swift test` green, then commit.
- Reply with: per-item [FIXED/DEFERRED: reason], test summary line, and anything you couldn't fix.
