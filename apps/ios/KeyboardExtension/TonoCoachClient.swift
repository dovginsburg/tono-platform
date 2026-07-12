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
            default:       return "Tono · \(riskLevel)"
            }
        }
    }

    public enum CoachError: Error, Equatable {
        case invalidURL
        case transport(String)
        case http(status: Int, body: String)
        case timeout
        case decoding(String)

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

    /// Fire a Coach request. The completion is invoked on the main queue.
    public func coach(
        draft: String,
        completion: @escaping (Result<CoachResponse, CoachError>) -> Void
    ) {
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
            return
        }

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
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
        return CoachResponse(
            riskLevel: riskLevel,
            perception: perception,
            subtext: subtext,
            reason: reason,
            suggestions: suggestions,
            flags: flags
        )
    }
}