package com.tono.shared.intelligence

import com.tono.shared.models.RewriteAxis
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class OnDeviceFunnierUseCaseTest {

    private val useCase = OnDeviceFunnierUseCase()

    /** A fake engine that counts calls so "no silent calls" is provable. */
    private class FakeEngine(
        private val availability: GeminiNanoAvailability,
        private val onRewrite: suspend () -> OnDeviceRewriteOutcome = {
            OnDeviceRewriteOutcome.Success("A funnier version 😄")
        },
    ) : OnDeviceRewriteEngine {
        var availabilityCalls = 0
        var rewriteCalls = 0
        var downloadCalls = 0
        val rewriteStarted = CompletableDeferred<Unit>()

        override suspend fun availability(): GeminiNanoAvailability {
            availabilityCalls++; return availability
        }
        override suspend fun download(): GeminiNanoAvailability {
            downloadCalls++; return availability
        }
        override suspend fun rewrite(text: String, axis: RewriteAxis, timeoutMs: Long): OnDeviceRewriteOutcome {
            rewriteCalls++; rewriteStarted.complete(Unit); return onRewrite()
        }
        override fun close() {}
    }

    private suspend fun run(
        engine: FakeEngine,
        draft: String = "Please send the report.",
        kill: Boolean = true,
        pref: GeminiRewritePreference = GeminiRewritePreference.UNSET,
    ) = useCase.run(
        draft = draft,
        engine = engine,
        remoteKillSwitchAllows = kill,
        preference = pref,
    )

    // ── Happy path ──────────────────────────────────────────────────────────

    @Test fun availableModelProducesARewrite() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE)
        val result = run(engine)
        assertTrue(result is OnDeviceFunnierResult.Rewrote)
        assertEquals("A funnier version 😄", (result as OnDeviceFunnierResult.Rewrote).text)
        assertEquals(1, engine.rewriteCalls) // exactly one generation, no fan-out
    }

    // ── No silent calls: every gate that refuses must NOT generate ──────────

    @Test fun emptyDraftNeverTouchesTheEngineGenerator() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE)
        val result = run(engine, draft = "   ")
        assertTrue(result is OnDeviceFunnierResult.Unavailable)
        assertEquals(GeminiRewriteUnavailableReason.EMPTY_DRAFT,
            (result as OnDeviceFunnierResult.Unavailable).reason)
        assertEquals(0, engine.rewriteCalls)
        assertEquals(0, engine.downloadCalls)
    }

    @Test fun killSwitchOffNeverGenerates() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE)
        val result = run(engine, kill = false)
        assertEquals(GeminiRewriteUnavailableReason.REMOTE_KILL_SWITCH,
            (result as OnDeviceFunnierResult.Unavailable).reason)
        assertEquals(0, engine.rewriteCalls)
    }

    @Test fun explicitOffNeverGenerates() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE)
        val result = run(engine, pref = GeminiRewritePreference.OFF)
        assertEquals(GeminiRewriteUnavailableReason.USER_TURNED_OFF,
            (result as OnDeviceFunnierResult.Unavailable).reason)
        assertEquals(0, engine.rewriteCalls)
    }

    @Test fun ineligibleDeviceNeverGenerates() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE)
        val result = run(engine)
        assertEquals(GeminiRewriteUnavailableReason.DEVICE_NOT_ELIGIBLE,
            (result as OnDeviceFunnierResult.Unavailable).reason)
        assertEquals(0, engine.rewriteCalls)
    }

    @Test fun downloadableSurfacesAsDownloadableAndDoesNotAutoDownload() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.DOWNLOADABLE)
        val result = run(engine)
        val reason = (result as OnDeviceFunnierResult.Unavailable).reason
        assertEquals(GeminiRewriteUnavailableReason.MODEL_DOWNLOADABLE, reason)
        assertTrue(OnDeviceFunnierUseCase.isDownloadable(reason))
        assertEquals(0, engine.downloadCalls) // no silent download
        assertEquals(0, engine.rewriteCalls)
    }

    // ── Failures from the engine pass straight through ──────────────────────

    @Test fun engineFailureIsSurfacedVerbatim() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE) {
            OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.NO_VALID_REWRITE)
        }
        val result = run(engine)
        assertEquals(GeminiRewriteUnavailableReason.NO_VALID_REWRITE,
            (result as OnDeviceFunnierResult.Unavailable).reason)
    }

    @Test fun engineTimeoutIsSurfaced() = runTest {
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE) {
            OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.TIMED_OUT)
        }
        assertEquals(GeminiRewriteUnavailableReason.TIMED_OUT,
            (run(engine) as OnDeviceFunnierResult.Unavailable).reason)
    }

    // ── Cancellation propagates (never swallowed as a "failure") ────────────

    @Test fun cancellationPropagatesAndDoesNotProduceAResult() = runTest {
        val gate = CompletableDeferred<OnDeviceRewriteOutcome>()
        val engine = FakeEngine(GeminiNanoAvailability.AVAILABLE) { gate.await() }
        var result: OnDeviceFunnierResult? = null
        val job = launch { result = run(engine) }
        engine.rewriteStarted.await() // generation is in flight
        job.cancel()
        job.join()
        assertTrue(job.isCancelled)
        assertEquals(null, result) // no Rewrote and no Unavailable was produced
    }

    // ── Copy: every reason has non-empty, deterministic copy ────────────────

    @Test fun everyReasonHasDeterministicNonEmptyCopy() {
        GeminiRewriteUnavailableReason.entries.forEach { reason ->
            val msg = OnDeviceFunnierUseCase.message(reason)
            assertFalse("empty copy for $reason", msg.isBlank())
            assertEquals("copy must be deterministic", msg, OnDeviceFunnierUseCase.message(reason))
        }
    }
}
