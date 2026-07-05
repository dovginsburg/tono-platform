# Tono iOS Shortcut — `TonoRewrite.shortcut`

The `.shortcut` binary plist in this directory is the v1.0 "Quick setup"
entry point. Install it once on Dov's iPhone to put Tono in the top row of
the iOS Share Sheet with one tap.

## What's in the box

| File | Purpose |
|---|---|
| `TonoRewrite.shortcut` | Binary plist. Importable directly into iOS Shortcuts app. |
| `TonoRewrite.shortcut.json` | Source-of-truth JSON manifest. Inspect/edit here, regenerate `.shortcut` via `python3 scripts/regenerate_shortcut.py`. |
| `README.md` | This file. |

## Install path (Dov, on iPhone)

**Path A — direct file transfer (preferred):**
1. AirDrop `TonoRewrite.shortcut` from this Mac to the iPhone.
2. iPhone prompts "Open in Shortcuts?" → tap **Add**.
3. Shortcut appears under "My Shortcuts" named `Tono Rewrite`.

**Path B — iCloud Drive:**
1. Copy `TonoRewrite.shortcut` into `~/Library/Mobile Documents/iCloud~is~workflow~shortcuts/` on the Mac (the iCloud Shortcuts sync folder).
2. Wait ~30s for iCloud to sync. The shortcut appears in the iPhone Shortcuts app under "My Shortcuts".

**Path C — universal URL (one-tap, no file transfer):**
1. From the iPhone Safari, open: `shortcuts://import-workflow?url=https://raw.githubusercontent.com/tono/tono/main/ios/shortcuts/TonoRewrite.shortcut`
   (URL becomes live once the public repo is set up; until then use Path A.)

## What the shortcut does

```
Receive text input from Share Sheet
  → POST https://api.tonoit.com/api/analyze (Tono backend, same endpoint
    the share extension and keyboard use)
  → Take first suggestion from response
  → Copy that text to clipboard
  → Show notification "Tono rewrite copied"
```

No `tono://` URL scheme hop. No app open. Pure Shortcuts-native.

## Why JSON + plist, not just `.shortcut`

`.shortcut` is a binary plist that iOS Shortcuts recognises. We also keep
the source JSON for:

- diffability in git (binary plists are opaque)
- regeneration: `python3 scripts/regenerate_shortcut.py`
- portable editing without needing Shortcuts.app on macOS

## Regeneration

```bash
cd /Users/Ezra/Projects/apps/tono/ios/shortcuts
python3 -c "
import json, plistlib
with open('TonoRewrite.shortcut.json') as f: d = json.load(f)
with open('TonoRewrite.shortcut', 'wb') as f:
    plistlib.dump({'shortcut': {**d, 'WFWorkflowName': 'Tono Rewrite'}}, f, fmt=plistlib.FMT_BINARY)
print('regenerated')
"
```

## Backend URL note

The endpoint `https://api.tonoit.com/api/analyze` is the production
backend. In Debug builds the iOS app falls back to `http://127.0.0.1:8765`
(see `Shared/TonoBackend.swift:198`). The shortcut bypasses the iOS app
entirely — there's no Debug fallback. For staging/dev, edit
`TonoRewrite.shortcut.json` to point at the local tunnel URL, regenerate
the `.shortcut`, and re-install.

## Verification (Sherlock, during QA)

After installing on iPhone:

1. Open any app with a text field (Notes, Mail, Messages).
2. Type something like "ok fine ill just do it myself like always".
3. Tap Share → look for "Tono Rewrite" in the top row of the share sheet.
4. Tap it. iOS Shortcuts opens, runs the workflow, shows notification.
5. Paste back. Result is the first suggestion from `/api/analyze`.

Acceptance criterion (per skill tono-ios-multi-entry-architecture):
"Shortcut appears in iOS Share Sheet across at least: iMessage, WhatsApp, Mail, Notes, Safari."

## Quirks

- iOS may add the shortcut to a second-tier "More" menu the first time;
  long-press → "Reorder" to pin it to the top row.
- The shortcut needs network access. First run will prompt for
  permission to allow shortcuts to make web requests. Approve once.
- The shortcut does NOT currently surface in the share sheet's "People
  Suggestions" row. To get there, also enable the Tono iOS share
  extension (separate code path, wired up in this build).