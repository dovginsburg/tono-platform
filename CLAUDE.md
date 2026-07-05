# Social Tone Coach (Tono) — AI Context

## What this is
An iOS keyboard extension that helps people say what they mean. User types a message, taps "Coach", gets risk analysis + 4 rewrites (warmer, clearer, funnier, safer). One-tap to swap in the rewrite.

**Tagline:** Say what you mean. Land how you intend.
**Price:** $5.99/mo or $39.99/yr (7-day free trial on annual)

## Architecture
- **App/** — SwiftUI host app (onboarding, settings, playground)
- **KeyboardExtension/** — Custom iOS keyboard with Coach mode
- **ShareExtension/** — Share Sheet extension (TonoShare.appex)
- **TonoMessagesExtension/** — iMessage extension (TonoMessagesExtension.appex)
- **Shared/** — Engine + analyzers compiled into all extension targets
- **Backend/** — FastAPI proxy server (users never see API keys)

## Entry points
1. **Keyboard** — Full keyboard replacement with Coach mode (v1.1, gated off in v1.0)
2. **Share Sheet** — Select text → Share → Tono → get rewrites
3. **iMessage** — Messages app drawer → Tono → analyze draft before sending
4. **Shortcut** — "Tono Rewrite" shortcut, auto-installs via deep link `shortcuts://import-workflow?url=...`

## Key files
- `Shared/ToneEngine.swift` — Unified engine, routes to backend or local APIs
- `Shared/TonoBackend.swift` — HTTP client for backend proxy
- `Shared/MockToneAnalyzer.swift` — Offline heuristics (no API key needed)
- `Shared/OpenAIToneAnalyzer.swift` — gpt-4o-mini with structured JSON
- `Shared/AnthropicToneAnalyzer.swift` — claude-haiku-4-5 with tool-use
- `KeyboardExtension/KeyboardRootView.swift` — Full keyboard UI (draft → coach → results)
- `ShareExtension/ShareViewController.swift` — Share sheet entry point
- `TonoMessagesExtension/MessagesViewController.swift` — iMessage extension entry point
- `App/OnboardingEntryPointsView.swift` — 3-tile onboarding (keyboard/share/shortcut)
- `Backend/server.py` — FastAPI: /api/analyze, auth, rate limiting, Stripe
- `Backend/store.py` — SQLite user/device storage
- `Backend/payments.py` — Stripe checkout + billing portal
- `Backend/auth.py` — Device registration + bearer tokens
- `SCOPE.md` — Full business case (29KB, durable)
- `scripts/add_messages_extension_target.rb` — Adds iMessage extension to Xcode project

## Current state
- 3 commits on main, working tree clean
- 2,118 LOC Swift + 1,701 LOC Python
- Backend tests: 14/14 passing
- Backend proxy fully wired (app routes through server, no API key entry)
- All 4 spec deliverables present (Xcode project, prototype, README, App Store metadata)

## What needs work
- **Xcode verification** — Can't compile/simulate without Xcode
- **Backend deploy** — Railway config ready (`railway.toml`, `Dockerfile`), not yet deployed
- **App Store Connect** — Register product IDs `com.tono.pro.monthly` and `com.tono.pro.yearly`
- **Keychain Team ID** — Replace `XXXXXXXXXX` placeholder in `SharedKeychain.swift:16`

## Pricing
- Free: 10 rewrites/day, all 4 axes
- Pro: $5.99/mo or $39.99/yr (7-day free trial on annual) — unlimited rewrites, style memory, per-recipient coaching, weekly digest
- B2B: $25/seat/mo (year 2)

## Tech stack
- Swift 5.0 / SwiftUI, iOS 16+ minimum
- FastAPI + SQLite + Stripe (backend)
- OpenAI gpt-4o-mini / Anthropic claude-haiku-4-5 (LLM providers)
- Mock analyzer for offline/free tier
