package com.tono.app.intelligence

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.tono.ime.intelligence.GeminiNanoRewriter
import com.tono.shared.intelligence.GeminiNanoAvailability
import com.tono.shared.intelligence.GeminiRewriteUnavailableReason
import com.tono.shared.intelligence.OnDeviceRewriteOutcome
import com.tono.shared.models.RewriteAxis
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented checks for the ML Kit (Gemini Nano) boundary. These run on a
 * device/emulator. On CI hardware WITHOUT AICore/Gemini Nano the engine must
 * fail closed — that is the assertion, not a real rewrite. DEVICE_VERIFIED for a
 * genuine on-device rewrite still requires an Apple-Intelligence-class Android
 * device with AICore; see docs/google-intelligence-readiness.md.
 */
@RunWith(AndroidJUnit4::class)
class GeminiNanoRewriterInstrumentedTest {

    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun featureStatusConstantsMatchMlKit() {
        // The illustrative FEATURE_STATUS_* ints in the pure :shared module must
        // equal ML Kit's real FeatureStatus constants, or the pure convenience
        // mapper would drift from the boundary. This is the only place ML Kit
        // symbols resolve, so it is the only place this can be checked.
        assertTrue(GeminiNanoRewriter.featureStatusConstantsMatchMlKit())
    }

    @Test
    fun availabilityIsHonestAndNeverThrows() = runBlocking {
        val engine = GeminiNanoRewriter(context)
        try {
            val availability = engine.availability()
            // Whatever the device reports, it is a real enum value; on CI it is
            // typically DEVICE_NOT_ELIGIBLE / UNSPECIFIED_UNAVAILABLE.
            assertTrue(availability in GeminiNanoAvailability.entries)
        } finally {
            engine.close()
        }
    }

    @Test
    fun emptyDraftFailsClosedWithoutGenerating() = runBlocking {
        val engine = GeminiNanoRewriter(context)
        try {
            val outcome = engine.rewrite("   ", RewriteAxis.FUNNIER, timeoutMs = 4_000)
            assertTrue(outcome is OnDeviceRewriteOutcome.Failure)
            assertEquals(
                GeminiRewriteUnavailableReason.EMPTY_DRAFT,
                (outcome as OnDeviceRewriteOutcome.Failure).reason,
            )
        } finally {
            engine.close()
        }
    }

    @Test
    fun rewriteFailsClosedWhenModelUnavailable() = runBlocking {
        val engine = GeminiNanoRewriter(context)
        try {
            val available = engine.availability().isAvailable
            val outcome = engine.rewrite("Please send the report by Friday.", RewriteAxis.FUNNIER, timeoutMs = 8_000)
            if (!available) {
                // No AICore/Gemini Nano on this hardware → deterministic failure,
                // never a crash and never the source draft echoed back.
                assertTrue(outcome is OnDeviceRewriteOutcome.Failure)
            } else {
                // If a real model IS present, the guard still forbids echoing the
                // source draft as a success.
                if (outcome is OnDeviceRewriteOutcome.Success) {
                    assertFalse(outcome.text.equals("Please send the report by Friday.", ignoreCase = true))
                }
            }
        } finally {
            engine.close()
        }
    }
}
