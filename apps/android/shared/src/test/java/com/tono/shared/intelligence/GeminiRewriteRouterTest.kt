package com.tono.shared.intelligence

import com.tono.shared.models.RewriteAxis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The routing matrix. Red-capable: each assertion pins a rule the product owner
 * stated, so a regression that (say) let Safer lead on-device, or that added a
 * fan-out, fails here. Pure JVM — no device, no ML Kit.
 */
class GeminiRewriteRouterTest {

    private val router = GeminiRewriteRouter() // default spike: {FUNNIER}

    private fun decide(
        axis: String,
        kill: Boolean = true,
        pref: GeminiRewritePreference = GeminiRewritePreference.UNSET,
        onDevice: GeminiNanoAvailability = GeminiNanoAvailability.AVAILABLE,
        saferGate: Boolean = false,
        offline: Boolean = false,
    ): RewriteRoutingDecision = router.decide(
        requestedAxis = axis,
        remoteKillSwitchAllows = kill,
        preference = pref,
        onDeviceAvailability = onDevice,
        saferCorpusGateOpen = saferGate,
        connectivityKnownAbsent = offline,
    )

    // ── Provider privacy properties ─────────────────────────────────────────

    @Test fun onDeviceDoesNotLeaveTheDeviceButBackendDoes() {
        assertFalse(RewriteProviderKind.GEMINI_NANO_ON_DEVICE.leavesDevice)
        assertTrue(RewriteProviderKind.TONO_BACKEND.leavesDevice)
        assertTrue(RewriteProviderKind.GEMINI_NANO_ON_DEVICE.isGoogleIntelligence)
        assertFalse(RewriteProviderKind.TONO_BACKEND.isGoogleIntelligence)
    }

    // ── Funnier is the on-device spike ──────────────────────────────────────

    @Test fun funnierLeadsOnDeviceWhenAvailable() {
        val d = decide("funnier")
        assertEquals(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, d.primaryProvider)
        // Backend is the ordered fallback — one at a time, never a fan-out.
        assertEquals(
            listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, RewriteProviderKind.TONO_BACKEND),
            d.orderedProviders,
        )
    }

    // ── Safer stays on the backend unless the corpus gate is open ───────────

    @Test fun saferStaysOnBackendByDefault() {
        assertEquals(RewriteProviderKind.TONO_BACKEND, decide("safer").primaryProvider)
    }

    @Test fun saferMayLeadOnDeviceOnlyWithCorpusGateOpen() {
        assertEquals(
            RewriteProviderKind.GEMINI_NANO_ON_DEVICE,
            decide("safer", saferGate = true).primaryProvider,
        )
    }

    // ── Warmer / Clearer are NOT in the default spike ───────────────────────

    @Test fun warmerAndClearerStayOnBackendByDefault() {
        assertEquals(RewriteProviderKind.TONO_BACKEND, decide("warmer").primaryProvider)
        assertEquals(RewriteProviderKind.TONO_BACKEND, decide("clearer").primaryProvider)
    }

    @Test fun widenedSpikeCanLetClearerLeadOnDevice() {
        val wide = GeminiRewriteRouter(onDeviceSpikeAxes = setOf(RewriteAxis.FUNNIER, RewriteAxis.CLEARER))
        val d = wide.decide("clearer", true, GeminiRewritePreference.UNSET, GeminiNanoAvailability.AVAILABLE, false, false)
        assertEquals(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, d.primaryProvider)
    }

    // ── Unknown / custom axis is never a Google axis ────────────────────────

    @Test fun unknownAxisStaysOnBackend() {
        assertEquals(RewriteProviderKind.TONO_BACKEND, decide("custom").primaryProvider)
    }

    // ── No fan-out: the ordered chain is always distinct ────────────────────

    @Test fun orderedChainIsDistinctEvenWithDuplicateFallbacks() {
        val plan = RewriteRoutePlan(
            primary = RewriteProviderKind.GEMINI_NANO_ON_DEVICE,
            fallbacks = listOf(
                RewriteProviderKind.GEMINI_NANO_ON_DEVICE, // dup of primary
                RewriteProviderKind.TONO_BACKEND,
                RewriteProviderKind.TONO_BACKEND,          // dup
            ),
        )
        assertEquals(
            listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, RewriteProviderKind.TONO_BACKEND),
            plan.ordered,
        )
    }

    // ── Fail-closed: kill switch / opt-out / unavailable → backend ──────────

    @Test fun killSwitchForcesFunnierToBackend() {
        assertEquals(RewriteProviderKind.TONO_BACKEND, decide("funnier", kill = false).primaryProvider)
    }

    @Test fun explicitOffForcesFunnierToBackend() {
        assertEquals(
            RewriteProviderKind.TONO_BACKEND,
            decide("funnier", pref = GeminiRewritePreference.OFF).primaryProvider,
        )
    }

    @Test fun unavailableModelForcesFunnierToBackend() {
        assertEquals(
            RewriteProviderKind.TONO_BACKEND,
            decide("funnier", onDevice = GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE).primaryProvider,
        )
        assertEquals(
            RewriteProviderKind.TONO_BACKEND,
            decide("funnier", onDevice = GeminiNanoAvailability.DOWNLOADABLE).primaryProvider,
        )
    }

    @Test fun unsetPreferenceLeadsOnDeviceOnlyWhenTrulyAvailable() {
        // unset resolves to ON only against a genuinely-available model.
        assertEquals(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, decide("funnier").primaryProvider)
        assertEquals(
            RewriteProviderKind.TONO_BACKEND,
            decide("funnier", onDevice = GeminiNanoAvailability.DOWNLOADING).primaryProvider,
        )
    }

    // ── On-device-only promise forbids the network ──────────────────────────

    @Test fun onlyOnDeviceForbidsBackendForFunnier() {
        val d = decide("funnier", pref = GeminiRewritePreference.ONLY_ON_DEVICE)
        assertEquals(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, d.primaryProvider)
        // Backend is dropped — the chain is on-device ONLY.
        assertEquals(listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE), d.orderedProviders)
    }

    @Test fun onlyOnDeviceWithNoModelIsTerminalNotBackend() {
        val d = decide(
            "funnier",
            pref = GeminiRewritePreference.ONLY_ON_DEVICE,
            onDevice = GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE,
        )
        assertNull(d.primaryProvider)
        assertTrue(d is RewriteRoutingDecision.Terminal)
        assertEquals(
            GeminiRewriteUnavailableReason.DEVICE_NOT_ELIGIBLE,
            (d as RewriteRoutingDecision.Terminal).reason,
        )
    }

    @Test fun onlyOnDeviceForSaferWithClosedGateIsTerminal() {
        val d = decide("safer", pref = GeminiRewritePreference.ONLY_ON_DEVICE, saferGate = false)
        assertTrue(d is RewriteRoutingDecision.Terminal)
        assertEquals(
            GeminiRewriteUnavailableReason.SAFER_NEEDS_REVIEW,
            (d as RewriteRoutingDecision.Terminal).reason,
        )
    }

    @Test fun offlineForbidsBackendAndYieldsTerminalWhenNoLocalEngine() {
        // Funnier, offline, model not eligible → nothing reachable → terminal.
        val d = decide("funnier", onDevice = GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE, offline = true)
        assertTrue(d is RewriteRoutingDecision.Terminal)
    }

    @Test fun offlineStillAllowsOnDeviceForFunnier() {
        // Offline drops only providers that leave the device; on-device stays.
        val d = decide("funnier", offline = true)
        assertEquals(listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE), d.orderedProviders)
    }

    @Test fun offlineForBackendOnlyAxisIsTerminalWithConnectionReason() {
        val d = decide("warmer", offline = true)
        assertTrue(d is RewriteRoutingDecision.Terminal)
        assertEquals(
            GeminiRewriteUnavailableReason.TONE_NEEDS_CONNECTION,
            (d as RewriteRoutingDecision.Terminal).reason,
        )
    }

    @Test fun terminalReasonNamesKillSwitchFirst() {
        val d = decide("warmer", kill = false, offline = true)
        assertEquals(
            GeminiRewriteUnavailableReason.REMOTE_KILL_SWITCH,
            (d as RewriteRoutingDecision.Terminal).reason,
        )
    }
}
