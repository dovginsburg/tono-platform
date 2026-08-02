package com.tono.ime.intelligence

import android.content.Context
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.rewriting.Rewriter
import com.google.mlkit.genai.rewriting.RewriterOptions
import com.google.mlkit.genai.rewriting.Rewriting
import com.google.mlkit.genai.rewriting.RewritingRequest
import com.tono.shared.intelligence.GeminiNanoAvailability
import com.tono.shared.intelligence.GeminiRewriteUnavailableReason
import com.tono.shared.intelligence.OnDeviceRewriteEngine
import com.tono.shared.intelligence.OnDeviceRewriteGuard
import com.tono.shared.intelligence.OnDeviceRewriteOutcome
import com.tono.shared.models.RewriteAxis
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

// The ML Kit GenAI (Gemini Nano) on-device rewrite boundary — the ONLY file in
// the codebase that links ML Kit. Android mirror of iOS `AppleRewriteBridge` /
// `OnDeviceAppleRewrite`, which are the only files there that link
// FoundationModels.
//
// Everything ML-Kit-specific is quarantined here so the routing/availability
// seams in :shared stay pure Kotlin and JVM-unit-testable. This class is
// compile-verified but NOT device-verified: producing a real rewrite requires a
// device with AICore + Gemini Nano, which CI does not have. Nothing here sends
// text off the device — Gemini Nano runs locally via AICore — and it never
// prefetches: `availability()` is a status check, and `rewrite()` runs only
// when an explicit caller invokes it.
//
// PRIVACY / SAFETY:
//   • On-device only: ML Kit GenAI Rewriting runs on Gemini Nano via AICore.
//     No draft text leaves the device on this path.
//   • Low-risk axis only: the router restricts this engine to the Funnier spike.
//     ML Kit Rewriting exposes a FIXED set of output types (ELABORATE, EMOJIFY,
//     SHORTEN, FRIENDLY, PROFESSIONAL, REPHRASE) — none is literally "funnier",
//     so Funnier maps to the lowest-risk playful type (FRIENDLY). This is
//     explicitly NOT claimed to be equivalent to Tono's reviewed backend
//     "Funnier" axis; it is a lighter on-device alternate the user opts into.
//   • Fail-closed: any decline (unavailable, timeout, cancellation, guardrail,
//     empty/no-op result) becomes a named [GeminiRewriteUnavailableReason].
class GeminiNanoRewriter(
    private val appContext: Context,
) : OnDeviceRewriteEngine {

    // A single Rewriter built for the spike output type (FRIENDLY, the on-device
    // stand-in for Funnier). Created lazily so merely constructing this class
    // touches no native resources, and closed in [close].
    @Volatile private var client: Rewriter? = null

    private fun rewriter(): Rewriter {
        client?.let { return it }
        val options = RewriterOptions.builder(appContext)
            .setOutputType(RewriterOptions.OutputType.FRIENDLY)
            .setLanguage(RewriterOptions.Language.ENGLISH)
            .build()
        return Rewriting.getClient(options).also { client = it }
    }

    override suspend fun availability(): GeminiNanoAvailability =
        runCatching { mapFeatureStatus(rewriter().checkFeatureStatus().awaitCancellable()) }
            .getOrElse { if (it is CancellationException) throw it else GeminiNanoAvailability.UNSPECIFIED_UNAVAILABLE }

    override suspend fun download(): GeminiNanoAvailability {
        val done = CompletableDeferred<Unit>()
        runCatching {
            rewriter().downloadFeature(object : DownloadCallback {
                override fun onDownloadStarted(bytesToDownload: Long) {}
                override fun onDownloadProgress(totalBytesDownloaded: Long) {}
                override fun onDownloadCompleted() { done.complete(Unit) }
                override fun onDownloadFailed(e: GenAiException) { done.complete(Unit) }
            })
        }.onFailure { if (it is CancellationException) throw it else done.complete(Unit) }
        done.await()
        return availability()
    }

    override suspend fun rewrite(
        text: String,
        axis: RewriteAxis,
        timeoutMs: Long,
    ): OnDeviceRewriteOutcome {
        val source = text.trim()
        if (source.isEmpty()) {
            return OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.EMPTY_DRAFT)
        }
        // Re-check availability immediately before generating: a status check,
        // not a prefetch, and it keeps the terminal state honest if the model
        // was uninstalled between the router decision and this call.
        val status = availability()
        if (!status.isAvailable) {
            return OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.fromAvailability(status))
        }
        return try {
            withTimeoutOrNull(timeoutMs) {
                val request = RewritingRequest.builder(source).build()
                val result = rewriter().runInference(request).awaitCancellable()
                val first = result.results.firstOrNull()?.text
                // The guard is the single authority for "distinct, non-empty":
                // the source draft is NEVER returned as a success.
                OnDeviceRewriteGuard.resolve(first, source)
            } ?: OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.TIMED_OUT)
        } catch (c: CancellationException) {
            throw c
        } catch (e: GenAiException) {
            OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.GENERATION_FAILED)
        } catch (e: Throwable) {
            OnDeviceRewriteOutcome.Failure(GeminiRewriteUnavailableReason.GENERATION_FAILED)
        }
    }

    override fun close() {
        runCatching { client?.close() }
        client = null
    }

    // ── ML Kit symbol mapping (authoritative: uses the real FeatureStatus
    //    constants, not the illustrative ints in the pure :shared module) ──────
    private fun mapFeatureStatus(code: Int): GeminiNanoAvailability = when (code) {
        FeatureStatus.AVAILABLE    -> GeminiNanoAvailability.AVAILABLE
        FeatureStatus.DOWNLOADABLE -> GeminiNanoAvailability.DOWNLOADABLE
        FeatureStatus.DOWNLOADING  -> GeminiNanoAvailability.DOWNLOADING
        FeatureStatus.UNAVAILABLE  -> GeminiNanoAvailability.DEVICE_NOT_ELIGIBLE
        else                       -> GeminiNanoAvailability.UNSPECIFIED_UNAVAILABLE
    }

    private val directExecutor = Executor { it.run() }

    /** Await a ListenableFuture, cancelling it if the coroutine is cancelled. */
    private suspend fun <T> ListenableFuture<T>.awaitCancellable(): T =
        suspendCancellableCoroutine { cont: CancellableContinuation<T> ->
            addListener({
                try {
                    cont.resume(get())
                } catch (e: ExecutionException) {
                    cont.resumeWithException(e.cause ?: e)
                } catch (e: Throwable) {
                    cont.resumeWithException(e)
                }
            }, directExecutor)
            cont.invokeOnCancellation { cancel(/* mayInterruptIfRunning = */ true) }
        }

    companion object {
        /**
         * Guards the illustrative `FEATURE_STATUS_*` ints in the pure :shared
         * module against the real ML Kit constants. Called from an instrumented
         * test (the only place ML Kit symbols resolve). If ML Kit ever changes
         * these values, the pure `GeminiNanoAvailability.fromFeatureStatus`
         * convenience would drift — this catches it. Production mapping does not
         * depend on it: [mapFeatureStatus] uses the real symbols directly.
         */
        fun featureStatusConstantsMatchMlKit(): Boolean =
            GeminiNanoAvailability.FEATURE_STATUS_AVAILABLE == FeatureStatus.AVAILABLE &&
            GeminiNanoAvailability.FEATURE_STATUS_DOWNLOADABLE == FeatureStatus.DOWNLOADABLE &&
            GeminiNanoAvailability.FEATURE_STATUS_DOWNLOADING == FeatureStatus.DOWNLOADING &&
            GeminiNanoAvailability.FEATURE_STATUS_UNAVAILABLE == FeatureStatus.UNAVAILABLE
    }
}
