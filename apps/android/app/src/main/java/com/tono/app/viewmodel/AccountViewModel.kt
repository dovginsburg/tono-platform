package com.tono.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.tono.app.BuildConfig
import com.tono.app.net.DeviceTokenStore
import com.tono.app.net.TonoApiClient
import com.tono.app.net.TonoApiException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

data class AccountUiState(
    val plan: String = "—",
    val isPro: Boolean = false,
    val billingStatus: String? = null,
    val couponStatus: String? = null,
)

/**
 * Backs the account/billing section of the Coach screen: registers a
 * device token on first use (mirroring background.js's ensureDeviceToken
 * on the browser extension), then drives /v1/me, /v1/checkout,
 * /v1/portal and /v1/coupon/redeem. Stripe Checkout/Portal are Stripe-
 * hosted pages, so this only ever hands their URL off to the UI layer —
 * see openUrl, consumed via Chrome Custom Tabs in MainActivity.
 */
class AccountViewModel(application: Application) : AndroidViewModel(application) {
    private val tokenStore = DeviceTokenStore(application)
    private val api = TonoApiClient(baseUrl = BuildConfig.TONO_API_URL, tokenProvider = { tokenStore.apiToken })

    private val _state = MutableStateFlow(AccountUiState())
    val state: StateFlow<AccountUiState> = _state

    private val _openUrl = Channel<String>(Channel.BUFFERED)
    val openUrl: Flow<String> = _openUrl.receiveAsFlow()

    init {
        viewModelScope.launch {
            runCatching {
                ensureDeviceToken()
                refreshStatusInternal()
            }
            // Backend not reachable yet (e.g. not started in dev) — fine,
            // refreshStatus()/upgrade()/redeemCoupon() retry lazily.
        }
    }

    private suspend fun ensureDeviceToken(): String {
        tokenStore.apiToken?.let { return it }
        val reg = api.register(platform = "android")
        tokenStore.apiToken = reg.apiToken
        return reg.apiToken
    }

    private suspend fun refreshStatusInternal() {
        val me = api.me()
        _state.value = _state.value.copy(plan = me.plan, isPro = me.isPro)
    }

    fun refreshStatus() {
        viewModelScope.launch {
            try {
                ensureDeviceToken()
                refreshStatusInternal()
            } catch (e: Exception) {
                // Leave the last known plan/isPro alone on a transient
                // failure — resetting just the plan label here would
                // desync it from the isPro-driven upgrade/manage button,
                // which would still reflect the old (correct) status.
            }
        }
    }

    fun upgrade() {
        viewModelScope.launch {
            _state.value = _state.value.copy(billingStatus = "opening checkout…")
            try {
                ensureDeviceToken()
                val result = api.checkout()
                _openUrl.send(result.url)
                _state.value = _state.value.copy(billingStatus = null)
            } catch (e: TonoApiException) {
                _state.value = _state.value.copy(billingStatus = e.message)
            } catch (e: Exception) {
                _state.value = _state.value.copy(billingStatus = "Something went wrong. Please try again.")
            }
        }
    }

    fun manageSubscription() {
        viewModelScope.launch {
            _state.value = _state.value.copy(billingStatus = "opening billing portal…")
            try {
                ensureDeviceToken()
                val result = api.portal()
                _openUrl.send(result.url)
                _state.value = _state.value.copy(billingStatus = null)
            } catch (e: TonoApiException) {
                _state.value = _state.value.copy(billingStatus = e.message)
            } catch (e: Exception) {
                _state.value = _state.value.copy(billingStatus = "Something went wrong. Please try again.")
            }
        }
    }

    fun redeemCoupon(code: String) {
        if (code.isBlank()) return
        viewModelScope.launch {
            _state.value = _state.value.copy(couponStatus = "redeeming…")
            try {
                ensureDeviceToken()
                val result = api.redeemCoupon(code)
                _state.value = _state.value.copy(couponStatus = result.message)
                // refreshStatus(), not refreshStatusInternal() — it catches
                // its own errors, so a flaky follow-up /v1/me call can't
                // fall through to this function's catch block and stomp
                // the success message we just set above.
                refreshStatus()
            } catch (e: TonoApiException) {
                _state.value = _state.value.copy(couponStatus = e.message)
            } catch (e: Exception) {
                _state.value = _state.value.copy(couponStatus = "Something went wrong. Please try again.")
            }
        }
    }
}
