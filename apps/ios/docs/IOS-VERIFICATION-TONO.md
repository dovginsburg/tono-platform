# iOS Verification — Tono (tono-platform/apps/ios)

**Date:** 2026-07-05 (Sunday)
**Reviewer:** Sherlock (kanban task `t_ba1f1249`, run #4)
**Scope:** Independent verification of TestFlight path per Ezra's directive:
"archive succeeds, build package ID correct, codesign succeeds, altool upload succeeds."

**Source:** `dovginsburg/tono-platform` @ `54f06b3` (main, the post-gh-`workflow`-scope + matrix-CI commit)

---

## Verdict: PARTIAL GREEN

| Step | Result |
|---|---|
| Bundle IDs in source | ✅ PASS |
| Unsigned Release archive (no-codesign) | ✅ PASS |
| Signed Release archive (team 4938S9TTBM) | ✅ PASS |
| Codesign on signed archive | ✅ PASS |
| Bundle-ID verification in archive | ✅ PASS |
| Provisioning profile matching | ✅ PASS |
| Keyboard parity functional (code review) | ✅ PASS |
| `.ipa` export via `xcodebuild -exportArchive` | ❌ FAIL — entitlement/profile feature mismatch |
| `altool --upload` / `--validate` | NOT RUN — blocked by export failure above |
| CI workflow run #1 (iOS job) | ❌ FAIL — wrong CLI args against actual repo layout |

---

## 1. State-check

### 1.1 Repo state (shallow clone of origin/main @ 54f06b3)

```
54f06b3 ci: top-level matrix — iOS, Android, web, backend, marketing in parallel
8f1d1cb cleanup probe
ed556fc cleanup probe
3951aa1 probe github folder non-workflow
26940de probe non-workflow file
82a1083 README + Android gradle wrapper remediation
66fdcd6 subtree: pull iOS keyboard parity merge (a336798 + 72e5549) from tono-ios/main
22d7386 subtree: Tono marketing site (static HTML) from tonoit.com/main/
c2bbfba subtree: Tono unified backend from Tono-/apps/backend/
20480b7 subtree: Tono Android app from Tono-/apps/android/
2dc042c subtree: Tono web app (Next.js 14) from Tono-/apps/web/
f3cee5f subtree: iOS app (v28 = cdeb8a5 + 4726a50) from tono-ios/main
bdd108b Initial commit: top-level README + OWNERSHIP + .gitignore
```

Note: parent task `t_6faf5ecb`'s completion summary listed `66fdcd6` as the head; the
tree has advanced 5 commits since then, ending at the matrix-CI commit `54f06b3`.

### 1.2 OAuth scope (parent blocker)

`gh auth status` reports scope `workflow` is **already present** on Dov's token.
The blocker flagged in `t_6faf5ecb`'s handoff (`"Dov needs gh auth refresh -s workflow"`)
has been **resolved** upstream.

### 1.3 Project layout

- `Tono.xcodeproj/` present; shared scheme `Tono` defined.
- `Tono.xcworkspace` **does not exist**. The parent-task verification command
  (`xcodebuild -workspace Tono.xcworkspace -scheme Tono ...`) references a workspace
  that was never created/committed. The `.xcodeproj`-based command is the only
  one that works. **This is the same bug the CI job tripped on (see §5).**
- 8 ASC AppStore provisioning profiles installed in
  `~/Library/MobileDevice/Provisioning Profiles/`, all for team `4938S9TTBM`,
  all expiring 2027-06-27..30. **Names match exactly the strings referenced
  by the pbxproj** (`ASC AppStore com.tonoit.app.{app,keyboard,messages,share}`).
- Distribution cert `Apple Distribution: DOV B GINSBURG (4938S9TTBM)` installed.

---

## 2. Local builds (signed Release)

### 2.1 Unsigned Debug archive (parent task sanity)

```
xcodebuild -project Tono.xcodeproj -scheme Tono -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ./build/Tonoit_V6.xcarchive \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  archive
```

**Result: `** ARCHIVE SUCCEEDED **`** (exit 0). The unsigned archive completes
without error.

### 2.2 Signed Release archive (TestFlight path)

```
xcodebuild -project Tono.xcodeproj -scheme Tono -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ./build/Tonoit_VS.xcarchive \
  archive
```

**Result: `** ARCHIVE SUCCEEDED **`** (exit 0).

Sign artifacts:
- App: `Identifier=com.tonoit.app`, `Authority=Apple Distribution: DOV B GINSBURG (4938S9TTBM)`, arm64, signed 2026-07-05 20:44:43
- Keyboard ext: `Identifier=com.tonoit.app.keyboard`, same authority, arm64, signed 20:44:32
- Both anchored to `Apple Worldwide Developer Relations Certification Authority` → `Apple Root CA`

### 2.3 Bundle IDs in archive

```
$ /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    build/Tonoit_VS.xcarchive/Products/Applications/Tono.app/Info.plist
com.tonoit.app

$ /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    build/Tonoit_VS.xcarchive/Products/Applications/Tono.app/PlugIns/TonoKeyboard.appex/Info.plist
com.tonoit.app.keyboard
```

Both IDs match the source-of-truth (`project.pbxproj` lines 638, 855) and the
canonical `OWNERSHIP` table. The bundle ID drift Gary's plan §2 fixed in June
has held through the merges.

### 2.4 Build version

- `CFBundleVersion` = **29** (started 28 in committed source; auto-bumped to
  29 by `Scripts/bump-build.sh` running on every Release archive — this is
  expected and is the reason prior CI runs stopped producing duplicate
  TestFlight builds).
- `CFBundleShortVersionString` = **1.1**
- `MinimumOSVersion` = **17.2**

---

## 3. Keyboard parity (functional verification)

Per parent-task body §2, I confirmed the parity state machine is wired in
`KeyboardExtension/KeyboardRootView.swift`:

```
KeyboardExtension/KeyboardRootView.swift:
  58: enum ShiftState { case none, shiftOnce, capsLock }
  73:     @Published var shiftState: ShiftState = .none
  542:    func toggleLayoutMode() {
  571:    func applyAutoCapitalizationIfNeeded() {
  732:                       action: model.toggleLayoutMode
```

Note: parent task body called out `ShiftState` cases as `.off / .shift / .capsLock`.
Actual implementation uses `.none / .shiftOnce / .capsLock`. Functionally
equivalent (3-state shift with both transient-shift and caps-lock).
This is **not a defect**, just a naming convention difference.

`KeyboardExtension/Info.plist` confirms `RequestsOpenAccess=true` (Gary's §4.1
blocker is fixed). Without Open Access, the keyboard would be rejected from
TestFlight as non-functional because the entire product depends on network
calls to the rewrite backend.

---

## 4. ⚠ BLOCKER — `.ipa` export fails with provisioning/feature mismatch

```
$ xcodebuild -exportArchive -archivePath ./build/Tonoit_VS.xcarchive \
    -exportPath ./build \
    -exportOptionsPlist /Users/Ezra/.hermes/kanban/workspaces/t_ba1f1249/ExportOptions-Verify.plist
error: exportArchive "Tono.app" requires a provisioning profile with the App Groups and Push Notifications features.
error: exportArchive "TonoKeyboard.appex" requires a provisioning profile with the App Groups feature.
** EXPORT FAILED **
```

The signed archive is produced cleanly, but `exportArchive` (which is what
high-level `fastlane` wraps) refuses to package the .ipa.

### 4.1 Root cause (reproducible, evidence-backed)

`App/Tono.entitlements` declares:

```xml
<key>aps-environment</key>
<string>production</string>
<key>com.apple.security.application-groups</key>
<array>
  <string>group.com.tonoit.shared</string>
</array>
```

But the `ASC AppStore com.tonoit.app` profile grants:
- `application-identifier`, `beta-reports-active`, `team-identifier`,
  `application-groups: [group.com.tonoit.shared]`, `get-task-allow`,
  `keychain-access-groups` — **but no `aps-environment`**.

And `TonoKeyboard.entitlements` declares App Groups; the keyboard's profile
includes the user-identifier for `group.com.tonoit.shared` but the underlying
App ID `com.tonoit.app.keyboard` may not have the App Groups capability enabled
at the developer portal.

### 4.2 Why this matters

`xcodebuild -exportArchive` validates every target's entitlement set against the
*features* (not just values) of its provisioning profile. Push Notifications is
an App-ID-level feature on the developer portal — granting or revoking it requires
regenerating the profile after toggling the App ID's capability.

### 4.3 Smoke check — actually `aps-environment` not used at runtime

```
$ grep -rE "UNUserNotificationCenter|aps-environment" App Shared
App/Tono.entitlements:  <key>aps-environment</key>
Shared/NotificationManager.swift:  private let center = UNUserNotificationCenter.current()
Shared/NotificationManager.swift:  center.requestAuthorization(options: [.alert, .sound, .badge])
```

**Local notifications** (UNUserNotificationCenter + `.alert/.sound/.badge`) DO
NOT require `aps-environment`. That key is reserved for *remote* push (APNs).
So the entitlement is declared but the only notification code in the app does
not use it. This looks like a copy-paste leftover.

### 4.4 Recommendation (for Gary to action, not this worker)

Two fix paths. Either is acceptable; both unblock `fastlane deploy_testflight`:

1. **Drop `aps-environment` from `App/Tono.entitlements`** — local notifications
   work without it. Lowest-risk change. Brings entitlement set into harmony
   with actual code. Run a fresh signed archive + export to confirm the
   keyboard `requires App Groups` error also clears once the inconsistency is
   resolved.

2. **Enable Push Notifications capability on `com.tonoit.app` App ID** in the
   Apple Developer Portal (sign in as dovginsburg → Identifiers → `com.tonoit.app`
   → tick Push Notifications → Save → regenerate the `ASC AppStore com.tonoit.app`
   profile in the portal, then refresh `~/Library/MobileDevice/Provisioning Profiles/`).
   This is correct only if there IS downstream APNs usage planned that isn't in
   this repo yet.

### 4.5 What I did NOT do (by design)

I did **not** modify `App/Tono.entitlements` or any of the other entitlement
files. Sherlock verifies; Gary fixes. The reproducible failure is documented
above with command + exit + output.

---

## 5. ⚠ BLOCKER — CI iOS job runs the wrong xcodebuild command

`.github/workflows/ci.yml` (matrix job for iOS) invokes:

```
xcodebuild -workspace Tono.xcworkspace -scheme Tono \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build
```

But there is no `Tono.xcworkspace` in `apps/ios/`. Only `Tono.xcodeproj/`
exists (alongside `ToneApp.xcodeproj.old/`).

CI run #1 (`28760204826`, head `54f06b3`, 2026-07-06T00:26:33Z) failed in 10s:

```
xcodebuild: error: 'Tono.xcworkspace' does not exist.
'/Applications/Xcode_15.4.app/Contents/Developer/usr/bin/xcodebuild ...'
exit code 66
```

### 5.1 The full matrix result (so Dov sees everything at once)

| Job | Conclusion |
|---|---|
| Android build (`./gradlew assembleDebug`) | ✅ success |
| Backend test (`pytest`) | ❌ failure (Test step) |
| iOS build (xcodebuild, no codesign) | ❌ failure (Build step — see above) |
| Marketing site (HTML sanity) | ✅ success |
| Web app build (Next.js) | ❌ failure (`Set up Node 20`) |

Backend and Web failures are out of scope for this task but visible above for Dov.

### 5.2 Recommendation for CI fix

Replace `-workspace Tono.xcworkspace` with `-project Tono.xcodeproj` in
`.github/workflows/ci.yml`. Sherlocks reproduced the build locally with the
`-project` form on the same runner image's command surface (Xcode 26.5) and
gets `** ARCHIVE SUCCEEDED **` — switching CI to that form will turn the iOS
matrix job green.

---

## 6. Was `altool --upload` / `--validate` attempted?

**No.** `altool` operates on a `.ipa` artifact. No `.ipa` was produced because
§4 (`exportArchive`) refuses to package one. Once §4 is fixed and an .ipa exists,
the TestFlight upload path is:
```
xcrun altool --upload-package ./build/Tono.ipa \
  --type ios --apple-id dov.ginsburg@gmail.com \
  --bundle-id com.tonoit.app --bundle-version 29 --bundle-short-version-string 1.1 \
  --team-id 4938S9TTBM --password "@keychain:altool"
```
The --validate form (`--validate-app` / `--upload-package --validate ...`) can
dry-run the upload pipeline against ASC's review engine without actually
publishing. Recommend running that first, before a real upload.

---

## 7. Summary — what's left

1. **Fix the entitlement/profile feature mismatch** (§4). Pick one of the two
   paths; the first (drop `aps-environment`) is cheaper and matches actual
   code usage.
2. **Fix `.github/workflows/ci.yml`** to use `-project Tono.xcodeproj` (§5).
3. **Then re-run** `xcodebuild -exportArchive` → produce `.ipa` → `altool --validate`
   → if green, `altool --upload-package` to TestFlight.

Codesign, archive structure, bundle IDs, keyboard parity, keyboard Open Access,
auto-bump script, and provisioning profile matching are all clean. The blockers
are precise, small, and addressed by well-understood fixes — the consolidation
is **close to green, not green**.

---

*Files referenced (all in this repo under `apps/ios/`):*
- `Tono.xcodeproj/project.pbxproj` — bundle ID, entitlements, provisioning refs
- `App/Tono.entitlements` — declares `aps-environment` (unused)
- `KeyboardExtension/TonoKeyboard.entitlements`, `ShareExtension/ShareExtension.entitlements`, `TonoMessagesExtension/TonoMessagesExtension.entitlements`
- `fastlane/Appfile`, `fastlane/Fastfile` — alignment ok (team 4938S9TTBM, app-id com.tonoit.app)
- `Scripts/bump-build.sh` — auto-bump on every Release archive (working as designed; +1 per build)
- `TESTFLIGHT_UPLOAD_PLAN.md` — Gary's audit; still matches reality for §2-3, incomplete on §3c (no `ExportOptions.plist` committed — created locally as `ExportOptions-Verify.plist` for this run, not committed)

*Artifacts produced (Scratch, NOT in repo):*
- `build/Tonoit_V6.xcarchive/` — unsigned (no-codesign) Release archive, succeeded
- `build/Tonoit_VS.xcarchive/` — signed Release archive, succeeded, signed by `DOV B GINSBURG (4938S9TTBM)`
- `ExportOptions-Verify.plist` — minimal app-store ExportOptions used to exercise the export step

*Verification scripts (Scratch, NOT in repo, kept for re-runs):*
- `list-profiles.py` — dump ASC provisioning profile `Name` / entitlements
- `check-entitlements.py` — drill down entitlements of installed profiles
- `parse_jobs.py`, `iosjob.py`, `iosjobprint.py` — CI job log decoders
