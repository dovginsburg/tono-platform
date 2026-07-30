package com.tono.shared.network

import com.tono.shared.account.EmailAuthException
import com.tono.shared.account.EmailAuthOutcome
import com.tono.shared.account.CouponRedemptionException
import com.tono.shared.account.CouponRedemptionOutcome
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
    @SerialName("account_id")           val accountId: String,
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

@Serializable data class CouponRedemption(
    @SerialName("coupon_pro_expires_at") val couponProExpiresAt: String,
    val message: String,
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
        val existingToken = SecureStore.get(KeychainKeys.API_TOKEN)?.takeIf { it.isNotBlank() }
        val existingCredential = SecureStore.get(KeychainKeys.DEVICE_CREDENTIAL)?.takeIf { it.isNotBlank() }
        if (existingToken != null && existingCredential != null) {
            runCatching { return me() }
        }
        val deviceId = SecureStore.get(KeychainKeys.DEVICE_ID)?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString().also { SecureStore.set(KeychainKeys.DEVICE_ID, it) }

        @Serializable data class Req(
            val device_id: String,
            val device_credential: String? = null,
            val platform: String,
            val app_version: String,
        )
        @Serializable data class Resp(
            val device_id: String,
            val api_token: String,
            val device_credential: String? = null,
            val plan: String,
            val is_pro: Boolean,
        )
        val resp: Resp = post(
            "/v1/register",
            Req(deviceId, existingCredential, "android", appVersion),
            authorize = existingToken != null,
        )
        SecureStore.set(KeychainKeys.DEVICE_ID, resp.device_id)
        SecureStore.set(KeychainKeys.API_TOKEN, resp.api_token)
        resp.device_credential?.takeIf { it.isNotBlank() }?.let {
            SecureStore.set(KeychainKeys.DEVICE_CREDENTIAL, it)
        }
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

    /**
     * Redeems against the account proven by the current bearer, then re-reads
     * the canonical entitlement. The redemption response is informational:
     * only `/v1/me` is allowed to update the cached Pro mirror used by the IME.
     */
    suspend fun redeemCoupon(code: String): CouponRedemption {
        val token = SecureStore.get(KeychainKeys.API_TOKEN)?.takeIf { it.isNotBlank() }
            ?: throw CouponRedemptionException(CouponRedemptionOutcome.SIGN_IN_REQUIRED)
        return redeemCouponAuthorized(
            code = code,
            bearerToken = token,
            serverBaseUrl = baseUrl,
            cacheAccount = ::cacheAccountState,
        )
    }

    internal suspend fun redeemCouponAuthorized(
        code: String,
        bearerToken: String,
        serverBaseUrl: String,
        cacheAccount: (TonoMe) -> Unit,
        requestExecutor: suspend (Request) -> String = ::executeCouponBody,
    ): CouponRedemption {
        @Serializable data class Req(val code: String)
        val redemption: CouponRedemption = decodeCouponResponse(requestExecutor(
            Request.Builder()
                .url("${serverBaseUrl.trimEnd('/')}/v1/coupon/redeem")
                .post(json.encodeToString(Req(code)).toRequestBody("application/json".toMediaType()))
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer $bearerToken")
                .build(),
        ))
        val refreshed: TonoMe = decodeCouponResponse(requestExecutor(
            Request.Builder()
                .url("${serverBaseUrl.trimEnd('/')}/v1/me")
                .get()
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer $bearerToken")
                .build(),
        ))
        cacheAccount(refreshed)
        return redemption
    }

    fun logAxisWin(axis: String, riskLevel: String) {
        @Serializable data class Req(val axis: String, val risk_level: String)
        fireAndForget("/v1/event/axis", Req(axis, riskLevel))
    }

    private fun cacheAccountState(me: TonoMe) {
        SharedStore.putBoolean(SharedKeys.PRO_UNLOCKED, me.isPro)
        SharedStore.putString(SharedKeys.ACCOUNT_ID, me.accountId)
        SharedStore.putString(SharedKeys.REGISTERED_AT, System.currentTimeMillis().toString())
    }

    // ── Email account (Build 114) ──────────────────────────────────────────
    //
    // Android reaches the SAME `/v1/auth/email/*` lane as iOS, so a person who
    // signed up on one platform signs in on the other and lands on the ONE
    // canonical account — with its history, its registration audit and its
    // entitlement intact. Nothing here handles a password beyond forwarding it
    // once, and nothing here ever stores one: verification and reset stay
    // link-based and are owned by the auth provider, server-side.
    //
    // Failures leave this layer as `EmailAuthException(outcome)` — a shape, with
    // no message field — so no response text can reach a screen. The generic
    // `execute` path is deliberately NOT reused: it decodes the server's error
    // message into `ToneEngineError.Backend`, which is right for Coach (where
    // the mapper re-classifies it) and wrong here.

    /** The audit tag written onto registration events. Set by the app at launch. */
    private val appBuildTag: String
        get() = SharedStore.getString(SharedKeys.APP_BUILD)?.takeIf { it.isNotBlank() } ?: "unknown"

    /**
     * Begin an email registration. The provider mails the confirmation link;
     * nothing is signed in until it is opened and the person signs in.
     *
     * Sent AUTHORIZED whenever this device already holds a bearer, which is what
     * makes an anonymous device upgrade in place: the server binds the pending
     * registration to the account this device has been using all along, so the
     * person keeps their history instead of starting a second one.
     *
     * Returns [EmailAuthOutcome.CHECK_YOUR_EMAIL] for a brand-new address AND
     * for one already registered — the server refuses to be an account oracle,
     * and so does this method.
     */
    suspend fun registerWithEmail(email: String, password: String): EmailAuthOutcome {
        emailRequest<EmailCredentialRequest, EmailAcceptedResponse>(
            path = "/v1/auth/email/register",
            body = EmailCredentialRequest(
                email = email,
                password = password,
                source_surface = SOURCE_SURFACE,
                app_version = appBuildTag,
            ),
            authorize = SecureStore.isRegistered(),
        )
        return EmailAuthOutcome.CHECK_YOUR_EMAIL
    }

    /**
     * Sign in. On success the server has already converged this device onto the
     * canonical person, so the returned `is_pro` is that account's real
     * entitlement — a subscriber who reinstalled is Pro again on this call, with
     * no restore tap and no second purchase.
     *
     * [KeychainKeys.SIGNED_IN_EMAIL] is written HERE and only here, and only
     * when the server says the address is confirmed. Writing it any earlier
     * would let an unconfirmed device bind a purchase to an account it cannot
     * recover.
     */
    suspend fun signInWithEmail(email: String, password: String): TonoMe {
        val session = emailRequest<EmailCredentialRequest, EmailSessionResponse>(
            path = "/v1/auth/email/login",
            body = EmailCredentialRequest(
                email = email,
                password = password,
                source_surface = SOURCE_SURFACE,
                app_version = appBuildTag,
            ),
            authorize = SecureStore.isRegistered(),
        )
        session.deviceId.takeIf { it.isNotBlank() }
            ?.let { SecureStore.set(KeychainKeys.DEVICE_ID, it) }
        session.apiToken.takeIf { it.isNotBlank() }
            ?.let { SecureStore.set(KeychainKeys.API_TOKEN, it) }
        session.deviceCredential?.takeIf { it.isNotBlank() }
            ?.let { SecureStore.set(KeychainKeys.DEVICE_CREDENTIAL, it) }
        SharedStore.putString(SharedKeys.ACCOUNT_ID, session.accountId)
        if (session.emailVerified) {
            session.email?.takeIf { it.isNotBlank() }
                ?.let { SecureStore.set(KeychainKeys.SIGNED_IN_EMAIL, it) }
        }
        // Re-read the canonical shape so the Pro mirror the IME reads is
        // refreshed from the server rather than from this response alone.
        return me()
    }

    /** Resend the confirmation link. Anti-enumerating, exactly like register. */
    suspend fun resendVerification(email: String): EmailAuthOutcome {
        emailRequest<EmailAddressRequest, EmailAcceptedResponse>(
            path = "/v1/auth/email/resend",
            body = EmailAddressRequest(email, SOURCE_SURFACE, appBuildTag),
            authorize = false,
        )
        return EmailAuthOutcome.CHECK_YOUR_EMAIL
    }

    /** Begin password recovery. Anti-enumerating, exactly like register. */
    suspend fun requestPasswordReset(email: String): EmailAuthOutcome {
        emailRequest<EmailAddressRequest, EmailAcceptedResponse>(
            path = "/v1/auth/email/reset",
            body = EmailAddressRequest(email, SOURCE_SURFACE, appBuildTag),
            authorize = false,
        )
        return EmailAuthOutcome.CHECK_YOUR_EMAIL
    }

    /**
     * Sign this device out.
     *
     * Local state is cleared whether or not the call succeeds: a person on a bad
     * connection must still be able to sign out of a shared device. The account
     * and its entitlement are untouched server-side, so signing back in returns
     * the same person to the same account.
     */
    suspend fun signOutEmail() {
        runCatching {
            emailRequest<Map<String, String>, EmailLogoutResponse>(
                path = "/v1/auth/email/logout",
                body = emptyMap(),
                authorize = true,
            )
        }
        SecureStore.clearSession()
        // The IME reads only this mirror. Clearing it is what stops the keyboard
        // presenting Pro for a device that no longer holds a credential to prove
        // it; the entitlement itself still belongs to the account.
        SharedStore.putBoolean(SharedKeys.PRO_UNLOCKED, false)
        SharedStore.putString(SharedKeys.ACCOUNT_ID, null)
    }

    private const val SOURCE_SURFACE = "android"

    @Serializable private data class EmailCredentialRequest(
        val email: String,
        val password: String,
        val source_surface: String,
        val app_version: String,
    )

    @Serializable private data class EmailAddressRequest(
        val email: String,
        val source_surface: String,
        val app_version: String,
    )

    @Serializable private data class EmailAcceptedResponse(val status: String = "")

    @Serializable private data class EmailLogoutResponse(
        @SerialName("signed_out") val signedOut: Boolean = false,
    )

    @Serializable private data class EmailSessionResponse(
        @SerialName("device_id") val deviceId: String,
        @SerialName("api_token") val apiToken: String,
        @SerialName("device_credential") val deviceCredential: String? = null,
        @SerialName("account_id") val accountId: String,
        val plan: String = "free",
        @SerialName("is_pro") val isPro: Boolean = false,
        val email: String? = null,
        @SerialName("email_verified") val emailVerified: Boolean = false,
    )

    /**
     * One request on the account lane, classified by SHAPE.
     *
     * Every non-2xx becomes an [EmailAuthException] whose only payload is an
     * [EmailAuthOutcome]; the response body is read for decoding a success and
     * is otherwise discarded unread. There is therefore no path from a response
     * to a sentence a person reads.
     */
    private suspend inline fun <reified In, reified Out> emailRequest(
        path: String, body: In, authorize: Boolean,
    ): Out {
        // A missing bearer on an authorized call is not a credential failure —
        // this device simply has not registered yet, which is an operational
        // state, not something to accuse the person's password of.
        val request = buildRequest(path, "POST", json.encodeToString(body), authorize)
            ?: throw EmailAuthException(EmailAuthOutcome.SERVICE_UNAVAILABLE)
        return suspendCancellableCoroutine { cont ->
            val call = client.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    cont.resumeWithException(EmailAuthException(outcomeForTransport(e)))
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use { resp ->
                        val outcome = outcomeForStatus(resp.code)
                        if (outcome != null) {
                            cont.resumeWithException(EmailAuthException(outcome))
                            return
                        }
                        val decoded = runCatching {
                            json.decodeFromString<Out>(resp.body?.string() ?: "")
                        }
                        decoded.fold(
                            onSuccess = { cont.resume(it) },
                            // An unreadable success is not a signed-in person.
                            // Fail closed rather than proceed on a guess.
                            onFailure = {
                                cont.resumeWithException(
                                    EmailAuthException(EmailAuthOutcome.SERVICE_UNAVAILABLE)
                                )
                            },
                        )
                    }
                }
            })
        }
    }

    /**
     * Status class → outcome. Null means success.
     *
     * Mirrors `server._email_auth_failure` exactly, and keeps 401, 403 and 429
     * apart: a rate limit is not a bad password and neither is a paywall.
     */
    fun outcomeForStatus(code: Int): EmailAuthOutcome? = when {
        code in 200..299 -> null
        code == 400 || code == 422 -> EmailAuthOutcome.INVALID_INPUT
        code == 401 -> EmailAuthOutcome.INVALID_CREDENTIALS
        code == 403 -> EmailAuthOutcome.VERIFICATION_REQUIRED
        code == 429 -> EmailAuthOutcome.RATE_LIMITED
        code >= 500 -> EmailAuthOutcome.SERVICE_UNAVAILABLE
        else -> EmailAuthOutcome.UNKNOWN_FAILURE
    }

    /**
     * Transport failure → outcome, by exception TYPE rather than by message.
     *
     * The message is where a host name rides along, so it is never consulted.
     * Only failures that genuinely mean "no usable connection" become
     * [EmailAuthOutcome.OFFLINE] — telling someone to check a working
     * connection is its own kind of wrong answer.
     */
    fun outcomeForTransport(error: Throwable): EmailAuthOutcome = when (error) {
        is java.net.UnknownHostException,
        is java.net.ConnectException,
        is java.net.NoRouteToHostException,
        is java.net.SocketTimeoutException,
        is java.net.PortUnreachableException,
        is javax.net.ssl.SSLException,
        -> EmailAuthOutcome.OFFLINE
        else -> EmailAuthOutcome.UNKNOWN_FAILURE
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
                            // 402 = the server-authoritative entitlement gate
                            // (there is no free tier): an active trial or paid
                            // subscription is required. Distinct from the 429
                            // per-IP rate limit below.
                            resp.code == 402 -> cont.resumeWithException(
                                ToneEngineError.Backend("An active trial or subscription is required. Open Tono to continue.")
                            )
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

    private inline fun <reified Out> decodeCouponResponse(body: String): Out =
        runCatching { json.decodeFromString<Out>(body) }.getOrElse {
            throw CouponRedemptionException(CouponRedemptionOutcome.SERVICE_UNAVAILABLE)
        }

    private suspend fun executeCouponBody(request: Request): String =
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(request)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    cont.resumeWithException(
                        CouponRedemptionException(
                            when (e) {
                                is java.net.UnknownHostException,
                                is java.net.ConnectException,
                                is java.net.NoRouteToHostException,
                                is java.net.SocketTimeoutException,
                                is javax.net.ssl.SSLException,
                                -> CouponRedemptionOutcome.OFFLINE
                                else -> CouponRedemptionOutcome.SERVICE_UNAVAILABLE
                            }
                        )
                    )
                }

                override fun onResponse(call: Call, response: Response) {
                    response.use { resp ->
                        couponOutcomeForStatus(resp.code)?.let { outcome ->
                            cont.resumeWithException(CouponRedemptionException(outcome))
                            return
                        }
                        cont.resume(resp.body?.string() ?: "")
                    }
                }
            })
        }

    internal fun couponOutcomeForStatus(code: Int): CouponRedemptionOutcome? = when {
        code in 200..299 -> null
        code == 401 || code == 403 -> CouponRedemptionOutcome.SIGN_IN_REQUIRED
        code == 409 -> CouponRedemptionOutcome.ALREADY_USED
        code == 410 -> CouponRedemptionOutcome.EXPIRED
        code == 400 || code == 404 || code == 422 -> CouponRedemptionOutcome.REJECTED
        code == 429 -> CouponRedemptionOutcome.RATE_LIMITED
        else -> CouponRedemptionOutcome.SERVICE_UNAVAILABLE
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
