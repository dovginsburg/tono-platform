// TonoAnalytics.swift
// A3: Lightweight, first-party event stream. Events go to /v1/events on
// the Tono backend — no third-party SDK, no heavy initialization, no memory
// cost in the keyboard extension at startup.
//
// A4 PRIVACY CONTRACT (enforced here, not downstream):
//   ✓  Event names, axis enums, risk-level enums, latency_ms, mode strings
//   ✓  Anonymized device ID only
//   ✗  NO message text — never include draft or rewrite text
//   ✗  NO recipient names — only axis labels and boolean flags
//   ✗  NO free-text user input of any kind
//
// Call site rule: properties are computed here and checked in code review.
// If a property ever needs to carry user-visible text, it must be replaced
// with an opaque enum value before the track() call.

import Foundation

// MARK: - Event catalog

public enum AnalyticsEvent: Sendable {
    /// User tapped Coach or Read.
    case coachRequested(mode: String)
    /// Analysis result appeared on screen (mock or real LLM).
    case analysisShown(riskLevel: String, latencyMs: Int, source: String)
    /// User tapped a rewrite chip and it was inserted.
    case rewriteInserted(selectedAxis: String, shownAxes: [String])
    /// Draft text changed after insert — user edited the suggested rewrite.
    case rewriteEditedAfterInsert
    /// User inserted one axis but others were shown (derived on back end).
    case axisRejected(shownAxes: [String], pickedAxis: String)
    /// User inserted a word from the inline suggestion strip.
    case suggestionTapped
    /// Collective improvement signal: content-free session outcome.
    /// Respects the improveTono flag — never sent when user has opted out.
    /// Fields: risk enum, axis enum or nil, mode enum, length BUCKET (not length),
    /// bool flags. NO message text, NO rewrite text, NO recipient identifier.
    case improvementOutcome(
        riskLevel: String,
        axisSelected: String?,
        mode: String,
        msgLenBucket: String,
        rewriteUsed: Bool,
        editAfter: Bool
    )

    public var name: String {
        switch self {
        case .coachRequested:           return "coach_requested"
        case .analysisShown:            return "analysis_shown"
        case .rewriteInserted:          return "rewrite_inserted"
        case .rewriteEditedAfterInsert: return "rewrite_edited_after_insert"
        case .axisRejected:             return "axis_rejected"
        case .suggestionTapped:         return "suggestion_tapped"
        case .improvementOutcome:       return "improvement_outcome"
        }
    }

    // A4: Only permitted properties — strings are enum values, not user content.
    public var properties: [String: Any] {
        switch self {
        case .coachRequested(let mode):
            return ["mode": mode]
        case .analysisShown(let risk, let ms, let source):
            return ["risk_level": risk, "latency_ms": ms, "source": source]
        case .rewriteInserted(let axis, let shown):
            return ["selected_axis": axis, "shown_axes": shown]
        case .rewriteEditedAfterInsert:
            return [:]
        case .axisRejected(let shown, let picked):
            return ["shown_axes": shown, "picked_axis": picked]
        case .suggestionTapped:
            return [:]
        case .improvementOutcome(let risk, let axis, let mode, let bucket, let used, let edit):
            var props: [String: Any] = [
                "risk_level": risk,
                "mode": mode,
                "msg_len_bucket": bucket,
                "rewrite_used": used,
                "edit_after": edit,
            ]
            if let axis { props["selected_axis"] = axis }
            return props
        }
    }
}

// MARK: - Client

public enum TonoAnalytics {
    /// Fire-and-forget: failures are silently discarded.
    /// Never blocks the calling thread; dispatches on a background URLSession.
    public static func track(_ event: AnalyticsEvent) {
        // Collective improvement events respect the opt-out flag — never sent
        // when the user has disabled "Help improve Tono" in Settings.
        if case .improvementOutcome = event, !FeatureFlags.isEnabled(.improveTono) { return }

        let deviceId = SharedKeychain.get(KeychainKeys.deviceID) ?? ""
        guard !deviceId.isEmpty else { return }
        let token = SharedKeychain.get(KeychainKeys.apiToken) ?? ""

        var body: [String: Any] = [
            "event": event.name,
            "device_id": deviceId,
            "ts": Int(Date().timeIntervalSince1970),
        ]
        event.properties.forEach { body[$0.key] = $0.value }

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        let url = TonoBackend.shared.baseURL.appendingPathComponent("v1/events")
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = data

        // Fire-and-forget on the default session (no response handling).
        URLSession.shared.dataTask(with: req).resume()
    }
}
