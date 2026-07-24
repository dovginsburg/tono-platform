package com.tono.app.billing

object BillingProducts {
    const val MONTHLY = "com.tonoit.pro.monthly"
    const val YEARLY = "com.tonoit.pro.yearly"
    const val MONTHLY_BASE_PLAN = "pro-monthly"
    const val YEARLY_BASE_PLAN = "pro-yearly"
    const val TRIAL_OFFER = "trial-14-days"
    val all: Set<String> = setOf(MONTHLY, YEARLY)

    fun basePlanFor(productId: String): String? = when (productId) {
        MONTHLY -> MONTHLY_BASE_PLAN
        YEARLY -> YEARLY_BASE_PLAN
        else -> null
    }
}

/** The backend is authoritative; a client-side Play purchase is never enough to unlock Pro. */
object EntitlementDecision {
    @Suppress("UNUSED_PARAMETER")
    fun isPro(hasActivePlayPurchase: Boolean, backendIsPro: Boolean): Boolean =
        backendIsPro
}
