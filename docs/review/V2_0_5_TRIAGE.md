# The v2.0.5 adversarial subsystem sweep: what was fixed, what is still open

> **All 34 fixed** — 8 in v2.0.5, 13 in v2.0.6, 13 in v2.0.7. Nothing left open.

Ten read-only reviewers, one per subsystem with an explicit file list, then every finding
refuted by three independent lenses (does it reproduce · is it already handled · is the platform
claim true). 35 raised, 1 refuted, 13 survived refutation, **21 lost their verifiers when the run
hit its session limit and are recorded UNJUDGED — never as confirmed.** A dead verifier must not
look like a vote in favour.

Full detail (repro steps, quoted evidence, proposed change) for every row:
`docs/review/v2.0.5-subsystem-sweep.json`.

## Fixed in v2.0.5 — 8 findings, 20 new tests

Every fix was red-proofed: the test was watched failing against the unfixed code before the fix
landed. Where the bug was a trap, the extraction step reproduced it as a real crash in the test
run (`Fatal error: Double value cannot be converted to UInt64 because it is either infinite or
NaN`), not as a compile error — a compile error proves nothing.

| ID | Sev | What was wrong | Fix |
|---|---|---|---|
| C1 | critical | Saving a macro with a name ≥120 characters produced a file name the library's own safety check rejects. The record saved, then read back as "file missing" — and on the next launch its decode threw, which took **the entire library index** with it (`try?` + `?? []` → empty), and the next edit persisted that empty list permanently. Two independent producers: the collision suffix `-N` was appended *after* the length cap, and `safeFileName` trimmed dots *before* capping, so the cap could land on a dot. | Budget the suffix inside the cap; make `safeFileName` idempotent; decode the index element-by-element so one bad row costs one row. The path-traversal defence is unchanged. |
| C6 | high | A macro file with a negative or infinite event time reached `UInt64(_:)` in the playback loop, which **traps and kills the app** on Play. Nothing bounded it: the decoder took the number raw, and the step editor's validator accepted anything `Double(_:)` parses with `t >= 0` — which `1e400` satisfies. | Clamp before the conversion, reject the value at decode, and require `.isFinite` in the editor. |
| U19 | high | Typing `nan` into any integer field **crashed the app**. The parse strategy really does accept it, and `min(max(nan, lo), hi)` returns `nan` — Swift's min/max propagate it — so the clamp never filtered it before `Int(_:rounded())` trapped. | One shared `FieldValue.stored` that refuses non-finite input. |
| U20 | high | The same `nan` in the interval field did not crash — worse, it was stored. `max(minimumDelay, nan)` returns the **1 ms floor**, i.e. a click storm, in a settings blob `JSONEncoder` then refuses, so every later save was silently dropped. | Routed through the same guard. |
| U1 | high | Background clicks landed at the wrong Y **on any multi-display setup**. The top-left→bottom-left flip used the union of all screens, but `NSEvent.mouseEvent(...).cgEvent` measures its own flip against the *primary* screen (measured: every `appKitY + cgY == 1080.0` exactly). With no screens at all the union's maxY is `+infinity`. `MacroRecorder` already flipped about the primary. | Flip about the primary, consistent with the recorder. |
| U2 | medium | **Every** background-posted event went out untagged: the "this is Macro Maker's own output" marker was written and then erased by `setSource`, which resets that field (measured: `305419896 → 0`). That marker is what stops "pause when I use the mouse" from pausing on the clicker's own clicks. | Tag after `setSource`, in both the mouse and key paths; `postKey` routed through the delivery seam so it can be tested at all. |
| U3 | low | An interval from an imported profile or a corrupted defaults blob reached `Duration.milliseconds(_:)` unbounded; above ~1.7e23 that call **traps**. Only the UI enforced the limit. | Hoisted the bound the view already used and applied it on the run path. |
| U10 | medium | The profile importer accepted **any** JSON object — `{"name":"Quarterly Report"}` imported as a complete, all-defaults profile wearing that title, and applying it reset every feature. `Macro` has guarded on its format key since v2.0; profiles never did. | Profiles now declare their format, and a payload with no identifying key is rejected. Files written before v2.0.5 still load. |

## Fixed in v2.0.6 — 13 more findings

| ID | Sev | What was wrong | Fix |
|---|---|---|---|
| C2 | critical | `.flagsChanged` fires on both the press and the release of a modifier, and the code only asked "is this modifier part of the combo". **Pressing ⌃ during a ⌃⌥C hold-run stopped the run.** | Require the flag to be ABSENT after the change. Extracted as `KeyCombo.isEndedByFlagsChange`, +3 tests. |
| U12 | critical | While recording, the step table shows `recorder.liveEvents` — but every editing action it offered indexed and rewrote `model.macro`, a **different array**, then autosaved it. Deleting "step 3" of a live recording deleted step 3 of the *previous* macro. | The context menu and double-click are gated on `!isRecording`, matching the data source. |
| C3 | high | Auto-resume was **structurally unreachable**. A pause cancels the worker, and a cancelled worker reports exactly like a finished one — so every pause ran `tearDownPauseWatching()`, killing the 1-second timer that is the only thing driving `resumeIfIdle`. | Skip the teardown while paused. Also stamp `lastRealInputAt` before the phase check, so idle is counted from the user's LAST keystroke, not their first. |
| C4 | high | The layout scan looped modifier state on the *outside*, so the whole plain pass finished first and the numeric keypad claimed any character that is unmodified there. Measured on the live layout: **`+` resolved to key 69 (KeypadPlus) and `*` to key 67 (KeypadMultiply)** instead of ⇧= and ⇧8. `KeyStrokeParserTests` always asserted the right answer — it passed only because its fake layout has no keypad to lose to. | Key code outer, state inner. Exactly 2 of 200 characters change, character set unchanged. Extracted as `KeyboardLayout.scan`, +3 tests, red-proofed by planting the old loop order. |
| C5 / U15 | high | `KeyPresserView` started an app-wide key capture with no `.onDisappear` to end it. Leaving the tab destroyed the view while the monitor stayed installed — and it returns `nil` for every keyDown, i.e. **swallowing every keystroke in every window**, writing the first one into the key field. | The same `.onDisappear` guard `HotkeyField` already carried. |
| U4 | high | `launch()` disarmed any armed schedule unconditionally, so scheduled start only ever worked inside the one session it was switched on in — and quit/relaunch is the normal path for a menu-bar login-item app. | Re-arm when the time is still ahead today; disarm only a missed one. Extracted as `ScheduleRules.staysArmedOnLaunch`, +3 tests. |
| C9 / U13 | high | "Insert Typed Text…" inserted a hard-coded `"abc"` as three keyDown/keyUp pairs, then opened the single-step *rename* editor on the first one, pre-filled with the whole word. Whatever the user typed replaced only the "a" — the "b" and "c" stayed in the macro silently. | Ask for the text first, via a new `.insertText` editor case. |
| U14 | high | Onboarding's "Test Click" posted a real click at the cursor — and the only way to press it is to click it, so the click landed back on the button and ran the action again, each pass posting another. It also proved nothing: that section only renders once macOS has *already* granted access. | Removed; replaced with the confirmation it was standing in for. |
| U18 | high | The "Hotkey" checkbox is the only control that can remove a macro hotkey, and it is replaced by the hotkey field the instant one is assigned — so a hotkey **could never be switched off** and its slot was consumed for good. With all 10 taken, every other row disabled itself while the banner said to "remove one". | A remove button on the field. |
| U11 | low | `nextOccurrence` added raw seconds to midnight. A day is 23 or 25 hours across a daylight-saving transition, so a **07:00 start fired at 08:00** (measured, 2026-03-29 Europe/London). | Set the wall-clock time on the day. +1 test. |
| C13 | low | Both `TISCopy…` calls return a +1 reference, but the balancing `takeRetainedValue()` sat inside a **lazy** chain that short-circuits — so the second source leaked on every layout rebuild. | Consume both retains up front. |

## Fixed in v2.0.7 — the remaining 13

| ID | Sev | What was wrong | Fix |
|---|---|---|---|
| C7 | medium | "Vary the point by up to ± N px" did nothing on the **default** target: the jittered point was computed for cursor targeting and then thrown away by passing `nil`, which re-reads the raw cursor position. | Pass the jittered point through; keep the `nil` fast path only when no jitter is configured. |
| C8 | medium | Clicks already done survive a pause, but elapsed time did not — each resume built a worker with a brand-new deadline, so "stop after 60 s" could run 60 s **per resume**, unbounded. | Carry elapsed time across pauses exactly as `clicksDone` already is. Extracted as `AutoClicker.runDeadlineNanos`, +5 tests; the clamp also closes another `UInt64` trap. |
| C10 | medium | Registration bumps a macro past a colliding hotkey slot, but dispatch recomputed the *un-bumped* hash — so the displaced macro's shortcut resolved to nothing, and the other resolved through a Dictionary scan with undefined order. | Record the slot actually registered and dispatch through it. |
| C11 | medium | `onToggleReassignedWhileHolding` fired only when the Auto Clicker toggle was the action addressed — but the clobber loop can strip that combo as a side effect of giving it to a *different* action, leaving a hold-run that `handleRelease` can never end. | Fire when the toggle's combo changes, whatever caused it. |
| C12 | low | The direct-app "target app quit" message was unreachable UI: it is reported with `finished: true`, and the same main-actor hop sets the phase to `.idle`, while the banner required a non-idle phase. Background clicking stopped with **no explanation at all**. | Drop the phase condition; both start paths already clear the warning. |
| U5 | medium | Every `toggle(_:)` stops a session that is already active — and `isActive` covers countdown and paused — so a "scheduled start" arriving while the feature was running performed a **stop**, then disarmed itself and never started it. | Start-only. |
| U6 | medium | A non-repeating `Timer` does not fire while the Mac sleeps; the run loop delivers it on wake, so the feature started whenever the lid opened rather than at the chosen time. | Refuse a fire more than the tolerance late. Extracted as `ScheduleRules.isOnTime`, +3 tests. |
| U7 | low | `saveWithPanel` wrote the bytes and only *then* did the caller rename the in-memory copy, so the `.macromaker` file on disk kept the old name — the rename made in the Save panel was lost on reopen. | Name it from the chosen URL before writing. |
| U8 | medium | Info.plist claims both document types, but every opened URL was decoded as a `Macro` — which requires a format key no profile carries — so double-clicking a `.macromakerprofile` always failed. | Branch on the extension; also handle every selected URL rather than just the first. |
| U9 | medium | `save()` matched on id, but the only caller mints a fresh UUID each time — so the update branch was unreachable and re-saving a name just accumulated duplicates. | Match on name as well, carrying the favourite flag and id across. |
| U16 | medium | The scheduled time only committed on Return. Its other path was an `.onChange` looking for a trailing newline — dead code, since a SwiftUI `TextField` never puts one in its string — so clicking away discarded the typed time and `.onAppear` quietly restored the old value. | Commit on focus loss too. |
| U17 | low | Menu-bar rows for hotkeyed macros hardcoded `phase: .idle` while routing into the shared player, whose toggle stops an active run — so while anything played, a button labelled "Play" did the opposite. | Disable them while the player is busy; the dedicated Play Macro row still stops it. |
| U21 | low | The Save button guards an empty profile name; `.onSubmit` did not, and `cleanedName("")` returns "Profile" — so Return in an empty field saved a junk profile. | Guard inside `saveCurrent()`, shared by both entry points. |

## Verification of this pass

- `./scripts/test.sh` — **173 tests in 33 suites, green** (131 before this session).
- Clean build from a fresh scratch path — **0 warnings, 0 errors** under Swift 6 strict concurrency.
- The layout gate re-run on each fix-pass binary — `TALLY FINAL: GOOD=10 BAD=0 OTHER=0
  IDENT-MISMATCH=0`, all four tabs bounded. Views changed, so the gate ran again each time.
  The v2.0.7 binary passed too: `GOOD=10 BAD=0 OTHER=0 IDENT-MISMATCH=0`, all four tabs bounded.
  Its first attempt scored `GOOD=1 BAD=0 OTHER=9` because the screen locked part way through —
  AX window trees read empty while the session is locked, so those nine runs were unmeasured,
  not failed (`BAD=0` throughout). `matrix3.sh` now re-checks the lock on EVERY run and aborts
  loudly rather than returning ambiguous OTHERs that read like a pass.
