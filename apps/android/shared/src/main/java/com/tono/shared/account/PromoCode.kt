package com.tono.shared.account

import java.util.Locale

object PromoCode {
    fun normalize(value: String): String = value.trim().uppercase(Locale.ROOT)
}

enum class CouponRedemptionOutcome {
    SIGN_IN_REQUIRED,
    REJECTED,
    ALREADY_USED,
    EXPIRED,
    RATE_LIMITED,
    OFFLINE,
    SERVICE_UNAVAILABLE,
}

class CouponRedemptionException(
    val outcome: CouponRedemptionOutcome,
) : Exception()

object CouponRedemptionCopy {
    const val SUCCESS = "Promo code applied. Your account has been refreshed."

    fun error(outcome: CouponRedemptionOutcome): String = when (outcome) {
        CouponRedemptionOutcome.SIGN_IN_REQUIRED ->
            "Sign in or reconnect your account before applying a promo code."
        CouponRedemptionOutcome.REJECTED ->
            "That promo code isn't valid. Check it and try again."
        CouponRedemptionOutcome.ALREADY_USED ->
            "That promo code has already been used."
        CouponRedemptionOutcome.EXPIRED ->
            "That promo code has expired."
        CouponRedemptionOutcome.RATE_LIMITED ->
            "Too many attempts. Wait a moment, then try again."
        CouponRedemptionOutcome.OFFLINE ->
            "You're offline. Reconnect, then try again."
        CouponRedemptionOutcome.SERVICE_UNAVAILABLE ->
            "Couldn't apply that promo code just now. Try again in a moment."
    }

    fun allSentences(): List<String> =
        listOf(SUCCESS) + CouponRedemptionOutcome.entries.map(::error)
}

data class PromoCodeUiState(
    val input: String = "",
    val isApplying: Boolean = false,
    val notice: String? = null,
) {
    val normalizedCode: String get() = PromoCode.normalize(input)
    val canApply: Boolean get() = normalizedCode.isNotEmpty() && !isApplying

    fun edited(value: String): PromoCodeUiState = copy(input = value, notice = null)
    fun applying(): PromoCodeUiState =
        if (canApply) copy(input = normalizedCode, isApplying = true, notice = null) else this
    fun succeeded(): PromoCodeUiState =
        copy(input = "", isApplying = false, notice = CouponRedemptionCopy.SUCCESS)
    fun failed(outcome: CouponRedemptionOutcome): PromoCodeUiState =
        copy(isApplying = false, notice = CouponRedemptionCopy.error(outcome))
}
