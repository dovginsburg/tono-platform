# Sherlock → Ezra — TestFlight Upload Blocker

**Date:** 2026-07-02 (Thursday)
**Card:** t_8519be08 (Upload Tono to TestFlight) — BLOCKED
**Sherlock card:** t_c647e325 (QA gate) — pending, will post on resolve
**Archive SHA:** `3972891c1f1aba2836378f33b53cb4edb1081b96` in `/Users/Ezra/Projects/apps/tono/`
**Target:** build 14 / version 1.1 / `com.tonoit.app` (+share, +keyboard)

---

## TL;DR

Cannot upload from this session. Two independent blockers, both confirmed:

1. **cua-driver is stale** — process alive but in headless mode (`/tmp/cua-driver.log`: "no Window Server / graphic-session access — running headless"). `computer_use capture` returns `width=0, height=0`, `list_apps` returns empty. Cannot click the codesign "Always Allow" dialog from a real GUI session because there is no GUI session reachable.
2. **macOS session is locked + non-Aqua** — `ioreg` reports `CGSSessionScreenIsLocked = Yes`, `SESS = 0` for my shell. Every `security` keychain operation returns `SecKeychainUnlock ... User interaction is not allowed.` (exit 36). SecurityAgent unreachable.

Without a way to click "Always Allow" on the codesign dialog, **the codesign step is blocked at the OS level**.

---

## What I verified (read-only — all green)

| Check | Result |
|---|---|
| `git log --oneline -3` | `3972891 build: share-extension v1.0 target + Shortcut + 3-tile onboarding` ✅ |
| `ls .../Tono.xcarchive/` | Info.plist + Products/ + dSYMs/ present ✅ |
| `plutil -p Info.plist` | `CFBundleIdentifier=com.tonoit.app`, `CFBundleShortVersionString=1.1`, `CFBundleVersion=14` ✅ |
| `PlugIns/` | Both `TonoKeyboard.appex` + `TonoShare.appex` present ✅ |
| `security find-identity -p codesigning -v` | 2 valid identities including `Apple Distribution: DOV B GINSBURG (4938S9TTBM)` (`DB73A646...`) ✅ |
| `pgrep -fl cua-driver` | PID 3011 alive (but in headless mode) ✅ |
| ExportOptions.plist | Present, correct (team `4938S9TTBM`, manual signing, app-store method) ✅ |

---

## What I tried (in order)

### 1. `focus_app(app='Xcode')` + `capture(mode='som')` on Xcode
- Result: `width=0, height=0, app="", window_title="", elements=[]`, 0 interactable elements.
- `list_apps` returns empty array.
- Root cause from cua-driver log: `WARN platform_macos::cursor::overlay: no Window Server / graphic-session access — skipping cursor overlay and running headless (issue #1724)`.

### 2. cua-driver recovery (skill-recommended ladder)
- Per `ios-testflight-fleet-pipeline/SKILL.md` → `references/cua-driver-codesign-recovery.md`: kill → respawn → `sudo killall accessibilityd`.
- `pkill -9 -f "cua-driver serve"` → **blocked by approval gate** ("force kill processes" pattern). Cannot self-approve.
- `/Applications/CuaDriver.app/Contents/MacOS/cua-driver --version` returns `cua-driver 0.7.0` (binary works); just no AX subsystem reachable.
- Respawn via `terminal(background=true)` would hit the same WindowServer access wall because the underlying issue is `accessibilityd` needs a restart that requires `sudo`.

### 3. Terminal `xcodebuild -exportArchive` (stage-then-export pattern)
- Command: `xcodebuild -exportArchive -archivePath /Users/Ezra/Library/Developer/Xcode/Archives/2026-07-02/Tono.xcarchive -exportPath /Users/Ezra/Projects/apps/tono/ios/Export/ -exportOptionsPlist /Users/Ezra/Projects/apps/tono/ios/Export/ExportOptions.plist -allowProvisioningUpdates`
- Result: `error: exportArchive codesign command failed (/var/folders/.../Payload/Tono.app/PlugIns/TonoKeyboard.appex: errSecInternalComponent)` then `** EXPORT FAILED **`.
- Exactly the documented failure mode for non-Aqua sessions (`skill §errSecInternalComponent`).

### 4. `security unlock-keychain -p '...' -u`
- Result: `security: SecKeychainUnlock /Users/Ezra/Library/Keychains/login.keychain-db: User interaction is not allowed.` (exit 36).
- Per skill: this is a no-op from non-GUI shells. Confirmed.

### 5. `security set-keychain-settings -lut 7200`
- Result: `User interaction is not allowed.` — every keychain ACL op blocked the same way.

### 6. Session classification
- `ioreg -l -w 0 | grep CGSSession`: `CGSSessionScreenIsLocked = Yes`, `kCGSSessionOnConsoleKey = Yes`, `CGSSessionUniqueSessionUUID = 3BD017C1-...`.
- My shell has `SESS = 0`, `??` (no controlling TTY), running under a background launchd domain.
- The session is reachable to me as a child process but the security agent (which fronts keychain unlock + ACL modifications) requires a graphical Aqua loginwindow session — which is what's locked.

---

## Required to unblock

**Option A — Dov (human, ~30 sec of clicks):**
1. Unlock the Mac screen (Wake / Touch ID / password).
2. Open `/Users/Ezra/Projects/apps/tono/ios/Export/ExportOptions.plist` is already correct — Dov doesn't need to edit it.
3. Open Xcode → Window → Organizer (Cmd+Shift+8).
4. Select the 2026-07-02 archive (top of list — should auto-discover from `~/Library/Developer/Xcode/Archives/2026-07-02/Tono.xcarchive`).
5. Click Distribute App → App Store Connect → Upload → (auto signing) → Upload.
6. **When "codesign wants to access key 'login'" pops up: click "Always Allow".** This is the critical click.
7. Wait 3-5 min. When "Upload Successful", click Done.

**Option B — Dov approves `sudo killall accessibilityd` (zero clicks for Dov, fully scriptable):**
1. Dov runs `sudo killall accessibilityd` on the Mac.
2. Sherlock respawns cua-driver: `terminal(background=true) command='/Applications/CuaDriver.app/Contents/MacOS/cua-driver serve > /tmp/cua-driver.log 2>&1'`.
3. Verify: `computer_use action=capture mode=som` returns non-zero dimensions, `list_apps` returns apps.
4. Sherlock drives Xcode Organizer → Distribute App → upload flow via `computer_use`, clicks "Always Allow" on the codesign dialog when it appears.
5. Sherlock verifies via `GET /v1/apps/6785755956/builds?limit=5`.
6. Dov only needs to pull-to-refresh TestFlight on his iPhone.

**Option B is documented in the skill as the preferred path** (Dov's preference: "u need to do it from the Mac"). Once `accessibilityd` is restarted once, codesign flow is fully scriptable for the rest of the session.

**Option C — Dov approves the `pkill -9 -f cua-driver` only (might not be enough):**
The kill alone doesn't fix the `no Window Server / graphic-session access` warning — that warning is from cua-driver's startup probe, not from accessibilityd. Killing and respawning cua-driver on a locked-screen session will log the same warning and produce the same 0×0 capture. Option C is a subset of Option B without the critical accessibilityd restart.

---

## Subagent notes for Ezra

- This shell has no kanban CLI on PATH. I cannot post comments to t_8519be08 / t_c647e325 directly. You (Ezra) need to translate this blocker into the kanban comment.
- This shell has no GUI session to attach to. I cannot operate Xcode from here even if you give me explicit task instructions that require it.
- The `/tmp/asc.py` helper is present and `python3 -c` importable. After Dov unblocks (Option A or B), Sherlock will verify via `GET /v1/apps/6785755956/builds?limit=5` and `GET /v1/apps/6785755956/betaGroups` (to find the Tonoit group ID), then attempt `POST /v1/betaGroups/{id}/relationships/builds` (will 422 if build is INTERNAL_ONLY — flag for Dov).
- Skill note: the Tonoit internal group ID is documented as `6ac94c27-...` (placeholder) — needs `GET /v1/apps/6785755956/betaGroups` to resolve the real ID. Not blocking the blocker report; blocking the post-upload attach step.

---

## Files I created/modified

- `/Users/Ezra/Projects/apps/tono/ios/SHERLOCK_BLOCKER_2026-07-02.md` (this file — for Ezra + Dov to read)
- `/tmp/asc.py` — `chmod +x` (was 0700; now executable bit set so future invocations don't hit "Permission denied")

I did **not** touch:
- project.pbxproj
- ExportOptions.plist
- Any source files
- Any other profile's skills/config
- `~/Library/Keychains/` (keychain ops all blocked anyway)

---

## Kanban action items for Ezra

1. **t_8519be08** (Upload Tono to TestFlight) → mark **blocked**. Comment: paste this entire file's TL;DR + "Required to unblock" sections. Move to `in_review` is premature — blocker is upstream (session access), not the upload itself.
2. **t_c647e325** (Sherlock QA gate) → leave in `in_progress` until either upload completes or Ezra explicitly reassigns. Comment: paste the verification table + the two independent blockers.
3. **Once Dov unblocks (Option A or B),** dispatch a fresh Sherlock run with a focused task: "Drive Xcode Organizer → Distribute App → Upload, click Always Allow, verify via ASC API, post build ID to t_c647e325."
4. **Dov needs:** screen-unlock OR `sudo killall accessibilityd` approval. Without one of these, no subagent can finish this card.

— Sherlock, 2026-07-02 16:30 UTC