package com.tono.app.billing

import java.security.MessageDigest

object BillingProducts {
    const val MONTHLY = "com.tonoit.pro.monthly"
    const val YEARLY = "com.tonoit.pro.yearly"
    val all: Set<String> = setOf(MONTHLY, YEARLY)
}

/** Provider-visible ownership id; must match the backend's `tono:<device id>` digest. */
object BillingOwnership {
    fun obfuscatedAccountId(deviceId: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest("tono:$deviceId".toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
}

object TrialOfferContract {
    fun isRealSevenDayTrial(priceAmountMicros: Long, billingPeriod: String): Boolean =
        priceAmountMicros == 0L && billingPeriod in setOf("P7D", "P1W")
}

/** The backend is authoritative; a client-side Play purchase is never enough to unlock Pro. */
object EntitlementDecision {
    @Suppress("UNUSED_PARAMETER")
    fun isPro(hasActivePlayPurchase: Boolean, backendIsPro: Boolean): Boolean =
        backendIsPro
}
