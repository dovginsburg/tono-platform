package com.tono.app.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Kotlin port of packages/shared/src/api-client.ts + types.ts. Native
 * clients (this, and Shared/TonoBackend.swift on iOS) each re-implement the
 * same wire contract rather than sharing code across languages — see
 * ARCHITECTURE.md for why a single cross-platform HTTP client wasn't worth
 * it here. Keep the three in lockstep by hand.
 */
data class RewriteSuggestion(
    val axis: String,
    val text: String,
    val rationale: String?,
    val riskAfter: String?,
)

data class ToneAnalysis(
    val riskLevel: String,
    val perception: String,
    val subtext: String,
    val riskReason: String,
    val suggestions: List<RewriteSuggestion>,
    val flags: List<String>,
)

data class RegisterResult(
    val deviceId: String,
    val apiToken: String,
    val plan: String,
    val isPro: Boolean,
)

data class MeResult(
    val deviceId: String,
    val plan: String,
    val isPro: Boolean,
    val usedToday: Int,
    val dailyLimit: Int,
)

data class CheckoutResult(val url: String, val sessionId: String)

data class PortalResult(val url: String)

data class RedeemCouponResult(val message: String, val couponProExpiresAt: String)

class TonoApiException(val status: Int, message: String) : Exception(message)

class TonoApiClient(
    private val baseUrl: String,
    private val tokenProvider: (() -> String?)? = null,
) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()
    private val jsonMedia = "application/json".toMediaType()

    suspend fun analyzePublic(
        draft: String,
        mode: String = "coach",
        locale: String = "en",
    ): ToneAnalysis = withContext(Dispatchers.IO) {
        val body = JSONObject().apply {
            put("draft", draft)
            put("mode", mode)
            put("locale", locale)
        }
        val response = execute("/v1/analyze", "POST", body, auth = false)
        parseToneAnalysis(response)
    }

    suspend fun analyze(
        text: String,
        mode: String = "coach",
        locale: String = "en",
        axes: List<String>? = null,
    ): ToneAnalysis = withContext(Dispatchers.IO) {
        val body = JSONObject().apply {
            put("text", text)
            put("mode", mode)
            put("locale", locale)
            if (axes != null) put("axes", JSONArray(axes))
        }
        val response = execute("/api/analyze", "POST", body, auth = true)
        parseToneAnalysis(response)
    }

    suspend fun register(platform: String): RegisterResult = withContext(Dispatchers.IO) {
        val body = JSONObject().apply { put("platform", platform) }
        val json = execute("/v1/register", "POST", body, auth = false)
        RegisterResult(
            deviceId = json.optString("device_id"),
            apiToken = json.optString("api_token"),
            plan = json.optString("plan"),
            isPro = json.optBoolean("is_pro"),
        )
    }

    suspend fun me(): MeResult = withContext(Dispatchers.IO) {
        val json = execute("/v1/me", "GET", null, auth = true)
        MeResult(
            deviceId = json.optString("device_id"),
            plan = json.optString("plan"),
            isPro = json.optBoolean("is_pro"),
            usedToday = json.optInt("used_today"),
            dailyLimit = json.optInt("daily_limit"),
        )
    }

    /** Creates a Stripe Checkout Session for Pro. Caller opens the returned
     * `url` (Chrome Custom Tabs on Android) — an in-app OkHttp client can't
     * host Stripe's hosted payment page itself. 503s if Stripe isn't
     * configured server-side. */
    suspend fun checkout(interval: String = "month"): CheckoutResult = withContext(Dispatchers.IO) {
        val body = JSONObject().apply { put("interval", interval) }
        val json = execute("/v1/checkout", "POST", body, auth = true)
        CheckoutResult(url = json.optString("url"), sessionId = json.optString("session_id"))
    }

    /** Creates a Stripe Billing Portal session for a signed-in Pro user to
     * manage/cancel. 400s if there's no Stripe customer on file yet. */
    suspend fun portal(): PortalResult = withContext(Dispatchers.IO) {
        // OkHttp requires a non-null body for POST even when the endpoint
        // itself ignores it.
        val json = execute("/v1/portal", "POST", JSONObject(), auth = true)
        PortalResult(url = json.optString("url"))
    }

    suspend fun redeemCoupon(code: String): RedeemCouponResult = withContext(Dispatchers.IO) {
        val body = JSONObject().apply { put("code", code) }
        val json = execute("/v1/coupon/redeem", "POST", body, auth = true)
        RedeemCouponResult(
            message = json.optString("message"),
            couponProExpiresAt = json.optString("coupon_pro_expires_at"),
        )
    }

    private fun execute(path: String, method: String, jsonBody: JSONObject?, auth: Boolean): JSONObject {
        val requestBuilder = Request.Builder().url("$baseUrl$path")
        if (auth) {
            tokenProvider?.invoke()?.let { requestBuilder.addHeader("Authorization", "Bearer $it") }
        }
        val body = jsonBody?.toString()?.toRequestBody(jsonMedia)
        requestBuilder.method(method, body)

        http.newCall(requestBuilder.build()).execute().use { resp ->
            val raw = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) {
                val message = runCatching {
                    JSONObject(raw).getJSONObject("error").getString("message")
                }.getOrDefault("request failed with status ${resp.code}")
                throw TonoApiException(resp.code, message)
            }
            return JSONObject(raw)
        }
    }

    private fun parseToneAnalysis(json: JSONObject): ToneAnalysis {
        val suggestions = mutableListOf<RewriteSuggestion>()
        val arr = json.optJSONArray("suggestions") ?: JSONArray()
        for (i in 0 until arr.length()) {
            val s = arr.getJSONObject(i)
            suggestions.add(
                RewriteSuggestion(
                    axis = s.optString("axis"),
                    text = s.optString("text"),
                    rationale = s.optString("rationale", null),
                    riskAfter = s.optString("risk_after", null),
                )
            )
        }
        val flags = mutableListOf<String>()
        val flagsArr = json.optJSONArray("flags") ?: JSONArray()
        for (i in 0 until flagsArr.length()) flags.add(flagsArr.getString(i))

        return ToneAnalysis(
            riskLevel = json.optString("risk_level"),
            perception = json.optString("perception"),
            subtext = json.optString("subtext"),
            riskReason = json.optString("risk_reason"),
            suggestions = suggestions,
            flags = flags,
        )
    }
}
