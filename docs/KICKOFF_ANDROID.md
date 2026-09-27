# Kickoff — Macro Maker for Android (first playable)

Researched 2026-09-27. Paste the box below into a fresh session **only once you've decided to build it**.

## Activate first
- [ ] `brew install --cask android-studio`, open it once, let it install the SDK + one emulator image (API 35). ~5–10 GB.
- [ ] Model: **Fable 5 at `high`** (from-scratch, long-horizon). No `/fast` (Fable has none).
- [ ] Working dir: a NEW repo `~/Projects/macro-maker-android` — Gradle and SwiftPM stay in separate repos.

```
Build Macro Maker for Android — first playable, native Kotlin + Jetpack Compose, in a new repo
~/Projects/macro-maker-android. Read ~/Projects/macro-maker/docs/KICKOFF_ANDROID.md (facts below) first.

Done = all green and shown:
1. An AccessibilityService taps other apps via dispatchGesture(): an instrumented test on the
   emulator taps a test Activity's button N=50 times and the counter reads exactly 50.
2. A floating bubble (overlay permission) over any app: Start / Stop / pick point. Stop also works
   from the notification and when the service is switched off mid-run (test for each).
3. Auto tap: point, interval ms + jitter, stop after N taps or T seconds; a tap SEQUENCE (tap A,
   wait, tap B, swipe) saved as JSON. Unit tests pin the scheduler/jitter/limits.
4. A prominent in-app disclosure + consent screen BEFORE sending the user to Accessibility settings
   (Google Play's AccessibilityService policy — keeps a Play listing possible later).
5. Signed debug APK installs on the emulator via adb; README says how to sideload it.
Out of scope: Play Store listing, key presses into other apps, iPhone.
```

## Measured facts (don't re-research)
- **Taps + swipes, not keys.** `dispatchGesture` taps whatever is on screen at that point. No raw key
  presses into other apps (needs root/ADB); typing into a focused text box works via `ACTION_SET_TEXT`,
  and Back/Home via `performGlobalAction`. No true background app — split-screen is the closest.
- **No recording of real touches** without an overlay that swallows them — v1 = place points, not record.
- **Mac macros don't transfer:** `.macromaker` points are Mac screen coordinates (MACRO_SCHEMA.md says
  point-macros are machine-local). Android keeps its own sequences.
- **Play policy:** automation apps must NOT set `isAccessibilityTool=true`; need the Play Console
  declaration + in-app disclosure + consent. "Autonomous" (AI-decided) actions are banned; a fixed,
  human-defined script is allowed. <https://support.google.com/googleplay/android-developer/answer/10964491>
- **Android 17** revokes the permission from non-accessibility apps **only when the user turns on
  Advanced Protection mode** (opt-in). <https://thehackernews.com/2026/03/android-17-blocks-non-accessibility.html>
- **Sideloading:** unverified-developer installs are blocked from 2026-09-30 in Brazil, Indonesia,
  Singapore and Thailand only; every other country in 2027 (ADB installs still work).
  <https://thehackernews.com/2026/06/google-sets-sept-30-deadline-for.html>
- **Why not the Tauri sibling:** its input engine is desktop-only (enigo/rdev), and the bubble must be a
  native overlay, so Tauri would only reuse the settings screens and would still need a Kotlin service.
- Machine has adb 1.0.41 + OpenJDK 25; no Android Studio yet (checked 2026-09-27).
