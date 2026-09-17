# The v2.0.5 adversarial subsystem sweep: what was fixed, what is still open

> **21 of 34 fixed** — 8 in v2.0.5, 13 in v2.0.6. 13 remain open, all medium or low.

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

## Still open — 13 findings, all medium or low

Not attempted. Each row in the JSON carries a concrete failure scenario, quoted evidence and a
proposed change. **UNJUDGED means unverified, not unreal** — treat the claim as a lead and
re-check it before acting, exactly as every fixed one was re-checked by hand.

| ID | Sev | Status | Where | What |
|---|---|---|---|---|
| C10 | medium | CONFIRMED | `Models/HotkeyAction.swift:107` | Macro hotkey dispatch recomputes the raw slot, ignoring the collision-avoided slot used to register |
| C11 | medium | CONFIRMED | `Services/HotkeyService.swift:95` | setCombo clobbers the Auto Clicker's combo without firing the hold-run hook |
| C7 | medium | CONFIRMED | `Services/AutoClicker.swift:335` | Position jitter is computed then discarded for the default cursor target |
| C8 | medium | CONFIRMED | `Services/AutoClicker.swift:227` | Stop-after-duration restarts its whole time budget on every resume |
| U16 | medium | UNJUDGED | `Views/SettingsView.swift:105` | Scheduled-start time is discarded unless the user presses Return in the field |
| U5 | medium | UNJUDGED | `App/AppModel.swift:176` | fireSchedule uses toggle(), so a scheduled start STOPS an already-running feature |
| U6 | medium | UNJUDGED | `App/AppModel.swift:167` | fireSchedule never checks the deadline, so a sleep-delayed timer starts hours late |
| U8 | medium | UNJUDGED | `App/AppDelegate.swift:24` | Double-clicking a .macromakerprofile file opens it as a macro and fails |
| U9 | medium | UNJUDGED | `Services/ProfileService.swift:23` | Save never overwrites: re-saving a profile name silently appends a twin |
| C12 | low | CONFIRMED | `Services/AutoClicker.swift:247` | The direct-app "target app quit" stop reason can never be displayed |
| U17 | low | UNJUDGED | `Views/MenuBarView.swift:60` | Menu-bar rows for hotkeyed macros hardcode phase .idle, so "Play" actually stops |
| U21 | low | UNJUDGED | `Views/Components/ProfilesSection.swift:13` | Return in an empty profile Name field saves a junk profile named "Profile" |
| U7 | low | UNJUDGED | `App/AppModel.swift:282` | saveMacro writes the file before renaming, so the saved file keeps the old name |

## Verification of this pass

- `./scripts/test.sh` — **165 tests in 31 suites, green** (131 before this session).
- Clean build from a fresh scratch path — **0 warnings, 0 errors** under Swift 6 strict concurrency.
- The layout gate re-run on each fix-pass binary — `TALLY FINAL: GOOD=10 BAD=0 OTHER=0
  IDENT-MISMATCH=0`, all four tabs bounded. Views changed, so the gate ran again each time.
