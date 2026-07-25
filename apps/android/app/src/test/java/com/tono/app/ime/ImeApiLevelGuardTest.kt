package com.tono.app.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Regression guard for the IME globe-key crash.
 *
 * `InputMethodService.switchToNextInputMethod(boolean)` only exists from API 28,
 * but the `ime` module ships `minSdk = 26`. Calling it unguarded threw
 * `NoSuchMethodError` on Android 8.0/8.1: the user tapped the globe to switch
 * keyboards and the keyboard process died mid-sentence. Android lint reported it
 * as a `NewApi` **error**, but `lintDebug` was not part of the build gate, so it
 * shipped silently.
 *
 * Two things now stop it recurring: `lintDebug` is wired into the CI Android job,
 * and this test pins the source shape directly so the guard survives even if a
 * lint baseline is regenerated or the check suppressed.
 *
 * Source-level rather than behavioural because exercising a real API-level branch
 * inside `InputMethodService` needs an instrumented device or Robolectric, and
 * neither belongs in the fast unit lane. Lives in `app` (not `ime`) so it runs
 * under the existing `testDebugUnitTest` gate without adding a test dependency
 * to a module that has none.
 */
class ImeApiLevelGuardTest {

    private val serviceSource: String by lazy {
        val relative = "ime/src/main/java/com/tono/ime/TonoImeService.kt"
        val candidates = listOf(
            File("../$relative"),                 // module dir = apps/android/app
            File(relative),                       // apps/android
            File("apps/android/$relative"),       // repo root
        )
        val found = candidates.firstOrNull { it.isFile }
        requireNotNull(found) {
            "TonoImeService.kt not found from ${File(".").absolutePath}; tried " +
                candidates.joinToString { it.path }
        }
        found.readText()
    }

    @Test
    fun `globe key never calls the API 28 service method unguarded`() {
        val callSites = Regex("""switchToNextInputMethod\s*\(\s*false\s*\)""")
            .findAll(serviceSource).count()
        assertTrue(
            "expected the API-28 service call exactly once, inside the guarded helper; found $callSites",
            callSites == 1
        )
        assertTrue(
            "switchToNextInputMethod(false) requires API 28 but minSdk is 26 — it must sit behind " +
                "a Build.VERSION.SDK_INT >= P check, or the keyboard crashes on Android 8.x",
            serviceSource.contains("Build.VERSION.SDK_INT >= Build.VERSION_CODES.P")
        )
    }

    @Test
    fun `a pre API 28 fallback path exists`() {
        assertTrue(
            "below API 28 the globe key must fall back to InputMethodManager.switchToNextInputMethod",
            serviceSource.contains("InputMethodManager") &&
                serviceSource.contains("imm.switchToNextInputMethod(")
        )
    }

    @Test
    fun `the fallback degrades to a no-op rather than throwing`() {
        assertTrue(
            "the window token lookup must be null-safe (`?: return`)",
            Regex("""attributes\?\.token\s*\?:\s*return""").containsMatchIn(serviceSource)
        )
        assertTrue(
            "the InputMethodManager lookup must be null-safe (`as?` + `?: return`)",
            Regex("""as\?\s+InputMethodManager\s*\?:\s*return""").containsMatchIn(serviceSource)
        )
    }

    @Test
    fun `the compose call site delegates to the guarded helper`() {
        assertTrue(
            "onSwitchIme must route through switchToNextIme()",
            Regex("""onSwitchIme\s*=\s*::switchToNextIme""").containsMatchIn(serviceSource)
        )
        assertFalse(
            "onSwitchIme must not call the API-28 method inline again",
            Regex("""onSwitchIme\s*=\s*\{\s*switchToNextInputMethod""").containsMatchIn(serviceSource)
        )
    }
}
