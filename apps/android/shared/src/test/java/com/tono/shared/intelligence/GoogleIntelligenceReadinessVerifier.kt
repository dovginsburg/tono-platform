package com.tono.shared.intelligence

import com.tono.shared.models.RewriteAxis
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Executable readiness verifier for the Google-intelligence seam — the Android
 * analogue of iOS `Scripts/verify_apple_intelligence_routing.swift`. It links
 * the REAL pure sources (no duplication, so it cannot drift) and runs a single
 * battery of `check()`s, printing a pass/fail count and failing the build if any
 * check fails.
 *
 * The iOS verifiers compile with `swiftc`; this machine has no standalone
 * `kotlinc`, so the equivalent runs under the Gradle JVM test runner. Invoke on
 * its own with:
 *   ./gradlew :shared:testDebugUnitTest \
 *     --tests "com.tono.shared.intelligence.GoogleIntelligenceReadinessVerifier"
 *
 * Covers the reviewer's checklist:
 *   • provider privacy (what leaves the device)
 *   • availability fail-closed (only AVAILABLE / SUPPORTED are usable)
 *   • routing: Safer stays backend unless the corpus gate is open
 *   • routing: Funnier is the on-device spike
 *   • routing: no fan-out (one primary; ordered chain distinct; most private first)
 *   • routing: on-device-only forbids the network and yields terminal
 *   • routing: fail-closed (kill switch / opt-out / unavailable → backend/terminal)
 *   • AppFunctions: fail-closed, DISABLED_BY_BUILD on the checked-in build
 *   • output guard: source draft is never a "success"
 */
class GoogleIntelligenceReadinessVerifier {

    private val failures = mutableListOf<String>()
    private var checks = 0

    private fun check(cond: Boolean, label: String) {
        checks++
        if (!cond) failures.add(label)
    }

    private fun <T> expectEq(a: T, b: T, label: String) {
        checks++
        if (a != b) failures.add("$label: got $a, want $b")
    }

    private val router = GeminiRewriteRouter()

    private fun decide(
        axis: String,
        kill: Boolean = true,
        pref: GeminiRewritePreference = GeminiRewritePreference.UNSET,
        onDevice: GeminiNanoAvailability = GeminiNanoAvailability.AVAILABLE,
        saferGate: Boolean = false,
        offline: Boolean = false,
    ) = router.decide(axis, kill, pref, onDevice, saferGate, offline)

    @Test
    fun verify() {
        // ── Provider privacy ────────────────────────────────────────────────
        check(!RewriteProviderKind.GEMINI_NANO_ON_DEVICE.leavesDevice, "on-device must not leave device")
        check(RewriteProviderKind.TONO_BACKEND.leavesDevice, "backend leaves device")
        check(RewriteProviderKind.GEMINI_NANO_ON_DEVICE.isGoogleIntelligence, "nano is google intelligence")
        check(!RewriteProviderKind.TONO_BACKEND.isGoogleIntelligence, "backend is not google intelligence")

        // ── Availability fail-closed ────────────────────────────────────────
        check(GeminiNanoAvailability.AVAILABLE.isAvailable, "AVAILABLE usable")
        GeminiNanoAvailability.entries.filter { it != GeminiNanoAvailability.AVAILABLE }
            .forEach { check(!it.isAvailable, "$it must not be usable") }

        // ── Routing: Funnier on-device spike; Safer/others on backend ───────
        expectEq(decide("funnier").primaryProvider, RewriteProviderKind.GEMINI_NANO_ON_DEVICE, "funnier leads on-device")
        expectEq(decide("safer").primaryProvider, RewriteProviderKind.TONO_BACKEND, "safer stays backend")
        expectEq(decide("safer", saferGate = true).primaryProvider, RewriteProviderKind.GEMINI_NANO_ON_DEVICE, "safer on-device only with gate")
        expectEq(decide("warmer").primaryProvider, RewriteProviderKind.TONO_BACKEND, "warmer backend")
        expectEq(decide("clearer").primaryProvider, RewriteProviderKind.TONO_BACKEND, "clearer backend")
        expectEq(decide("custom").primaryProvider, RewriteProviderKind.TONO_BACKEND, "custom backend")

        // ── Routing: no fan-out; most private first; distinct chain ─────────
        expectEq(
            decide("funnier").orderedProviders,
            listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, RewriteProviderKind.TONO_BACKEND),
            "funnier chain = [on-device, backend]",
        )
        expectEq(
            RewriteRoutePlan(
                RewriteProviderKind.GEMINI_NANO_ON_DEVICE,
                listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, RewriteProviderKind.TONO_BACKEND, RewriteProviderKind.TONO_BACKEND),
            ).ordered,
            listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE, RewriteProviderKind.TONO_BACKEND),
            "ordered chain is de-duplicated",
        )

        // ── Routing: fail-closed ────────────────────────────────────────────
        expectEq(decide("funnier", kill = false).primaryProvider, RewriteProviderKind.TONO_BACKEND, "kill switch → backend")
        expectEq(decide("funnier", pref = GeminiRewritePreference.OFF).primaryProvider, RewriteProviderKind.TONO_BACKEND, "opt-out → backend")
        expectEq(decide("funnier", onDevice = GeminiNanoAvailability.DOWNLOADABLE).primaryProvider, RewriteProviderKind.TONO_BACKEND, "downloadable → backend")

        // ── Routing: on-device-only forbids the network ─────────────────────
        expectEq(
            decide("funnier", pref = GeminiRewritePreference.ONLY_ON_DEVICE).orderedProviders,
            listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE),
            "only-on-device drops backend",
        )
        check(
            decide("funnier", pref = GeminiRewritePreference.ONLY_ON_DEVICE, onDevice = GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE)
                is RewriteRoutingDecision.Terminal,
            "only-on-device + no model → terminal",
        )
        check(
            decide("warmer", offline = true) is RewriteRoutingDecision.Terminal,
            "offline backend-only axis → terminal",
        )
        expectEq(
            decide("funnier", offline = true).orderedProviders,
            listOf(RewriteProviderKind.GEMINI_NANO_ON_DEVICE),
            "offline still allows on-device",
        )

        // ── AppFunctions fail-closed ────────────────────────────────────────
        check(AppFunctionAvailability.SUPPORTED.isAvailable, "SUPPORTED available")
        AppFunctionAvailability.entries.filter { it != AppFunctionAvailability.SUPPORTED }
            .forEach { check(!it.isAvailable, "$it must not be available") }
        expectEq(AppFunctionGate.currentBuildAvailability(40), AppFunctionAvailability.DISABLED_BY_BUILD, "checked-in build disabled")
        check(!AppFunctionGate.COMPILED_INTO_THIS_BUILD, "not compiled into build")
        expectEq(AppFunctionGate.MINIMUM_ANDROID_SDK, 36, "min android 16")

        // ── Output guard: source draft is never a success ───────────────────
        check(OnDeviceRewriteGuard.resolve("Hello world", "hello, world!!") is OnDeviceRewriteOutcome.Failure, "no-op is a failure")
        check(OnDeviceRewriteGuard.resolve("", "x") is OnDeviceRewriteOutcome.Failure, "empty is a failure")
        check(OnDeviceRewriteGuard.resolve("Totally new wording", "old") is OnDeviceRewriteOutcome.Success, "distinct is a success")

        // ── Copy completeness ───────────────────────────────────────────────
        GeminiRewriteUnavailableReason.entries.forEach {
            check(OnDeviceFunnierUseCase.message(it).isNotBlank(), "copy for $it")
        }

        // Deterministic default spike is exactly {FUNNIER}.
        expectEq(GeminiRewriteRouter().onDeviceSpikeAxes, setOf(RewriteAxis.FUNNIER), "default spike = {funnier}")

        println("GoogleIntelligenceReadinessVerifier: $checks checks, ${failures.size} failures")
        if (failures.isNotEmpty()) {
            println("FAILURES:\n" + failures.joinToString("\n") { "  - $it" })
        }
        assertEquals("readiness verifier failures: $failures", 0, failures.size)
    }
}
