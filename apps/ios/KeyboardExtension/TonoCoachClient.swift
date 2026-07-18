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
                let parsed = try TonoCoachClient.decode(bodyData)
                DispatchQueue.main.async { completion(.success(parsed)) }
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
