package com.tono.app.billing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Build 126 — the client half of the RevenueCat canary routing, pinned as fast
 * pure JVM tests (no Play, no SDK, no key). Mirrors the iOS
 * `Build126RevenueCatRoutingTests`.
 *
 * Turns red if: off/shadow ever conduct a purchase through RevenueCat;
 * authoritative silently downgrades to a Play charge when the SDK/key is missing
 * (instead of failing closed); or the mode parser stops failing closed to OFF.
 */
class RevenueCatRoutingTest {

    // ── Mode routing ───────────────────────────────────────────────────────

    @Test
    fun offRoutesPurchaseToPlayRegardlessOfRevenueCatUsability() {
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.route(RevenueCatMode.OFF, revenueCatUsable = true))
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.route(RevenueCatMode.OFF, revenueCatUsable = false))
    }

    @Test
    fun shadowRoutesPurchaseToPlayAndNeverToRevenueCat() {
        // shadow = observe only; the legacy Play path stays the sole writer.
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.route(RevenueCatMode.SHADOW, revenueCatUsable = true))
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.route(RevenueCatMode.SHADOW, revenueCatUsable = false))
    }

    @Test
    fun authoritativeUsesRevenueCatWhenUsable() {
        assertEquals(RevenueCatPurchaseRoute.REVENUE_CAT,
            RevenueCatPurchaseRouter.route(RevenueCatMode.AUTHORITATIVE, revenueCatUsable = true))
    }

    @Test
    fun authoritativeFailsClosedWhenRevenueCatNotUsable() {
        // Core fail-closed rule: no key / no configured SDK ⇒ blocked, NOT a
        // silent Play charge under an authoritative build.
        assertEquals(RevenueCatPurchaseRoute.BLOCKED_NOT_CONFIGURED,
            RevenueCatPurchaseRouter.route(RevenueCatMode.AUTHORITATIVE, revenueCatUsable = false))
    }

    @Test
    fun noModeEverRoutesAnUnusableRevenueCatToTheRevenueCatEngine() {
        for (mode in RevenueCatMode.values()) {
            assertNotEquals(
                "$mode must never conduct a purchase through an unusable RevenueCat",
                RevenueCatPurchaseRoute.REVENUE_CAT,
                RevenueCatPurchaseRouter.route(mode, revenueCatUsable = false),
            )
        }
    }

    // ── Restore routing — never charges, so it may fall back ────────────────

    @Test
    fun restoreFallsBackToPlayWhenAuthoritativeButUnusable() {
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.restoreRoute(RevenueCatMode.AUTHORITATIVE, revenueCatUsable = false))
    }

    @Test
    fun restoreUsesRevenueCatWhenAuthoritativeAndUsable() {
        assertEquals(RevenueCatPurchaseRoute.REVENUE_CAT,
            RevenueCatPurchaseRouter.restoreRoute(RevenueCatMode.AUTHORITATIVE, revenueCatUsable = true))
    }

    @Test
    fun restoreStaysOnPlayForOffAndShadow() {
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.restoreRoute(RevenueCatMode.OFF, revenueCatUsable = true))
        assertEquals(RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRouter.restoreRoute(RevenueCatMode.SHADOW, revenueCatUsable = true))
    }

    // ── Mode parsing fails closed ───────────────────────────────────────────

    @Test
    fun modeParsingFailsClosedToOff() {
        assertEquals(RevenueCatMode.OFF, RevenueCatMode.parse(null))
        assertEquals(RevenueCatMode.OFF, RevenueCatMode.parse(""))
        assertEquals(RevenueCatMode.OFF, RevenueCatMode.parse("   "))
        assertEquals(RevenueCatMode.OFF, RevenueCatMode.parse("garbage"))
        assertEquals(RevenueCatMode.OFF, RevenueCatMode.parse("off"))
    }

    @Test
    fun modeParsingRecognizesRealModesCaseAndWhitespaceInsensitively() {
        assertEquals(RevenueCatMode.SHADOW, RevenueCatMode.parse("shadow"))
        assertEquals(RevenueCatMode.SHADOW, RevenueCatMode.parse("  Shadow "))
        assertEquals(RevenueCatMode.SHADOW, RevenueCatMode.parse("SHADOW"))
        assertEquals(RevenueCatMode.AUTHORITATIVE, RevenueCatMode.parse("authoritative"))
        assertEquals(RevenueCatMode.AUTHORITATIVE, RevenueCatMode.parse(" AUTHORITATIVE "))
    }

    @Test
    fun exactlyThreeModesExist() {
        assertEquals(3, RevenueCatMode.values().size)
    }
}
