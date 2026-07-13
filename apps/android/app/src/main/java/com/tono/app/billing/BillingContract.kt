package com.tono.app.billing

object BillingProducts {
    const val MONTHLY = "com.tonoit.pro.monthly"
    const val YEARLY = "com.tonoit.pro.yearly"
    val all: Set<String> = setOf(MONTHLY, YEARLY)
}

/** The backend is authoritative; a client-side Play purchase is never enough to unlock Pro. */
object EntitlementDecision {
    @Suppress("UNUSED_PARAMETER")
    fun isPro(hasActivePlayPurchase: Boolean, backendIsPro: Boolean): Boolean =
        backendIsPro
}
