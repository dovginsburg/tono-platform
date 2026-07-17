# Tono — Social Tone Coach (iOS Keyboard MVP)

> Say what you mean. Land how you intend.

Tono is a pre-send text-rewriting keyboard for iOS. You draft a message in any
text field, switch to the Tono keyboard, tap **Coach**, and see four rewrites
on different tone axes — **warmer**, **clearer**, **funnier**, **safer** —
plus a **risk badge** (low / medium / high) so you know if the draft might
misfire. One tap swaps the chosen rewrite into the host text field.

The wedge is **before send**, not "better grammar." This is the MVP scaffold
described in `SCOPE.md` (§6.1).

## Status

- Xcode project: `ToneApp.xcodeproj` — two targets: `Tono` (host app) and
  `TonoKeyboard` (Custom Keyboard extension).
- iOS 16+ minimum. Swift 5.0 / SwiftUI. Bundle IDs `com.tonocoach.app` and
  `com.tonocoach.app.keyboard`. App Group `group.com.tonocoach.shared`.
- Shared engine in `Shared/` is compiled into both targets.
- Mock analyzer works offline. OpenAI (gpt-4o-mini) and Anthropic
  (claude-haiku-4-5) providers wired up with structured JSON output
  (response_format=json_schema on OpenAI, tool-use on Anthropic).
- Tests: `ToneEngineTests.swift` covers the mock analyzer, JSON decoder,
  and free-tier gate. Open Xcode and ⌘U to run.

## Repo layout

```
social-tone-coach/
├── SCOPE.md                     ← business case & spec (29KB, durable)
├── README.md                    ← this file
├── ToneApp.xcodeproj/           ← Xcode project (open this)
├── App/                         ← host app: onboarding, settings, playground
│   ├── TonoApp.swift
│   ├── HomeView.swift
│   ├── SettingsView.swift
│   ├── PlaygroundView.swift
│   ├── Info.plist
│   └── Tono.entitlements
├── KeyboardExtension/           ← the custom keyboard
│   ├── KeyboardViewController.swift
│   ├── KeyboardRootView.swift
│   ├── Info.plist
│   └── TonoKeyboard.entitlements
├── Shared/                      ← compiled into both targets
│   ├── ToneEngine.swift
│   ├── MockToneAnalyzer.swift
│   ├── OpenAIToneAnalyzer.swift
│   ├── AnthropicToneAnalyzer.swift
│   ├── SharedUserDefaults.swift
│   └── ToneEngineTests.swift
├── AppStoreMetadata/            ← App Store Connect copy + privacy labels
│   ├── app-store-listing.md
│   ├── keywords.txt
│   ├── privacy-nutrition.md
│   └── screenshots-plan.md
├── Screenshots/                 ← Figma/photopea mocks live here
└── Backend/                     ← optional Ezra-as-backend stub (FastAPI)
    └── server.py
```

## Run it

1. Install **Xcode 15+** (the project file is `Xcode 14.0` compatible too).
   The keyboard extension only compiles with the full Xcode.app, not just
   the Command Line Tools.
2. Open `ToneApp.xcodeproj`.
3. Set your **Development Team** on both targets (Signing & Capabilities).
   The bundle IDs are pre-filled; App Group `group.com.tonocoach.shared`
   is referenced in both entitlements files.
4. Select the **Tono** scheme, pick any iOS 16+ simulator, **Run** (⌘R).
5. In the host app's **Settings** tab, choose a provider (Mock / OpenAI /
   Anthropic) and paste an API key if you picked OpenAI or Anthropic.
6. To exercise the keyboard:
   - Open Settings app → General → Keyboard → Keyboards → Add New Keyboard…
     → **Tono**.
   - In any text field, long-press the 🌐 globe, pick Tono.
   - Type a message, tap **Coach**, see the rewrites.

> Apple requires the **Allow Full Access** toggle for keyboard extensions
> to make network calls. The keyboard uses this only to call your chosen
> LLM provider with the draft text. Drafts are not stored on a Tono
> server — see `AppStoreMetadata/privacy-nutrition.md`.

## Architecture

```
┌─────────────────────────────────────────┐
│ Host app (Tono)                         │   ← onboarding, settings, paywall
│ - TonePreferences (read/write)          │      playground
│ - FreeTierGate                          │
└──────────────┬──────────────────────────┘
               │ App Group: group.com.tonocoach.shared
               ▼
┌─────────────────────────────────────────┐
│ Shared engine                           │
│ - ToneEngine                            │   ← one source of truth
│ - MockToneAnalyzer / OpenAI / Anthropic │
│ - JSON schema, system prompt            │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ Keyboard extension (TonoKeyboard)       │   ← SwiftUI inside UIInputView
│ - KeyboardViewController (UIKit host)  │
│ - KeyboardRootView (SwiftUI)            │
│ - Two states: keyboard ↔ results       │
└─────────────────────────────────────────┘
```

The host app is the **only** place the user enters their API key. The
keyboard reads it from the App Group `UserDefaults`. The Playground tab
in the host app uses the same engine so QA can rehearse the Coach flow
without enabling the keyboard.

### The rewrite-axis system prompt

`Shared/ToneEngine.swift → TonePrompts.system` codifies the rewrite axes
and the seven prohibitions. The prompt is seeded from Ezra's group-chat
tone discipline (1-sentence ceiling, no tool narration, no analysis
dumps, gut check). See `SCOPE.md` §4.1 and §9 for the recoupment
argument — the axis library is the same muscle that already runs Ezra's
own group outputs.

### Structured output

- **OpenAI**: `response_format: { type: json_schema, json_schema: { ... TonePrompts.jsonSchema ... }, strict: true }`.
- **Anthropic**: tool-use with `tone_analysis` tool and the same schema.
- **Decoder** (`ToneEngine.decode`) tolerates accidental code fences and
  drops unknown axes silently.

## Pricing model

See `SCOPE.md` §5. Pro is $3.99/month or $39.99/year after an eligible 7-day
trial — unlimited rewrites, style memory, and all surfaces. B2B: $25/seat.
The in-app paywall is a stub — wire RevenueCat or StoreKit 2 before launch.

## App Store review notes

- Keyboard extensions requesting **Full Access** must explain why. The
  Info.plist flag `RequestsOpenAccess` is set to `true`. The host app's
  onboarding copy and the Settings tab explain why Full Access is needed
  (network calls to the LLM provider).
- Custom keyboards may not be used to exfiltrate passwords; Tono does
  not call out from password fields (the keyboard extension sees no
  text in those fields anyway, per Apple).
- The App Store Connect privacy labels for this build are in
  `AppStoreMetadata/privacy-nutrition.md`. **Data not collected by us**:
  Tono has no server. The LLM provider you choose (OpenAI / Anthropic)
  sees the draft text — that's the user's own API-key relationship, not
  Tono's.

## Backend (optional)

`Backend/server.py` is a thin FastAPI shim that proxies the same
JSON-schema call to a hosted model. For MVP the keyboard calls the
provider directly from the device — this folder exists for the eventual
"Ezra-as-backend" architecture (see `SCOPE.md` §4 and §9). Not used at
runtime by the keyboard.

## Roadmap

- V1.5 (months 3–4): Android keyboard, macOS share-extension, style
  profile per recipient, conversation context.
- V2 (months 5–8): Slack/Teams/Outlook add-ins, admin console.
- V3 (months 9–12): Family plan, recipient modeling opt-in, morning-review
  cron.

## Open questions for Dov

These are the six questions in `SCOPE.md` §10.2 — none block the
green-light, but they shape the v1.5 + v2 roadmap. The naming
shortlist (Tone / Relay / Hearth / After / Landing) is the one that
needs an answer before App Store metadata is locked.
