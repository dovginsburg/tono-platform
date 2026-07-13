package com.tono.app.billing

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.net.Uri
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.tono.shared.network.TonoBackend
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private const val PLAY_PACKAGE_NAME = "com.tono.myapp"

data class PlayProduct(
    val id: String,
    val label: String,
    val formattedPrice: String,
)

data class BillingUiState(
    val products: List<PlayProduct> = emptyList(),
    val isLoading: Boolean = true,
    val isPro: Boolean = false,
    val message: String? = null,
    val error: String? = null,
)

/**
 * Process-wide Play Billing coordinator. Google owns checkout; the Tono backend
 * verifies every purchase token and remains the only authority for Pro access.
 */
object PlayBillingManager : PurchasesUpdatedListener {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(BillingUiState())
    val state: StateFlow<BillingUiState> = _state.asStateFlow()

    private lateinit var billingClient: BillingClient
    private val productDetails = mutableMapOf<String, ProductDetails>()
    private var connecting = false

    fun start(application: Application) {
        if (::billingClient.isInitialized) return
        _state.value = _state.value.copy(
            isPro = SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED),
        )
        billingClient = BillingClient.newBuilder(application)
            .setListener(this)
            .enablePendingPurchases()
            .build()
        connect()
    }

    fun refresh() {
        if (!::billingClient.isInitialized) return
        _state.value = _state.value.copy(isLoading = true, message = null, error = null)
        if (billingClient.isReady) {
            queryProducts()
            queryPurchases()
        } else {
            connect()
        }
    }

    fun restore() {
        _state.value = _state.value.copy(
            isLoading = true,
            message = "Checking Google Play for purchases…",
            error = null,
        )
        if (billingClient.isReady) queryPurchases(restoring = true) else connect()
    }

    fun purchase(activity: Activity, productId: String) {
        val details = productDetails[productId]
        val offer = details?.subscriptionOfferDetails?.firstOrNull()
        if (details == null || offer == null) {
            _state.value = _state.value.copy(
                error = "This subscription is not available from Google Play right now.",
            )
            refresh()
            return
        }

        val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(details)
            .setOfferToken(offer.offerToken)
            .build()
        val result = billingClient.launchBillingFlow(
            activity,
            BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(productParams))
                .build(),
        )
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            showBillingError(result, "Could not open Google Play checkout")
        }
    }

    fun manageSubscriptions(activity: Activity) {
        val uri = Uri.parse(
            "https://play.google.com/store/account/subscriptions?package=$PLAY_PACKAGE_NAME",
        )
        activity.startActivity(Intent(Intent.ACTION_VIEW, uri))
    }

    override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> processPurchases(purchases.orEmpty())
            BillingClient.BillingResponseCode.USER_CANCELED -> {
                _state.value = _state.value.copy(
                    isLoading = false,
                    message = "Purchase cancelled. You were not charged.",
                    error = null,
                )
            }
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> queryPurchases(restoring = true)
            else -> showBillingError(result, "Purchase failed")
        }
    }

    private fun connect() {
        if (connecting) return
        connecting = true
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                connecting = false
                if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                    queryProducts()
                    queryPurchases()
                } else {
                    showBillingError(result, "Google Play Billing is unavailable")
                }
            }

            override fun onBillingServiceDisconnected() {
                connecting = false
                _state.value = _state.value.copy(
                    isLoading = false,
                    error = "Google Play disconnected. Tap Retry to reconnect.",
                )
            }
        })
    }

    private fun queryProducts() {
        val products = BillingProducts.all.map { id ->
            QueryProductDetailsParams.Product.newBuilder()
                .setProductId(id)
                .setProductType(BillingClient.ProductType.SUBS)
                .build()
        }
        val params = QueryProductDetailsParams.newBuilder().setProductList(products).build()
        billingClient.queryProductDetailsAsync(params) { result, details ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                showBillingError(result, "Could not load subscription prices")
                return@queryProductDetailsAsync
            }
            productDetails.clear()
            details.forEach { productDetails[it.productId] = it }
            val displayProducts = details
                .filter { it.productId in BillingProducts.all }
                .sortedBy { if (it.productId == BillingProducts.MONTHLY) 0 else 1 }
                .mapNotNull(::toDisplayProduct)
            _state.value = _state.value.copy(
                products = displayProducts,
                isLoading = false,
                error = if (displayProducts.size == BillingProducts.all.size) null
                    else "Google Play has not returned both Tono Pro plans.",
            )
        }
    }

    private fun queryPurchases(restoring: Boolean = false) {
        val params = QueryPurchasesParams.newBuilder()
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        billingClient.queryPurchasesAsync(params) { result, purchases ->
            if (result.responseCode == BillingClient.BillingResponseCode.OK) {
                processPurchases(purchases, restoring)
            } else {
                showBillingError(result, "Could not restore purchases")
            }
        }
    }

    private fun processPurchases(purchases: List<Purchase>, restoring: Boolean = false) {
        val tonoPurchases = purchases.filter { purchase ->
            purchase.products.any { it in BillingProducts.all }
        }
        val purchased = tonoPurchases.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
        val hasPending = tonoPurchases.any { it.purchaseState == Purchase.PurchaseState.PENDING }

        if (purchased.isEmpty()) {
            scope.launch {
                val backend = runCatching { withContext(Dispatchers.IO) { TonoBackend.me() } }
                backend.fold(
                    onSuccess = { me ->
                        _state.value = _state.value.copy(
                            isLoading = false,
                            isPro = EntitlementDecision.isPro(false, me.isPro),
                            message = when {
                                hasPending -> "Purchase pending approval in Google Play."
                                restoring -> if (me.isPro) "Pro entitlement restored." else "No active Play purchase found."
                                else -> null
                            },
                            error = null,
                        )
                    },
                    onFailure = { error ->
                        _state.value = _state.value.copy(
                            isLoading = false,
                            message = if (hasPending) "Purchase pending approval in Google Play." else null,
                            error = "Could not confirm entitlement: ${error.message ?: "backend unavailable"}",
                        )
                    },
                )
            }
            return
        }

        _state.value = _state.value.copy(
            isLoading = true,
            message = "Verifying purchase with Tono…",
            error = null,
        )
        scope.launch {
            for (purchase in purchased) {
                val productId = purchase.products.firstOrNull { it in BillingProducts.all } ?: continue
                val verified = runCatching {
                    withContext(Dispatchers.IO) {
                        TonoBackend.syncGooglePlaySubscription(
                            packageName = PLAY_PACKAGE_NAME,
                            productId = productId,
                            purchaseToken = purchase.purchaseToken,
                        )
                    }
                }
                if (verified.isFailure) {
                    _state.value = _state.value.copy(
                        isLoading = false,
                        isPro = SharedStore.getBoolean(SharedKeys.PRO_UNLOCKED),
                        message = null,
                        error = "Purchase received, but secure verification failed. Tap Restore purchases to retry.",
                    )
                    return@launch
                }
                val me = verified.getOrThrow()
                if (!me.isPro) {
                    _state.value = _state.value.copy(
                        isLoading = false,
                        isPro = false,
                        message = null,
                        error = "Google Play purchase is not active. No Pro access was granted.",
                    )
                    return@launch
                }
                if (!purchase.isAcknowledged) acknowledge(purchase)
                _state.value = _state.value.copy(
                    isLoading = false,
                    isPro = EntitlementDecision.isPro(true, me.isPro),
                    message = if (restoring) "Pro entitlement restored." else "Tono Pro is active.",
                    error = null,
                )
            }
        }
    }

    private fun acknowledge(purchase: Purchase) {
        val params = AcknowledgePurchaseParams.newBuilder()
            .setPurchaseToken(purchase.purchaseToken)
            .build()
        billingClient.acknowledgePurchase(params) { result ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                showBillingError(result, "Purchase verified, but Google Play acknowledgement failed")
            }
        }
    }

    private fun toDisplayProduct(details: ProductDetails): PlayProduct? {
        val regularPhase = details.subscriptionOfferDetails
            ?.firstOrNull()
            ?.pricingPhases
            ?.pricingPhaseList
            ?.lastOrNull()
            ?: return null
        return PlayProduct(
            id = details.productId,
            label = if (details.productId == BillingProducts.MONTHLY) "Monthly" else "Yearly",
            formattedPrice = regularPhase.formattedPrice,
        )
    }

    private fun showBillingError(result: BillingResult, prefix: String) {
        val detail = result.debugMessage.takeIf { it.isNotBlank() }
        _state.value = _state.value.copy(
            isLoading = false,
            message = null,
            error = if (detail == null) prefix else "$prefix: $detail",
        )
    }
}
