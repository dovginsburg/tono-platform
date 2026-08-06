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
