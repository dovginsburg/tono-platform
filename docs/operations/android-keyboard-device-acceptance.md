# Android keyboard — real-device acceptance checklist (for Ari)

Run this against the **new build (versionCode 121 or later)**. A build at
versionCode 120 predates the letter-key keyboard and will reproduce the original
"letters not showing up" report no matter what else is fixed — check
**Settings → Apps → Tono → App details** (or `adb shell dumpsys package com.tono.myapp | grep versionCode`)
and confirm it is **≥ 121** before testing anything below.

## 0. Enable the keyboard
- [ ] Settings → System → Languages & input → On-screen keyboard → **enable "Tono"**
- [ ] Switch to Tono via the keyboard-switch key (⌨) or the notification picker

## 1. Letters are visible and type — WhatsApp
- [ ] Open a chat, tap the message field: the keyboard shows **three QWERTY rows**
      (q…p / a…l / z…m) with **readable legends** — not blank keys
- [ ] Type `hello` → the field shows `hello`
- [ ] Every row types: tap one key from each row (e.g. `q`, `a`, `z`)

## 2. Letters are visible and type — Google Messages
- [ ] Same as above in an SMS/RCS conversation
- [ ] Type a full sentence and confirm each character lands in order

## 3. Letters are visible and type — Chrome
- [ ] Focus the address bar or any web text field; type `tono`
- [ ] Confirm the return key performs the field's action (Go/Search), not a newline

## 4. Light + dark mode
- [ ] Switch the phone between **light** and **dark** system themes
- [ ] In BOTH: key legends remain readable (the keyboard is intentionally a dark
      surface in both themes — legends must never be invisible or same-colour-as-key)

## 5. Modifier and editing keys
- [ ] **Shift** once → next letter is capital, then reverts to lowercase
- [ ] **Shift twice quickly** → caps lock (legend ⇪); all letters capital until released
- [ ] **Delete (⌫)** removes the previous character; also deletes a selection
- [ ] **Space** inserts a space; the next sentence auto-capitalizes after `. `
- [ ] **123 / ABC** toggles to symbols and back — symbols legible, letters return
- [ ] **Punctuation** on the symbol layer types `. , ? ! '` correctly
- [ ] **Return** inserts a newline in a multi-line field (e.g. Notes/email body)

## 6. Keyboard switching
- [ ] Tap the ⌨ key → the system offers other keyboards; switching away works
- [ ] Switch back to Tono → letters still render and type (no blank keyboard on re-entry)

## 7. Secure field — Tono must fail closed
- [ ] Open any **password field** (e.g. a login screen, or Settings → Wi-Fi password)
- [ ] Confirm: **typing still works** (letters visible, characters commit)
- [ ] Confirm: the Coach/Read strip is **replaced by the password notice** —
      "Password field — Tono types on your device. Coach and Read are off here."
- [ ] Confirm: no draft preview of the password text appears anywhere in the keyboard

## 8. Coach/Read still work in a normal field
- [ ] In WhatsApp, type a draft, tap **Coach** → suggestions appear
- [ ] Tap **← Back** → returns to the keyboard with letters intact

## Report back
For any failure, note: app, light/dark, the exact key(s), and whether the legend
was missing vs. the character not appearing. Those are two different defects and
the distinction determines the fix.

---

## Artifact receipt — verified build (2026-08-06, Opus 4.8 lane)

Built **foreground on this host** from branch
`claude/tono-controllable-completion-opus48-20260804` at **HEAD `c95d18a`**
(tree contains the versionCode-121 fix `73e9337`). Toolchain: JDK 17 (Zulu
17.0.19), AGP 8.2.2 / Gradle 8.4, Android SDK build-tools 35.0.0, daemon
`-Xmx4096m`. Both builds exited **BUILD SUCCESSFUL**.

| Artifact | Path (worktree, gitignored build output) | Size | SHA-256 |
|---|---|---|---|
| Release APK | `apps/android/app/build/outputs/apk/release/app-release.apk` | 2,548,318 B | `3d59fbb2a9da33026ee5c2926748c1aec016da06eca2a918024ee6795dd928a7` |
| Release AAB | `apps/android/app/build/outputs/bundle/release/app-release.aab` | 4,858,452 B | `6df759e3229909ea80596c23ed44da11acd5336d3f47a37d80ef014303d88680` |

**Identity read back from the APK itself** (`aapt dump badging`, corroborated by
`output-metadata.json`):

- applicationId **`com.tono.myapp`**
- **versionCode `121`** ✅ (past the consumed 120 — the delivery fix)
- versionName `1.1`, minSdk 26, targetSdk 35
- Merged manifest declares the IME service **`com.tono.ime.TonoImeService`**
  (`android.view.InputMethod`); the letter layout (`letterRows` q-w-e-r-t-y… in
  `ime/src/main/java/com/tono/ime/keyboard/KeyboardLayout.kt`) is compiled in via
  `:app → implementation(project(":ime"))`.
- Unit tests green on this tree: `:app` **88/0**, incl. `KeyboardLetterVisibilityTest` **9/0**.

> ⚠️ **SIGNING — verification identity, NOT the Play upload key.** These
> artifacts are signed by a **throwaway local keystore** generated for this
> verification only (cert DN `CN=Tono LOCAL VERIFICATION ONLY, OU=DoNotUpload`;
> APK v2 scheme verified true). The real `apps/android/tono-release.keystore` +
> `keystore.properties` are **absent from this host** and are the operator's.
> **DO NOT UPLOAD these files to Play.** They are adequate only for **sideload
> device testing of keyboard behavior** (the signature does not affect
> rendering).

### Sideload for Ari (keyboard behavior test — safe, reversible)
```
adb install -r apps/android/app/build/outputs/apk/release/app-release.apk
adb shell dumpsys package com.tono.myapp | grep versionCode   # expect versionCode=121
```
Then run §0–§8 above. Expected visible behavior: three QWERTY rows with readable
legends (q…p / a…l / z…m) that **type characters** in WhatsApp/Messages/Chrome,
in light and dark — i.e. the original "letters not showing up" report does **not**
reproduce.

### Rollback
- Uninstall the sideloaded build: `adb uninstall com.tono.myapp` (restores
  whatever Play build was present). No account/data migration is involved.
- The throwaway keystore + `keystore.properties` are gitignored/untracked; delete
  `apps/android/tono-release.keystore` and `apps/android/keystore.properties` to
  remove them. No source or committed state changed.

### Remaining gate: **DEVICE_VERIFIED — still NO**
Requires Ari (or any physical Android ≥ versionCode 121) to run §0–§8 and confirm
letters render+type. The Play **upload/release** is a separate operator gate:
rebuild the AAB signed with the **real** `tono-release.keystore` and roll out a
versionCode ≥ 121 (internal → production). This lane did neither and must not.
