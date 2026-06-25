# Privacy Nutrition — Tono

App Store Connect privacy labels for the **Tono** iOS app, version 1.0.

## Summary

Tono has no server. The app stores preferences locally and calls the
LLM provider you've configured (OpenAI or Anthropic) using your own API
key. **Tono does not collect any data linked to you.** Data sent to the
LLM provider is governed by that provider's privacy policy and your
relationship with them as a paying customer.

## App Store Connect privacy labels

| Category | Data type | Collected | Linked to user | Tracking | Purpose |
|---|---|---|---|---|---|
| Contact Info | — | No | — | — | — |
| Health & Fitness | — | No | — | — | — |
| Financial Info | Purchase history | Yes | Yes | No | App Store subscription management |
| Location | — | No | — | — | — |
| Sensitive Info | — | No | — | — | — |
| Contacts | — | No | — | — | — |
| User Content | Draft text | **Sent to user's LLM provider, not Tono** | No | No | Tone analysis |
| Browsing History | — | No | — | — | — |
| Search History | — | No | — | — | — |
| Identifiers | — | No | — | — | — |
| Usage Data | Product interaction | Yes (on-device only) | No | No | Local free-tier counter |
| Diagnostics | — | No | — | — | — |
| Purchases | Subscription status | Yes | Yes | No | App Store IAP |
| Other Data | — | No | — | — | — |

## Data NOT collected

- Account / login: Tono has no account system.
- Analytics: none. No third-party SDKs.
- Crash reporting: none in v1.0. Add Sentry / Crashlytics post-launch.
- Push notifications: not used in v1.0.
- Advertising data: none. Tono does not advertise.

## Network endpoints

- `https://api.openai.com/v1/chat/completions` — only if user picks OpenAI
- `https://api.anthropic.com/v1/messages` — only if user picks Anthropic

Both calls go directly from the user's device. The request body contains
the draft text. Authorization is the user's own API key, stored in the
App Group `UserDefaults`. The mock provider makes no network calls.

## On-device storage

Stored in the App Group container `group.com.tonocoach.shared`:

- `tc.provider` — selected provider (mock / openai / anthropic)
- `tc.apiKey` — API key (use Keychain for stronger protection in v1.1)
- `tc.preferredVoice` — user style hint
- `tc.axes` — enabled rewrite axes
- `tc.freeTierUsed`, `tc.freeTierDay`, `tc.freeTierLimit` — daily counter
- `tc.proUnlocked` — subscription status
- `tc.lastRewriteVoice` — last accepted rewrite (style memory)

## Children's privacy

Tono is rated 12+. It does not knowingly collect data from children. The
keyboard works in any text field but does not call out from password
fields (per Apple's Custom Keyboard security model — those fields give
the keyboard no text).

## Data retention

Tono retains nothing on a server. The user's own LLM provider may retain
data per their policies; Tono does not control this.

## User controls

- **Delete all on-device data:** uninstalling the app deletes the App
  Group container.
- **Revoke Full Access:** Settings → General → Keyboard → Tono → toggle
  off "Allow Full Access." The keyboard continues to work offline with
  the mock provider.
- **Switch providers:** in-app Settings → Provider.

## Contact

privacy@tono.app

---

This document is the source of truth for App Store Connect privacy
labels. Update when new endpoints, providers, or on-device storage are
added.
