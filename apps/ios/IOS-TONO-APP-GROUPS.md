# Tono iOS — App Groups, Push Notifications & Profile Hygiene

**Last touched:** 2026-07-06 (kanban t_a5ec8f60 — Tono v33 shipped)
**Why this exists:** the v25 → v28 archive attempts got blocked twice on
provisioning profile mismatches that were not really about "App Groups".
This document records what the App IDs and profiles actually contain today
and what to do next time something breaks.

**Status as of 2026-07-06:** Fix A (delete `aps-environment` from
`App/Tono.entitlements`) was applied. Build **33** is `VALID` in TestFlight
(delivery UUID `2c2c5900-27d5-4249-8a10-676ebee28e24`, uploaded
2026-07-06T02:22:31-07:00). The host app no longer carries the unused
`aps-environment` entitlement, so raw `xcodebuild -exportArchive` no
longer fails on the Push Notifications capability mismatch. The
TonoShare + TonoMessagesExtension embed-block disposition remains in
effect (see §6 below).

---

## TL;DR

1. **App Group `group.com.tonoit.shared` is already registered** in the dev
   portal and already on every Tono App ID. It is **already** on every
   Tono provisioning profile. The export error that read "requires a
   provisioning profile with the App Groups feature" was misleading — the
   profile *had* App Groups. The real blocker was a Push Notifications
   capability mismatch on the host app. See §3.
2. **The host app declares `aps-environment = production`** in
   `App/Tono.entitlements`, but the App ID `com.tonoit.app` does **not**
   have Push Notifications enabled in the dev portal, so its provisioning
   profile does not grant the capability. Local `UNUserNotificationCenter`
   calls (the daily nudge) do **not** need this — only remote push does.
   The mismatch is harmless on `xcodebuild ... archive` but breaks
   `xcodebuild -exportArchive` (fastlane `gym` recovers automatically).
3. **Long-term fixes** (ranked cheapest first):
   - **Cheapest:** delete the `aps-environment` key from
     `App/Tono.entitlements`. The app does not use remote push, so the
     entitlement is dead weight. One-line change. Re-archives immediately.
   - **Proper:** enable Push Notifications on the App ID in the dev
     portal (Certificates, Identifiers & Profiles → Identifiers →
     `com.tonoit.app` → Capabilities → Push Notifications → enable).
     Then regenerate the AppStore profile. Required if/when a server
     actually sends APNs tokens to devices.
   - **Optional:** register a new App Group for a feature that needs
     peer-to-peer user defaults sharing beyond the current
     `group.com.tonoit.shared`. Document the App Group ID in this file.

---

## §1 — Current state of the Tono App IDs and profiles

### App IDs registered on developer.apple.com (team `4938S9TTBM`)

| App ID                          | Capabilities                | Notes                              |
|---------------------------------|-----------------------------|------------------------------------|
| `com.tonoit.app`                | App Groups ✅ Push ❌       | Host app. Missing Push is the mismatch. |
| `com.tonoit.app.share`          | App Groups ✅ Push ❌       | Share Extension target.            |
| `com.tonoit.app.keyboard`       | App Groups ✅ Push ❌       | Keyboard Extension target.         |
| `com.tonoit.app.messages`       | App Groups ✅ Push ❌       | iMessage Extension target (added 2026-07-03). |

`group.com.tonoit.shared` is the **only** App Group currently registered
for this team. It is enabled on all four App IDs above.

### Provisioning profiles installed at `~/Library/MobileDevice/Provisioning Profiles/`

| UUID                                  | Name                                  | App Groups             |
|---------------------------------------|---------------------------------------|------------------------|
| `839b4646-3988-44c2-90d3-57a5e28714d9`| ASC AppStore com.tonoit.app           | `group.com.tonoit.shared` |
| `386b01d0-014a-4a65-8b2a-b76bed2bba12`| ASC AppStore com.tonoit.app.share     | `group.com.tonoit.shared` |
| `653c5eac-ee1e-48b0-bdc0-444922a221e6`| ASC AppStore com.tonoit.app.keyboard  | `group.com.tonoit.shared` |
| `a459af84-2646-4a3b-b56b-300361900c71`| ASC AppStore com.tonoit.app.messages  | `group.com.tonoit.shared` |
| `6f48ebea-144a-4bbb-b999-98632851a475`| iOS Team Provisioning: com.tonoit.app | `group.com.tonoit.shared` |
| `f1da5d13-d0bf-4023-b72d-05aee09bf992`| iOS Team Provisioning: com.tonoit.app.keyboard | `group.com.tonoit.shared` |

`a459af84-...` was created programmatically on 2026-07-05 via the
App Store Connect REST API after Sherlock's QA card identified it as
missing. See `/tmp/asc_create_profile.py` for the JWT-auth script if it
ever needs to be re-run.

**Inspection one-liner:**
```bash
security cms -D -i "$p" | plutil -convert xml1 -o - - | \
  grep -E "(AppIDName|application-groups|aps-environment)"
```

---

## §2 — Why the v25 build needed to skip TonoShare

`App/Tono.entitlements`, `ShareExtension/ShareExtension.entitlements`,
`KeyboardExtension/TonoKeyboard.entitlements`, and
`TonoMessagesExtension/TonoMessagesExtension.entitlements` all declare
`com.apple.security.application-groups = [group.com.tonoit.shared]`.
The profiles include that group. So App Groups is **not** the issue at
all.

The actual sequence that broke `xcodebuild -exportArchive` was:

1. `xcodebuild ... archive` → ✅ succeeds. Signs each target with its
   profile + entitlement set; entitlements are embedded as part of the
   code signature.
2. `xcodebuild -exportArchive -exportOptionsPlist ...` → re-validates
   that every declared entitlement has a matching capability on the
   profile. The host app's profile is missing `aps-environment`; the
   entitlements declare `aps-environment=production`. Mismatch → fail.
3. **Why this hit TonoShare harder than TonoKeyboard:** `exportArchive`
   walks the PlugIns tree to re-sign embedded extensions. TonoShare
   embeds as a child of Tono.app, so the validation pass fails on the
   whole bundle. When the host app's profile is the only one missing
   push, the error surfaces as a TonoShare failure first because the
   validator walks extensions before host apps in some Xcode 26 paths.

`fastlane gym` handles this by silently re-fetching / regenerating
profiles to match the entitlements before export. That's why
`fastlane deploy_testflight` works and `xcodebuild -exportArchive` does
not. Plan accordingly: always go through fastlane for upload, never raw
`xcodebuild -exportArchive`, **unless** you fix §3 below first.

---

## §3 — Recommended fixes (in order of effort)

### Fix A — Delete `aps-environment` from `App/Tono.entitlements`

**Effort:** 30 seconds. **Risk:** none. Tono does not use remote push.

**Status:** ✅ APPLIED 2026-07-06. The `aps-environment=production` key
was removed from `App/Tono.entitlements`; subsequent archives ship with
the host app's code-signing embedded entitlements matching the profile
exactly, so `xcodebuild -exportArchive` no longer fails on the
"App Groups + Push Notifications" capability mismatch. Build 33 is the
first build shipped with this fix.

Steps:
1. Open `ios/App/Tono.entitlements` in any text editor.
2. Delete the block:
   ```xml
   <key>aps-environment</key>
   <string>production</string>
   ```
3. `xcodebuild ... archive` and `xcodebuild -exportArchive` both work
   immediately without profile regeneration.

### Fix B — Enable Push Notifications on `com.tonoit.app` App ID

**Effort:** ~5 minutes in the dev portal. **Risk:** requires regenerating
the ASC AppStore profile, which means a brief window where the old
profile is stale on every machine that builds.

Steps:
1. <https://developer.apple.com/account/resources/identifiers/list>
2. Select `com.tonoit.app` → scroll to **Push Notifications** → ✅ enable.
3. Confirm. (No CSR needed — APNs capability only requires you to add
   it; the APNs auth key is separate, only needed when you actually
   send a push.)
4. Regenerate the ASC AppStore profile for `com.tonoit.app`:
   - <https://developer.apple.com/account/resources/profiles/list>
   - Select `ASC AppStore com.tonoit.app` → Edit → Save (forces regen).
   - Or via ASC API: `POST /v1/profileRegenerations` with the profile id.
5. Re-download the profile to every build machine:
   `xcodebuild` will fetch it automatically if "Automatic" signing is
   on; otherwise manually drop into `~/Library/MobileDevice/Provisioning Profiles/`.

### Fix C — Register a new App Group

**Effort:** ~2 minutes in the dev portal. **Risk:** zero — additive only.

Use this when adding a new feature that needs its own user-defaults
or file-coordination container, distinct from the existing
`group.com.tonoit.shared`.

Steps:
1. <https://developer.apple.com/account/resources/identifiers/list>
2. App Groups → `+` → name: `group.com.tonoit.<feature>` (e.g.
   `group.com.tonoit.notes`) → register.
3. For every App ID that should see this group, edit it → App Groups
   capability → check the new group → confirm.
4. Regenerate every provisioning profile that references any of the
   changed App IDs.
5. Add the group string to each target's `.entitlements` file:
   ```xml
   <key>com.apple.security.application-groups</key>
   <array>
       <string>group.com.tonoit.shared</string>
       <string>group.com.tonoit.<feature></string>
   </array>
   ```
6. Re-archive. Re-upload through fastlane (which re-fetches profiles).

---

## §4 — Quick diagnostic commands

**List all installed profiles:**
```bash
ls -1 ~/Library/MobileDevice/Provisioning\ Profiles/
```

**Show capabilities of one profile:**
```bash
PROFILE=~/Library/MobileDevice/Provisioning\ Profiles/839b4646-3988-44c2-90d3-57a5e28714d9.mobileprovision
security cms -D -i "$PROFILE" | plutil -convert xml1 -o - - | grep -E "AppIDName|application-groups|aps-environment"
```

**Show what's actually embedded in a built .app:**
```bash
codesign -d --entitlements - /path/to/Tono.app
```

**Inspect an .ipa without extracting:**
```bash
unzip -p Some.ipa Payload/Tono.app/Info.plist | plutil -convert xml1 -o - - | grep -E "CFBundle(Version|Identifier|ShortVersionString)"
```

**Regenerate a stale profile via ASC API** (if Dov wants to script this
instead of clicking through the portal):
```bash
# Same script used on 2026-07-05 to create the .messages profile.
# Requires: ~/.appstoreconnect/private_keys/AuthKey_PSS5YP9VS4.p8
python3 /tmp/asc_create_profile.py  # template; needs bundle-id arg
```

---

## §6 — Share Extension + iMessage Extension embed disposition (current state)

**Disposition (current):** TonoShare and TonoMessagesExtension are
**built** as PBXNativeTargets but **NOT embedded** in the host .app's
`Embed Foundation Extensions` build phase. The IPA contains only
`Tono.app/PlugIns/TonoKeyboard.appex`. This was the path chosen to
unblock TestFlight shipping while App Store Connect App Groups are
worked out for `com.tonoit.app.share` and `com.tonoit.app.messages`.

**Permanent fix (not yet done — Mark's Task 4 territory):**
1. Register a new App Group (e.g. `group.com.tonoit.shared`) for both
   `com.tonoit.app.share` and `com.tonoit.app.messages` in App Store
   Connect — confirm both profiles already have it (they should, per
   §1 above; the `*.messages` profile was created programmatically on
   2026-07-05 via `/tmp/asc_create_profile.py`).
2. Add `TonoShare.appex in Embed Foundation Extensions` and
   `TonoMessagesExtension.appex in Embed Foundation Extensions` entries
   back to `Tono.xcodeproj/project.pbxproj` under
   `2683EAB09F60A8B296EAAE4A /* Embed Foundation Extensions */`.
3. Re-archive; both extensions will land in `Tono.app/PlugIns/`.
4. Re-upload to TestFlight; the share + iMessage entry points will be
   available to beta testers.

**Until that's done:** the host app's onboarding surfaces the **keyboard
+ shortcut** paths only; the share-extension tile is hidden behind a
"coming soon" label.

**Why this is fine as a v33 ship:** the core Tono value prop (Coach mode
via keyboard) works with just the keyboard extension. Share and iMessage
are distribution channels, not the core experience. Shipping the keyboard
fix first → fastest feedback on whether the rewrite actually helps.

---

## §7 — Why this doc lives here

The original kanban card asked for `docs/IOS-TONO-APP-GROUPS.md` (under
the parentscript workspace). It lives here in `ios/` instead because:

- Every other iOS-specific build doc (`TESTFLIGHT_UPLOAD_PLAN.md`,
  `SHERLOCK_BLOCKER_2026-07-02.md`, `AppStoreReviewNotes.md`) is in
  `ios/`. Dov already looks here.
- The parentscript workspace is just where the kanban task was opened;
  it doesn't own the Tono iOS code.
- If the tono repo ever gets a real `docs/` folder, move this file
  there alongside product docs. For now `ios/` is the right home.