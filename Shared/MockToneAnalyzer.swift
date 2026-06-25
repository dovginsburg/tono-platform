// MockToneAnalyzer.swift
// Deterministic local stub. Used when the user has not yet set an API key,
// in previews, and in unit tests. Returns a ToneAnalysis built from a few
// hand-tuned heuristics on the draft text.

import Foundation

public struct MockToneAnalyzer: ToneAnalyzing {
    public init() {}

    public func analyze(_ req: AnalysisRequest) async throws -> ToneAnalysis {
        if req.mode == .read {
            return analyzeReceived(req)
        }
        return analyzeCoach(req)
    }

    private func analyzeReceived(_ req: AnalysisRequest) -> ToneAnalysis {
        let lower = req.draft.lowercased()
        let length = req.draft.count

        let isPassiveAggressive =
            lower.contains("as per my last message") ||
            lower.contains("per my last") ||
            lower.contains("as previously discussed")

        let isTerse = length < 6 || lower == "ok." || lower == "fine." || lower == "k."

        let risk: RiskLevel = isPassiveAggressive ? .high : isTerse ? .medium : .low

        let flags: [String] = isPassiveAggressive ? ["passive-aggressive"] :
                              isTerse ? ["terse reply"] : []

        let perception: String = isPassiveAggressive ? "Sender sounds frustrated or passive-aggressive. 📩" :
                                  isTerse ? "Very short — hard to read intent. 🤔" :
                                  "Seems straightforward. No obvious friction. ✅"
        let subtext: String = isPassiveAggressive ? "annoyed, wants acknowledgment" :
                              isTerse ? "minimal engagement, possibly busy or cold" : "neutral, informational"
        let reason: String = isPassiveAggressive ? "Sender is reminding you they were ignored." :
                             isTerse ? "Too brief to read — could be neutral or dismissive." :
                             "Reads as direct — nothing ambiguous or loaded."

        return ToneAnalysis(
            riskLevel: risk,
            perception: perception,
            subtext: subtext,
            reason: reason,
            suggestions: [],
            flags: flags
        )
    }

    private func analyzeCoach(_ req: AnalysisRequest) -> ToneAnalysis {
        let draft = req.draft
        let lower = draft.lowercased()
        let length = draft.count

        // Heuristics — kept small and obvious so reviewers can see exactly
        // what each branch does.
        let isPassiveAggressive =
            lower.contains("as per my last message") ||
            lower.contains("per my last") ||
            lower.contains("as previously discussed") ||
            (lower.contains("thanks!") && lower.contains("but"))

        let isVague =
            lower.contains("let me know") && !lower.contains("by ") ||
            lower.contains("sometime") ||
            lower.contains("when you can")

        let isCold =
            length < 6 ||
            lower == "ok." ||
            lower == "fine." ||
            lower == "k."

        let risk: RiskLevel =
            (isPassiveAggressive || isCold) ? .high :
            (isVague) ? .medium : .low

        let flags: [String] = {
            var f: [String] = []
            if isPassiveAggressive { f.append("passive-aggressive") }
            if isVague { f.append("ambiguous ask") }
            if isCold { f.append("terse — could read as cold") }
            return f
        }()

        let perception: String
        if isPassiveAggressive {
            perception = "Might land as a guilt-trip. 📩 😶"
        } else if isVague {
            perception = "The ask is hard to act on without more detail. 🤔"
        } else if isCold {
            perception = "Reads as dismissive. 🥶"
        } else {
            perception = "Lands cleanly. ✅"
        }

        let subtext = isPassiveAggressive ? "frustrated, wants resolution" :
                      isVague ? "wants a reply but won't ask directly" :
                      isCold ? "upset or distracted" : "calm, neutral"

        let reason: String = isPassiveAggressive ? "Reads as a guilt-trip — implies they ignored you." :
                             isVague ? "Ambiguous ask — no deadline or clear next step." :
                             isCold ? "Too terse — reads as cold or annoyed." :
                             "Lands cleanly — nothing stands out as risky."

        var suggestions: [RewriteSuggestion] = []

        if req.axes.contains(.warmer) {
            let warmer = warmRewrite(of: draft)
            suggestions.append(RewriteSuggestion(
                axis: .warmer,
                text: warmer,
                rationale: "Adds a one-line validation before the ask."
            ))
        }
        if req.axes.contains(.clearer) {
            let clearer = clearRewrite(of: draft)
            suggestions.append(RewriteSuggestion(
                axis: .clearer,
                text: clearer,
                rationale: "Names the ask and a specific deadline."
            ))
        }
        if req.axes.contains(.funnier) {
            suggestions.append(RewriteSuggestion(
                axis: .funnier,
                text: draft,
                rationale: "context doesn't call for humor"
            ))
        }
        if req.axes.contains(.safer) {
            suggestions.append(RewriteSuggestion(
                axis: .safer,
                text: safeRewrite(of: draft),
                rationale: "Removes anything that could be read as guilt or cold."
            ))
        }

        return ToneAnalysis(
            riskLevel: risk,
            perception: perception,
            subtext: subtext,
            reason: reason,
            suggestions: suggestions,
            flags: flags
        )
    }

    // Tiny rule-based rewrites. These are intentionally conservative — the
    // real product delegates to an LLM. The mock is for offline previews.
    private func warmRewrite(of s: String) -> String {
        if s.lowercased().hasPrefix("thanks") || s.lowercased().hasPrefix("thank you") {
            return "Hey — really appreciate it. " + s
        }
        return "Hey! " + s
    }

    private func clearRewrite(of s: String) -> String {
        if s.lowercased().contains("let me know") {
            return s.replacingOccurrences(
                of: "let me know", with: "could you reply by Friday EOD?"
            )
        }
        return s
    }

    private func safeRewrite(of s: String) -> String {
        var out = s
        let bad: [(String, String)] = [
            ("as per my last message", "following up on my last note"),
            ("per my last", "following up on my last"),
            ("as previously discussed", "to recap where we left off"),
        ]
        for (from, to) in bad {
            out = out.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        if out == s && s.last == "." && s.count < 6 {
            out = "Sounds good — thanks."
        }
        return out
    }
}
