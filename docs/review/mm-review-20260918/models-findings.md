# Adversarial review — agent `models`

Scope: `Sources/MacroMaker/Models/`, `Utilities/Persistence.swift`, `Services/MacroFiles.swift`, `MacroLibrary.swift`, `ProfileService.swift`.
Method: read-only; claims verified against code and git history back to v1.0 (`92289cc`).

## Verdict on the TOP-PRIORITY symptom (directApp clicks never arrive)

**No root cause found inside this scope — the settings chain that feeds direct-app clicking is intact end-to-end:**

- `directAppBundleID` / `directAppX` / `directAppY` tolerant-decode correctly (`FeatureSettings.swift:78-80`) and round-trip through `ProfileEntry` wholesale (`Profile.swift:88-94`).
- Point capture → settings → `Plan` is a straight copy with no coordinate mangling (`AutoClicker.swift:520-523` → `Plan.init` at `AutoClicker.swift:99-100`); the capture is a raw CG screen point, which is what `BackgroundPoster.windowPoint` expects.
- The only scope-adjacent way directApp settings could be lost is finding **F3** below (a decode throw resets *all* AutoClicker settings, reverting `target` to `.cursor` and blanking `directAppBundleID`) — but that failure mode is *visible*: the UI would fall back to cursor mode and `directAppProblem` (`AutoClicker.swift:36-46`) would show "Pick an app". The reported symptom (mode stays `.directApp`, clicks posted but never arriving) points at the event-construction/posting layer in `BackgroundPoster.swift` (fields 91/92, subtype, NX_COMMAND flag, `CGEventPostToPid` semantics) — **that file is outside this agent's scope** and should be re-reviewed there.

Findings below are everything adversarially wrong *within* scope.

---

## F1 — One undecodable profile entry silently destroys the entire saved-profiles list (permanent, silent data loss)

**Severity: HIGH** (data-loss grade when triggered; latent) · **Confidence: certain (mechanics), likely (trigger)**

`Services/ProfileService.swift:14`:
```swift
entries = load ? (Persistence.load([ProfileEntry].self, key: Self.storageKey) ?? []) : []
```
with `Utilities/Persistence.swift:5-8`:
```swift
static func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
```

`ProfileEntry` (`Models/Profile.swift:77-107`) has **no custom `init(from:)`** — its decoding is synthesized, which requires every non-optional key (`id`, `name`, all four settings sections, `macro`, and even `isFavorite`, whose property default does not relax synthesis). Any one entry with a missing key, a type mismatch, an unknown enum raw value (`Browser`, `Target`, `Mode`, `LocatorKind` all decode strictly by raw value), or a `Macro` payload of an unknown format version makes the whole-array decode throw → `try?` → nil → `?? []` → the UI shows an empty list, and the very next `save`/`delete`/`rename`/`setFavorite` persists `[]` over the old blob. **All profiles lost, permanently and silently** — no `lastError` is set anywhere on this path.

This is precisely the failure `MacroLibrary.swift:18-23` documents as already fixed for macros ("one such entry threw, `try?` turned the whole result into nil … the loss was permanent … it must cost one row, not all of them") — `MacroLibrary.records(fromIndex:)` decodes per-entry tolerantly; `ProfileService.init` never got the same treatment. Direction: per-entry tolerant decode for the profiles array, mirroring `records(fromIndex:)`.

## F2 — Tolerant decoders accept non-finite doubles that later trap in `Int`/`UInt64` (crash via crafted defaults blob or imported profile)

**Severity: MEDIUM** (app-killing crash; requires corrupt/untrusted input — and untrusted profile import is an acknowledged vector, see the typed-text warning at `AppModel.swift:370-373`) · **Confidence: certain (mechanics), likely (end-to-end)**

`Models/FeatureSettings.swift:57` and `:75` (and every other Double field decoded the same way):
```swift
intervalMs = try c.decodeIfPresent(Double.self, forKey: .intervalMs) ?? 100
...
delayedStartSeconds = try c.decodeIfPresent(Double.self, forKey: .delayedStartSeconds) ?? 0
```

No finiteness check. The codebase itself notes the vector (`Models/Macro.swift:136-137`): *"JSON has no NaN literal, but `1e400` parses to +infinity."* `MacroEvent.time` is guarded against exactly this — **no settings Double is**. Traps reachable from decoded values:

- `intervalMs = 1e400` (or anything > ~1.8e10): `AutoClicker.swift:321-322` `UInt64(delay * 1_000_000_000)` with `delay = inf` (or > `UInt64.max`) **traps** and kills the process on the first tick. Ironically `HumanizerMath.delay` guards `isFinite` (`Humanizer.swift:73`), so the crash only fires when the humanizer is *disabled* — the plain path.
- `delayedStartSeconds = 1e400`: `AutoClicker.swift:126` `countdownExtra: Int(max(0, settings.delayedStartSeconds).rounded())` — `Int(inf)` **traps** at toggle time.

The UI's `IntervalUnit.displayRange` caps user input, but the decode path (defaults blob, and profiles applied via `applyProfile`, which then persists the value straight into UserDefaults via `didSet`) has no clamp. Direction: validate `isFinite` (and a sane range) at decode for every Double setting.

## F3 — Tolerance is only as good as the strictest nested type: `ClickRegion` and `WebTargetSettings` throw the whole settings blob away

**Severity: MEDIUM** (silent full-settings reset — e.g. directApp target/bundle ID wiped) · **Confidence: certain (mechanics), possible (trigger)**

`Models/FeatureSettings.swift:70`:
```swift
region = try c.decodeIfPresent(ClickRegion.self, forKey: .region) ?? ClickRegion()
```
`ClickRegion` (`Models/ClickRegion.swift:5-27`) has **synthesized** Codable — a strict decoder that requires all four keys (`x`, `y`, `width`, `height`); its `init(x:y:width:height:)` defaults are irrelevant at decode time. If the stored `region` dict is missing one key or holds a type mismatch, `decodeIfPresent` **throws** (it does not fall back to the `??` default — that only catches key-absence/null), the whole `AutoClickerSettings` decode fails, `Persistence.load`'s `try?` returns nil, and `AutoClicker.swift:9` falls back to `?? AutoClickerSettings()` — **every AutoClicker setting silently resets**: target back to `.cursor`, `directAppBundleID` wiped, burst/counts/limits gone.

Same hole one level up: `WebTargetSettings` (`Models/FeatureSettings.swift:146-167`) also has no custom `init(from:)` (unlike `AutoClickerSettings`, `KeyPresserSettings`, `PlaybackSettings`, `HumanizerSettings`, which are all tolerant), so `Persistence.load(WebTargetSettings.self, …) ?? WebTargetSettings()` at `WebClicker.swift:22-23` resets all web-target settings on a single missing key. Additionally, any *present-but-unreadable* enum value (a raw value not in the case list — e.g. a blob from a newer build) throws rather than defaulting; `decodeIfPresent` never rescues a bad value. Direction: custom tolerant `init(from:)` for `ClickRegion` and `WebTargetSettings`.

## F4 — A `MacroRecord` whose stored file name fails the safe-name check is silently dropped and then permanently erased from the index

**Severity: MEDIUM** (silent, permanent, unrecoverable row loss; file orphaned with no recovery path) · **Confidence: certain**

`Models/MacroRecord.swift:32-35`:
```swift
guard MacroLibraryRules.isSafeFileName(decodedFileName) else {
    throw DecodingError.dataCorruptedError(forKey: .fileName, in: c, ...)
```
combined with `MacroLibrary.swift:24-30`:
```swift
nonisolated static func records(fromIndex data: Data) -> [MacroRecord] {
    struct Tolerant: Decodable { ... record = try? MacroRecord(from: decoder) }
    return ((try? JSONDecoder().decode([Tolerant].self, from: data)) ?? []).compactMap(\.record)
}
```

The path-traversal defence is right to throw. But the drop is *silent* — no `lastError`, no UI trace — and because the row is gone from the in-memory list, the **next `persist()` of any kind (a favorite toggle is enough) writes the reduced list back over the index**, permanently. The row's file is still on disk, but nothing ever re-indexes it (the library never scans the folder; the index is the sole source of truth by design), so the loss has no recovery path inside the app. The doc comment says the bad row "must cost one row, not all of them" — it does, but the cost is paid invisibly and irreversibly, where the user's only remediation is re-adding the macro by hand from a file they must find in Finder themselves. Direction: surface dropped rows (a count + `lastError`) instead of pure `compactMap`.

## F5 — Applying a profile during an active point-capture lets the pending capture overwrite the just-applied settings

**Severity: MEDIUM** (broken edge case; user-visible settings flip seconds after Apply) · **Confidence: likely**

`AppModel.applyProfile` (`App/AppModel.swift:82-90`) stops runs and assigns settings but never cancels an in-flight point capture:
```swift
stopAll()
autoClicker.settings = entry.autoClicker
...
```
`AutoClicker.completePick` (`AutoClicker.swift:506-528`) fires 1–3 s after `beginPick`, reads the **current** settings (now the profile's), mutates them, and re-assigns:
```swift
var updated = settings
...
case .directAppPoint:
    updated.directAppX = location.x.rounded()
    ...
    updated.target = .directApp
settings = updated
```
So: start "pick point", click Apply mid-countdown → the profile lands → then the capture completes and silently rewrites `target` (and `x`/`y` or the region) on top of it. `toggle()` calls `cancelPick()` (`AutoClicker.swift:116`); `applyProfile` (and `stopAll`) do not. Direction: `cancelPick()` from `applyProfile`.

## F6 — `stopAll()` bypasses `AutoClicker.endRun()`: pause-monitor and 1 Hz resume timer leak past "Stop everything" / profile apply

**Severity: LOW** (wasted event tap + timer; no wrong clicks observed) · **Confidence: certain (mechanics)**

`AppModel.stopAll()` (`App/AppModel.swift:263-269`) calls `autoClicker.session.stop()` directly — the raw state-machine stop — while the teardown lives only in `AutoClicker.endRun()` (`AutoClicker.swift:134-141` → `tearDownPauseWatching()` at `:242-246`):
```swift
private func endRun() {
    tearDownPauseWatching()
    session.stop()
    ...
```
After stopping a `pauseOnRealInput` run via the "Stop everything" hotkey or profile apply, `RealInputMonitor` keeps its tap installed and `resumeTimer` keeps firing every second until the next run arms a new pair or the app quits. `pauseIfNeeded` no-ops on the new settings, so no misbehaviour — just a leak the state machine has an owner for. (`currentPlan`/`clicksDone`/`runWarning` are likewise left stale, though `resume()`'s `isPaused` guard makes them unreachable.) Direction: route stopAll through a per-feature teardown, not the bare session.

## F7 — Applying a macro-less profile keeps the current macro loaded: the profile's playback settings get attached to a stale, unrelated macro

**Severity: LOW** (design asymmetry, possible surprise playback) · **Confidence: possible**

`AppModel.applyProfile` (`App/AppModel.swift:88`):
```swift
if let profileMacro = entry.macro { load(profileMacro) }
```
A profile saved with no macro (the documented norm — `Profile.swift:24` "most profiles won't have one") restores *no* macro when applied: the user's currently-loaded recording stays, but now plays with the freshly-applied `PlaybackSettings` (speed, repeats, humanizer). Apply is not a faithful snapshot restore in that direction, and the mixed state is invisible in the UI. Direction: decide and document (either clear the macro or warn).

## F8 — Fail-open `try?` on every persistence write: a failed autosave/library/index write is indistinguishable from success

**Severity: LOW** (silent loss of the last recording on a full/slow disk, exactly when the app is about to quit) · **Confidence: certain**

`Services/MacroFiles.swift:26-27`:
```swift
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try? macro.jsonData().write(to: url, options: .atomic)
```
`shutdown()` (`AppModel.swift:238-241`) relies on this path to survive quitting; a throw here (disk full, sandbox denial) discards the last recording with no error channel anywhere (`MacroFiles` has no `lastError`, unlike both services). `Persistence.save` (`Persistence.swift:11`) is the same shape: `guard let data = try? … else { return }` — an encode failure is a silent no-op. Atomicity itself is fine (all file writes use `.atomic`; see F11 for the one exception that matters). Direction: surface autosave failures once.

## F9 — `MacroLibrary.add` doc comment promises update-on-same-id; the code always inserts a new record

**Severity: LOW** (comment lies; UI implications) · **Confidence: certain**

`MacroLibrary.swift:61-62`:
```swift
/// Returns the record (same id is fine: a second save with the same id updates).
```
versus `:71`:
```swift
var record = MacroRecord(id: UUID(), name: name, createdAt: Date(), fileName: fileName)
```
Every `add` mints a fresh id and inserts at 0 — there is no update branch, and `LibrarySection.swift:34` calls `add` unconditionally. Saving the same recording twice creates two library entries and two files ("login.macromaker", "login-2.macromaker"), which is arguably intended library-copy semantics, but the comment describes behaviour that does not exist, and it is exactly the kind of stale contract that misleads the next change. Direction: fix the comment or implement the update.

## F10 — `rename`: `try?`-swallowed move still updates the index, desyncing it from disk

**Severity: LOW** · **Confidence: certain (mechanics), low likelihood**

`MacroLibrary.swift:115-116`:
```swift
try? FileManager.default.moveItem(at: oldURL, to: newURL)
records[index].fileName = newURL.lastPathComponent
```
If `moveItem` throws (the realistic case: the old file is missing — an orphan record being renamed), the record's `fileName` is rewritten anyway, so the index now points at a file that never existed while the old one (if present under a name that failed to move) sits on disk unindexed. The rename "succeeds" in the UI with no `lastError`. (Collision is pre-empted by `uniqueFileName`, so failure is mostly the orphan path — but that is exactly when users rename to *fix* things.) Direction: update the index only on a successful move.

## F11 — One corrupt hotkey entry silently resets every custom hotkey to defaults

**Severity: LOW** (silent settings loss, same fail-open family as F1) · **Confidence: certain (mechanics)**

`HotkeyService.swift:49` (`?? [:]`) plus `Models/HotkeyAction.swift:122-129`:
```swift
if let parsed = HotkeyAction(rawValue: name) { self = parsed }
else { throw DecodingError.dataCorrupted(...) }
```
The stored `[HotkeyAction: KeyCombo?]` dictionary decodes strictly: one unknown action name (a deleted builtin case, a malformed `macro:` uuid, a hand-edited plist) throws, `Persistence.load`'s `try?` yields nil, and `?? [:]` restores the six default combos — the user's customised shortcuts are gone on next launch with no report. The model is in this scope; the consuming `init` is not. Direction: per-entry tolerant decode, as `MacroLibrary` already does.

## F12 — `save()` matches profiles by name case-insensitively: a case-variant name silently *replaces* a different profile; `importFile` freely creates duplicate display names

**Severity: LOW** · **Confidence: certain (mechanics), possible (impact)**

`ProfileService.swift:27-28`:
```swift
let existing = entries.firstIndex { $0.id == entry.id }
    ?? entries.firstIndex { $0.name.localizedCaseInsensitiveCompare(entry.name) == .orderedSame }
```
Saving the current setup as "GAMING" overwrites the existing "Gaming" entry (its id and favourite are kept, its settings replaced) instead of erroring or suffixing — the update-by-name semantics the comment endorses, but the replace is silent and the overwritten settings are unrecoverable. Meanwhile `importFile` (`:129`) inserts imported entries with no name-collision check at all, so the list can hold two "Login" entries, after which Apply-by-row still works but any future same-name `save` arbitrarily picks the first match. Direction: collide-check on import; decide the case-variant rule explicitly.

---

## Hunt items with nothing found (explicit)

- **Duplicate macro ids**: no path found. `add` (`MacroLibrary.swift:71`) and `duplicate` (`:136`) both mint fresh UUIDs; nothing reuses ids; `delete`'s `removeAll { $0.id == … }` is idempotent-safe even under hypothetical duplicates.
- **JSON write atomicity**: all file writes use `.atomic` (`MacroFiles.swift:27,54`, `MacroLibrary.swift:80`, `ProfileService.swift:98`); a crash mid-save cannot corrupt the autosave, library files, or exports. UserDefaults writes go through cfprefsd. The one *silent* write failure is F8, which is an error-reporting hole, not an atomicity one.
- **Equatable from stale snapshots**: `Macro`/`MacroRecord`/`Profile` Equatable are synthesized over live values and only used for identity-agnostic comparisons; no stale-snapshot equality dependency found.
- **MacroLibrary index drift beyond F4/F10**: `uniqueFileName` correctly unions disk + index (case-insensitively) on every add/rename/duplicate; the isOrphan flag can be stale between persists but `load()` re-checks existence independently (`MacroLibrary.swift:165-169`), so the worst case is a stale warning, not a wrong load.