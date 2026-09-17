# v2.0.5 — adversarial subsystem sweep: what was fixed, what is still open

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

## Still open — 26 findings

Not attempted in this pass. Each row in the JSON carries a concrete failure scenario, quoted
evidence and a proposed change. **UNJUDGED means unverified, not unreal** — treat the claim as a
lead and re-check it before acting on it, exactly as the fixed ones were re-checked by hand.

| ID | Sev | Status | Where | What |
|---|---|---|---|---|
| C2 | critical | CONFIRMED | `Services/HotkeyService.swift:239` | flagsChanged: a modifier key-DOWN is treated as a release, killing the run |
| U12 | critical | UNJUDGED | `Views/RecorderView.swift:136` | Step-editor actions on LIVE recording rows mutate and autosave the OTHER macro |
| C3 | high | CONFIRMED | `Services/AutoClicker.swift:162` | Auto-resume can never fire: a pause tears down its own resume timer |
| C4 | high | CONFIRMED | `Utilities/KeyboardLayout.swift:71` | Layout build maps "+" and "*" to numeric-keypad key codes, not the main row |
| C5 | high | CONFIRMED | `Views/KeyPresserView.swift:106` | Key-field capture is never ended when the Key Presser tab goes away |
| U13 | high | UNJUDGED | `Views/RecorderView.swift:298` | Insert Typed Text pre-fills the rename editor with the whole word, not the one step |
| U14 | high | UNJUDGED | `Views/OnboardingView.swift:50` | Onboarding "Test Click" clicks itself — a self-retriggering click loop |
| U18 | high | UNJUDGED | `Views/Components/LibrarySection.swift:136` | A macro hotkey can never be switched off once enabled |
| U4 | high | UNJUDGED | `App/AppModel.swift:203` | Scheduled start disarms itself on every launch, even when still ahead |
| C10 | medium | CONFIRMED | `Models/HotkeyAction.swift:107` | Macro hotkey dispatch recomputes the raw slot, ignoring the collision-avoided slot used to register |
| C11 | medium | CONFIRMED | `Services/HotkeyService.swift:95` | setCombo clobbers the Auto Clicker's combo without firing the hold-run hook |
| C7 | medium | CONFIRMED | `Services/AutoClicker.swift:335` | Position jitter is computed then discarded for the default cursor target |
| C8 | medium | CONFIRMED | `Services/AutoClicker.swift:227` | Stop-after-duration restarts its whole time budget on every resume |
| C9 | medium | CONFIRMED | `Views/RecorderView.swift:298` | "Insert Typed Text…" edits only the first character, so the macro types the wrong text |
| U15 | medium | UNJUDGED | `Views/KeyPresserView.swift:106` | Key Presser key capture is never ended when the view goes away |
| U16 | medium | UNJUDGED | `Views/SettingsView.swift:105` | Scheduled-start time is discarded unless the user presses Return in the field |
| U5 | medium | UNJUDGED | `App/AppModel.swift:176` | fireSchedule uses toggle(), so a scheduled start STOPS an already-running feature |
| U6 | medium | UNJUDGED | `App/AppModel.swift:167` | fireSchedule never checks the deadline, so a sleep-delayed timer starts hours late |
| U8 | medium | UNJUDGED | `App/AppDelegate.swift:24` | Double-clicking a .macromakerprofile file opens it as a macro and fails |
| U9 | medium | UNJUDGED | `Services/ProfileService.swift:23` | Save never overwrites: re-saving a profile name silently appends a twin |
| C12 | low | CONFIRMED | `Services/AutoClicker.swift:247` | The direct-app "target app quit" stop reason can never be displayed |
| C13 | low | CONFIRMED | `Utilities/KeyboardLayout.swift:48` | One TISInputSource leaked on every keyboard-layout rebuild |
| U11 | low | UNJUDGED | `Utilities/ScheduleRules.swift:30` | nextOccurrence adds raw seconds to midnight — off by an hour on DST days |
| U17 | low | UNJUDGED | `Views/MenuBarView.swift:60` | Menu-bar rows for hotkeyed macros hardcode phase .idle, so "Play" actually stops |
| U21 | low | UNJUDGED | `Views/Components/ProfilesSection.swift:13` | Return in an empty profile Name field saves a junk profile named "Profile" |
| U7 | low | UNJUDGED | `App/AppModel.swift:282` | saveMacro writes the file before renaming, so the saved file keeps the old name |
## Verification of this pass

- `./scripts/test.sh` — **155 tests in 29 suites, green** (131 before this session).
- Clean build from a fresh scratch path — **0 warnings, 0 errors** under Swift 6 strict concurrency.
- The layout gate re-run on the fix-pass binary — `TALLY FINAL: GOOD=10 BAD=0 OTHER=0
  IDENT-MISMATCH=0`, all four tabs bounded. Views changed, so the gate had to run again.
