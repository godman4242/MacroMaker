# v2.0.4 — the blank-sidebar bug, and how it was finally measured

The bug: launched as a `.app` bundle, the `NavigationSplitView` adopted the grouped Forms'
~2742pt intrinsic height inside a ~1050pt window. The split's top sat at y=-790, so the sidebar
rows were drawn in invisible space above the window and the detail's top hid under the titlebar.

## Why v2.0.2 and v2.0.3 both false-passed

**It only reproduces via `open <bundle>`** — a LaunchServices launch. The `swift build` debug
binary run directly never shows it. Both earlier fixes were verified with the direct binary
only, so both shipped the bug. Every measurement below is a real bundle launch.

## The version-by-version story

| | Theory | What shipped | Verdict |
|---|---|---|---|
| v2.0.2 | The hosting view was detached from the window | `NSHostingController`, `sizingOptions = []` | Bug remained |
| v2.0.3 | The *window* was the wrong size | `NSHostingView` pinned by autoresizing + a screen-fit clamp | Necessary, not sufficient — bug remained |
| v2.0.4 | The *detail column's shape* is what the split measures | Detail root is a `ScrollView`; header is a sticky section header inside it | Fixed |

v2.0.3's hosting change is still required and still in place — it stops SwiftUI's intrinsic size
from driving the window. It just never addressed what the split itself measured.

## The measured invariant: a ScrollView with no layout wrapper around it

A `ScrollView` reports the height it is proposed, so the split can never exceed the window. Wrap
it in anything that *lays out* and the split adopts the detail's full intrinsic height instead.
Identity-only modifiers are safe. Each row is bundle launches, scored on the invariant "the split
is fully inside the window vertically and fills at least half of it":

| Detail-column shape | GOOD | BAD |
|---|---|---|
| pre-fix control (VStack root, per-tab ScrollViews) | 0 | **4** |
| ScrollView root, no pinned header | **5** | 0 |
| P1 — `VStack { banner; hero; Divider; ScrollView }` | 0 | **8** |
| P2 — `ScrollView.safeAreaInset(.top) { header }` | 0 | **8** |
| P3 — `ScrollView { LazyVStack(pinnedViews: [.sectionHeaders]) { Section } }` | **8** | 0 |
| P3 + `.id(selectedTab)` **on the ScrollView** (shipped) | **6** | 0 |

P1 and P2 are the load-bearing negatives: a `VStack` wrapper and `.safeAreaInset` each reproduce
the exact pre-fix signature. That is why the pinned header has to live *inside* the scroll
content as a sticky section header, and why this shape must not be "tidied up".

`.id` sits on the ScrollView, not on its content — the scroll offset belongs to the ScrollView,
so rebuilding only the content left the recorder opening halfway down its event table (measured).

## Final confirmation (this commit's exact source)

```
TALLY FINAL: GOOD=10 BAD=0 OTHER=0 IDENT-MISMATCH=0
```

Per-tab probe on one live window — the split stays bounded on every tab, not just the launch tab:

| Tab | Window (x y w h) | Split (x y w h) |
|---|---|---|
| Auto Clicker | 650 95 620 844 | 650 147 620 792 |
| Key Presser | 650 95 620 844 | 650 147 620 792 |
| Web Target | 650 95 620 844 | 650 147 620 792 |
| Macro Recorder | 650 95 620 844 | 650 147 620 792 |

A separate 20-launch hunt on the same binary: `GOOD=20 BAD=0 OTHER=0`.

Screenshots: the recorder opens at its Record/Save toolbar; the Auto Clicker scrolled to its
bottom still shows the banner and status hero — and therefore **Stop All**, the only global
emergency stop — pinned at the top with content scrolling underneath.

## Why the harness can be trusted

1. **Binary identity per run.** Each run hashes the *running process's own executable* and
   requires a match. This fired for real: a pre-fix bundle at `/private/tmp/mmapp2` respawns
   after `pkill`, and an earlier harness measured it instead of the build under test.
2. **The verdict is the invariant, not a coordinate.** `sy >= wy && sy+sh <= wy+wh`, valid at
   any window size or position. An earlier harness hard-coded `y=-790`, so any other window
   origin silently fell into OTHER.
3. **The gate was probed for its own false-passes.** Plain containment would score a *collapsed*
   split (height 0) as GOOD, so the verdict also requires the split to fill at least half the
   window. Healthy runs measure 94–95%, so the floor is nowhere near tuned-to-pass.
4. **Fail-closed on a locked screen.** With the session locked every AX window tree reads empty,
   so every run would score OTHER — which reads like "no failures". The harness aborts instead.
   Not hypothetical: it happened, and it is why this confirmation ran late.
5. **The probe records how long it waited.** See below.

## Open item — an unexplained no-window launch (not the layout bug)

Twice, a run scored `OTHER` with `NOWINDOW`: a process whose binary hash matched had an **empty
AX window list for a full 10 seconds** (and the resize probe timed out for another 10). This was
only visible because the probe was changed to wait for readiness and *print the wait*; as a bare
one-shot snapshot it was indistinguishable from a transient read.

- Not reproduced in **72** subsequent launches (20-run hunt + the 10-run final + 42 hand-rolled).
- `BAD=0` across every run ever taken of this shape, so it is **not** the layout bug.
- Direct measurement of startup: the window enters the AX tree in **299–920 ms**, 12/12.
- Both occurrences followed a `codesign --force` of the bundle moments earlier; that is a
  correlation, not a demonstrated cause.

Diagnostics are armed in `matrix3.sh`: the next occurrence dumps every MacroMaker process with
its hash and state, the CGWindowList (does a real window exist that AX cannot see?), and a
main-thread sample. Do not "fix" this by retrying — the retry already exists and is instrumented.

## Also in this commit

- **The screen-fit clamp no longer moves a window that already fits.** `show()` re-runs the
  clamp on *every* open, and the main window is opened from the menu bar, a hotkey, a Dock reopen
  and the permission prompt — so the old unconditional re-centre threw the window back to the
  middle of the screen every single time, defeating the `MacroMaker.main` frame autosave.
  Red-proofed: the test was watched failing against the old code (a window at `(40, 60)` came
  back as `(410, 57.5)`) before the fix landed. `ScreenFitTests`, 4 tests.
- **`CFBundleShortVersionString` was still `2.0.0`** — v2.0.1 through v2.0.3 all shipped
  labelled 2.0.0. Now 2.0.4 (build 5).

Harness and raw logs: `/tmp/mm-fix/` — `matrix3.sh`, `ax-probe`, `ax-wait`, `ax-scroll`, `ax-tab`,
`winid`, `rebuild.sh`, `final-verify.sh`, per-run `m3-*.log`, screenshots `final-*.png`.
