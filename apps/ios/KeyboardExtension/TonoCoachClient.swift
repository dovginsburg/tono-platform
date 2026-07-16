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

struct CoachLatencySnapshot: Equatable {
    let tapToAcknowledgementMilliseconds: Double
    let tapToDispatchMilliseconds: Double
    let dispatchToFirstByteMilliseconds: Double
    let responseToRenderMilliseconds: Double
    let totalMilliseconds: Double

    var logLine: String {
        String(
            format: "TONO_KB coach_latency tap_to_ack_ms=%.0f tap_to_dispatch_ms=%.0f dispatch_to_first_byte_ms=%.0f response_to_render_ms=%.0f total_ms=%.0f",
            tapToAcknowledgementMilliseconds,
            tapToDispatchMilliseconds,
            dispatchToFirstByteMilliseconds,
            responseToRenderMilliseconds,
            totalMilliseconds
        )
    }
}

struct CoachLatencyTrace: Equatable {
    let tapAt: TimeInterval
    private(set) var acknowledgedAt: TimeInterval?
    private(set) var dispatchedAt: TimeInterval?
    private(set) var firstByteAt: TimeInterval?
    private(set) var responseAt: TimeInterval?
    private(set) var renderedAt: TimeInterval?

    mutating func markAcknowledged(at timestamp: TimeInterval) { acknowledgedAt = timestamp }
    mutating func markDispatched(at timestamp: TimeInterval) { dispatchedAt = timestamp }
    mutating func markFirstByte(at timestamp: TimeInterval) { firstByteAt = timestamp }
    mutating func markResponse(at timestamp: TimeInterval) { responseAt = timestamp }
    mutating func markRendered(at timestamp: TimeInterval) { renderedAt = timestamp }

    var snapshot: CoachLatencySnapshot? {
        guard let acknowledgedAt,
              let dispatchedAt,
              let firstByteAt,
              let responseAt,
              let renderedAt,
              tapAt <= acknowledgedAt,
              acknowledgedAt <= dispatchedAt,
              dispatchedAt <= firstByteAt,
              firstByteAt <= responseAt,
              responseAt <= renderedAt else { return nil }
        return CoachLatencySnapshot(
            tapToAcknowledgementMilliseconds: (acknowledgedAt - tapAt) * 1_000,
            tapToDispatchMilliseconds: (dispatchedAt - tapAt) * 1_000,
            dispatchToFirstByteMilliseconds: (firstByteAt - dispatchedAt) * 1_000,
            responseToRenderMilliseconds: (renderedAt - responseAt) * 1_000,
            totalMilliseconds: (renderedAt - tapAt) * 1_000
        )
    }
}

/// Immutable request-time text range. A rewrite is permitted only while the
/// same visible document is present; caret-only moves are handled by returning
/// to the captured range, while any edit fails closed.
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

    static func capture(before: String, after: String) -> Self? {
        guard let first = before.firstIndex(where: { !$0.isWhitespace }),
              let last = before.lastIndex(where: { !$0.isWhitespace }) else { return nil }
        let end = before.index(after: last)
        let draft = String(before[first..<end])
        return Self(
            draft: draft,
            before: before,
            after: after,
            draftEndOffset: before.distance(from: before.startIndex, to: end),
            trailingWhitespaceCount: before.distance(from: end, to: before.endIndex)
        )
    }

    func mutationPlan(liveBefore: String, liveAfter: String, replacement: String) -> MutationPlan? {
        guard liveBefore + liveAfter == before + after else { return nil }
        return MutationPlan(
            initialCursorOffset: draftEndOffset - liveBefore.count,
            deleteCount: draft.count,
            insertion: replacement,
            finalCursorOffset: trailingWhitespaceCount
        )
    }

    func matches(liveBefore: String, liveAfter: String) -> Bool {
        liveBefore + liveAfter == before + after
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

public final class TonoCoachClient {

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
                if status == 429 { return "Daily free limit reached. Open Tono to upgrade." }
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

    public init(endpoint: String, timeout: TimeInterval) {
        // The endpoint string is fixed by the build configuration, so we
        // trust the caller — but we still guard so a future regression
        // can't crash on a bad constant.
        self.endpoint = URL(string: endpoint) ?? URL(string: "https://api.tonoit.com/v1/analyze")!
        self.timeout = timeout
    }

    // MARK: - Public entry point

    /// Fire a Coach request. First-byte and completion callbacks are delivered
    /// on the main queue so the keyboard can mutate one latency trace safely.
    @discardableResult
    public func coach(
        draft: String,
        onFirstByte: @escaping (TimeInterval) -> Void = { _ in },
        completion: @escaping (Result<CoachResponse, CoachError>) -> Void
    ) -> URLSessionDataTask? {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = timeout

        let body: [String: Any] = [
            "draft": draft,
            "mode":  "coach",
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            DispatchQueue.main.async { completion(.failure(.decoding("encode body: \(error.localizedDescription)"))) }
            return nil
        }

        let delegate = CoachRequestDelegate(
            onFirstByte: onFirstByte,
            completion: completion
        )
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        delegate.session = session
        let task = session.dataTask(with: req)
        task.resume()
        return task
    }

    private static func requestResult(
        data: Data,
        response: URLResponse?,
        error: Error?
    ) -> Result<CoachResponse, CoachError> {
        if let urlError = error as? URLError {
            return .failure(urlError.code == .timedOut
                ? .timeout
                : .transport(urlError.localizedDescription))
        }
        if let error {
            return .failure(.transport(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure(.transport("no http response"))
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(status: http.statusCode, body: body))
        }
        do {
            return .success(try decode(data))
        } catch {
            return .failure(.decoding(error.localizedDescription))
        }
    }

    private final class CoachRequestDelegate: NSObject, URLSessionDataDelegate {
        var session: URLSession?
        private let onFirstByte: (TimeInterval) -> Void
        private let completion: (Result<CoachResponse, CoachError>) -> Void
        private var response: URLResponse?
        private var body = Data()
        private var deliveredFirstByte = false

        init(
            onFirstByte: @escaping (TimeInterval) -> Void,
            completion: @escaping (Result<CoachResponse, CoachError>) -> Void
        ) {
            self.onFirstByte = onFirstByte
            self.completion = completion
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            self.response = response
            if !deliveredFirstByte {
                deliveredFirstByte = true
                let timestamp = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [onFirstByte] in onFirstByte(timestamp) }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            body.append(data)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            let result = TonoCoachClient.requestResult(
                data: body,
                response: response,
                error: error
            )
            DispatchQueue.main.async { [completion] in completion(result) }
            session.finishTasksAndInvalidate()
            self.session = nil
        }
    }

    // MARK: - Pure decoder (testable without UIKit / URLSession)

    /// Decode the JSON body of a `/v1/analyze` 200 response.
    /// Throws on malformed payload; returns a `CoachResponse` on success.
    public static func decode(_ data: Data) throws -> CoachResponse {
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
        let canonical = try canonicalSuggestions(suggestions)
        return CoachResponse(
            riskLevel: riskLevel,
            perception: perception,
            subtext: subtext,
            reason: reason,
            suggestions: canonical,
            flags: flags
        )
    }

    /// The keyboard has four fixed semantic result slots. Normalize backend
    /// casing/whitespace, reject unsupported, blank, duplicate, or missing axes,
    /// and return exactly one rewrite per axis in stable semantic order.
    public static func canonicalSuggestions(_ raw: [CoachRewrite]) throws -> [CoachRewrite] {
        let canonicalAxes = ["warmer", "clearer", "funnier", "safer"]
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
