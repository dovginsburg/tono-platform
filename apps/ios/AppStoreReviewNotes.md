# App Store Review Notes — Tono

Prepared for the reviewer's benefit. Covers the keyboard's Full Access
requirement, data transmission, and the payment flow.

---

## 1. Why Full Access is Required

Tono is a **pre-send communication coach**. When the user taps "Coach"
or "Read", the keyboard sends the draft/message text to the Tono backend,
which calls an LLM and returns a risk badge + rewrites. This analysis
request requires a network call, which iOS only permits from a keyboard
extension when Full Access is granted.

**Without Full Access**, the keyboard still functions as a normal QWERTY
keyboard — all typing, backspace, space, and globe/next-keyboard work
as expected. Only the Coach and Read buttons are blocked (they show a
friendly prompt directing the user to Settings).

---

## 2. Data Transmission Audit

**What leaves the device (and when):**

| Data | When sent | Destination |
|---|---|---|
| Draft text (the message the user typed) | Only on explicit "Coach" or "Read" tap | Tono backend (api.tonoit.com) |
| Thread context text | Only when user taps "Paste" explicitly | Included in the same Coach/Read request |
| Bearer token (auth) | Every API request | Tono backend |
| Device ID (UUID) | On first launch registration only | Tono backend |

**What is NOT sent:**
- The keyboard does NOT passively transmit keystrokes.
- The clipboard is only read on explicit "Paste" user action (`UIPasteboard.general.string`
  inside `pasteThreadContext()`, called from a Paste button).
- No data is sent to any third party. The Tono backend is the sole recipient.
- API keys for OpenAI / Anthropic are server-side only; they never appear
  on the device.

**Privacy policy:** covers full description of data handling and retention.
The Info.plist `NSPrivacyAccessedAPITypes` key is populated for
`UIPasteboard` (user-initiated reads only).

---

## 3. Payment Flow — StoreKit 2 Only

The iOS subscription is handled entirely through **StoreKit 2**:
- Product IDs: `com.tonoit.pro.monthly` ($3.99/mo) and `com.tonoit.pro.yearly` ($39.99/yr)
- Eligible monthly and annual subscriptions include a 7-day free trial
- No web checkout, no Stripe redirect, no external links for the iOS
  subscription purchase path

Stripe is used only for the Slack integration's B2B billing — that flow
never appears in the iOS app.

The paywall UI (`PaywallView`) calls:
- `StoreKit.Product.products(for:)` to fetch prices from App Store Connect
- `product.purchase()` for the transaction
- `Transaction.currentEntitlements` to verify active entitlements

**Restore Purchases** is available via a "Restore purchases" link in
PaywallView, calling `AppStore.sync()`.

---

## 4. Keychain Access Group — Action Required Before Submission

`SharedKeychain.swift:16` contains a placeholder `XXXXXXXXXX` for the
Team ID in the Keychain access group:

```swift
private static let accessGroup = "XXXXXXXXXX.com.tonocoach.shared"
```

Replace `XXXXXXXXXX` with the actual Apple Developer Team ID before
signing and submitting. Failure to do so will prevent the app and
keyboard extension from sharing Keychain secrets (the bearer token and
device ID), breaking authentication on first launch.

The Team ID is visible in Xcode → Project → Signing & Capabilities,
or at developer.apple.com/account.

---

## 5. App Group Container

The host app and keyboard extension share an App Group:
`group.com.tonocoach.shared`

This must be enabled in both targets in Xcode → Signing & Capabilities → App Groups.

---

## 6. Suggested Test Account

To test the paywall and Pro features without a real purchase, use a
Sandbox test account in App Store Connect. Tono offers **Pro** at $3.99/mo or
$39.99/yr. Eligible subscriptions include a 7-day free trial (real Apple
  introductory offer configured in App Store Connect), then auto-renews
  unless cancelled. Unlimited + thread context + style memory + weekly digest.

The trial disclosure copy reads (from `Product.subscription?.introductoryOffer`,
dynamically rendered): "Free for 7 days, then auto-renews at the StoreKit
price unless cancelled." The paywall also shows
the standard App Store boilerplate required by guideline 3.1.2 (payment
timing, renewal window, free-trial forfeiture) below the buy buttons.

Sign in with the sandbox Apple ID, then start the Pro trial to test the full experience.

---

## 7. Demo Flow for Review

1. Install the host app
2. Follow the onboarding: Settings → General → Keyboard → Add New Keyboard → Tono → Allow Full Access
3. Open any app with a text field (e.g. Notes)
4. Switch to the Tono keyboard via the globe key
5. Type a message (e.g. "As per my last message, let me know when you can.")
6. Tap **Coach** — the backend returns a risk badge (High), a reason, and 4 rewrites
7. Tap a rewrite chip to insert it
8. Tap **Read**, type or paste a received message, then tap **Read** again to get an interpretation

The companion app (Coach tab) shows setup status, Playground for in-app
testing, This Week digest, and Settings/account management.
