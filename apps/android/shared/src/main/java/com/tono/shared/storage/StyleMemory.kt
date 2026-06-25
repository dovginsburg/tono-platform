package com.tono.shared.storage

import com.tono.shared.models.RewriteAxis
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

// Mirrors ios/Shared/StyleMemory.swift
// Per-recipient axis tap weights. Earns a nudge once a recipient has ≥3
// interactions AND one axis has ≥50% share. Stored in SharedPreferences as
// JSON-encoded Map<String, Map<String, Int>>.

object StyleMemory {

    // Against-the-grain bonus: axes the user hasn't picked in a while get +2
    // so the top suggestion doesn't calcify into one axis forever.
    private const val GRAIN_BONUS = 2

    fun recordTap(axis: RewriteAxis, recipientId: String? = null) {
        updateWeights(axis, recipientId)
        if (recipientId != null) updateWeights(axis, null) // also update global
    }

    // Returns the axis with the highest weight for a given recipient (or global).
    // Returns null when there aren't enough interactions to be confident.
    fun preferredAxis(recipientId: String? = null): RewriteAxis? {
        val weights = loadWeights(recipientId)
        val total = weights.values.sum()
        if (total < 3) return null
        val top = weights.maxByOrNull { it.value } ?: return null
        if (top.value.toDouble() / total < 0.5) return null
        return RewriteAxis.from(top.key)
    }

    // Returns axes ranked by adjusted weight (global fallback when no recipientId).
    fun rankedAxes(recipientId: String? = null): List<RewriteAxis> {
        val weights = if (recipientId != null) loadWeights(recipientId) else loadWeights(null)
        val top = preferredAxis(recipientId)
        return RewriteAxis.all.sortedByDescending { axis ->
            val base = weights[axis.value] ?: 0
            if (axis == top) base else base + GRAIN_BONUS
        }
    }

    private fun updateWeights(axis: RewriteAxis, recipientId: String?) {
        val key = weightsKey(recipientId)
        val weights = loadWeights(recipientId).toMutableMap()
        weights[axis.value] = (weights[axis.value] ?: 0) + 1
        SharedStore.putString(key, Json.encodeToString(weights))
    }

    private fun loadWeights(recipientId: String?): Map<String, Int> {
        val raw = SharedStore.getString(weightsKey(recipientId)) ?: return emptyMap()
        return runCatching { Json.decodeFromString<Map<String, Int>>(raw) }.getOrDefault(emptyMap())
    }

    private fun weightsKey(recipientId: String?) =
        if (recipientId != null) "${SharedKeys.AXIS_WEIGHTS}.$recipientId"
        else SharedKeys.AXIS_WEIGHTS
}
