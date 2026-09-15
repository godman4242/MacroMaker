# MacroMaker — Adversarial Architecture Review (SSHD-style)

Inherited from the SSHD-1-1 `sshd-architecture-review` workflow (wf_fb97818a-47c).
Adapted 2026-09-16 for the MacroMaker autoclicker/macro tool.

## The One Law — ARCH-A
EVERY finding must cite a real file:line, a pasted command output, or a build/test log
line. A finding without one is an OPINION and MUST be dropped. Verify each cite by
running the command before reporting it.

## Fail Closed
If you found nothing, say so explicitly and return an empty findings array. A padded
finding is WORSE than an empty return. Never invent a line number.

## Write To Disk Before Returning
FIRST action after forming conclusions: write your structured JSON to your assigned
path under `~/Projects/macro-maker/docs/review/`. Then return. (SSHD lost work to
session limits 11×; disk-before-return is why it lost no data.)

## Findings Schema (same as SSHD)
{ integrity, wrote_to, summary, findings[] }
finding: { id, claim, cite, evidence, severity(kills-project|expensive|minor),
          rule_targeted, proposed_change, is_deletion, word_delta }

## Phases
1. **Evidence** (parallel): history miner (git log/build log) + blind lenses:
   - correctness (concurrency, tick scheduling, race conditions)
   - security (injection, privilege, macro file parsing)
   - permissions (Accessibility/Input Monitoring UX)
   - cross-platform readiness (platform-coupled code inventory)
   - performance (event tap load, CPU on long runs)
   - UX/usability (hotkey conflicts, error surfacing)
   - persistence/schema (macro JSON versioning, migration)
   - test adequacy (what's untested, red-first protocol)
2. **Adversary**: one argues every proposed change is wrong (second-order effects,
   rollback cost); one argues do-nothing.
3. **Verify**: re-run every cite; audit the review's own gate (SSHD gate scored 4 RED
   of 6 — learn from that: verify the verify).

## Sizing
Fan-out sized to codebase, not to budget. ~36 Swift files → 9 lenses + 1 history
miner + 2 adversaries + 2 verifiers = 14 agents. Do NOT pad to 64: fail-closed law.

## Cross-Platform Track (decided 2026-09-16, Kheshav-requested)
- Native macOS app (SwiftUI) finishes first — it is the reference implementation.
- Cross-platform sibling: **Tauri v2** (macOS/Windows/Linux), input via `enigo`,
  global hotkeys via `global-hotkey` crate, shared macro JSON schema v1 with the
  Swift app. Schema doc: `docs/MACRO_SCHEMA.md`.
- Platform-coupled code inventory from the review feeds the Tauri port checklist.