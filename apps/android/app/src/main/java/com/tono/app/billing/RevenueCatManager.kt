package com.tono.app.billing

import android.app.Activity
import android.app.Application
import com.tono.app.BuildConfig
import com.tono.shared.storage.SharedStore
import com.tono.shared.storage.SharedKeys
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.LogLevel
import com.revenuecat.purchases.Offering
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.getCustomerInfoWith
import com.revenuecat.purchases.getOfferingsWith
import com.revenuecat.purchases.logInWith
import com.revenuecat.purchases.purchaseWith
import com.revenuecat.purchases.restorePurchasesWith
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * RevenueCat canary integration (Build 123) — lives in :app ONLY.
 *
 * RevenueCat is the first Tono canary for a unified subscription lifecycle. This
 * object owns the RevenueCat Android SDK lifecycle: authenticated identity
 * (logIn/appUserID = the canonical Tono account UUID), safe logout/reset,
 * CustomerInfo refresh, exact product/package mapping, purchase, restore, pending
 * handling, and a kill switch.
 *
 * TWO invariants keep this safe as an additive canary:
 *
 *  1. The Tono BACKEND stays the sole entitlement authority. RevenueCat's
 *     CustomerInfo is OBSERVATION only; it never unlocks Pro. The Pro gate remains
 *     [EntitlementDecision.isPro] over the backend `tc.proUnlocked` mirror
 *     populated exclusively from `/v1/me`. No client-side RevenueCat state grants
 *     access, and no anonymous user owns durable paid access — we only ever logIn
 *     the server-issued account UUID.
 *
 *  2. This is in the :app module, never :ime. The keyboard must not see account
 *     identity or auth (KeyboardPrivacyContract); it reads only the PRO_UNLOCKED
 *     mirror. The existing [PlayBillingManager] path is unchanged (no duplicate
 *     checkout) — this provides the identity/observation layer now and the
 *     purchase/restore capability for a later, deliberate cutover.
 *
 * Kill switch: RevenueCat is configured ONLY when [BuildConfig.REVENUECAT_PUBLIC_SDK_KEY]
 * holds a real publishable `goog_` key. An empty/placeholder key leaves RevenueCat
 * entirely dormant — the default canary posture.
 */
object RevenueCatManager {

    /** The RevenueCat entitlement id that maps to the canonical Tono `pro`. */
    private const val ENTITLEMENT_ID = "pro"

    /** RevenueCat's default package identifiers for the monthly / annual offering. */
    const val PACKAGE_MONTHLY = "\$rc_monthly"
    const val PACKAGE_ANNUAL = "\$rc_annual"

    private val _customerInfoIsPro = MutableStateFlow(false)
    /** RevenueCat's view of entitlement — OBSERVATION ONLY, never the Pro gate. */
    val customerInfoIsPro: StateFlow<Boolean> = _customerInfoIsPro.asStateFlow()

    private val _localizedPrices = MutableStateFlow<Map<String, String>>(emptyMap())
    /** Localized display price per package id (e.g. "$3.99"), from the provider. */
    val localizedPrices: StateFlow<Map<String, String>> = _localizedPrices.asStateFlow()

    private val _purchaseError = MutableStateFlow<String?>(null)
    val purchaseError: StateFlow<String?> = _purchaseError.asStateFlow()

    @Volatile
    private var configured = false

    /** True when a real publishable key is present (kill switch on). */
    val isEnabled: Boolean
        get() = publicSdkKey() != null

    /** True once the RevenueCat SDK has actually been configured with a real key.
     * The paywall routes a purchase/restore to RevenueCat only when this is true
     * (Build 126 `authoritative` mode); otherwise the router fails closed to the
     * existing Play path. Distinct from [isEnabled], which only reports that a key
     * is present — configuration additionally requires the SDK to be linked and
     * `configureIfEnabled` to have run. */
    fun isConfigured(): Boolean = Purchases.isConfigured

    private fun publicSdkKey(): String? {
        val key = BuildConfig.REVENUECAT_PUBLIC_SDK_KEY.trim()
        // Empty / obvious placeholder => not configured (fail closed / dormant).
        return if (key.isEmpty() || key.equals("REPLACE_ME", ignoreCase = true)) null else key
    }

    /** The immutable, server-issued Tono account UUID — the ONLY App User ID we
     * ever use. Never the device id, email, or an anonymous RevenueCat id. */
    private fun canonicalAccountId(): String? =
        SharedStore.getString(SharedKeys.ACCOUNT_ID)?.trim()?.takeIf { it.isNotEmpty() }

    /**
     * Configure RevenueCat once at app launch, behind the kill switch. A no-op when
     * no real key is present. If the canonical account UUID already exists we
     * configure with it so no anonymous RevenueCat identity is created; otherwise
     * we identify later via [identifyFromStore] once registration completes.
     */
    fun configureIfEnabled(app: Application) {
        val key = publicSdkKey() ?: return  // kill switch: dormant by default
        if (configured || Purchases.isConfigured) return
        Purchases.logLevel = if (BuildConfig.DEBUG) LogLevel.DEBUG else LogLevel.ERROR
        val builder = PurchasesConfiguration.Builder(app, key)
        canonicalAccountId()?.let { builder.appUserID(it) }
        Purchases.configure(builder.build())
        configured = true
        refreshCustomerInfo()
        refreshOfferings()
    }

    /**
     * Log the canonical account UUID into RevenueCat. Call after the Tono account
     * is established (post-register / post-sign-in). No-op if there is no account
     * UUID yet — we never create an anonymous durable identity.
     */
    fun identifyFromStore() {
        if (!Purchases.isConfigured) return
        val appUserId = canonicalAccountId() ?: return
        Purchases.sharedInstance.logInWith(
            appUserId,
            onError = { /* transient; observation only, never fail the app */ },
            onSuccess = { _, _ -> refreshCustomerInfo() },
        )
    }

    /** Reset RevenueCat identity on sign-out / account deletion so the next person
     * on this device never inherits the previous account's RevenueCat customer. */
    fun signOut() {
        _customerInfoIsPro.value = false
        _localizedPrices.value = emptyMap()
        _purchaseError.value = null
        if (!Purchases.isConfigured) return
        Purchases.sharedInstance.logOut()
    }

    /** Refresh CustomerInfo for OBSERVATION. Never changes the Pro gate. */
    fun refreshCustomerInfo() {
        if (!Purchases.isConfigured) return
        Purchases.sharedInstance.getCustomerInfoWith(
            onError = { /* telemetry only — leave last known value */ },
            onSuccess = { info -> _customerInfoIsPro.value = info.isEntitlementActive() },
        )
    }

    /** Load the current offering and cache localized display prices per package. */
    fun refreshOfferings() {
        if (!Purchases.isConfigured) return
        Purchases.sharedInstance.getOfferingsWith(
            onError = { /* paywall falls back to existing Play prices */ },
            onSuccess = { offerings ->
                val current = offerings.current ?: return@getOfferingsWith
                val prices = current.availablePackages.associate { pkg ->
                    pkg.identifier to pkg.product.price.formatted
                }
                _localizedPrices.value = prices
            },
        )
    }

    sealed class PurchaseOutcome {
        object Purchased : PurchaseOutcome()
        /** Play deferred / pending (e.g. Ask-to-Buy, slow card) — NOT yet granted. */
        object Pending : PurchaseOutcome()
        object Cancelled : PurchaseOutcome()
        object NotConfigured : PurchaseOutcome()
        object Unavailable : PurchaseOutcome()
        data class Failed(val message: String) : PurchaseOutcome()
    }

    /**
     * Purchase the subscription for a product id ([BillingProducts.MONTHLY] /
     * [BillingProducts.YEARLY]). Requires the canonical account UUID (never an
     * anonymous purchase). The backend remains the entitlement authority — a
     * successful purchase surfaces via the RevenueCat webhook, which the server
     * projects; this callback only drives local UI state.
     */
    fun purchase(activity: Activity, productId: String, onResult: (PurchaseOutcome) -> Unit) {
        if (!Purchases.isConfigured) { onResult(PurchaseOutcome.NotConfigured); return }
        if (canonicalAccountId() == null) {
            val msg = "Finish account setup before purchasing."
            _purchaseError.value = msg
            onResult(PurchaseOutcome.Failed(msg)); return
        }
        _purchaseError.value = null
        identifyFromStore()
        Purchases.sharedInstance.getOfferingsWith(
            onError = { onResult(PurchaseOutcome.Unavailable) },
            onSuccess = { offerings ->
                val offering = offerings.current
                val pkg = offering?.packageForProduct(productId)
                if (offering == null || pkg == null) { onResult(PurchaseOutcome.Unavailable); return@getOfferingsWith }
                Purchases.sharedInstance.purchaseWith(
                    PurchaseParams.Builder(activity, pkg).build(),
                    onError = { error, userCancelled ->
                        if (userCancelled) {
                            onResult(PurchaseOutcome.Cancelled)
                        } else {
                            val msg = "Purchase could not be completed. Please try again."
                            _purchaseError.value = msg
                            onResult(PurchaseOutcome.Failed(msg))
                        }
                    },
                    onSuccess = { _, customerInfo ->
                        // A success without an active entitlement is a PENDING Play
                        // purchase (deferred). Do not present it as granted.
                        val active = customerInfo.isEntitlementActive()
                        _customerInfoIsPro.value = active
                        refreshCustomerInfo()
                        onResult(if (active) PurchaseOutcome.Purchased else PurchaseOutcome.Pending)
                    },
                )
            },
        )
    }

    /** Restore purchases (reinstall / second device). Re-identifies the canonical
     * account first so a restore attaches to the right RevenueCat customer. */
    fun restore(onResult: (PurchaseOutcome) -> Unit) {
        if (!Purchases.isConfigured) { onResult(PurchaseOutcome.NotConfigured); return }
        _purchaseError.value = null
        identifyFromStore()
        Purchases.sharedInstance.restorePurchasesWith(
            onError = {
                val msg = "Restore could not be completed. Please try again."
                _purchaseError.value = msg
                onResult(PurchaseOutcome.Failed(msg))
            },
            onSuccess = { info ->
                val active = info.isEntitlementActive()
                _customerInfoIsPro.value = active
                onResult(if (active) PurchaseOutcome.Purchased else PurchaseOutcome.Failed("No active subscription found to restore."))
            },
        )
    }

    private fun CustomerInfo.isEntitlementActive(): Boolean =
        entitlements[ENTITLEMENT_ID]?.isActive == true

    private fun Offering.packageForProduct(productId: String): com.revenuecat.purchases.Package? {
        return when (productId) {
            BillingProducts.MONTHLY -> monthly
            BillingProducts.YEARLY -> annual
            else -> null
        } ?: availablePackages.firstOrNull { it.product.id.startsWith(productId) }
    }
}
