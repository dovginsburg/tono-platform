package com.tono.shared.engine

import com.tono.shared.models.AnalysisMode
import com.tono.shared.models.AnalysisRequest
import com.tono.shared.models.RewriteAxis
import com.tono.shared.models.RewriteSuggestion
import com.tono.shared.models.RiskLevel
import com.tono.shared.models.ToneAnalysis

// Mirrors ios/Shared/MockToneAnalyzer.swift
// Deterministic local stub for offline previews and unit tests.

object MockToneAnalyzer {

    fun analyze(req: AnalysisRequest): ToneAnalysis =
        if (req.mode == AnalysisMode.READ) analyzeReceived(req) else analyzeCoach(req)

    private fun analyzeReceived(req: AnalysisRequest): ToneAnalysis {
        val lower = req.draft.lowercase()
        val isPA = lower.contains("as per my last message") ||
                   lower.contains("per my last") ||
                   lower.contains("as previously discussed")
        val isTerse = req.draft.length < 6 || lower in listOf("ok.", "fine.", "k.")
        val risk = if (isPA) RiskLevel.HIGH else if (isTerse) RiskLevel.MEDIUM else RiskLevel.LOW
        return ToneAnalysis(
            riskLevel  = risk,
            perception = if (isPA) "Sender sounds frustrated or passive-aggressive. 📩"
                         else if (isTerse) "Very short — hard to read intent. 🤔"
                         else "Seems straightforward. No obvious friction. ✅",
            subtext    = if (isPA) "annoyed, wants acknowledgment"
                         else if (isTerse) "minimal engagement, possibly busy or cold"
                         else "neutral, informational",
            reason     = if (isPA) "Sender is reminding you they were ignored."
                         else if (isTerse) "Too brief to read — could be neutral or dismissive."
                         else "Reads as direct — nothing ambiguous or loaded.",
            suggestions = emptyList(),
            flags       = if (isPA) listOf("passive-aggressive") else if (isTerse) listOf("terse reply") else emptyList(),
        )
    }

    private fun analyzeCoach(req: AnalysisRequest): ToneAnalysis {
        val lower = req.draft.lowercase()
        val isPA = lower.contains("as per my last message") ||
                   lower.contains("per my last") ||
                   lower.contains("as previously discussed") ||
                   (lower.contains("thanks!") && lower.contains("but"))
        val isVague = (lower.contains("let me know") && !lower.contains("by ")) ||
                      lower.contains("sometime") || lower.contains("when you can")
        val isCold = req.draft.length < 6 || lower in listOf("ok.", "fine.", "k.")
        val risk = when {
            isPA || isCold -> RiskLevel.HIGH
            isVague        -> RiskLevel.MEDIUM
            else           -> RiskLevel.LOW
        }
        val flags = buildList {
            if (isPA)   add("passive-aggressive")
            if (isVague) add("ambiguous ask")
            if (isCold) add("terse — could read as cold")
        }
        val perception = when {
            isPA    -> "Might land as a guilt-trip. 📩 😶"
            isVague -> "The ask is hard to act on without more detail. 🤔"
            isCold  -> "Reads as dismissive. 🥶"
            else    -> "Lands cleanly. ✅"
        }
        val subtext = when {
            isPA    -> "frustrated, wants resolution"
            isVague -> "wants a reply but won't ask directly"
            isCold  -> "upset or distracted"
            else    -> "calm, neutral"
        }
        val reason = when {
            isPA    -> "Reads as a guilt-trip — implies they ignored you."
            isVague -> "Ambiguous ask — no deadline or clear next step."
            isCold  -> "Too terse — reads as cold or annoyed."
            else    -> "Lands cleanly — nothing stands out as risky."
        }
        val suggestions = buildList {
            if (req.axes.contains(RewriteAxis.WARMER))
                add(RewriteSuggestion(RewriteAxis.WARMER, warmRewrite(req.draft), "Adds a one-line validation before the ask."))
            if (req.axes.contains(RewriteAxis.CLEARER))
                add(RewriteSuggestion(RewriteAxis.CLEARER, clearRewrite(req.draft), "Names the ask and a specific deadline."))
            if (req.axes.contains(RewriteAxis.FUNNIER))
                add(RewriteSuggestion(RewriteAxis.FUNNIER, req.draft, "context doesn't call for humor"))
            if (req.axes.contains(RewriteAxis.SAFER))
                add(RewriteSuggestion(RewriteAxis.SAFER, safeRewrite(req.draft), "Removes anything that could be read as guilt or cold."))
        }
        return ToneAnalysis(risk, perception, subtext, reason, suggestions, flags)
    }

    private fun warmRewrite(s: String) =
        if (s.lowercase().startsWith("thanks") || s.lowercase().startsWith("thank you")) "Hey — really appreciate it. $s"
        else "Hey! $s"

    private fun clearRewrite(s: String) =
        if (s.lowercase().contains("let me know")) s.replace("let me know", "could you reply by Friday EOD?", ignoreCase = true)
        else s

    private fun safeRewrite(s: String): String {
        var out = s
        listOf(
            "as per my last message" to "following up on my last note",
            "per my last"            to "following up on my last",
            "as previously discussed" to "to recap where we left off",
        ).forEach { (from, to) -> out = out.replace(from, to, ignoreCase = true) }
        if (out == s && s.endsWith(".") && s.length < 6) out = "Sounds good — thanks."
        return out
    }
}
