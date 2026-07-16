package com.tono.shared.models

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

// Mirrors ios/Shared/ToneEngine.swift

enum class RewriteAxis(val value: String) {
    WARMER("warmer"),
    CLEARER("clearer"),
    FUNNIER("funnier"),
    SAFER("safer");

    val displayName: String get() = value.replaceFirstChar { it.uppercase() }

    val bestWhen: String get() = when (this) {
        WARMER  -> "Best when you want to preserve the relationship"
        CLEARER -> "Best when ambiguity is the risk"
        FUNNIER -> "Best when the relationship already has banter"
        SAFER   -> "Best when the topic is sensitive or power dynamics are involved"
    }

    val helpText: String get() = when (this) {
        WARMER  -> "Adds warmth, validation, or care."
        CLEARER -> "Tightens the ask and removes ambiguity."
        FUNNIER -> "Lightens the tone; only if the context allows."
        SAFER   -> "Reduces the chance of being misread or causing friction."
    }

    companion object {
        fun from(value: String): RewriteAxis? = entries.firstOrNull { it.value == value }
        val all: List<RewriteAxis> = entries
    }
}

enum class RiskLevel(val value: String) {
    LOW("low"),
    MEDIUM("medium"),
    HIGH("high");

    // D1: guidance-framed labels that calm rather than alarm
    val displayName: String get() = when (this) {
        LOW    -> "Looks okay"
        MEDIUM -> "Worth softening"
        HIGH   -> "Could land wrong"
    }

    // A5: icon name for non-color accessibility signal
    val icon: String get() = when (this) {
        LOW    -> "check_circle"
        MEDIUM -> "warning"
        HIGH   -> "error"
    }

    companion object {
        fun from(value: String): RiskLevel = entries.firstOrNull { it.value == value } ?: MEDIUM
    }
}

data class RewriteSuggestion(
    val axis: RewriteAxis,
    val text: String,
    val rationale: String? = null,
    val riskAfter: RiskLevel? = null,
)

data class ToneAnalysis(
    val riskLevel: RiskLevel,
    val perception: String,
    val subtext: String,
    val reason: String?,
    val suggestions: List<RewriteSuggestion>,
    val flags: List<String>,
)

enum class AnalysisMode(val value: String) {
    COACH("coach"),
    READ("read");
}

data class AnalysisRequest(
    val draft: String,
    val recipientHint: String? = null,
    val preferredVoice: String? = null,
    val axes: List<RewriteAxis> = RewriteAxis.all,
    val contextHints: List<String> = emptyList(),
    val threadContext: String? = null,
    val mode: AnalysisMode = AnalysisMode.COACH,
)

sealed class ToneEngineError(message: String) : Exception(message) {
    object NoAPIKey     : ToneEngineError("No API key configured.")
    class Network(msg: String)  : ToneEngineError("Network error: $msg")
    class Decoding(msg: String) : ToneEngineError("Could not read response: $msg")
    class Backend(msg: String)  : ToneEngineError("Backend: $msg")
    object Offline      : ToneEngineError("No connection. Tap Back and try again when you have signal.")
    object RateLimit
        : ToneEngineError("Active trial or subscription required. Open Tono to continue.")
}

// Wire JSON models (kotlinx.serialization)

@Serializable
data class WireToneAnalysis(
    @SerialName("risk_level")  val riskLevel: String,
    val perception: String,
    val subtext: String,
    @SerialName("risk_reason") val riskReason: String? = null,
    val suggestions: List<WireSuggestion>,
    val flags: List<String>,
)

@Serializable
data class WireSuggestion(
    val axis: String,
    val text: String,
    val rationale: String? = null,
    @SerialName("risk_after") val riskAfter: String? = null,
)

fun WireToneAnalysis.toAnalysis() = ToneAnalysis(
    riskLevel   = RiskLevel.from(riskLevel),
    perception  = perception,
    subtext     = subtext,
    reason      = riskReason,
    suggestions = suggestions.mapNotNull { s ->
        val axis = RewriteAxis.from(s.axis) ?: return@mapNotNull null
        RewriteSuggestion(axis, s.text, s.rationale, s.riskAfter?.let { RiskLevel.from(it) })
    },
    flags = flags,
)
