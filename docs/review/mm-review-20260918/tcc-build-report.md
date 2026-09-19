# Adversarial review — agent `tcc-build`

**Scope:** `scripts/build-app.sh`, `scripts/test.sh`, `scripts/make-icon.swift`, `Support/MacroMaker.entitlements`, `Support/Info.plist`, git history.
**Method:** read the files AND verified against live system state — dumped the built app's actual entitlements and designated requirement, decoded the TCC `csreq` blobs from `/Library/Application Support/com.apple.TCC/TCC.db`, inspected the "Kheshav Dev" certificate chain with openssl, and evaluated the stored TCC requirements against the current build with `codesign -v -R`.

## Verdict on the TOP-PRIORITY symptom (entitlements/TCC exoneration, with evidence)

The `.directApp` failure is **not** an entitlements or sandbox problem — every code-signing precondition for `CGEventPostToPid` is met on the shipped build:

1. **Sandbox is OFF in the actual shipped binary**, not just in the source file. Dumped from `build/Macro Maker.app`:
   ```
   com.apple.security.app-sandbox = false
   com.apple.security.automation.apple-events = true
   ```
   That is the complete entitlement set — **no `get-task-allow` leftover** (`codesign -d --entitlements -` shows exactly two keys).
2. **Hardened runtime is on and passes** with the self-signed cert: `CodeDirectory … flags=0x10000(runtime)`, `codesign --verify --strict` → "valid on disk / satisfies its Designated Requirement". Apple's runtime enforcement does not treat self-signed anchors differently for this entitlement class (no Apple-restricted entitlements are requested; `automation.apple-events` is a general entitlement).
3. **The Accessibility TCC grant matches the current build.** The system TCC row for `kTCCServiceAccessibility / com.kheshav.MacroMaker` (auth_value=2, 2026-09-17 17:44:55) decodes to:
   ```
   identifier "com.kheshav.MacroMaker" and certificate root = H"b094509c153b8d6a005805800b13c7b935387190"
   ```
   and `codesign -v -R='<that requirement>' build/Macro Maker.app` → **rc=0**. The cert chain is `CN=Kheshav Dev` ← `CN=Kheshav Dev CA` (self-signed root, valid 2026→2036, leaf EKU = Apple codeSigning `1.2.840.113635.100.6.1.3` + Code Signing, KeyUsage digitalSignature) — a correctly-built codesigning cert.
4. **The universal binary is real**, not faked: `codesign -d` reports `Mach-O universal (x86_64 arm64)`; the per-triple `.build/arm64-apple-macosx` and `.build/x86_64-apple-macosx` dirs exist and `lipo -create` genuinely combines two SwiftPM builds.

So the root cause lives in the event recipe / window targeting (other agents' scope — `BackgroundPoster.mouseEvent` fields 91/92, subtype 3, NX_COMMAND), **or** in the one permission gap below, which is the only in-scope lead that fits the symptom's shape.

## Findings

### 1. MEDIUM — `kTCCServicePostEvent` is never preflighted or requested; the app holds every TCC grant except the one service other clickers have
**Evidence:** `PermissionService.swift:18-20` checks only `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()`; `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` (public API, `CGEvent.h:405-408` in the installed SDK) appear nowhere in `Sources/`.
Live TCC DB (`/Library/Application Support/com.apple.TCC/TCC.db`): MacroMaker has `kTCCServiceAccessibility=2`, `kTCCServiceListenEvent=2`, `kTCCServiceSystemPolicyAllFiles=2` — but **no `kTCCServicePostEvent` row at all**. Working clickers on this machine hold it: `com.chaoshidai.MouseClicker → PostEvent=2`, `com.parallels.desktop.console → PostEvent=2` (denied example: `com.autoclicker → PostEvent=0`).
**Why it matters:** if this Tahoe build gates `CGEventPostToPid` (per-process posting) on `kTCCServicePostEvent` while the HID-tap path (`CGEventPost(tap: .cghidEventTap)`, `EventSynthesizer.swift:139`) rides the Accessibility grant, that exactly reproduces the symptom: frontmost-mode clicks land, direct-app clicks silently never arrive, and no prompt ever fires because the app never calls the request API. The absence of a PostEvent row (TCC normally writes a denied row on a failed check — compare the ListenEvent row that exists) is also consistent with a silent gate.
**Confidence:** possible — not proven; frontmost-mode working is compatible with this story, but the recipe could equally be the culprit. This is the one cheap falsification test worth running before touching the recipe: **one debug build that logs `CGPreflightPostEventAccess()` in direct mode** — false ⇒ this finding is the root cause; true ⇒ rule it out and hunt the event fields.

### 2. MEDIUM — commit bdc0289's "TCC grants survive rebuilds" is only true for grants issued *after* the cert switch; the pre-existing Input Monitoring grant is cdhash-pinned to two stale builds and breaks on every rebuild
**Evidence:** the `kTCCServiceListenEvent / com.kheshav.MacroMaker` row (2026-09-17 06:03:42, i.e. hours *before* the cert was created at 17:20 GMT) decodes to:
```
cdhash H"266bc6af5e99664dc9a7de6a26b2f148fdec7f59" or cdhash H"3e1c541ab1a1fe8af52e8db319492ed8047505ba"
```
`codesign -v -R='<that>' build/Macro Maker.app` → **rc=3, "code failed to satisfy"**. The commit message and `build-app.sh:19-21` ("an ad-hoc signature's … every build looks like a new app to TCC and macOS re-prompts. A certificate-anchored DR does not") over-claim: only the Accessibility grant was re-issued against the cert root; Input Monitoring still goes stale per rebuild and still needs the README's remove-and-re-add dance (`README.md:89` — which the commit arguably makes misleading for that one permission).
**Why it matters:** the owner believes the fix made *permissions* stable; recording (Input Monitoring) still breaks silently per rebuild, and nothing in the app or docs says the fix is grant-by-grant, not app-wide.
**Confidence:** certain (both csreq blobs decoded and evaluated against the current build).
**Direction:** re-grant Input Monitoring once now (delete stale row, relaunch, approve) so it anchors to the cert root.

### 3. LOW — `SIGN_IDENTITY=""` cannot select the ad-hoc fallback; empty string is silently treated as unset
**Evidence:** `build-app.sh:17` `SIGN_IDENTITY="${SIGN_IDENTITY:-}"` + lines 18-27: an explicitly-passed empty identity falls into the auto-select branch and signs with "Kheshav Dev" instead of ad-hoc. Anyone scripting "force ad-hoc this once" (`SIGN_IDENTITY= ./scripts/build-app.sh`) gets a cert-signed build with no warning.
**Confidence:** certain.
**Direction:** distinguish unset from empty (`${SIGN_IDENTITY-}`) or document `-` as the ad-hoc override (which already works).

### 4. LOW — `make-icon.swift` exits 0 when `iconutil` fails, and writes its output relative to the CWD
**Evidence:** `make-icon.swift:57-62`: `process.waitUntilExit(); print(status == 0 ? "Wrote…" : "iconutil failed")` — a failed `iconutil` (e.g. `Support/` doesn't exist because the script was run from `scripts/` instead of the repo root, as line 2 requires) leaves the **stale old icon in place and the script still exits 0**. A pipelined run would never notice.
**Why it matters:** a regenerated icon silently not landing means the app ships with an icon that no longer matches the source of truth.
**Confidence:** certain.
**Direction:** `exit(process.terminationStatus)` and resolve the output path from `#filePath` instead of CWD.

### 5. LOW — the minimum-macOS value exists in FOUR places; the build guard pins only two of them
**Evidence:** `14.0` appears in `Support/Info.plist:28` (`LSMinimumSystemVersion`), `project.yml` (`deploymentTarget` and `MACOSX_DEPLOYMENT_TARGET`), and `Package.swift:9` (`.macOS(.v14)`). `build-app.sh:32-35` greps only `project.yml`; a future bump that edits the plist and project.yml but not `Package.swift` produces a SwiftPM build whose availability gates silently disagree with the declared minimum. (Twin-value rule: four copies, two pinned.)
**Confidence:** certain about the structure; the failure is latent (all four currently say 14.0).
**Direction:** extend the guard to grep `Package.swift`, or derive the triple from one file.

### 6. LOW — `test.sh`'s CLT detection is a substring match; the workaround itself is verified real and does not mask failures
**Evidence:** `test.sh:8` `[[ "$DEV" == *CommandLineTools* ]]` — an Xcode at a path merely *containing* "CommandLineTools" (renamed copy, alternate toolchain location) would take the CLT branch and inject bogus `-F`/rpath flags. Positive verification: `xcode-select -p` → `/Library/Developer/CommandLineTools`, and `$DEV/Library/Developer/Frameworks` **does contain** `Testing.framework` (+ `_Testing_*` variants) and `…/usr/lib` contains `lib_TestingInterop.dylib`, so the flag set points at real files; `set -euo pipefail` + `exec` means a missing framework fails loudly, not silently. No masked-failure bug found.
**Confidence:** certain for the mechanism, the misfire is an edge case.

### 7. LOW — `swift build` runs twice per arch; second run is a redundant no-op invocation
**Evidence:** `build-app.sh:40-41` builds, then immediately re-invokes `swift build --show-bin-path` to discover the path — a second full process launch (incremental no-op) per arch. Harmless, pure latency.
**Confidence:** certain.
**Direction:** compute the path once from `swift build --triple … --show-bin-path` before building.

## Verified negative results (checked, not assumed)
- Entitlements file syntax valid; applied at sign time and present in the shipped binary (both keys).
- `LSMinimumSystemVersion` 14.0 ↔ `project.yml` consistency guard passes right now; `CFBundleShortVersionString` 2.0.8 / `CFBundleVersion` 9 bumped together in bdc0289.
- No `get-task-allow` anywhere in the shipped signature.
- `--timestamp` correctly gated to `Developer ID*` identities (timestamping a self-signed cert would fail); ad-hoc fallback with `--options runtime` is legal.
- Self-signed cert + user-domain-trusted root: **Accessibility grant persistence across rebuilds is verified TRUE on this machine** (root-anchored csreq satisfies the current build) — the commit's core mechanism works; only its scope is overstated (finding 2).
- The x86_64 slice is genuinely cross-compiled (`.build/x86_64-apple-macosx` exists), so the universal claim in the script header is honest.

## Bottom line for the owner's hunt
Nothing in signing, entitlements, or the build blocks `CGEventPostToPid` — that haystack is empty, with dump-level evidence. Before deep-diving the private-field recipe, spend two minutes on finding 1's falsification test (log `CGPreflightPostEventAccess()` from a debug build in direct-app mode): it is the only untested permission on the direct-app path, and this machine's TCC DB shows exactly the clicker apps that work holding the grant Macro Maker lacks.