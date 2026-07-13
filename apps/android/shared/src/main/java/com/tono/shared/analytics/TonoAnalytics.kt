package com.tono.shared.analytics

import com.tono.shared.flags.FeatureFlag
import com.tono.shared.flags.FeatureFlags
import com.tono.shared.network.TonoBackend
import com.tono.shared.storage.KeychainKeys
import com.tono.shared.storage.SecureStore
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

// Mirrors ios/Shared/TonoAnalytics.swift
//
// A4 PRIVACY CONTRACT (enforced here, not downstream):
//   ✓  Event names, axis enums, risk-level enums, latency_ms, mode strings
//   ✓  Anonymized device ID only
//   ✗  NO message text — never include draft or rewrite text
//   ✗  NO recipient names — only axis labels and boolean flags
//   ✗  NO free-text user input of any kind

sealed class AnalyticsEvent {
    data class CoachRequested(val mode: String) : AnalyticsEvent()
    data class AnalysisShown(val riskLevel: String, val latencyMs: Int, val source: String) : AnalyticsEvent()
    data class RewriteInserted(val selectedAxis: String, val shownAxes: List<String>) : AnalyticsEvent()
    object RewriteEditedAfterInsert : AnalyticsEvent()
    data class AxisRejected(val shownAxes: List<String>, val pickedAxis: String) : AnalyticsEvent()
    // Collective improvement: content-free session outcome.
    // Respects IMPROVE_TONO flag — never sent when user has opted out.
    // NO message text, NO rewrite text, NO recipient identifier.
    data class ImprovementOutcome(
        val riskLevel: String,
        val axisSelected: String?,
        val mode: String,
        val msgLenBucket: String,
        val rewriteUsed: Boolean,
        val editAfter: Boolean,
    ) : AnalyticsEvent()

    val name: String get() = when (this) {
        is CoachRequested           -> "coach_requested"
        is AnalysisShown            -> "analysis_shown"
        is RewriteInserted          -> "rewrite_inserted"
        is RewriteEditedAfterInsert -> "rewrite_edited_after_insert"
        is AxisRejected             -> "axis_rejected"
        is ImprovementOutcome       -> "improvement_outcome"
    }

    // A4: only permitted properties — no user content
    val properties: Map<String, Any> get() = when (this) {
        is CoachRequested           -> mapOf("mode" to mode)
        is AnalysisShown            -> mapOf("risk_level" to riskLevel, "latency_ms" to latencyMs, "source" to source)
        is RewriteInserted          -> mapOf("selected_axis" to selectedAxis, "shown_axes" to shownAxes)
        is RewriteEditedAfterInsert -> emptyMap()
        is AxisRejected             -> mapOf("shown_axes" to shownAxes, "picked_axis" to pickedAxis)
        is ImprovementOutcome       -> buildMap {
            put("risk_level", riskLevel)
            put("mode", mode)
            put("msg_len_bucket", msgLenBucket)
            put("rewrite_used", rewriteUsed)
            put("edit_after", editAfter)
            axisSelected?.let { put("selected_axis", it) }
        }
    }
}

object TonoAnalytics {
    private val client = OkHttpClient()
    private val json = Json { ignoreUnknownKeys = true }

    fun track(event: AnalyticsEvent) {
        // Collective improvement events respect the opt-out flag.
        if (event is AnalyticsEvent.ImprovementOutcome &&
            !FeatureFlags.isEnabled(FeatureFlag.IMPROVE_TONO)) return

        val deviceId = SecureStore.get(KeychainKeys.DEVICE_ID)?.takeIf { it.isNotBlank() } ?: return
        val token = SecureStore.get(KeychainKeys.API_TOKEN) ?: ""

        val body: MutableMap<String, Any> = mutableMapOf(
            "event" to event.name,
            "device_id" to deviceId,
            "ts" to (System.currentTimeMillis() / 1000).toInt(),
        )
        body.putAll(event.properties)

        val bodyJson = json.encodeToString(
            kotlinx.serialization.json.buildJsonObject {
                body.forEach { (k, v) ->
                    when (v) {
                        is String -> put(k, kotlinx.serialization.json.JsonPrimitive(v))
                        is Int    -> put(k, kotlinx.serialization.json.JsonPrimitive(v))
                        is Boolean -> put(k, kotlinx.serialization.json.JsonPrimitive(v))
                        is List<*> -> put(k, kotlinx.serialization.json.buildJsonArray {
                            v.forEach { item -> if (item is String) add(kotlinx.serialization.json.JsonPrimitive(item)) }
                        })
                        else -> {}
                    }
                }
            }
        )

        val request = Request.Builder()
            .url("${TonoBackend.baseUrl}/v1/events")
            .post(bodyJson.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .apply { if (token.isNotBlank()) header("Authorization", "Bearer $token") }
            .build()

        client.newCall(request).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) = Unit
            override fun onResponse(call: Call, response: Response) { response.close() }
        })
    }
}
