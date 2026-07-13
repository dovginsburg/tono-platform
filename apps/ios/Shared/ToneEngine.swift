// ToneEngine.swift
// Shared tone-analysis engine for Social Tone Coach.
// Used by both the host app and the keyboard extension.
//
// The rewrite-axis definitions (warmer / clearer / funnier / safer) are
// seeded from Ezra's group-chat tone discipline (1-sentence ceiling, 7
// prohibitions, gut check) — see SCOPE.md §4 and §9 for the recoupment
// thesis. Backend can be OpenAI, Anthropic, or the on-device stub.

import Foundation

// MARK: - Public types

public enum RewriteAxis: String, Codable, CaseIterable, Identifiable {
    case warmer
    case clearer
    case funnier
    case safer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .warmer: return "Warmer"
        case .clearer: return "Clearer"
        case .funnier: return "Funnier"
        case .safer: return "Safer"
        }
    }

    public var glyph: String {
        switch self {
        case .warmer: return "warm.fill"
        case .clearer: return "sparkle"
        case .funnier: return "face.smiling"
        case .safer: return "checkmark.shield"
        }
    }

    public var helpText: String {
        switch self {
        case .warmer: return "Adds warmth, validation, or care."
        case .clearer: return "Tightens the ask and removes ambiguity."
        case .funnier: return "Lightens the tone; only if the context allows."
        case .safer: return "Reduces the chance of being misread or causing friction."
        }
    }

    /// C3: Usage condition shown under each rewrite chip — converts
    /// synonym-machine perception into coaching advice.
    public var bestWhen: String {
        switch self {
        case .warmer:  return "Best when you want to preserve the relationship"
        case .clearer: return "Best when ambiguity is the risk"
        case .funnier: return "Best when the relationship already has banter"
        case .safer:   return "Best when the topic is sensitive or power dynamics are involved"
        }
    }
}

public enum RiskLevel: String, Codable {
    case low
    case medium
    case high

    /// D1: Guidance-framed labels that calm rather than alarm.
    public var displayName: String {
        switch self {
        case .low:    return "Looks okay"
        case .medium: return "Worth softening"
        case .high:   return "Could land wrong"
        }
    }

    /// A5: SF Symbol for non-color accessibility signal (colorblind + VoiceOver).
    public var systemIcon: String {
        switch self {
        case .low:    return "checkmark.circle"
        case .medium: return "exclamationmark.circle"
        case .high:   return "exclamationmark.triangle"
        }
    }
}

public struct RewriteSuggestion: Codable, Identifiable, Equatable {
    public let axis: RewriteAxis
    public let text: String
    public let rationale: String?
    public let riskAfter: RiskLevel?

    public var id: String { axis.rawValue }

    public init(axis: RewriteAxis, text: String, rationale: String? = nil, riskAfter: RiskLevel? = nil) {
        self.axis = axis
        self.text = text
        self.rationale = rationale
        self.riskAfter = riskAfter
    }
}

public extension Array where Element == RewriteSuggestion {
    func canonicalCoachChoices() throws -> [RewriteSuggestion] {
        let axes = RewriteAxis.allCases
        guard count == axes.count,
              Set(map(\.axis)).count == axes.count,
              Set(map(\.axis)) == Set(axes)
        else { throw ToneEngineError.decoding("incomplete Coach choices") }
        return axes.compactMap { axis in first { $0.axis == axis } }
    }
}

public struct ToneAnalysis: Codable, Equatable {
    public let riskLevel: RiskLevel
    public let perception: String          // 1-sentence "how it might land"
    public let subtext: String              // optional: what the writer might be feeling
    public let reason: String?             // ≤12-word plain-language "why" for the risk rating
    public let suggestions: [RewriteSuggestion]
    public let flags: [String]              // e.g. ["passive-aggressive", "ambiguous ask"]

    public init(
        riskLevel: RiskLevel,
        perception: String,
        subtext: String,
        reason: String? = nil,
        suggestions: [RewriteSuggestion],
        flags: [String]
    ) {
        self.riskLevel = riskLevel
        self.perception = perception
        self.subtext = subtext
        self.reason = reason
        self.suggestions = suggestions
        self.flags = flags
    }
}

public enum AnalysisMode: String, Codable {
    case coach
    case read
}

public struct AnalysisRequest {
    public let draft: String
    public let recipientHint: String?      // optional free-text context
    public let preferredVoice: String?      // optional user-style hint
    public let axes: [RewriteAxis]          // which axes to generate
    public let contextHints: [String]       // on-device memory facts (see UserMemory)
    public let threadContext: String?       // prior message the user is replying to
    public let mode: AnalysisMode           // coach = draft you're sending; read = message you received

    public init(
        draft: String,
        recipientHint: String? = nil,
        preferredVoice: String? = nil,
        axes: [RewriteAxis] = RewriteAxis.allCases,
        contextHints: [String] = [],
        threadContext: String? = nil,
        mode: AnalysisMode = .coach
    ) {
        self.draft = draft
        self.recipientHint = recipientHint
        self.preferredVoice = preferredVoice
        self.axes = axes
        self.contextHints = contextHints
        self.threadContext = threadContext
        self.mode = mode
    }
}

public enum ToneEngineError: Error, LocalizedError {
    case noAPIKey
    case network(String)
    case decoding(String)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured. Open the host app to set one."
        case .network(let m): return "Network error: \(m)"
        case .decoding(let m): return "Could not read response: \(m)"
        case .backend(let m): return "Backend: \(m)"
        }
    }
}

// MARK: - Provider

public enum LLMProvider: String, Codable, CaseIterable {
    case openai
    case anthropic
    case mock
}

public protocol ToneAnalyzing {
    func analyze(_ req: AnalysisRequest) async throws -> ToneAnalysis
}

// MARK: - Engine entrypoint

public struct ToneEngine: ToneAnalyzing {
    public let provider: LLMProvider
    public let model: String
    public let apiKey: String?

    public init(provider: LLMProvider, model: String, apiKey: String?) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
    }

    /// Convenience: a "backend" engine that ignores the legacy
    /// provider/apiKey fields and forwards the request to the Tono
    /// backend proxy. The server holds the LLM API key.
    public static func backend() -> ToneEngine {
        ToneEngine(provider: .mock, model: "backend", apiKey: nil)
    }

    public func analyze(_ req: AnalysisRequest) async throws -> ToneAnalysis {
        // Backend path: every analyze() goes to the proxy when the
        // client is in "backend mode" (the default post v0.2). The
        // keyboard + host app both rely on this so users never see
        // an API key.
        if model == "backend" {
            let resp = try await TonoBackend.shared.analyze(
                text: req.draft,
                preferredVoice: req.preferredVoice,
                axes: req.axes.isEmpty ? nil : req.axes,
                recipientHint: req.recipientHint,
                contextHints: req.contextHints.isEmpty ? nil : req.contextHints,
                threadContext: req.threadContext,
                mode: req.mode
            )
            return resp.toAnalysis()
        }
        switch provider {
        case .mock:
            return try await MockToneAnalyzer().analyze(req)
        case .openai:
            guard let apiKey, !apiKey.isEmpty else { throw ToneEngineError.noAPIKey }
            return try await OpenAIToneAnalyzer(model: model, apiKey: apiKey).analyze(req)
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw ToneEngineError.noAPIKey }
            return try await AnthropicToneAnalyzer(model: model, apiKey: apiKey).analyze(req)
        }
    }

    /// Streaming path — returns events as they arrive from the backend.
    /// Falls back to non-streaming (emits all events at once) for mock/direct providers.
    public func analyzeStream(_ req: AnalysisRequest) -> AsyncStream<AnalysisEvent> {
        if model == "backend" {
            return TonoBackend.shared.analyzeStream(
                text: req.draft,
                preferredVoice: req.preferredVoice,
                axes: req.axes.isEmpty ? nil : req.axes,
                recipientHint: req.recipientHint,
                contextHints: req.contextHints.isEmpty ? nil : req.contextHints,
                threadContext: req.threadContext,
                mode: req.mode
            )
        }
        // Fallback: run non-streaming analyze and emit all events at once
        return AsyncStream { continuation in
            Task {
                do {
                    let result = try await self.analyze(req)
                    continuation.yield(.perception(result.perception))
                    for s in result.suggestions {
                        continuation.yield(.suggestion(
                            axis: s.axis.rawValue,
                            text: s.text,
                            rationale: s.rationale ?? "",
                            riskAfter: s.riskAfter?.rawValue
                        ))
                    }
                    continuation.yield(.complete(
                        riskLevel: result.riskLevel.rawValue,
                        subtext: result.subtext,
                        riskReason: result.reason ?? "",
                        flags: result.flags
                    ))
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - System prompt

/// The system prompt is the seed of the rewrite-axis library.
///
/// Codified from Ezra's group-chat tone discipline:
/// 1-sentence ceiling, 7 prohibitions (no tool narration, no "based on", no
/// paragraphs in groups, no score predictions, no apologies, no strike ladder
/// carry-over, no analysis dumps), and the gut check ("would a friend text
/// this?"). See SCOPE.md §4.1 and §9 for the recoupment framing.
public enum TonePrompts {
    public static let system = """
    You are Social Tone Coach. You help a person say what they mean in a way
    that actually lands. You are NOT an editor or a grammar checker. You are
    NOT a therapist. You translate intent into impact.

    Operate by these rules:

    1. ONE-SENTENCE CEILING for any single rewrite. If a rewrite needs two
       sentences, rewrite it again until it doesn't.
    2. PRESERVE the writer's voice. Do not over-polish into corporate or
       generic-LLM English.
    3. FLAG passive aggression, ambiguous asks, unstated assumptions, and
       anything that could plausibly be misread as hostile, cold, or guilt-tripping.
    4. Each rewrite must differ on exactly ONE axis. Do not bundle warmth
       with humor; the user picks the axis that fits the moment.
    5. NEVER use "based on", "I checked", "looking at", "my read", or any
       tool-narration filler.
    6. NO score predictions, NO analysis dumps. A perception is one short
       sentence plus, optionally, up to three emoji.
    7. FUNNIER is risky. Only generate a funnier variant if the message has
       a clear light register. Otherwise return the same text for that axis
       with rationale "context doesn't call for humor".
    8. SAFER removes anything that could be misread as guilt, sarcasm,
       cold-shoulder, or an unstated ask.

    Return JSON ONLY matching the ToneAnalysis schema. No prose, no markdown
    fences, no commentary.
    """

    public static func userPrompt(for req: AnalysisRequest) -> String {
        var lines: [String] = []
        lines.append("DRAFT:")
        lines.append(req.draft)
        if let hint = req.recipientHint, !hint.isEmpty {
            lines.append("")
            lines.append("RECIPIENT CONTEXT: \(hint)")
        }
        if let voice = req.preferredVoice, !voice.isEmpty {
            lines.append("")
            lines.append("PREFERRED VOICE: \(voice)")
        }
        lines.append("")
        lines.append("GENERATE REWRITES FOR AXES: \(req.axes.map(\.rawValue).joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    /// JSON schema for tool/structured-output calls when supported.
    public static let jsonSchema = """
    {
      "type": "object",
      "properties": {
        "risk_level": { "type": "string", "enum": ["low", "medium", "high"] },
        "perception": { "type": "string", "description": "One short sentence plus up to 3 emoji." },
        "subtext": { "type": "string", "description": "What the writer might be feeling, in <=12 words." },
        "risk_reason": { "type": "string", "description": "One phrase <=12 words: why the risk rating was assigned." },
        "suggestions": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "axis": { "type": "string", "enum": ["warmer", "clearer", "funnier", "safer"] },
              "text": { "type": "string" },
              "rationale": { "type": "string" }
            },
            "required": ["axis", "text"],
            "additionalProperties": false
          }
        },
        "flags": {
          "type": "array",
          "items": { "type": "string" }
        }
      },
      "required": ["risk_level", "perception", "subtext", "risk_reason", "suggestions", "flags"],
      "additionalProperties": false
    }
    """
}

// MARK: - JSON wire model

struct WireToneAnalysis: Decodable {
    let risk_level: String
    let perception: String
    let subtext: String
    let risk_reason: String?
    let suggestions: [WireSuggestion]
    let flags: [String]
}

struct WireSuggestion: Decodable {
    let axis: String
    let text: String
    let rationale: String?
    let risk_after: String?
}

public extension ToneEngine {
    /// Decode the wire JSON the LLM returns. Tolerates small variations.
    static func decode(_ jsonString: String) throws -> ToneAnalysis {
        // Strip code fences if the model emitted them anyway.
        var trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // Drop first fence line
            if let nl = trimmed.firstIndex(of: "\n") {
                trimmed.removeSubrange(trimmed.startIndex...nl)
            }
            if trimmed.hasSuffix("```") {
                trimmed.removeLast(3)
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = trimmed.data(using: .utf8) else {
            throw ToneEngineError.decoding("not utf-8")
        }
        let wire: WireToneAnalysis
        do {
            wire = try JSONDecoder().decode(WireToneAnalysis.self, from: data)
        } catch {
            throw ToneEngineError.decoding(error.localizedDescription)
        }

        let risk = RiskLevel(rawValue: wire.risk_level) ?? .medium
        let suggestions: [RewriteSuggestion] = wire.suggestions.compactMap { s in
            guard let axis = RewriteAxis(rawValue: s.axis) else { return nil }
            return RewriteSuggestion(
                axis: axis, text: s.text, rationale: s.rationale,
                riskAfter: s.risk_after.flatMap { RiskLevel(rawValue: $0) }
            )
        }
        return ToneAnalysis(
            riskLevel: risk,
            perception: wire.perception,
            subtext: wire.subtext,
            reason: wire.risk_reason,
            suggestions: suggestions,
            flags: wire.flags
        )
    }
}
