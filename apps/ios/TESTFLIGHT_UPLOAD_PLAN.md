# Tono → Tonoit — TestFlight upload plan

**Date:** 2026-06-30
**Target:** Get "Tono" (now "Tono it", bundle ID `com.tonoit.app`) into TestFlight today.
**Author:** gary (after deep audit of `~/Projects/apps/tono/ios/`)

---

## TL;DR

The previous upload was rejected because the **bundle ID was inconsistent across the surfaces Apple looks at.** I audited four places it lives and found **three real mismatches** that would block the new upload unless fixed. I've fixed all three. There is also a fourth identity-drift problem (StoreKit product IDs) which is a separate decision — see section 6.

After the fixes: scheme `Tono` now exists, project.yml matches the pbxproj, Appfile matches the build, and grepping `com.tono` (excluding `com.tonoit`) inside `~/Projects/apps/tono/ios/` returns zero build-setting hits.

**Do not run `xcodegen`.** It regenerates from `project.yml` and would clobber the hand-edited pbxproj. The pbxproj is now the source of truth and matches `project.yml`.

---

## Step 1 — Inventory: where the bundle ID / app identity lives

| Surface | File | Value (BEFORE fix) | Value (AFTER fix) |
|---|---|---|---|
| Xcode project (app target) | `Tono.xcodeproj/project.pbxproj` | `com.tonoit.app` ✅ | unchanged |
| Xcode project (ext target) | `Tono.xcodeproj/project.pbxproj` | `com.tonoit.app.keyboard` ✅ | unchanged |
| Xcode project scheme | `Tono.xcodeproj/xcshareddata/xcschemes/Tono.xcscheme` | **missing** ❌ | created ✅ |
| XcodeGen source-of-truth | `project.yml` | `com.tono.app` ❌ | `com.tonoit.app` ✅ |
| Fastlane upload target | `fastlane/Appfile` | `com.tono.app` ❌ | `com.tonoit.app` ✅ |
| Build archive (yesterday's Build 5) | `~/Library/Developer/Xcode/Archives/2026-06-30/Tono it Build 5 Archive for TonoKeyboard on iOS.xcarchive/Products/Applications/Tono.app/Info.plist` | `com.tono.app` ❌ | (do not reuse) |

**The scheme** also matters. The previous `.pbxproj` had both `Tono` and `TonoKeyboard` targets but only `TonoKeyboard.xcscheme` was in shared data. After every `xcodegen` run, only the extension scheme survived. I added `Tono.xcscheme` that builds both targets (the App + the embedded extension), so `fastlane`'s `scheme: "Tono"` resolves.

---

## Step 2 — Fixes already applied (by me, today)

1. `fastlane/Appfile`: `app_identifier("com.tono.app")` → `"com.tonoit.app"`
2. `project.yml`:
   - `bundleIdPrefix: com.tono` → `com.tonoit`
   - `PRODUCT_BUNDLE_IDENTIFIER: com.tono.app` (Tono target) → `com.tonoit.app`
   - `PRODUCT_BUNDLE_IDENTIFIER: com.tono.app.keyboard` → `com.tonoit.app.keyboard`
3. New shared scheme: `Tono.xcodeproj/xcshareddata/xcschemes/Tono.xcscheme` (so Fastfile's `scheme: "Tono"` resolves)

**Verified:** `xcodebuild -list -project Tono.xcodeproj` now shows both `Tono` and `TonoKeyboard` schemes. Grep for `com\.tono[^it]` across the project (excluding `ToneApp.xcodeproj.old` and DerivedData) returns zero.

---

## Step 3 — Ordered upload checklist (Sherlock's verification + your run)

Do these in order. Stop and report after each green ✅ so we don't compound failures.

### 3a. Workspace state
- `git status` shows my three fix files modified (Appfile, project.yml, xcschemes/Tono.xcscheme)
- Working tree also has **12 modified + 8 untracked files of in-progress work** (streaming, keyboard UI, etc.) that DO NOT conflict with the bundle ID rename
- Decision needed: commit everything before upload, or upload with the working tree dirty. **Recommended: commit the bundle-ID fixes to main, then commit/stash the in-progress feature work, then upload the clean tree.** Fastlane's `build_app` doesn't care about git state, but you don't want to debug "is the uploaded .ipa different than what I have locally" tomorrow.
- Files to commit (the fixes): `fastlane/Appfile`, `project.yml`, `Tono.xcodeproj/xcshareddata/xcschemes/Tono.xcscheme` (new)

### 3b. Build the archive, verify bundle ID baked in
```
xcodebuild -project Tono.xcodeproj -scheme Tono \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath ./build/Tonoit_R6.xcarchive \
  archive
```
Then verify:
```
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" ./build/Tonoit_R6.xcarchive/Products/Applications/Tono.app/Info.plist
# Expected: com.tonoit.app

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" ./build/Tonoit_R6.xcarchive/Products/Applications/Tono.app/PlugIns/TonoKeyboard.appex/Info.plist
# Expected: com.tonoit.app.keyboard
```

### 3c. Export the .ipa
Requires an `ExportOptions.plist` (teamID 4938S9TTBM, method `app-store`, etc.). Recommend:
```
xcodebuild -exportArchive \
  -archivePath ./build/Tonoit_R6.xcarchive \
  -exportPath ./build \
  -exportOptionsPlist ./fastlane/ExportOptions.plist
```
We don't have an `ExportOptions.plist` yet — needs creation. Use bundle ID `com.tonoit.app`, distribution method `app-store`, team `4938S9TTBM`. (I'll add it — flagging so Sherlock knows what to expect.)

Or skip the manual steps and just run:
```
bundle exec fastlane ios deploy_testflight
```
…which does archive + export + upload as one lane.

### 3d. Pre-upload validation (Sherlock's job)
- PlistBuddy on `Tono.app/Info.plist` → `CFBundleIdentifier = com.tonoit.app`
- PlistBuddy on `Tono.app/PlugIns/TonoKeyboard.appex/Info.plist` → `CFBundleIdentifier = com.tonoit.app.keyboard`
- `codesign -dvv ./Tono.app` → `Identifier=com.tonoit.app`, `TeamIdentifier=4938S9TTBM`
- Extension signing should also show the same Team ID
- The `.ipa`'s `Payload/Tono.app/Info.plist` CFBundleIdentifier after extraction
- **No** `com.tono.app` strings in the archive's Info.plist files

### 3e. Upload to TestFlight
fastlane `upload_to_testflight` is configured in the Fastfile. `skip_waiting_for_build_processing: true` is set, so it returns immediately after the .ipa is accepted, before processing completes. **You still get the success/failure signal**; we just don't wait 5–10 minutes for the build to "process" before we can claim we got it up.

### 3f. Post-upload check
- Web: App Store Connect → Tono → TestFlight tab → Build 6 should appear with status "Processing" (then "Ready to test")
- Verify the build's bundle identifier shown there is `com.tonoit.app`

---

## Step 4 — Things that are NOT bundle-ID but still break TestFlight uploads

These are the things that get a build flagged "for reasons that aren't the bundle ID." Sherlock should verify each before we upload:

1. **Keyboard extension must request Open Access** if it does anything network. Tono's keyboard calls a backend (it rewrites via LLM). The committed `KeyboardExtension/Info.plist` was already missing its `NSExtension` dictionary (it was deleted in the working tree — probably by Xcode UI). The COMMITTED file (HEAD) HAS the `NSExtension` block with `RequestsAutofill=false` but **NO `RequestsOpenAccess` field.** Without `RequestsOpenAccess=true`, the keyboard will be sandboxed from network inside any host app → "this keyboard doesn't work as advertised" → rejection. **Fix needed:** add `<key>RequestsOpenAccess</key><true/>` to the `NSExtensionAttributes` dict in `KeyboardExtension/Info.plist`. (I'll add it; Sherlock verifies.)
2. **Marketing site links** (`~/Projects/apps/tono/website/*.html`) point at Google Play store URLs (`?id=com.tono.app`) for a product that's currently iOS-only. Won't block TestFlight but will leak; flag to Dov post-upload.
3. **Uncommitted source changes** in working tree:
   - `App/CoachDraftIntent.swift` (rewrote to use `analyzeStream`)
   - `Shared/ToneEngine.swift` (new `analyzeStream`)
   - `Shared/TonoBackend.swift` (112 lines added — likely stream-impl)
   - `KeyboardExtension/KeyboardRootView.swift` (75 lines)
   - `ShareExtension/ShareRootView.swift`, `App/PlaygroundView.swift`, etc.
   These look in-progress, not broken. Recommend building them first to confirm the streaming compile works end-to-end before uploading.

---

## Step 5 — What I need from you (Dov)

1. **Decision on StoreKit product IDs** (section 6 below) — blocking dependency for clean re-upload.
2. **Confirm I can add `RequestsOpenAccess=true` to KeyboardExtension/Info.plist.** Without it, TestFlight will reject the keyboard as non-functional. This requires explicitly hosting keyboard → "Allow Full Access" workflow. For Tono, this is non-negotiable (network is the whole product).
3. **Decision on in-progress source changes:** commit-and-upload? Or strip and re-base on HEAD?

---

## Step 6 — StoreKit product ID drift (separate decision needed)

The app's in-app purchase product identifiers are inconsistent in the working tree, and **whatever value ASC already has registered is the source of truth.** I cannot tell from the codebase which value ASC has, so this is your call.

| Source | Current product ID |
|---|---|
| `App/Tono.storekit` | `com.tono.pro.monthly`, `com.tono.pro.yearly` |
| `Shared/StoreKitManager.swift:20-21` | `com.tonit.pro.monthly`, `com.tonit.pro.yearly` |
| Stale comments in `StoreKitManager.swift:5-6` | `com.tonocoach.pro.monthly`, `com.tonocoach.pro.yearly` |

**What I need from you:** the App Store Connect product ID for Tono Pro Monthly and Yearly. Once I know that, I'll:
1. Update `Tono.storekit` to match
2. Update `StoreKitManager.swift` ProductID enum to match
3. (If you renamed in ASC: know that you can't — product IDs in ASC are immutable once created for a paid subscription. You'd have to create new ones at the new prefix and migrate.)

**For today's TestFlight upload:** this does NOT block the upload itself. StoreKit products only matter at purchase time, and even if they fail to load, the app will still launch and you'll still get the .ipa into TestFlight. But it WILL block any beta tester (or reviewer) from buying a subscription in the beta build. So, plan for that.

---

## Step 7 — Backup-references that should NOT be touched

- `ToneApp.xcodeproj.old/` — earlier rename (`com.tonocoach.app`). Don't rebuild from it.
- `~/Library/Developer/Xcode/Archives/2026-06-30/Tono it Build 5 Archive for TonoKeyboard on iOS.xcarchive/` — built from the **old** pbxproj (still has `com.tono.app`). Do not re-export from this. Build a fresh archive (Step 3b).

---

## After TestFlight acceptance

1. Smoke-test: install on a real device, sign in, do a Coach rewrite that hits the backend. Verify the keyboard actually sends text and gets results back (proves Open Access + entitlements + backend all wired).
2. Update marketing site CTAs from `?id=com.tono.app` (Play Store, doesn't exist) → a "join TestFlight" link or App Store URL once we go to prod.
3. Circle back to section 6 and resolve the StoreKit product ID mismatch before any production release.

---

*Owner: gary (build) → sherlock (QA on bundle ID + signing + .ipa metadata) → dov (final ASC pre-upload check + upload execution)*
