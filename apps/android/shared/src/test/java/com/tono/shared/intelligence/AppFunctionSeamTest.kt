package com.tono.shared.intelligence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The App Functions availability gate and action logic. The whole point is that
 * on the checked-in build the gate is fail-closed (DISABLED_BY_BUILD) and no
 * action can read ambient state or bypass a gate. Pure JVM.
 */
class AppFunctionSeamTest {

    // ── Availability gate is fail-closed ────────────────────────────────────

    @Test fun onlySupportedCountsAsAvailable() {
        assertTrue(AppFunctionAvailability.SUPPORTED.isAvailable)
        AppFunctionAvailability.entries
            .filter { it != AppFunctionAvailability.SUPPORTED }
            .forEach { assertFalse("$it must not be available", it.isAvailable) }
    }

    @Test fun checkedInBuildIsDisabledByBuildEvenOnAndroid16() {
        // Even on a hypothetical Android 16 device, the checked-in build did not
        // compile the @AppFunction service in, so it is DISABLED_BY_BUILD.
        assertEquals(
            AppFunctionAvailability.DISABLED_BY_BUILD,
            AppFunctionGate.currentBuildAvailability(osSdkInt = 40),
        )
        assertFalse(AppFunctionGate.COMPILED_INTO_THIS_BUILD)
    }

    @Test fun gateShortCircuitsInObservableOrder() {
        // Not built → DISABLED_BY_BUILD regardless of the rest.
        assertEquals(AppFunctionAvailability.DISABLED_BY_BUILD,
            AppFunctionGate.decide(compiledIntoBuild = false, osSdkInt = 40, managerPresent = true, eapAdmitted = true))
        // Built but old OS → UNSUPPORTED_OS.
        assertEquals(AppFunctionAvailability.UNSUPPORTED_OS,
            AppFunctionGate.decide(true, osSdkInt = 34, managerPresent = true, eapAdmitted = true))
        // Built, new OS, no manager → MANAGER_UNAVAILABLE.
        assertEquals(AppFunctionAvailability.MANAGER_UNAVAILABLE,
            AppFunctionGate.decide(true, osSdkInt = AppFunctionGate.MINIMUM_ANDROID_SDK, managerPresent = false, eapAdmitted = true))
        // Built, new OS, manager present, not admitted → EAP_NOT_ADMITTED.
        assertEquals(AppFunctionAvailability.EAP_NOT_ADMITTED,
            AppFunctionGate.decide(true, osSdkInt = AppFunctionGate.MINIMUM_ANDROID_SDK, managerPresent = true, eapAdmitted = false))
        // Everything genuinely met → SUPPORTED (the only true state).
        assertEquals(AppFunctionAvailability.SUPPORTED,
            AppFunctionGate.decide(true, osSdkInt = AppFunctionGate.MINIMUM_ANDROID_SDK, managerPresent = true, eapAdmitted = true))
    }

    @Test fun minimumSdkIsAndroid16AndPermissionsAreNamed() {
        assertEquals(36, AppFunctionGate.MINIMUM_ANDROID_SDK)
        assertEquals("android.permission.EXECUTE_APP_FUNCTIONS", AppFunctionGate.EXECUTE_PERMISSION)
        assertEquals("android.permission.BIND_APP_FUNCTION_SERVICE", AppFunctionGate.BIND_PERMISSION)
    }

    // ── Route enum + one-shot signal (via injectable writer) ────────────────

    @Test fun routeEnumRoundTrips() {
        assertEquals(AppFunctionRoute.KEYBOARD_SETUP, AppFunctionRoute.from("keyboard_setup"))
        assertNull(AppFunctionRoute.from("something_else"))
    }

    @Test fun openKeyboardSetupQueuesTheRouteAndNoText() {
        val captured = mutableListOf<AppFunctionRoute>()
        val writer = object : AppFunctionRouteSignalWriter {
            override fun request(route: AppFunctionRoute) { captured.add(route) }
        }
        val result = OpenKeyboardSetupAction.perform(writer)
        assertEquals(AppFunctionRoute.KEYBOARD_SETUP, result.route)
        assertEquals(listOf(AppFunctionRoute.KEYBOARD_SETUP), captured)
        assertTrue(result.message.isNotBlank())
    }

    // ── Coach Text is a gate, never a silent sender ─────────────────────────

    @Test fun coachTextRefusesEmptyBeforeAnythingElse() {
        assertEquals(CoachTextAction.Outcome.EmptyInput,
            CoachTextAction.authorize("   ", isRegistered = true, isPro = true))
    }

    @Test fun coachTextRequiresRegistrationThenEntitlement() {
        assertEquals(CoachTextAction.Outcome.NotRegistered,
            CoachTextAction.authorize("hi", isRegistered = false, isPro = true))
        assertEquals(CoachTextAction.Outcome.EntitlementRequired,
            CoachTextAction.authorize("hi", isRegistered = true, isPro = false))
    }

    @Test fun coachTextAuthorizesTrimmedTextOnlyWhenRegisteredAndPro() {
        val outcome = CoachTextAction.authorize("  draft here  ", isRegistered = true, isPro = true)
        assertTrue(outcome is CoachTextAction.Outcome.Authorized)
        assertEquals("draft here", (outcome as CoachTextAction.Outcome.Authorized).text)
        assertTrue(outcome.isAuthorized)
    }

    @Test fun everyCoachTextOutcomeHasNonEmptyCopy() {
        listOf(
            CoachTextAction.Outcome.Authorized("x"),
            CoachTextAction.Outcome.EmptyInput,
            CoachTextAction.Outcome.NotRegistered,
            CoachTextAction.Outcome.EntitlementRequired,
        ).forEach { assertTrue(it.message.isNotBlank()) }
    }

    // ── Set Tone Variant is local and never widens on-device-only ───────────

    @Test fun toneVariantRejectsUnknownVariant() {
        assertEquals(ToneVariantAction.Outcome.UnknownVariant,
            ToneVariantAction.apply("teleport", enable = true, current = GeminiRewritePreference.OFF))
    }

    @Test fun toneVariantEnableFromOffTurnsOn() {
        val outcome = ToneVariantAction.apply(ToneVariantAction.ON_DEVICE_FUNNIER, true, GeminiRewritePreference.OFF)
        assertEquals(GeminiRewritePreference.ON, (outcome as ToneVariantAction.Outcome.Set).preference)
        assertTrue(outcome.didChange)
    }

    @Test fun toneVariantEnableDoesNotWidenOnlyOnDevice() {
        val outcome = ToneVariantAction.apply(ToneVariantAction.ON_DEVICE_FUNNIER, true, GeminiRewritePreference.ONLY_ON_DEVICE)
        // Already on (and narrower) → unchanged, still ONLY_ON_DEVICE.
        assertTrue(outcome is ToneVariantAction.Outcome.Unchanged)
        assertEquals(GeminiRewritePreference.ONLY_ON_DEVICE,
            (outcome as ToneVariantAction.Outcome.Unchanged).preference)
        assertFalse(outcome.didChange)
    }

    @Test fun toneVariantDisableTurnsOff() {
        val outcome = ToneVariantAction.apply(ToneVariantAction.ON_DEVICE_FUNNIER, false, GeminiRewritePreference.ON)
        assertEquals(GeminiRewritePreference.OFF, (outcome as ToneVariantAction.Outcome.Set).preference)
    }
}
