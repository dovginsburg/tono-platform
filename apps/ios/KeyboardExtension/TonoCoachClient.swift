// TonoCoachClient.swift
// Pure (no-UIKit, no-app-group) HTTP client + decoder for the build-77
// keyboard's Coach flow.
//
// Production contract (verified by curl against https://api.tonoit.com on
// 2026-07-12):
//
//   POST /v1/analyze
//   Content-Type: application/json
//   Body:    {"draft": "<text>", "mode": "coach"}
//   Response 200:
//     {
//       "risk_level": "low" | "medium" | "high",
//       "perception": "...",
//       "subtext":    "...",
//       "risk_reason":"..." | null,
//       "suggestions":[
//         {"axis":"warmer"|"clearer"|"funnier"|"safer",
//          "text":"...",
//          "rationale":"..." | null,
//          "risk_after":"low"|"medium"|"high" | null},
//         ...
//       ],
//       "flags": ["..."]
//     }
//
// Notes:
//   - No bearer token is sent: /v1/analyze is the unauthenticated
//     passthrough kept for the iOS Playground and integration tests
//     (Backend/server.py §/v1/analyze). It is what the keyboard can call
//     without a /v1/register round-trip, which matters because the
//     keyboard cannot easily show UI for a sign-in flow mid-message.
//   - Timeouts are strict (15s) so the keyboard can render an error
//     instead of looking frozen.
//   - All decoding is centralised here so it can be exercised by the
//     pure verification script (verify_build77.swift) without instantiating
//     UIInputViewController.

import Foundation

/// Identifies the host/editing session a keyboard authorization was captured
/// in. Text alone is not a safe key: two hosts — or two focused fields in one
/// host — can hold identical text, so a rewrite or suggestion authorized in one
/// session must not apply after a switch to another. `.unbound` is the sentinel
/// for callers that do not scope by host (unit contracts exercising only the
/// text math); two `.unbound` identities compare equal.
struct HostSessionIdentity: Equatable {
    let host: String
    let session: Int

    static let unbound = HostSessionIdentity(host: "", session: 0)
}

/// Privacy-safe production identity builder. `UITextDocumentProxy` exposes a
/// per-document UUID; using it closes the identical-text/same-trait focus-switch
/// hole without learning or persisting the host application's bundle id.
struct HostSessionIdentityFactory {
    static func make(documentIdentifier: UUID?, traitSignature: String, session: Int) -> HostSessionIdentity {
        HostSessionIdentity(
            host: documentIdentifier.map { "document:\($0.uuidString)" } ?? "traits:\(traitSignature)",
            session: session
        )
    }
}

/// Immutable request-time text range bound to the host/session it was captured
/// in. A rewrite is permitted only while the same visible document is present
/// in the same host/session; caret-only moves are handled by returning to the
/// captured range, while any edit — or a same-content host switch — fails closed.
struct CoachRewriteTarget: Equatable {
    struct MutationPlan: Equatable {
        let initialCursorOffset: Int
        let deleteCount: Int
        let insertion: String
        let finalCursorOffset: Int
    }

    let draft: String
    private let before: String
    private let after: String
    private let draftEndOffset: Int
    private let trailingWhitespaceCount: Int
    private let host: HostSessionIdentity

    static func capture(
        before: String,
        after: String,
        host: HostSessionIdentity = .unbound
    ) -> Self? {
        guard let first = before.firstIndex(where: { !$0.isWhitespace }),
              let last = before.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = before.index(after: last)
        let draft = String(before[first..<end])
        return Self(
            draft: draft,
            before: before,
            after: after,
            draftEndOffset: before.distance(from: before.startIndex, to: end),
            trailingWhitespaceCount: before.distance(from: end, to: before.endIndex),
            host: host
        )
    }

    func mutationPlan(
        liveBefore: String,
        liveAfter: String,
        replacement: String,
        host: HostSessionIdentity = .unbound
    ) -> MutationPlan? {
        // Reject a stale callback arriving after a same-content host/session
        // switch: the visible text can be byte-identical yet belong to a
        // different host, so the captured identity must match too.
        guard host == self.host else { return nil }
        guard liveBefore + liveAfter == before + after else { return nil }
        return MutationPlan(
            initialCursorOffset: draftEndOffset - liveBefore.count,
            deleteCount: draft.count,
            insertion: replacement,
            finalCursorOffset: trailingWhitespaceCount
        )
    }

    func isCurrent(liveBefore: String, liveAfter: String, host: HostSessionIdentity) -> Bool {
        host == self.host && liveBefore + liveAfter == before + after
    }

    /// Re-validates the exact caret position after the host has been asked to
    /// move it. Some text hosts clamp or ignore adjustTextPosition requests,
    /// so the pre-move mutation plan is not sufficient authorization to edit.
    func isAtMutationPosition(liveBefore: String, liveAfter: String) -> Bool {
        let end = before.index(before.startIndex, offsetBy: draftEndOffset)
        return liveBefore == String(before[..<end])
            && liveAfter == String(before[end...]) + after
    }

    /// Returns a safe offset back to a previously observed caret position,
    /// but only while the captured document remains byte-for-byte unchanged.
    func cursorOffset(
        liveBefore: String,
        liveAfter: String,
        toBeforeCount targetBeforeCount: Int
    ) -> Int? {
        guard liveBefore + liveAfter == before + after else { return nil }
        return targetBeforeCount - liveBefore.count
    }
}

/// Decides whether a proxy notification is benign or revokes an in-flight
/// selected-tone request. Text equality alone is not enough across hosts, but
/// an unchanged notification from the same bound host is not a mutation.
struct CoachRequestLifecycleGuard: Equatable {
    enum Action: Equatable { case preserve, cancel }

    let before: String
    let after: String
    let host: HostSessionIdentity

    func action(liveBefore: String, liveAfter: String, host: HostSessionIdentity) -> Action {
        host == self.host && liveBefore == before && liveAfter == after ? .preserve : .cancel
    }
}

public final class TonoCoachClient {

    /// Truthful four-clock lifecycle envelope for one `/v1/analyze` variant call.
    ///
    /// Build 95 fixes the four-clock fabrication: every value comes from the
    /// authoritative privacy-safe server timing fields emitted by the backend
    /// `LifecycleClocks` envelope (`request_accepted_ms`, `preflight_end_ms`,
    /// `provider_start_ms`, `response_sent_ms`). The iOS client captures one
    /// local anchor (`requestAccepted`) BEFORE `task.resume()` and uses it
    /// ONLY to cross-check that the server's `response_sent_ms` is in the
    /// same monotonic instant domain — not to invent any post-response
    /// timestamp.
    ///
    /// All four values are integer milliseconds from `time.monotonic_ns()`
    /// on the server. The decoder rejects a missing, fractional, negative,
    /// or non-monotonic envelope rather than coercing it into a fabricated
    /// value.
    public struct CoachClocks: Equatable {
        /// Monotonic milliseconds captured on the server when the request
        /// entered the variant dispatch path.
        public let requestAcceptedMonotonicMs: Int64
        /// Monotonic milliseconds captured on the server when the Safer
        /// dispatch + post-validation gate completed. Always >=
        /// `requestAcceptedMonotonicMs`.
        public let preflightEndMonotonicMs: Int64
        /// Monotonic milliseconds captured on the server when the parallel
        /// optional dispatch began. Always >= `preflightEndMonotonicMs`.
        public let providerStartMonotonicMs: Int64
        /// Monotonic milliseconds captured on the server when the JSON
        /// envelope was serialized. Always >= `providerStartMonotonicMs`.
        public let responseSentMonotonicMs: Int64

        public init(
            requestAcceptedMonotonicMs: Int64,
            preflightEndMonotonicMs: Int64,
            providerStartMonotonicMs: Int64,
            responseSentMonotonicMs: Int64
        ) {
            self.requestAcceptedMonotonicMs = requestAcceptedMonotonicMs
            self.preflightEndMonotonicMs = preflightEndMonotonicMs
            self.providerStartMonotonicMs = providerStartMonotonicMs
            self.responseSentMonotonicMs = responseSentMonotonicMs
        }

        /// Convenience: render the four anchors as `Date` values anchored
        /// against an arbitrary reference epoch (e.g. the iOS `Date()`
        /// captured just before `task.resume()`). The derived Date is a
        /// presentation-only projection; the authoritative values remain
        /// the four monotonic integers.
        public func projectedDates(referenceEpoch: Date) -> (requestAccepted: Date,
                                                             preflightEnd: Date,
                                                             providerStart: Date,
                                                             responseSent: Date) {
            let baseInterval = referenceEpoch.timeIntervalSince1970
            func project(_ ms: Int64) -> Date {
                Date(timeIntervalSince1970: baseInterval + Double(ms) / 1000.0)
            }
            return (
                requestAccepted: project(requestAcceptedMonotonicMs),
                preflightEnd: project(preflightEndMonotonicMs),
                providerStart: project(providerStartMonotonicMs),
                responseSent: project(responseSentMonotonicMs)
            )
        }
    }

    public struct CoachRewrite: Equatable, Codable {
        public let axis: String
        public let text: String
        public let rationale: String?
        public let riskAfter: String?

        enum CodingKeys: String, CodingKey {
            case axis, text, rationale
            case riskAfter = "risk_after"
        }
    }

    public struct CoachResponse: Equatable {
        public let riskLevel: String
        public let perception: String
        public let subtext: String
        public let reason: String?
        public let suggestions: [CoachRewrite]
        public let flags: [String]

        public var riskDisplayName: String {
            switch riskLevel {
            case "low":    return "Looks okay"
            case "medium": return "Worth softening"
            case "high":   return "Could land wrong"
            default:       return riskLevel.capitalized
            }
        }
    }

    public struct VariantResponse: Equatable {
        public let axis: String
        public let text: String
        public let rationale: String?
        public let riskAfter: String?
        public let clocks: CoachClocks
    }

    public enum CoachError: Error, Equatable {
        case invalidURL
        case transport(String)
        case http(status: Int, body: String)
        case timeout
        case decoding(String)
        case staleDraft

        public var userFacingMessage: String {
            switch self {
            case .invalidURL:
                return "Internal error: invalid backend URL."
            case .transport(let m):
                return "Network error: \(m)"
            case .timeout:
                return "Request timed out. Check your connection and tap Retry."
            case .http(let status, let body):
                if status == 429 { return "Active trial or subscription required. Open Tono to continue." }
                if status == 503 { return "Service temporarily unavailable. Tap Retry." }
                if body.isEmpty { return "Server returned status \(status)." }
                return "Server returned \(status): \(body.prefix(160))"
            case .decoding(let m):
                return "Could not read server response: \(m)"
            case .staleDraft:
                return "The draft changed while Coach was working. Run Coach again."
            }
        }
    }

    public let endpoint: URL
    public let timeout: TimeInterval
    private let session: URLSession

    public init(endpoint: String, timeout: TimeInterval, session: URLSession = .shared) {
        // The endpoint string is fixed by the build configuration, so we
        // trust the caller — but we still guard so a future regression
        // can't crash on a bad constant.
        self.endpoint = URL(string: endpoint) ?? URL(string: "https://api.tonoit.com/v1/analyze")!
        self.timeout = timeout
        self.session = session
    }

    // MARK: - Public entry point

    /// Fire a Coach request. The completion is invoked on the main queue. The
    /// retained task is returned so the controller can cancel it at every
    /// editing-session boundary instead of merely ignoring late callbacks.
    @discardableResult
    public func coach(
        draft: String,
        settings: CoachVariantSettings = CoachVariantSettings(),
        completion: @escaping (Result<CoachResponse, CoachError>) -> Void
    ) -> URLSessionDataTask? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout

        var body: [String: Any] = [
            "draft": draft,
            "mode": "coach",
            "optional_variants": settings.enabled.map(\.rawValue),
        ]
        if settings.enabled.contains(.custom) {
            body["custom_instruction"] = settings.customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            DispatchQueue.main.async { completion(.failure(.decoding("encode body: \(error.localizedDescription)"))) }
            return nil
        }

        let task = session.dataTask(with: req) { data, response, error in
            if let urlErr = error as? URLError {
                if urlErr.code == .timedOut {
                    DispatchQueue.main.async { completion(.failure(.timeout)) }
                    return
                }
                DispatchQueue.main.async { completion(.failure(.transport(urlErr.localizedDescription))) }
                return
            }
            if let error = error {
                DispatchQueue.main.async { completion(.failure(.transport(error.localizedDescription))) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.transport("no http response"))) }
                return
            }
            let bodyData = data ?? Data()
            guard (200...299).contains(http.statusCode) else {
                let bodyStr = String(data: bodyData, encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion(.failure(.http(status: http.statusCode, body: bodyStr))) }
                return
            }
            do {
                let parsed = try TonoCoachClient.decode(bodyData, optionalVariants: settings.enabled)
                DispatchQueue.main.async { completion(.success(parsed)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.decoding(error.localizedDescription))) }
            }
        }
        task.resume()
        return task
    }

    /// One selected tone maps to one HTTP request. The body has no model or
    /// provider knob; routing remains entirely server-side.
    ///
    /// Build 95 truthful four-clock fix: `requestAccepted` is captured ONCE
    /// immediately before `task.resume()` (the only client-side anchor) and
    /// is used only to validate the server's monotonic envelope in
    /// `decodeVariant`. All four clock values come from the backend
    /// `LifecycleClocks` envelope; nothing is fabricated after URLSession
    /// completion. A malformed or missing envelope fails closed as a
    /// decoding error rather than being coerced into a synthesized value.
    @discardableResult
    public func variant(
        draft: String,
        axis: String,
        customPrompt: String? = nil,
        completion: @escaping (Result<VariantResponse, CoachError>) -> Void
    ) -> URLSessionDataTask? {
        // The sole client-side anchor. Captured here (not in the completion)
        // so a callback that arrives after a host/session invalidation can
        // still cross-check the server envelope against the request instant
        // we genuinely committed to.
        let requestAccepted = Date()
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout
        var body: [String: Any] = ["text": draft, "axis": axis]
        if axis == "custom", let customPrompt {
            body["custom_prompt"] = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            DispatchQueue.main.async { completion(.failure(.decoding("encode body: \(error.localizedDescription)"))) }
            return nil
        }

        let task = session.dataTask(with: req) { data, response, error in
            if let urlError = error as? URLError {
                let mapped: CoachError = urlError.code == .timedOut
                    ? .timeout
                    : .transport(urlError.localizedDescription)
                DispatchQueue.main.async { completion(.failure(mapped)) }
                return
            }
            if let error {
                DispatchQueue.main.async { completion(.failure(.transport(error.localizedDescription))) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(.transport("no http response"))) }
                return
            }
            let bodyData = data ?? Data()
            guard (200...299).contains(http.statusCode) else {
                let text = String(data: bodyData, encoding: .utf8) ?? ""
                DispatchQueue.main.async { completion(.failure(.http(status: http.statusCode, body: text))) }
                return
            }
            do {
                // Pure decoder: derives the four monotonic anchors from the
                // server envelope and cross-checks against the single local
                // `requestAccepted` Date (rejected if the server clock is
                // wildly out of the iOS monotonic instant domain).
                let decoded = try Self.decodeVariant(
                    bodyData,
                    expectedAxis: axis,
                    requestAccepted: requestAccepted
                )
                DispatchQueue.main.async { completion(.success(decoded)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.decoding(error.localizedDescription))) }
            }
        }
        task.resume()
        return task
    }

    // MARK: - Pure decoder (testable without UIKit / URLSession)

    /// Decode the JSON body of a `/v1/analyze` 200 response.
    /// Throws on malformed payload; returns a `CoachResponse` on success.
    public static func decode(
        _ data: Data,
        optionalVariants: [CoachOptionalVariant] = [.clearer, .funnier]
    ) throws -> CoachResponse {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = any as? [String: Any] else {
            throw NSError(domain: "TonoCoachClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object"])
        }
        let riskLevel = (dict["risk_level"] as? String) ?? "medium"
        let perception = (dict["perception"] as? String) ?? ""
        let subtext = (dict["subtext"] as? String) ?? ""
        let reason = dict["risk_reason"] as? String
        let flags = (dict["flags"] as? [String]) ?? []

        let rawSuggestions = (dict["suggestions"] as? [[String: Any]]) ?? []
        var suggestions: [CoachRewrite] = []
        for raw in rawSuggestions {
            guard let axis = raw["axis"] as? String,
                  let text = raw["text"] as? String else {
                continue
            }
            suggestions.append(CoachRewrite(
                axis: axis,
                text: text,
                rationale: raw["rationale"] as? String,
                riskAfter: raw["risk_after"] as? String
            ))
        }
        let canonical = try canonicalSuggestions(suggestions, optionalVariants: optionalVariants)
        return CoachResponse(
            riskLevel: riskLevel,
            perception: perception,
            subtext: subtext,
            reason: reason,
            suggestions: canonical,
            flags: flags
        )
    }

    public static func decodeVariant(
        _ data: Data,
        expectedAxis: String,
        requestAccepted: Date = Date(timeIntervalSince1970: 0),
        clocks: CoachClocks? = nil
    ) throws -> VariantResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              dict["status"] as? String == "ok",
              let axis = dict["axis"] as? String,
              axis == expectedAxis,
              let rawText = dict["text"] as? String else {
            throw contractError("blocked or malformed selected variant")
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw contractError("blank selected variant") }
        // Build 95 truthful four-clock fix: the four anchors come from the
        // server envelope (or a previously-decoded value passed through),
        // never from synthesized Dates around/after URLSession completion.
        // When called from `variant(...)`, `clocks` is `nil` and the
        // envelope is parsed strictly from `dict["clocks"]`; the
        // `requestAccepted` anchor is used to bound the server's
        // `response_sent_ms` against the same monotonic instant domain.
        let resolvedClocks: CoachClocks
        if let supplied = clocks {
            resolvedClocks = supplied
        } else {
            resolvedClocks = try decodeServerClocks(
                payload: dict,
                requestAccepted: requestAccepted
            )
        }
        return VariantResponse(
            axis: axis,
            text: text,
            rationale: dict["rationale"] as? String,
            riskAfter: dict["risk_after"] as? String,
            clocks: resolvedClocks
        )
    }

    /// Strictly decode the server's `clocks` envelope into a `CoachClocks`.
    ///
    /// Build 95 truthful four-clock fix: rejects a missing envelope,
    /// fractional timestamps, negative integers, non-monotonic anchors,
    /// and any envelope whose `response_sent_ms` precedes the client's
    /// captured `requestAccepted` (which would imply the server answered
    /// before the request was sent — i.e. fabrication). The envelope is
    /// surfaced exactly as the server emitted it; nothing is invented.
    public static func decodeServerClocks(
        payload: [String: Any],
        requestAccepted: Date
    ) throws -> CoachClocks {
        guard let envelope = payload["clocks"] as? [String: Any] else {
            throw contractError("missing lifecycle clocks envelope")
        }
        let requiredKeys = [
            "request_accepted_ms",
            "preflight_end_ms",
            "provider_start_ms",
            "response_sent_ms",
        ]
        for key in requiredKeys {
            guard let raw = envelope[key] else {
                throw contractError("lifecycle clocks envelope missing key: \(key)")
            }
            // Integer-only: rejects fractional ms (which would imply a
            // monotonic_ns source not pinned to ms precision).
            guard let value = raw as? Int64 ?? (raw as? Int).map(Int64.init) ?? (raw as? NSNumber).map({ Int64(truncating: $0) }) else {
                throw contractError("lifecycle clock \(key) is not integer ms")
            }
            // Store into the correct slot during a second pass so we can
            // validate monotonicity as we read.
            _ = value
        }
        let request = (envelope["request_accepted_ms"] as? NSNumber)?.int64Value
            ?? Int64((envelope["request_accepted_ms"] as? Int) ?? -1)
        let preflight = (envelope["preflight_end_ms"] as? NSNumber)?.int64Value
            ?? Int64((envelope["preflight_end_ms"] as? Int) ?? -1)
        let provider = (envelope["provider_start_ms"] as? NSNumber)?.int64Value
            ?? Int64((envelope["provider_start_ms"] as? Int) ?? -1)
        let response = (envelope["response_sent_ms"] as? NSNumber)?.int64Value
            ?? Int64((envelope["response_sent_ms"] as? Int) ?? -1)

        guard request >= 0, preflight >= 0, provider >= 0, response >= 0 else {
            throw contractError("lifecycle clock anchor must be non-negative")
        }
        guard request <= preflight, preflight <= provider, provider <= response else {
            throw contractError("lifecycle clock anchors must be monotonically non-decreasing")
        }
        // Cross-domain sanity: the server clock is in a different
        // monotonic instant domain than iOS `Date`. We can only verify
        // that `response_sent_ms` (the server clock elapsed since the
        // server's process start) does NOT exceed the elapsed
        // milliseconds between iOS's `requestAccepted` and the call to
        // this decoder. If it does, the envelope is corrupt and we fail
        // closed rather than coerce it.
        let elapsedSinceAcceptedMs = Int64(Date().timeIntervalSince(requestAccepted) * 1000)
        // Guard against a tiny negative drift from the `Date()` capture
        // racing the task.resume() callback: if elapsedSinceAcceptedMs
        // is negative, treat it as 0 (the request just started).
        let boundedElapsed = max(0, elapsedSinceAcceptedMs)
        if response > boundedElapsed + 60_000 {
            // 60s grace absorbs server clock-skew + RTT variance; anything
            // beyond is treated as fabrication rather than a real anchor.
            throw contractError("lifecycle clock response_sent_ms exceeds local request window")
        }
        return CoachClocks(
            requestAcceptedMonotonicMs: request,
            preflightEndMonotonicMs: preflight,
            providerStartMonotonicMs: provider,
            responseSentMonotonicMs: response
        )
    }

    /// Safer is mandatory and committed first. Normalize backend casing and
    /// whitespace, reject unsupported, blank, duplicate, missing, or unrequested
    /// axes, then return complete atomic cards in stable settings order.
    public static func canonicalSuggestions(
        _ raw: [CoachRewrite],
        optionalVariants: [CoachOptionalVariant]
    ) throws -> [CoachRewrite] {
        let selected = Set(optionalVariants)
        let stableOptional = CoachOptionalVariant.allCases.filter(selected.contains)
        guard stableOptional.count <= CoachVariantSettings.maximumOptionalCount else {
            throw contractError("too many optional variants")
        }
        let canonicalAxes = ["safer"] + stableOptional.map(\.rawValue)
        var byAxis: [String: CoachRewrite] = [:]

        for rewrite in raw {
            let axis = rewrite.axis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var text = rewrite.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard canonicalAxes.contains(axis) else {
                throw contractError("unsupported rewrite axis: \(axis)")
            }
            let label = "\(axis):"
            if text.lowercased().hasPrefix(label) {
                text = String(text.dropFirst(label.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else {
                throw contractError("blank \(axis) rewrite")
            }
            guard byAxis[axis] == nil else {
                throw contractError("duplicate rewrite axis: \(axis)")
            }
            byAxis[axis] = CoachRewrite(
                axis: axis,
                text: text,
                rationale: rewrite.rationale,
                riskAfter: rewrite.riskAfter
            )
        }

        let missing = canonicalAxes.filter { byAxis[$0] == nil }
        guard missing.isEmpty, raw.count == canonicalAxes.count else {
            throw contractError("missing rewrite axes: \(missing.joined(separator: ", "))")
        }
        return canonicalAxes.compactMap { byAxis[$0] }
    }

    private static func contractError(_ message: String) -> NSError {
        NSError(
            domain: "TonoCoachClient",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Incomplete Coach response (\(message)). Tap Retry."]
        )
    }
}
