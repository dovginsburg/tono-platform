package com.tono.shared.intelligence

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GeminiNanoAvailabilityTest {

    // ── Availability gate is fail-closed: only AVAILABLE is usable ───────────

    @Test fun onlyAvailableCountsAsUsable() {
        assertTrue(GeminiNanoAvailability.AVAILABLE.isAvailable)
        GeminiNanoAvailability.entries
            .filter { it != GeminiNanoAvailability.AVAILABLE }
            .forEach { assertFalse("$it must not be usable", it.isAvailable) }
    }

    @Test fun featureStatusFlattensToTheRightState() {
        assertEquals(GeminiNanoAvailability.AVAILABLE,
            GeminiNanoAvailability.fromFeatureStatus(GeminiNanoAvailability.FEATURE_STATUS_AVAILABLE))
        assertEquals(GeminiNanoAvailability.DOWNLOADABLE,
            GeminiNanoAvailability.fromFeatureStatus(GeminiNanoAvailability.FEATURE_STATUS_DOWNLOADABLE))
        assertEquals(GeminiNanoAvailability.DOWNLOADING,
            GeminiNanoAvailability.fromFeatureStatus(GeminiNanoAvailability.FEATURE_STATUS_DOWNLOADING))
        assertEquals(GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE,
            GeminiNanoAvailability.fromFeatureStatus(GeminiNanoAvailability.FEATURE_STATUS_UNAVAILABLE))
        // An unrecognised status is fail-closed, never AVAILABLE.
        assertEquals(GeminiNanoAvailability.UNSPECIFIED_UNAVAILABLE,
            GeminiNanoAvailability.fromFeatureStatus(999))
    }

    // ── Preference resolution (quad-state) ──────────────────────────────────

    @Test fun preferenceResolvesAgainstRealAvailability() {
        // UNSET is ON only when the model is genuinely available.
        assertTrue(GeminiRewritePreference.UNSET.resolved(GeminiNanoAvailability.AVAILABLE))
        assertFalse(GeminiRewritePreference.UNSET.resolved(GeminiNanoAvailability.DOWNLOADABLE))
        // ON / ONLY_ON_DEVICE resolve ON regardless; OFF resolves OFF regardless.
        assertTrue(GeminiRewritePreference.ON.resolved(GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE))
        assertTrue(GeminiRewritePreference.ONLY_ON_DEVICE.resolved(GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE))
        assertFalse(GeminiRewritePreference.OFF.resolved(GeminiNanoAvailability.AVAILABLE))
    }

    @Test fun onlyOnDeviceProhibitsNetworkAndOthersDoNot() {
        assertTrue(GeminiRewritePreference.ONLY_ON_DEVICE.prohibitsNetwork)
        assertFalse(GeminiRewritePreference.ON.prohibitsNetwork)
        assertFalse(GeminiRewritePreference.UNSET.prohibitsNetwork)
        assertFalse(GeminiRewritePreference.OFF.prohibitsNetwork)
    }

    @Test fun explicitnessMatchesChoice() {
        assertFalse(GeminiRewritePreference.UNSET.isExplicit)
        assertTrue(GeminiRewritePreference.ON.isExplicit)
        assertTrue(GeminiRewritePreference.OFF.isExplicit)
        assertTrue(GeminiRewritePreference.ONLY_ON_DEVICE.isExplicit)
    }

    @Test fun rawValueRoundTripsAndUnknownIsUnset() {
        GeminiRewritePreference.entries.forEach {
            assertEquals(it, GeminiRewritePreference.from(it.id))
        }
        assertEquals(GeminiRewritePreference.UNSET, GeminiRewritePreference.from("garbage"))
        assertEquals(GeminiRewritePreference.UNSET, GeminiRewritePreference.from(null))
    }

    // ── Store rules (pure helpers) ──────────────────────────────────────────

    @Test fun turningOffAlwaysGoesOff() {
        GeminiRewritePreference.entries.forEach {
            assertEquals(GeminiRewritePreference.OFF, GeminiRewritePreference.afterSetEnabled(it, false))
        }
    }

    @Test fun turningOnDoesNotWidenOnDeviceOnly() {
        // Re-enabling from ONLY_ON_DEVICE preserves the narrower choice.
        assertEquals(
            GeminiRewritePreference.ONLY_ON_DEVICE,
            GeminiRewritePreference.afterSetEnabled(GeminiRewritePreference.ONLY_ON_DEVICE, true),
        )
        // Every other prior state re-enables to plain ON.
        assertEquals(GeminiRewritePreference.ON, GeminiRewritePreference.afterSetEnabled(GeminiRewritePreference.OFF, true))
        assertEquals(GeminiRewritePreference.ON, GeminiRewritePreference.afterSetEnabled(GeminiRewritePreference.UNSET, true))
    }

    @Test fun onDeviceOnlyToggleIsExplicitBothWays() {
        assertEquals(GeminiRewritePreference.ONLY_ON_DEVICE, GeminiRewritePreference.afterSetOnDeviceOnly(true))
        assertEquals(GeminiRewritePreference.ON, GeminiRewritePreference.afterSetOnDeviceOnly(false))
    }

    // ── Reason mapping from availability ─────────────────────────────────────

    @Test fun everyAvailabilityMapsToADistinctReason() {
        assertEquals(GeminiRewriteUnavailableReason.MODEL_DOWNLOADABLE,
            GeminiRewriteUnavailableReason.fromAvailability(GeminiNanoAvailability.DOWNLOADABLE))
        assertEquals(GeminiRewriteUnavailableReason.MODEL_DOWNLOADING,
            GeminiRewriteUnavailableReason.fromAvailability(GeminiNanoAvailability.DOWNLOADING))
        assertEquals(GeminiRewriteUnavailableReason.DEVICE_NOT_ELIGIBLE,
            GeminiRewriteUnavailableReason.fromAvailability(GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE))
        assertEquals(GeminiRewriteUnavailableReason.UNSUPPORTED_OS,
            GeminiRewriteUnavailableReason.fromAvailability(GeminiNanoAvailability.UNSUPPORTED_OS))
        // An "available" model that still fails is a generation failure, not an
        // availability problem.
        assertEquals(GeminiRewriteUnavailableReason.GENERATION_FAILED,
            GeminiRewriteUnavailableReason.fromAvailability(GeminiNanoAvailability.AVAILABLE))
    }
}
