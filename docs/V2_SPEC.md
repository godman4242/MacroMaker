# Macro Maker v2.0 — Build Task (harness brief)

You are working directly in the existing Swift package at `/Users/kheshav/Projects/macro-maker`. It is **git-initialised** — FIRST ACTION: run `git add -A && git commit -m "Snapshot before v2.0"` so v1 is recoverable. If the working tree is already clean, skip.

## Ground rules (non-negotiable)

1. **Read before you write.** Read every file you touch first. The codebase inventory: menu-bar SwiftUI app (`MacroMakerApp`, `MenuBarExtra`), single `AppModel` (@MainActor @Observable) source of truth, AppKit `WindowCoordinator` windows, per-feature `@Observable` services with `RunSession` (idle → countdown → running), `WorkerThread` with deadlock-free instantaneous cancellation, `EventSynthesizer` posting to `.cghidEventTap` with explicit flags + `.maskNonCoalesced` + self-tag `eventSourceUserData`, `TickSchedule` drift-free deadline math (pure, tested), Carbon `RegisterEventHotKey` hotkeys, JSON-in-UserDefaults persistence, `.macromaker` versioned macro files, Swift Testing test suite. Keep all of these idioms. Zero third-party dependencies. macOS 14+ floor. Swift 6 concurrency-clean.
2. **Every change has tests where testable.** Pure logic (timing math, parsers, scheduling, models, Codable) → Swift Testing suites in `Tests/MacroMakerTests`. Error paths exercised, not just happy paths. GUI/event-injection code that can't be unit-tested gets careful code review instead.
3. **Build green, then test green.** After EVERY stage: `swift build` must pass. After all stages: `swift test` must pass (use `scripts/test.sh` if present). Fix what you break before moving on.
4. **Don't regress v1.** Recorder must still ignore the app's own events (self-tag), hotkeys must suspend during capture, modifier flags must stay explicit per event, `.macromaker` v1 files must still load (bump schema to v2 with backward-compat decoding if you extend it — see MACRO_SCHEMA.md).
5. README.md: update features list + screenshot section reference at the end. Bump app version to 2.0.0 where version strings live (check project.yml / build-app.sh / Info.plist).

## Architecture for v2

Keep the 4 tab layout but grow it. Recommended: convert `ContentView`'s TabView to a **sidebar NavigationSplitView** (macOS 14-friendly) with sections, since tabs won't scale to ~8 features. Keep every existing view working during the transition. All new services follow the existing pattern: `@MainActor @Observable` class, `Persistence.load/save` settings struct, `RunSession` for lifecycle, worker-thread execution, 50 ms-throttled progress reporting.

---

## Stage A — Clicker Parity Pack (extend `AutoClickerSettings` + `AutoClicker` + view)

1. **Burst clicks**: N presses per interval (1–10).
2. **Click count per event**: single / double / triple (`mouseEventClickState`).
3. **Interval units**: ms / s / min / hour picker — store canonical ms; user finally gets his 2-minute clicks without mental math. Show live human-readable rate ("every 2 min ≈ 0.008 CPS") in all units.
4. **Click region**: random point inside a user-set rect (x,y,w,h) with a countdown picker (capture two corners or drag-free: two ⌃⌥-picked points). Position micro-jitter toggle (±N px applied around fixed point or inside region). New `TickSchedule`-style pure helpers + tests.
5. **Stop when frontmost app changes** toggle: worker polls `NSWorkspace.shared.frontmostApplication` (sample at tick boundaries, cache per tick) — worker is nonisolated, so wrap in a small MainActor accessor.
6. **Hold-to-click mode**: clicks repeatedly only while the toggle hotkey is physically held. Implement by watching the Carbon hotkey's key-up (extend HotkeyService with an onRelease callback) — do NOT poll CGEventSource key state; event-driven.
7. **Delayed start**: extra seconds field merged into the existing 3-s countdown (button starts = 3 + N).
8. **Restore cursor option**: after each fixed-point/region click, post a mouseMove back to the pre-click location (HID tap moves the real cursor — this undoes the visible side effect).
9. **Panic Stop**: new global hotkey action `.stopEverything` (default ⌃⌥␣ conflicts — pick ⌃⌥⌫) calling the existing stop-all path. Add to Settings + MenuBar.

Tests: interval-unit conversion, burst counting, click-count mapping, region random point generation (bounds), frontmost-change stop predicate, delayed-start total.

## Stage B — Event Targeting (NEW fifth feature — the headline)

`TargetMode` enum on the auto clicker: `.cursor`, `.fixedPoint`, `.region`, `.directApp(bundleID+point)`. New `BackgroundPoster` service implementing the **public-API background post recipe** (research summary — follow it exactly):

- Resolve target app via `NSRunningApplication`/bundle id → pid; resolve its main layer-0 window via `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` filtered by `kCGWindowOwnerPID` and `kCGWindowLayer == 0` → `kCGWindowNumber` + `kCGWindowBounds`.
- Build mouse events via `NSEvent.mouseEvent(...)` → `.cgEvent` (do NOT overwrite the 12 auto-filled fields: 0,1,2,41,43,44,50,51,55,59,102,108).
- Write fields: `.mouseEventButtonNumber`(3); `.mouseEventSubtype`(7) = **3**; `kCGMouseEventWindowUnderMousePointer`(91) = window id; `...ThatCanHandleThisEvent`(92) = window id.
- Set screen-space point, then translate by the negative of the window origin and call private `CGEventSetWindowLocation` via `dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation")` — optional-chain the symbol, fail loudly in UI if absent.
- When target `!isActive`: set `event.flags` to include `0x00100000` (⌘ flag) — WindowServer background filter bypass. Do NOT use `.maskNonCoalesced` confusion — keep both correct.
- Post via `event.postToPid(pid)`, down+up like `EventSynthesizer.click`, hold via existing `pressDuration`.
- UI: app picker (running non-MacroMaker apps with icons, `NSWorkspace.shared.runningApplications`), "pick point over target window" countdown capture (screen point → convert to window-local using window bounds; recompute window bounds each click), live target-status line (app running? window found? on screen?).
- **Honesty in UI**: small footnote "Direct-app mode relies on macOS per-process event delivery. Most apps accept it; games with custom input loops (e.g. Roblox) may ignore it — verify with a test click." Add a **Test Click** button that fires one direct click. *(Updated 2026-09-20: the "may ignore it" half is now measured fact for games — they read the click's position from the system cursor and drop input while not frontmost — so v2.1 adds the per-app "It's a game" route: real HID-tap clicks at the captured point, one real raise of the game at run start, a topmost-window visibility gate per click, a per-click frontmost guard that refuses (and doesn't count) clicks while the game isn't frontmost, a 15 ms hold floor that caps delivery at ~60 cps, and honest copy that never says "sent" for a click the game ate.)*
- Key events: `postToPid` works reliably per research — allow key presser to target an app too (reuse picker).
- The existing `.cghidEventTap` path stays default; direct-app is opt-in per-run. Self-tag everything so the recorder ignores it.

Tests: window-info filtering logic (pure function over dictionaries), window-local coordinate conversion, background-flag rule (active vs inactive). dlsym wrapper needs a protocol seam for tests.

## Stage C — Humanization Suite (NEW — pure logic, heavily testable)

`Humanizer` utility + settings integrated into AutoClicker, KeyPresser, and MacroPlayer:
1. **Gaussian/box-muller interval jitter** (current ±uniform stays as "uniform" option) — clamped, seeded-testable `RandomNumberGenerator` injection.
2. **Fatigue drift**: intervals gradually lengthen by up to X% then recover sinusoidally over a run (models human slowing).
3. **Rhythm breaks**: every N±jitter clicks, insert a longer pause (configurable range) — "human looks away".
4. **Replay humanization** in MacroPlayer: apply timing jitter factor to event gaps when enabled.
5. Keep min 1 ms floor + all limits clamped. Full unit-test coverage (distribution sanity: mean/variance ranges with fixed-seed RNG, never negative, monotonic deadline safety).

## Stage D — Trigger & Scheduling (extend views/services)

1. **Start at clock time**: time picker; worker waits until wall-clock target (`DispatchWallTime`), then starts. Menu bar shows armed state.
2. **Countdown start**: reuse RunSession countdown with configurable seconds (unifies with A7).
3. **Panic stop already in A9** — done there.
4. **Pause-on-real-input** (politely auto-pause): while clicker runs, a listen-only CGEvent tap watches for non-self-tagged keyDown/mouseDown; on detection, pause the run and show "Paused — you took over" with Resume button + optional auto-resume after N idle seconds. Reuse recorder-tap machinery (listen-only `.cgSessionEventTap`) — factor a small shared `EventTapMonitor` if clean; do not duplicate run-loop code sloppily.

Tests: wall-clock deadline calculation, pause/resume state transitions (pure state machine object), idle-detection timing.

## Stage E — Profiles (NEW sixth UI section)

- Named profiles capturing the **full app state**: clicker settings, key presser, web target, playback options, hotkeys optional (include; they're part of a workflow).
- Store as JSON array in UserDefaults (`profiles` key) + export/import as `.macromakerprofile` JSON documents reusing the `MacroFiles` panel patterns (register UTI in Info.plist + project.yml).
- UI section: list with star/favorite, duplicate, rename, apply, delete; search field. Applying a profile stops running features first (safety).
- Tests: profile Codable round-trip, export/import schema with version field, migration when new settings fields appear (decode-with-defaults tolerant decoding — verify a v1-settings JSON still decodes after new fields added; use `decodeIfPresent ?? default`).

## Stage F — Macro Library (extend Recorder into its own library section)

- Multiple saved macros: in-app library (name, duration, event count, created) backed by a folder in `~/Library/Application Support/Macro Maker/Macros/` as `.macromaker` files + UserDefaults index. Keep autosaved "Last Recording".
- Duplicate / rename / delete / favorite / search.
- **Per-macro hotkey**: extend HotkeyAction model — dynamic actions per macro id (Carbon hotkeys are just registrations; HotkeyService already tracks them). Cap at 10 library hotkeys. Show conflict warnings.
- Step editor v1 (careful, keep it simple but real): the existing events `Table` gains (a) delete selected events, (b) insert wait (dialog: ms), (c) edit event time, (d) insert text-typing step encoded as keyUp/keyDown pairs via `KeyStrokeParser` (`.text` strokes) at insertion point. Recorded merges of consecutive same-char typing stays as-is; editing is enough for v1.
- Tests: library index Codable, file CRUD naming collisions, per-macro hotkey registration model (registration requests, not Carbon itself), step-edit operations on `Macro` (insert-wait shifts subsequent times correctly!).

## Stage G — UI/UX Polish (design pass, all views)

Goal: best-looking autoclicker on macOS, bar none. Native SwiftUI, no assets needed:
1. **Sidebar redesign** (per Architecture note) with SF Symbols, section grouping: Automate (Clicker/Keys/Web), Record (Macros), Library (Profiles/Macros/Triggers status).
2. **Live status hero**: when anything runs, a compact always-visible banner in the main window + the existing menu-bar icon swap gets a subtle countdown/rate label.
3. **Color polish**: semantic accent states (running = green accent, countdown = orange, error = red, paused = indigo) applied consistently via a small `RunPhase` color extension. Respect dark/light automatically — no custom theme engine needed (native materials).
4. **Onboarding**: first-launch sheet (UserDefaults flag) walking the 3 permissions with live grant detection (PermissionService already polls) + "test click" button at the end.
5. **Empty states**: every list/table gets a designed empty state with icon + hint.
6. Keep the window min sizes usable; verify visually with a build (you can't screenshot — rely on careful, conservative layout: VStacks, form sections, no absolute positioning).

## Order of work

A → C → B → D → E → F → G → docs version bumps → final `swift build` + `swift test` → `git add -A && git commit -m "Macro Maker v2.0"`.

If a stage can't be completed in your budget, STOP at a green build with completed stages committed individually per stage (commit after each stage). Never leave the tree broken.

## Explicit NON-goals (do not build)

- Image/pixel detection, SkyLight/SLEventPostToPid private SPI, App Store sandboxing, update checker, localization, movement-path recording. These are deferred by the owner deliberately.
