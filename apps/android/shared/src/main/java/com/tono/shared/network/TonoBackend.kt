package com.tono.shared.network

import com.tono.shared.models.AnalysisMode
import com.tono.shared.models.RewriteAxis
import com.tono.shared.models.ToneAnalysis
import com.tono.shared.models.ToneEngineError
import com.tono.shared.models.WireToneAnalysis
import com.tono.shared.models.toAnalysis
import com.tono.shared.storage.KeychainKeys
import com.tono.shared.storage.SecureStore
import com.tono.shared.storage.SharedKeys
import com.tono.shared.storage.SharedStore
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// Mirrors ios/Shared/TonoBackend.swift

@Serializable data class TonoMe(
    @SerialName("device_id")            val deviceId: String,
    val plan: String,
    @SerialName("is_pro")               val isPro: Boolean,
    @SerialName("used_today")           val usedToday: Int,
    @SerialName("daily_limit")          val dailyLimit: Int,
    @SerialName("subscription_status")  val subscriptionStatus: String? = null,
    @SerialName("subscription_renews_at") val subscriptionRenewsAt: String? = null,
)

@Serializable data class TonoSuggestionWire(
    val axis: String,
    val text: String,
    val rationale: String? = null,
    @SerialName("risk_after") val riskAfter: String? = null,
)

@Serializable data class TonoAnalysisResponse(
    @SerialName("risk_level")  val riskLevel: String,
    val perception: String,
    val subtext: String,
    @SerialName("risk_reason") val reason: String? = null,
    val suggestions: List<TonoSuggestionWire>,
    val flags: List<String>,
    @SerialName("used_today")  val usedToday: Int,
    @SerialName("daily_limit") val dailyLimit: Int,
    val plan: String,
)

@Serializable data class WeeklyDigestResponse(
    val rewrites: Int,
    @SerialName("days_active")       val daysActive: Int,
    @SerialName("top_axis")          val topAxis: String? = null,
    @SerialName("axis_breakdown")    val axisBreakdown: Map<String, Int>,
    @SerialName("prev_axis_breakdown") val prevAxisBreakdown: Map<String, Int>,
)

object TonoBackend {

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    val baseUrl: String get() {
        SharedStore.getString(SharedKeys.BACKEND_URL)?.takeIf { it.isNotBlank() }?.let { return it }
        // Live production backend.
        return "https://api.tonoit.com"
    }

    // MARK: - Public API

    suspend fun registerIfNeeded(appVersion: String): TonoMe {
        if (SecureStore.isRegistered()) {
            runCatching { return me() }
        }
        val deviceId = SecureStore.get(KeychainKeys.DEVICE_ID)?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString().also { SecureStore.set(KeychainKeys.DEVICE_ID, it) }

        @Serializable data class Req(
            val device_id: String,
            val platform: String,
            val app_version: String,
        )
        @Serializable data class Resp(
            val device_id: String,
            val api_token: String,
            val plan: String,
            val is_pro: Boolean,
        )
        val resp: Resp = post("/v1/register", Req(deviceId, "android", appVersion), authorize = false)
        SecureStore.set(KeychainKeys.DEVICE_ID, resp.device_id)
        SecureStore.set(KeychainKeys.API_TOKEN, resp.api_token)
        return me()
    }

    suspend fun me(): TonoMe = get<TonoMe>("/v1/me").also(::cacheAccountState)

    /**
     * Sends the opaque Play token to the backend for Google-side verification.
     * The Android client never grants itself Pro from local Purchase state.
     */
    suspend fun syncGooglePlaySubscription(
        packageName: String,
        productId: String,
        purchaseToken: String,
    ): TonoMe {
        @Serializable data class Req(
            @SerialName("package_name") val packageName: String,
            @SerialName("product_id") val productId: String,
            @SerialName("purchase_token") val purchaseToken: String,
        )
        return post<Req, TonoMe>(
            "/v1/google-play/subscription",
            Req(packageName, productId, purchaseToken),
            authorize = true,
        ).also(::cacheAccountState)
    }

    suspend fun analyze(
        text: String,
        preferredVoice: String? = null,
        axes: List<RewriteAxis>? = null,
        recipientHint: String? = null,
        contextHints: List<String>? = null,
        threadContext: String? = null,
        mode: AnalysisMode = AnalysisMode.COACH,
    ): ToneAnalysis {
        @Serializable data class Req(
            val text: String,
            val provider: String? = null,
            val preferred_voice: String? = null,
            val axes: List<String>? = null,
            val recipient_hint: String? = null,
            val context_hints: List<String>? = null,
            val thread_context: String? = null,
            val mode: String,
        )
        val resp: TonoAnalysisResponse = post(
            "/api/analyze",
            Req(
                text = text,
                preferred_voice = preferredVoice,
                axes = axes?.map { it.value },
                recipient_hint = recipientHint,
                context_hints = contextHints?.takeIf { it.isNotEmpty() },
                thread_context = threadContext,
                mode = mode.value,
            ),
            authorize = true,
        )
        return toToneAnalysis(resp)
    }

    suspend fun fetchFeatures(): Map<String, Boolean> = get("/v1/features")

    suspend fun setFeaturePreference(flag: String, enabled: Boolean) {
        @Serializable data class Req(val enabled: Boolean)
        @Serializable data class Resp(val ok: Boolean, val key: String, val enabled: Boolean)
        put<Req, Resp>("/v1/features/$flag", Req(enabled), authorize = true)
    }

    suspend fun weeklyDigest(): WeeklyDigestResponse = get("/v1/digest")

    fun logAxisWin(axis: String, riskLevel: String) {
        @Serializable data class Req(val axis: String, val risk_level: String)
        fireAndForget("/v1/event/axis", Req(axis, riskLevel))
    }

    private fun cacheAccountState(me: TonoMe) {
        SharedStore.putBoolean(SharedKeys.PRO_UNLOCKED, me.isPro)
        SharedStore.putString(SharedKeys.REGISTERED_AT, System.currentTimeMillis().toString())
    }

    // MARK: - HTTP plumbing

    private inline fun <reified In> fireAndForget(path: String, body: In) {
        val request = buildRequest(path, "POST", json.encodeToString(body), authorize = true)
            ?: return
        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = Unit
            override fun onResponse(call: Call, response: Response) { response.close() }
        })
    }

    private suspend inline fun <reified Out> get(path: String): Out {
        val request = buildRequest(path, "GET", null, authorize = true)
            ?: throw ToneEngineError.Backend("not registered")
        return execute(request)
    }

    private suspend inline fun <reified In, reified Out> post(
        path: String, body: In, authorize: Boolean,
    ): Out {
        val request = buildRequest(path, "POST", json.encodeToString(body), authorize)
            ?: throw ToneEngineError.Backend("not registered")
        return execute(request)
    }

    private suspend inline fun <reified In, reified Out> put(
        path: String, body: In, authorize: Boolean,
    ): Out {
        val request = buildRequest(path, "PUT", json.encodeToString(body), authorize)
            ?: throw ToneEngineError.Backend("not registered")
        return execute(request)
    }

    private fun buildRequest(path: String, method: String, jsonBody: String?, authorize: Boolean): Request? {
        if (authorize && !SecureStore.isRegistered()) return null
        val body = jsonBody?.toRequestBody("application/json".toMediaType())
        return Request.Builder()
            .url("$baseUrl$path")
            .method(method, body)
            .apply {
                header("Content-Type", "application/json")
                if (authorize) {
                    val token = SecureStore.get(KeychainKeys.API_TOKEN) ?: return null
                    header("Authorization", "Bearer $token")
                }
            }
            .build()
    }

    private suspend inline fun <reified Out> execute(request: Request): Out =
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    val err = if (e.message?.contains("network") == true || e.message?.contains("connect") == true)
                        ToneEngineError.Offline else ToneEngineError.Network(e.message ?: "unknown")
                    cont.resumeWithException(err)
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use { resp ->
                        val bodyStr = resp.body?.string() ?: ""
                        when {
                            resp.code == 429 -> {
                                val used = runCatching {
                                    json.decodeFromString<ErrorBody>(bodyStr).error.usedToday ?: 0
                                }.getOrDefault(0)
                                cont.resumeWithException(ToneEngineError.RateLimit(used, 5))
                            }
                            resp.code == 401 -> cont.resumeWithException(
                                ToneEngineError.Backend("Sign-in expired. Open Tono to refresh.")
                            )
                            !resp.isSuccessful -> {
                                val msg = runCatching {
                                    json.decodeFromString<ErrorBody>(bodyStr).error.message
                                }.getOrDefault("Server error (${resp.code})")
                                cont.resumeWithException(ToneEngineError.Backend(msg))
                            }
                            else -> {
                                val result = runCatching { json.decodeFromString<Out>(bodyStr) }
                                result.fold(
                                    onSuccess = { cont.resume(it) },
                                    onFailure = { cont.resumeWithException(ToneEngineError.Decoding(it.message ?: "")) }
                                )
                            }
                        }
                    }
                }
            })
        }

    @Serializable private data class ErrorBody(val error: ErrorInner)
    @Serializable private data class ErrorInner(
        val message: String = "",
        @SerialName("used_today")  val usedToday: Int? = null,
        @SerialName("daily_limit") val dailyLimit: Int? = null,
    )

    private fun toToneAnalysis(r: TonoAnalysisResponse): ToneAnalysis {
        val wire = WireToneAnalysis(
            riskLevel   = r.riskLevel,
            perception  = r.perception,
            subtext     = r.subtext,
            riskReason  = r.reason,
            suggestions = r.suggestions.map {
                com.tono.shared.models.WireSuggestion(it.axis, it.text, it.rationale, it.riskAfter)
            },
            flags = r.flags,
        )
        return wire.toAnalysis()
    }
}
