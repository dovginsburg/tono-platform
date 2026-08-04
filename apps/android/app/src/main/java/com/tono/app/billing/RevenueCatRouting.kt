package com.tono.app.billing

/**
 * Build 126 — the client half of the RevenueCat canary routing for Android.
 *
 * A pure, SDK-free decision layer that selects which engine conducts a paywall
 * purchase/restore, mirroring the iOS `RevenueCatPurchaseRouter`, the backend
 * `TONO_REVENUECAT_MODE`, and the web `NEXT_PUBLIC_REVENUECAT_MODE`. Being pure,
 * every rule below is exercised by fast JVM unit tests — no Play, no key, no SDK.
 *
 *  - [RevenueCatMode.OFF]:           the existing Play Billing path conducts the
 *                                    purchase/restore; RevenueCat is dormant.
 *  - [RevenueCatMode.SHADOW]:        the Play path still conducts the purchase — it
 *                                    stays the sole deterministic writer — and
 *                                    RevenueCat only observes, never granting.
 *  - [RevenueCatMode.AUTHORITATIVE]: RevenueCat conducts the purchase/restore
 *                                    lifecycle; the backend remains the sole
 *                                    durable entitlement projector.
 */
enum class RevenueCatMode {
    OFF,
    SHADOW,
    AUTHORITATIVE;

    companion object {
        /** Parse a raw BuildConfig/env string, failing closed to [OFF] for
         * anything unknown, empty, or null. */
        fun parse(raw: String?): RevenueCatMode =
            when (raw?.trim()?.lowercase()) {
                "shadow" -> SHADOW
                "authoritative" -> AUTHORITATIVE
                else -> OFF // fail closed: unknown/empty/null ⇒ off
            }
    }
}

/** Which engine should conduct a paywall purchase/restore. */
enum class RevenueCatPurchaseRoute {
    /** The legacy Play Billing path (off / shadow, and the authoritative restore
     * fallback). */
    PLAY_BILLING,

    /** RevenueCat conducts the purchase/restore (authoritative + usable). */
    REVENUE_CAT,

    /** Authoritative requested but RevenueCat is not usable (missing key / SDK).
     * A purchase fails closed here — never a silent charge via the wrong engine. */
    BLOCKED_NOT_CONFIGURED,
}

object RevenueCatPurchaseRouter {

    /**
     * Decide which engine conducts a **purchase**. [revenueCatUsable] must be true
     * only when a real publishable key is present and the SDK is configured
     * (`Purchases.isConfigured`).
     */
    fun route(mode: RevenueCatMode, revenueCatUsable: Boolean): RevenueCatPurchaseRoute =
        when (mode) {
            // The legacy Play path is the deterministic writer; shadow only adds
            // RevenueCat observation on top — it never conducts the purchase.
            RevenueCatMode.OFF, RevenueCatMode.SHADOW -> RevenueCatPurchaseRoute.PLAY_BILLING
            // Fail closed: authoritative without a usable RevenueCat is blocked,
            // not silently downgraded to a Play charge.
            RevenueCatMode.AUTHORITATIVE ->
                if (revenueCatUsable) RevenueCatPurchaseRoute.REVENUE_CAT
                else RevenueCatPurchaseRoute.BLOCKED_NOT_CONFIGURED
        }

    /**
     * Decide which engine conducts a **restore**. Restore never charges, so an
     * authoritative-but-unusable state safely falls back to a Play restore rather
     * than blocking the user out of recovering an existing subscription.
     */
    fun restoreRoute(mode: RevenueCatMode, revenueCatUsable: Boolean): RevenueCatPurchaseRoute =
        when (route(mode, revenueCatUsable)) {
            RevenueCatPurchaseRoute.REVENUE_CAT -> RevenueCatPurchaseRoute.REVENUE_CAT
            RevenueCatPurchaseRoute.PLAY_BILLING,
            RevenueCatPurchaseRoute.BLOCKED_NOT_CONFIGURED -> RevenueCatPurchaseRoute.PLAY_BILLING
        }
}
