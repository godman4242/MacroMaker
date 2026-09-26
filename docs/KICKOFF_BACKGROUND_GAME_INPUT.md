# Kickoff — background clicking into a game while another app owns the machine

> **Status 2026-09-26 (v2.1.1):** still open for GAMES — nothing below has changed for Roblox.
> Shipped around it: macro **Play into** (a recorded macro plays straight into one background
> app — AppKit measured live: clicks, keys and typed text land with the app inactive and the
> cursor untouched), **Brave** in Web Target (background-tab clicking), and a fix for replayed
> clicks missing ("Follow the window" split clicks into drags). Roblox is refused up front by
> `MacroPlayer.playIntoProblem`. Open follow-up: measure whether Chromium targets accept clicks
> with ONLY the focus record (no defocus record to the user's front app) — if so, the one-time
> "focus nudge" that can pause the user's own game disappears.

Written 2026-09-20, after v2.1 commit `1fb0f2b` (the frontmost game route, shipped green:
311 tests / 51 suites). Paste this whole file as the first message of a fresh session.

**Working directory: `~/Projects/macro-maker`** — a SwiftUI menubar app (macOS 26.5.2,
Apple Silicon). All commands below assume that cwd.

## The need (Kheshav's words, 2026-09-20)

> "it still does not work when i switch to another app, i need that feature so that i can
> work or do other stuff while the clicker is clicking in roblox despite it running in
> the background. eg playing minecraft full screen while the macro is clicking where i
> want in the roblox"

The frontmost case is DONE and works: the per-app **"It's a game"** toggle
(`directAppGameRoute`) switches an app's clicks to real input — the run raises the game
once, then posts each click at the HID tap with a 15 ms hold, refuses with a warning
while the game isn't frontmost, and never says "sent" for a click the target could eat.
This session is the **background** case: clicking Roblox while Minecraft (fullscreen) or
another app is the one being used.

## The wall, as already measured — do not re-litigate without new evidence

Two independent sub-walls, both measured on Roblox, macOS 26.5.2:

1. **Aim.** Roblox reads a click's POSITION from the system cursor, not from the posted
   event's fields — measured: clicks posted "at" a configured point landed wherever the
   live cursor happened to be. The shared cursor is a single WindowServer-wide value;
   while the user is in Minecraft it sits in Minecraft. Any background route that does
   not solve aim clicks into the wrong app even if acceptance worked.
2. **Acceptance.** Games discard input while their app is not active/frontmost —
   measured: a backgrounded Roblox is pixel-identical before and after a posted click,
   while `CGEventPost` reports success. Focus is the blocker, not anti-cheat, not the
   delivery recipe. macOS has exactly one active app per login session.

Together they say: two simultaneously-interactive apps on one stock macOS session is
architecturally impossible — you cannot play Minecraft (which needs the one cursor and
the one focus) while Roblox auto-clicks, unless a route exists that BOTH delivers aimed
input without the shared cursor AND gets a backgrounded game to accept it.

**The mission is therefore NOT "make it work" — it is: rigorously close the experiment
matrix, then ship the honest consequence of whichever way it lands.** The expected
outcome is a documented NO-GO plus real workarounds in the UI. A fake "background mode"
that silently clicks into whatever app has focus would be the worst possible ship.

**Time estimate: one ~2–4 h session** (≈1 h experiments, ≈1 h ruling + UX + docs, plus
red-proofs and a full suite run).

## Phase 1 — the experiment matrix

Each cell gets a written **GO / NO-GO** in the decision doc with pasted evidence. The
protocol for every cell: capture the Roblox window region before and after the click,
pixel-compare (screencapture + cmp, or a small Swift helper); ALWAYS run the control case
first (frontmost + real click = must show change) so a NO is provably a discard and not a
broken probe. Screenshot evidence copies are study-only and stay out of the commit.

- **E1 — the Chromium recipe on Roblox.** `BackgroundPoster.activateWithoutRaise` (the
  SkyLight call that made Chromium-class apps accept background input, commit `6ba2090`)
  applied to Roblox, then the PID route with window fields. The aggregate memory says
  "not the recipe" blocked games — but the specific cell (input-active + PID post into a
  backgrounded Roblox) has no written numbers. Document it properly.
- **E2 — real HID click at a visible, backgrounded Roblox window.** Windowed Roblox on
  screen, another app frontmost; a real HID-tap click physically lands on Roblox's
  window (the OS routes by point). Does Roblox's loop discard it? Write the number.
- **E3 — private `CGEventSourceStateID`.** Events posted with a private source state
  update that state's own mouse position without moving the shared cursor. Is there any
  posting route through which a game reads an aimed position from a source state instead
  of the shared cursor? Expected NO (aim sub-wall), never measured.
- **E4 — Roblox client FFlags.** Research `client_app_settings.json` (the Roblox FFlag
  database, Roblox dev forum): any flag that processes input while unfocused, or reads
  position from event fields. Read-only research; a candidate flag gets tested with the
  same protocol. Ground in real sources, never model memory.
- **E5 — ecosystem scan.** Does ANY macOS tool claim background clicking into
  Roblox/Unity/SDL games, and by what mechanism? (MurGaa, Auto Mouse Click, Hammerspoon
  threads, Roblox dev forum.) Every claim grounded in a real source link.

## Phase 2 — ruling + ship (both outcomes ship something)

**All NO-GO (expected):**
- Decision doc `docs/BACKGROUND_GAME_INPUT.md`: the full matrix, protocols, pasted
  numbers, the ruling, and the workarounds below.
- README (games row + route paragraph) and the in-app caption get the definitive
  statement in plain English, plus the real options:
  1. **Second Mac**: Roblox frontmost on the other machine with Macro Maker on it — the
     shipped game route already covers this exactly; view/check it via Screen Sharing
     from the main machine. (Roles can flip: Roblox on the Mac mini, Minecraft on any
     other device.)
  2. **Frontmost co-use**: the clicker runs while Roblox is frontmost and everything
     else is passive (reading, watching) — what v2.1 ships today.
  3. **Roblox-side macros**: out of scope — bannable and not this app.
- Name the near-miss honestly: a macOS VM on the same machine is architecturally sound
  (a VM has its own WindowServer), but this 8GB Mac mini cannot carry Minecraft + Roblox
  + a macOS VM simultaneously — vetoed on RAM, not on theory.

**Any GO (not expected):** implement behind the existing per-app flag, red-proof the new
path (plant the failure → watch RED → fix → watch GREEN), full suite green, README +
V2_SPEC updated in the same commit.

## Done criteria (measurable)

1. Every cell E1–E5 has a GO/NO-GO + pasted evidence in `docs/BACKGROUND_GAME_INPUT.md`.
2. README + in-app caption updated IN THE SAME COMMIT as any copy change; no weasel
   words ("may not work") — the ruling names what is impossible and what to do instead.
3. `swift build` green and the FULL suite green via `./scripts/test.sh` (baseline: 311
   tests / 51 suites, ~15 s) with the output pasted. Docs-only changes still run it.
4. A verdict Kheshav can act on for "Minecraft fullscreen + Roblox clicking" on this
   8GB Mac mini — a concrete recommendation, not a survey.

## Rules that bind (this project's standing contract)

- **Tests:** `./scripts/test.sh` (bare `swift test` FAILS — CLT toolchain, no Testing
  module). Filter: `--filter 'nameA|nameB'` (substring or ERE, never `\|`).
- **Red-proof every new guard**: plant the failure, watch the named test go RED, restore
  byte-identical. A plant that stays green is a missing test — write the test.
- **Measure, don't infer**: every claim about what macOS or Roblox does comes from a
  run, with the output pasted.
- **Subagents**: unlimited count on Ollama Cloud models (Kheshav, 2026-09-20 — flat
  subscription) — but READS ONLY in fan-outs; every write stays in the one parent loop;
  agents write findings to disk before returning; an empty reply is NO-OUTPUT, never a
  pass; a dead run and a found-nothing run must never look the same.
- **No fake "sent"** — honesty in UI is this app's spine (the whole v2.1 line exists
  because "Test click sent." lied).
- **Commit + push when green.** Commit message ends with
  `Co-Authored-By: Claude Code <noreply@anthropic.com>`.
- **Stuck-stop**: after 2 failed attempts at a cell, stop — write what was tried + the
  evidence, move to the next cell. Do not grind one cell.

## Rejected up front (do not re-litigate; reasons measured or architectural)

- **Multi-cursor / second pointer device**: macOS has one WindowServer cursor; all
  pointing devices drive it.
- **Focus ping-pong** (raise Roblox per click, refocus Minecraft): steals focus every
  click; two fullscreen apps each own a Space, so every flip slides the whole display.
  Unusable while playing.
- **Roblox window floating above Minecraft** (private window-level calls): still not
  frontmost — acceptance sub-wall unchanged.
- **Fast user switching** (Roblox in the second login session): switched-away sessions
  deactivate their apps — same acceptance wall.
- **Posting at the HID tap while Minecraft is used**: clicks land wherever the cursor
  is — in Minecraft. Aim sub-wall.
- **In-game/Roblox-client automation**: bannable, out of scope, not this app.

## VERIFY (Kheshav, at session end)

1. If NO-GO ruling: with "It's a game" ON, read the caption — VERIFY it names the
   impossibility and the second-Mac option in plain English, no hedging.
2. If any GO: Roblox backgrounded, Minecraft fullscreen, run ON — VERIFY clicks land at
   the captured spot in Roblox while Minecraft stays focused and fully usable.

## Where things live (symbols, not line numbers)

`directAppGameRoute` — `Sources/MacroMaker/Models/FeatureSettings.swift` ·
`gameRouteClick` / `gameRouteTestClick` — `Sources/MacroMaker/Services/AutoClicker.swift` ·
`activateWithoutRaise`, `topmostWindowOwner`, `mainThreadRunner`, the PID route —
`Sources/MacroMaker/Services/BackgroundPoster.swift` ·
`cursorLocationReader` / `mouseBuilder` seams — `Sources/MacroMaker/Services/EventSynthesizer.swift` ·
`gameRouteHold` (15 ms floor) — `Sources/MacroMaker/Utilities/TickSchedule.swift` ·
the 21-test suite — `Tests/MacroMakerTests/GameRouteTests.swift` ·
README games table + route paragraph — `README.md` (~lines 13–40) ·
spec changelog — `docs/V2_SPEC.md` (§44).