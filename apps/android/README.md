# Tono for Android

Native Kotlin/Compose companion app + a native `InputMethodService` keyboard.
Android has no React Native equivalent for a system keyboard, so unlike
web/desktop/Slack this platform can't share JS with `packages/shared` — see
`ARCHITECTURE.md` at the repo root for why, and `app/src/main/java/com/tono/app/net/TonoApiClient.kt`
for the Kotlin port of the same wire contract.

## Structure

- `app/src/main/java/com/tono/app/ui/MainActivity.kt` — companion app (Compose), mirrors the web app's Coach flow
- `app/src/main/java/com/tono/app/viewmodel/CoachViewModel.kt` — state holder calling the backend
- `app/src/main/java/com/tono/app/net/TonoApiClient.kt` — OkHttp client matching `packages/shared`'s wire contract
- `app/src/main/java/com/tono/keyboard/TonoInputMethodService.kt` — the actual system keyboard (single-case QWERTY + Coach button; see the class doc for scope limits)
- `app/src/main/java/com/tono/app/ui/BiometricGate.kt` — gates the Coach screen behind Face/fingerprint/PIN (`androidx.biometric.BiometricPrompt`) before showing anything; Android's answer to "unlock with Face ID." Skips itself entirely on devices with no biometric enrolled.
- `app/src/main/res/values*/strings.xml` — localized strings (en, es, fr, de, ja, pt-BR, ar), same copy as `packages/shared/src/i18n/locales/*.json`

## Opening this project

This was hand-written outside Android Studio, so the Gradle wrapper JAR
(`gradle/wrapper/gradle-wrapper.jar`) isn't checked in — this sandbox has no
network access to fetch it. Two ways to get building:

1. **Open in Android Studio** (recommended) — it regenerates the wrapper JAR
   automatically on first sync.
2. **CLI**, if you have a local Gradle install: `gradle wrapper` once from
   this directory, then `./gradlew assembleDebug`.

## Running against the backend

`app/build.gradle.kts` defaults `BuildConfig.TONO_API_URL` to
`http://10.0.2.2:8765` — the Android emulator's alias for your host
machine's localhost, matching `uvicorn Backend.server:app --port 8765` run
from `apps/backend`. For a physical device, point it at your machine's LAN
IP or a deployed backend URL instead.

The keyboard service (`TonoInputMethodService`) currently hardcodes the same
URL independently, since it runs in its own `:keyboard` process and can't
read the app module's `BuildConfig` directly — see the `TODO` in that file
for the follow-up (share config via `SharedPreferences` written on app launch).

## Enabling the keyboard on-device

1. Install and open the Tono app once.
2. Settings → System → Languages & input → On-screen keyboard → Manage keyboards → enable **Tono**.
3. In any text field, tap the keyboard-switcher icon (globe/keyboard glyph on the system nav bar) and pick **Tono**.

This mirrors the iOS flow (Settings → Keyboards → Add New Keyboard → Full
Access) documented in `tono-ios/BRIEF.md`.
