// TonoBackend.swift
// Thin async client for the Tono backend. The host app and the keyboard
// extension both use this; the server holds the LLM API keys, enforces
// rate limits, and tracks the user's plan.
//
// Wire shape (Backend/server.py):
//   POST /v1/register   {device_id?, app_version?, platform?} ->
//                       {device_id, api_token, plan, is_pro}
//   GET  /v1/me         -> {device_id, plan, is_pro, used_today,
//                            daily_limit, subscription_status, ...}
//   POST /api/analyze   {text, provider?, preferred_voice?, axes?,
//                        recipient_hint?} ->
//                       {risk_level, perception, subtext, suggestions,
//                        flags, used_today, daily_limit, plan}
//   POST /v1/checkout   {interval} -> {url, session_id}
//   POST /v1/portal                 -> {url}
//
// The backend URL is configurable via the `tonoBackendURL` shared
// default. Defaults to the local dev server. Production should set
// `tonoBackendURL` to the Railway / Fly deployment.

import Foundation

public enum TonoBackendError: Error, LocalizedError {
    case notRegistered
    case http(Int, String)
    case decoding(String)
    case network(String)
    case offline
    /// Anti-fraud: email already on `current` devices (max allowed: `max`).
    /// Backend returns 403 with `{detail: {error: "too_many_devices", current, max}}`.
    case tooManyDevices(current: Int, max: Int)

    public var errorDescription: String? {
        switch self {
        case .notRegistered:
            return "Account not set up yet. Open the Tono app once to sign in."
        case .http(let code, let msg):
            // 429 carries a usage payload; we surface its message but the
            // caller already has used_today/daily_limit on the response
            // model so the UI can render "N/10 today" without parsing.
            if code == 429 { return "Daily free limit reached. Open Tono to upgrade." }
            if code == 401 { return "Sign-in expired. Open the Tono app to refresh." }
            if code == 503 { return "Service temporarily unavailable." }
            return msg.isEmpty ? "Server error (\(code))." : msg
        case .decoding(let m): return "Could not read server response: \(m)"
        case .network(let m): return "Network error: \(m)"
        case .offline: return "Offline. Check your connection and try again."
        case .tooManyDevices(let current, let max):
            return "This email is already on \(current) devices (max \(max)). Contact support if you need more."
        }
    }
}

public struct TonoMe: Codable, Equatable {
    public let deviceId: String
    public let plan: String
    public let isPro: Bool
    public let usedToday: Int
    public let dailyLimit: Int
    public let subscriptionStatus: String?
    public let subscriptionRenewsAt: String?
    // Email identity (added 2026-07-03). nil = anonymous user.
    public let email: String?
    public let emailVerifiedAt: String?
    // Number of devices linked to this email (1 = only this device).
    // Used for the iOS app to show "This account is on N devices" + fraud signal.
    public let deviceCountForEmail: Int?
    public let maxDevicesPerEmail: Int?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case plan
        case isPro = "is_pro"
        case usedToday = "used_today"
        case dailyLimit = "daily_limit"
        case subscriptionStatus = "subscription_status"
        case subscriptionRenewsAt = "subscription_renews_at"
        case email
        case emailVerifiedAt = "email_verified_at"
        case deviceCountForEmail = "device_count_for_email"
        case maxDevicesPerEmail = "max_devices_per_email"
    }
}

public struct TonoAnalysisResponse: Codable {
    public let riskLevel: String
    public let perception: String
    public let subtext: String
    public let reason: String?
    public let suggestions: [TonoSuggestion]
    public let flags: [String]
    public let usedToday: Int
    public let dailyLimit: Int
    public let plan: String

    enum CodingKeys: String, CodingKey {
        case riskLevel = "risk_level"
        case reason = "risk_reason"
        case perception, subtext, suggestions, flags, plan
        case usedToday = "used_today"
        case dailyLimit = "daily_limit"
    }

    public func toAnalysis() -> ToneAnalysis {
        let risk = RiskLevel(rawValue: riskLevel) ?? .medium
        let mapped: [RewriteSuggestion] = suggestions.compactMap { s in
            guard let axis = RewriteAxis(rawValue: s.axis) else { return nil }
            return RewriteSuggestion(
                axis: axis, text: s.text, rationale: s.rationale,
                riskAfter: s.riskAfter.flatMap { RiskLevel(rawValue: $0) }
            )
        }
        return ToneAnalysis(
            riskLevel: risk,
            perception: perception,
            subtext: subtext,
            reason: reason,
            suggestions: mapped,
            flags: flags
        )
    }
}

public struct TonoSuggestion: Codable {
    public let axis: String
    public let text: String
    public let rationale: String?
    public let riskAfter: String?

    enum CodingKeys: String, CodingKey {
        case axis, text, rationale
        case riskAfter = "risk_after"
    }
}

// MARK: - Streaming analysis events

public enum AnalysisEvent {
    case perception(String)
    case suggestion(axis: String, text: String, rationale: String, riskAfter: String?)
    case complete(riskLevel: String, subtext: String, riskReason: String, flags: [String])
    case error(String)
}

public struct WeeklyDigestResponse: Codable {
    public let rewrites: Int
    public let daysActive: Int
    public let topAxis: String?
    public let axisBreakdown: [String: Int]
    public let prevAxisBreakdown: [String: Int]

    enum CodingKeys: String, CodingKey {
        case rewrites
        case daysActive = "days_active"
        case topAxis = "top_axis"
        case axisBreakdown = "axis_breakdown"
        case prevAxisBreakdown = "prev_axis_breakdown"
    }
}

public struct CouponRedemption: Decodable {
    public let couponProExpiresAt: String
    public let message: String

    enum CodingKeys: String, CodingKey {
        case couponProExpiresAt = "coupon_pro_expires_at"
        case message
    }
}

public struct TonoUsage: Codable {
    public let usedToday: Int
    public let dailyLimit: Int
    public let plan: String
    public let isPro: Bool

    public init(usedToday: Int, dailyLimit: Int, plan: String, isPro: Bool) {
        self.usedToday = usedToday
        self.dailyLimit = dailyLimit
        self.plan = plan
        self.isPro = isPro
    }

    enum CodingKeys: String, CodingKey {
        case plan
        case isPro = "is_pro"
        case usedToday = "used_today"
        case dailyLimit = "daily_limit"
    }
}

public final class TonoBackend: @unchecked Sendable {
    public static let shared = TonoBackend()

    /// Resolution order (first match wins):
    ///   1. Runtime override via SharedKeys.backendURL (useful for staging toggle)
    ///   2. Info.plist key "TONO_BACKEND_URL" (set per-scheme via xcconfig)
    ///   3. Compile-time fallback: Debug → localhost, Release → Railway URL
    public var baseURL: URL {
        // 1. Runtime override
        if let raw = SharedStore.defaults.string(forKey: SharedKeys.backendURL),
           !raw.isEmpty, let u = URL(string: raw) {
            return u
        }
        // 2. Build-time Info.plist (add TONO_BACKEND_URL to Info.plist in Xcode,
        //    driven by an xcconfig so Debug and Release use different values)
        if let raw = Bundle.main.object(forInfoDictionaryKey: "TONO_BACKEND_URL") as? String,
           !raw.isEmpty, let u = URL(string: raw) {
            return u
        }
        // 3. Hard-coded compile-time fallback
        #if DEBUG
        return URL(string: "http://127.0.0.1:8765")!
        #else
        // Replace with your Railway URL after first deploy.
        // The runtime override (option 1) lets you update it without a rebuild.
        return URL(string: "https://api.tonoit.com")!
        #endif
    }

    public func registerIfNeeded(platform: String, appVersion: String) async throws -> TonoMe {
        // Migrate legacy UserDefaults secrets into the Keychain on first call.
        SharedKeychain.migrateFromDefaults(key: KeychainKeys.apiToken, defaultsKey: SharedKeys.apiToken)
        SharedKeychain.migrateFromDefaults(key: KeychainKeys.deviceID, defaultsKey: SharedKeys.deviceID)
        SharedKeychain.migrateFromDefaults(key: KeychainKeys.apiKey,   defaultsKey: SharedKeys.apiKey)

        if SharedKeychain.get(KeychainKeys.apiToken) != nil,
           let me = try? await me() {
            return me
        }
        let did: String = {
            if let stored = SharedKeychain.get(KeychainKeys.deviceID), !stored.isEmpty {
                return stored
            }
            let fresh = UUID().uuidString
            SharedKeychain.set(fresh, forKey: KeychainKeys.deviceID)
            return fresh
        }()

        struct Req: Encodable { let device_id: String; let platform: String; let app_version: String }
        struct Resp: Decodable {
            let device_id: String
            let api_token: String
            let plan: String
            let is_pro: Bool
        }
        let resp: Resp = try await post(
            path: "/v1/register",
            body: Req(device_id: did, platform: platform, app_version: appVersion),
            authorize: false
        )
        SharedKeychain.set(resp.device_id, forKey: KeychainKeys.deviceID)
        SharedKeychain.set(resp.api_token, forKey: KeychainKeys.apiToken)
        // Wipe any residual plain-text credentials from UserDefaults.
        SharedStore.defaults.removeObject(forKey: SharedKeys.apiKey)
        SharedStore.defaults.removeObject(forKey: SharedKeys.provider)
        SharedStore.defaults.removeObject(forKey: SharedKeys.apiToken)
        SharedStore.defaults.removeObject(forKey: SharedKeys.deviceID)
        return try await me()
    }

    public func me() async throws -> TonoMe {
        try await get(path: "/v1/me")
    }

    // ── Email identity (added 2026-07-03) ──────────────────────────────────
    // Send a 6-digit OTP to `email`. Always succeeds (server doesn't leak
    // whether the email exists). User receives the code in their inbox,
    // types it back into the iOS app, which calls `verifyEmailOTP`.
    @discardableResult
    public func requestEmailLink(email: String) async throws -> [String: Any] {
        let body: [String: Any] = ["email": email]
        return try await postObject(path: "/v1/auth/request-link", json: body)
    }

    /// Verify the 6-digit OTP. On success, the backend:
    ///   1. links this device's `device_id` to the email (or migrates
    ///      an existing anonymous row to the canonical email row)
    ///   2. returns a fresh `api_token` (per-device)
    ///   3. marks `email` on the iOS keychain so the user stays signed in
    ///      across reinstalls (next install will re-trigger this flow)
    /// Throws `TonoBackendError.tooManyDevices(current, max)` if the email
    /// already has the max allowed device rows.
    @discardableResult
    public func verifyEmailOTP(
        email: String,
        otp: String,
    ) async throws -> TonoMe {
        let body: [String: Any] = [
            "email": email,
            "otp": otp,
            "device_id": SharedKeychain.get(KeychainKeys.deviceID) ?? "",
        ]
        let resp: [String: Any] = try await postObject(
            path: "/v1/auth/verify-otp",
            json: body,
        )
        // Persist the new api_token (per-device, server-issued).
        if let token = resp["api_token"] as? String, !token.isEmpty {
            SharedKeychain.set(token, forKey: KeychainKeys.apiToken)
        }
        // Persist the email so future installs (fresh device_id) can
        // auto-claim the same identity on first sign-in.
        SharedKeychain.set(email, forKey: KeychainKeys.signedInEmail)
        // Re-read /v1/me to get the canonical user shape.
        return try await me()
    }

    /// Lightweight health check used by Settings to confirm reachability.
    /// Returns `true` when the backend responds 2xx to GET /health. Throws
    /// `TonoBackendError` for transport / non-2xx failures so the caller
    /// can surface a real error string instead of a generic "unreachable".
    public func health() async throws -> Bool {
        guard let url = URL(string: "/health", relativeTo: baseURL) else {
            throw TonoBackendError.network("invalid url: /health")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw TonoBackendError.network("no http response")
            }
            return (200...299).contains(http.statusCode)
        } catch let urlErr as URLError where urlErr.code == .notConnectedToInternet {
            throw TonoBackendError.offline
        } catch let e as TonoBackendError {
            throw e
        } catch {
            throw TonoBackendError.network(error.localizedDescription)
        }
    }

    public func analyze(
        text: String,
        preferredVoice: String?,
        axes: [RewriteAxis]?,
        recipientHint: String? = nil,
        contextHints: [String]? = nil,
        threadContext: String? = nil,
        mode: AnalysisMode = .coach
    ) async throws -> TonoAnalysisResponse {
        struct Req: Encodable {
            let text: String
            let provider: String?
            let preferred_voice: String?
            let axes: [String]?
            let recipient_hint: String?
            let context_hints: [String]?
            let thread_context: String?
            let mode: String
        }
        // We deliberately omit `provider` so the server picks based on
        // env-configured TONO_PROVIDER. The client has no business
        // choosing for the user.
        let req = Req(
            text: text,
            provider: nil,
            preferred_voice: preferredVoice,
            axes: axes?.map(\.rawValue),
            recipient_hint: recipientHint,
            context_hints: contextHints,
            thread_context: threadContext,
            mode: mode.rawValue
        )
        return try await post(path: "/api/analyze", body: req, authorize: true)
    }

    /// Thin convenience wrapper for the keyboard extension's "Coach" flow.
    ///
    /// The full `analyze(...)` surface takes ~7 parameters; in a custom
    /// keyboard we want a single-tap entry point with no allocation of
    /// RewriteAxis / AnalysisMode values. This hits `POST /v1/coach` with
    /// the minimal `{text: ...}` body the user confirmed works.
    ///
    /// Returns the rewrites payload as a flat JSON string — the keyboard's
    /// SwiftUI `KeyboardRootView` parses it client-side via `JSONDecoder`
    /// straight into `ToneAnalysis`. Designed to be safe to call from
    /// inside the keyboard extension (no UIApplication, no app-group
    /// entitlements required — uses `URLSession.shared.data(for:)` like
    /// the rest of the backend client).
    public struct CoachResponse: Codable, Equatable {
        public let rewrites: [CoachRewrite]
        public let usedToday: Int?
        public let dailyLimit: Int?
        public let plan: String?
        public init(rewrites: [CoachRewrite], usedToday: Int? = nil, dailyLimit: Int? = nil, plan: String? = nil) {
            self.rewrites = rewrites
            self.usedToday = usedToday
            self.dailyLimit = dailyLimit
            self.plan = plan
        }
    }
    public struct CoachRewrite: Codable, Equatable {
        public let axis: String
        public let text: String
        public let rationale: String?
        public let riskAfter: String?
        public init(axis: String, text: String, rationale: String? = nil, riskAfter: String? = nil) {
            self.axis = axis
            self.text = text
            self.rationale = rationale
            self.riskAfter = riskAfter
        }
    }
    public func coach(text: String) async throws -> String {
        struct Req: Encodable { let text: String }
        struct Resp: Decodable {
            let rewrites: [CoachRewrite]?
            let suggestions: [CoachRewrite]?
            let analysis: CoachResponse?
        }
        let req = Req(text: text)
        let (data, response) = try await postRaw(path: "/v1/coach", body: req, authorize: true)
        guard let http = response as? HTTPURLResponse else {
            throw TonoBackendError.network("no http response")
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 429 {
                throw TonoBackendError.http(http.statusCode, "Daily free limit reached.")
            }
            if http.statusCode == 401 {
                throw TonoBackendError.notRegistered
            }
            throw TonoBackendError.http(http.statusCode, body)
        }
        // Two server shapes observed: {rewrites: [...]} or {suggestions: [...]}
        // or {analysis: {...}}. Tolerate all three; keyboard caller only
        // needs the rewrite array so we hand back a canonical JSON blob.
        if let parsed = try? JSONDecoder().decode(CoachResponse.self, from: data) {
            return String(data: (try? JSONEncoder().encode(parsed)) ?? data, encoding: .utf8) ?? ""
        }
        if let loose = try? JSONDecoder().decode(Resp.self, from: data) {
            let canonical = CoachResponse(
                rewrites: loose.rewrites ?? loose.suggestions ?? [],
                usedToday: loose.analysis?.usedToday,
                dailyLimit: loose.analysis?.dailyLimit,
                plan: loose.analysis?.plan
            )
            return String(data: (try? JSONEncoder().encode(canonical)) ?? data, encoding: .utf8) ?? ""
        }
        // Last-ditch: return whatever the server gave us.
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Streaming version of analyze — returns an AsyncStream of AnalysisEvents.
    /// The caller sees perception → suggestions → complete progressively.
    public func analyzeStream(
        text: String,
        preferredVoice: String?,
        axes: [RewriteAxis]?,
        recipientHint: String? = nil,
        contextHints: [String]? = nil,
        threadContext: String? = nil,
        mode: AnalysisMode = .coach
    ) -> AsyncStream<AnalysisEvent> {
        struct Req: Encodable {
            let text: String
            let provider: String?
            let preferred_voice: String?
            let axes: [String]?
            let recipient_hint: String?
            let context_hints: [String]?
            let thread_context: String?
            let mode: String
        }
        let req = Req(
            text: text,
            provider: nil,
            preferred_voice: preferredVoice,
            axes: axes?.map(\.rawValue),
            recipient_hint: recipientHint,
            context_hints: contextHints,
            thread_context: threadContext,
            mode: mode.rawValue
        )

        return AsyncStream { continuation in
            Task {
                do {
                    guard let url = URL(string: "/api/analyze", relativeTo: baseURL) else {
                        continuation.yield(.error("Invalid URL"))
                        continuation.finish()
                        return
                    }
                    var urlReq = URLRequest(url: url)
                    urlReq.httpMethod = "POST"
                    urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlReq.timeoutInterval = 30
                    if let token = SharedKeychain.get(KeychainKeys.apiToken), !token.isEmpty {
                        urlReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    }
                    urlReq.httpBody = try JSONEncoder().encode(req)

                    let (bytes, response) = try await URLSession.shared.bytes(for: urlReq)
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        continuation.yield(.error("Server error (\(code))"))
                        continuation.finish()
                        return
                    }

                    // Detect response shape: SSE ("text/event-stream") vs single JSON object.
                    // Fallback path matters because the current /api/analyze endpoint is
                    // `return ApiAnalyzeResponse(...)` — a single JSON object — and our iOS
                    // SSE parser would otherwise produce zero events and a blank UI.
                    let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    let isJSON = contentType.contains("application/json")

                    var eventsYielded = false
                    var rawLines: [String] = []

                    for try await line in bytes.lines {
                        rawLines.append(line)
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data: ") else { continue }
                        let payload = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let evt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let type = evt["type"] as? String {
                            switch type {
                            case "perception":
                                if let text = evt["text"] as? String {
                                    continuation.yield(.perception(text))
                                    eventsYielded = true
                                }
                            case "suggestion":
                                continuation.yield(.suggestion(
                                    axis: evt["axis"] as? String ?? "",
                                    text: evt["text"] as? String ?? "",
                                    rationale: evt["rationale"] as? String ?? "",
                                    riskAfter: evt["risk_after"] as? String
                                ))
                                eventsYielded = true
                            case "complete":
                                continuation.yield(.complete(
                                    riskLevel: evt["risk_level"] as? String ?? "low",
                                    subtext: evt["subtext"] as? String ?? "",
                                    riskReason: evt["risk_reason"] as? String ?? "",
                                    flags: evt["flags"] as? [String] ?? []
                                ))
                                eventsYielded = true
                            case "error":
                                continuation.yield(.error(evt["message"] as? String ?? "Unknown error"))
                                eventsYielded = true
                            default:
                                break
                            }
                        }
                    }

                    // Fallback: server returned a non-SSE response (today this means a
                    // single JSON `ToneAnalysis`). Parse the buffered body and synthesize
                    // events so the UI still gets a result.
                    if !eventsYielded && isJSON {
                        let body = rawLines.joined(separator: "\n")
                        if let data = body.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            // Match the backend ApiAnalyzeResponse / ToneAnalysis wire shape:
                            // { risk_level, perception, subtext, risk_reason, suggestions: [...], flags: [...] }
                            // (also tolerate empty body — just send a low-risk complete).
                            // NOTE: the wire key is `risk_reason`, NOT `reason` — server-side
                            // snake_case matches the Pydantic alias in Backend/analyze.py.
                            let perception = obj["perception"] as? String ?? ""
                            if !perception.isEmpty {
                                continuation.yield(.perception(perception))
                            }
                            if let suggestions = obj["suggestions"] as? [[String: Any]] {
                                for s in suggestions {
                                    continuation.yield(.suggestion(
                                        axis: s["axis"] as? String ?? "",
                                        text: s["text"] as? String ?? "",
                                        rationale: s["rationale"] as? String ?? "",
                                        riskAfter: s["risk_after"] as? String
                                    ))
                                }
                            }
                            continuation.yield(.complete(
                                riskLevel: obj["risk_level"] as? String ?? "low",
                                subtext: obj["subtext"] as? String ?? "",
                                riskReason: obj["risk_reason"] as? String ?? "",
                                flags: obj["flags"] as? [String] ?? []
                            ))
                        } else {
                            // Body wasn't parseable — surface as error so caller can show toast
                            continuation.yield(.error("Unexpected response from server"))
                        }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    /// Fetch resolved feature flags for this device from the backend.
    public func fetchFeatures() async throws -> [String: Bool] {
        try await get(path: "/v1/features")
    }

    /// Sync a user preference toggle to the backend (fire-and-forget wrapper).
    public func setFeaturePreference(flag: String, enabled: Bool) async throws {
        struct Req: Encodable { let enabled: Bool }
        struct Resp: Decodable { let ok: Bool; let key: String; let enabled: Bool }
        let _: Resp = try await put(
            path: "/v1/features/\(flag)",
            body: Req(enabled: enabled),
            authorize: true
        )
    }

    /// Fetch the weekly tone digest from the backend.
    public func weeklyDigest() async throws -> WeeklyDigestResponse {
        try await get(path: "/v1/digest")
    }

    public func checkout(interval: String) async throws -> URL {
        struct Req: Encodable { let interval: String }
        struct Resp: Decodable { let url: String }
        let resp: Resp = try await post(
            path: "/v1/checkout",
            body: Req(interval: interval),
            authorize: true
        )
        guard let url = URL(string: resp.url) else {
            throw TonoBackendError.decoding("invalid checkout url")
        }
        return url
    }

    public func portal() async throws -> URL {
        struct Resp: Decodable { let url: String }
        let resp: Resp = try await post(path: "/v1/portal", body: EmptyBody(), authorize: true)
        guard let url = URL(string: resp.url) else {
            throw TonoBackendError.decoding("invalid portal url")
        }
        return url
    }

    public func redeemCoupon(code: String) async throws -> CouponRedemption {
        struct Req: Encodable { let code: String }
        return try await post(path: "/v1/coupon/redeem", body: Req(code: code), authorize: true)
    }

    public func isRegistered() -> Bool {
        SharedKeychain.get(KeychainKeys.apiToken)?.isEmpty == false
    }

    /// Fire-and-forget: records which rewrite axis the user tapped.
    /// Used for product analytics; failure is silently ignored.
    public func logAxisWin(axis: String, riskLevel: String) {
        struct Req: Encodable { let axis: String; let risk_level: String }
        fireAndForget(path: "/v1/event/axis", body: Req(axis: axis, risk_level: riskLevel))
    }

    // MARK: - HTTP plumbing

    private struct EmptyBody: Encodable {}

    private func fireAndForget<In: Encodable>(path: String, body: In) {
        Task {
            guard let req = try? buildRequest(path: path, method: "POST", body: body, authorize: true)
            else { return }
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    private func get<Out: Decodable>(path: String) async throws -> Out {
        let req = try buildRequest(path: path, method: "GET", body: Optional<EmptyBody>.none, authorize: true)
        return try await execute(req)
    }

    /// POST with a free-form [String: Any] body, returns the raw JSON dict.
    /// Used for the email-identity endpoints (`/v1/auth/request-link` and
    /// `/v1/auth/verify-otp`) which need a non-Codable shape on the iOS side
    /// (OTP codes, free-form errors).
    private func postObject(
        path: String,
        json: [String: Any],
        authorize: Bool = true
    ) async throws -> [String: Any] {
        let url = baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorize, let token = SharedKeychain.get(KeychainKeys.apiToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TonoBackendError.network("no response")
        }
        if !(200...299).contains(http.statusCode) {
            // Decode the error body — server returns {"detail": {...}} for our
            // 403 too_many_devices, or {"detail": "..."} for 401.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = obj["detail"] {
                if let dict = detail as? [String: Any], let err = dict["error"] as? String {
                    if err == "too_many_devices",
                       let cur = dict["current"] as? Int,
                       let max = dict["max"] as? Int {
                        throw TonoBackendError.tooManyDevices(current: cur, max: max)
                    }
                }
                throw TonoBackendError.http(http.statusCode, "\(detail)")
            }
            throw TonoBackendError.http(http.statusCode, "request failed")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TonoBackendError.network("invalid JSON response")
        }
        return obj
    }

    private func post<In: Encodable, Out: Decodable>(
        path: String, body: In, authorize: Bool
    ) async throws -> Out {
        let req = try buildRequest(path: path, method: "POST", body: body, authorize: authorize)
        return try await execute(req)
    }

    /// Raw POST that returns Data + URLResponse without trying to decode.
    /// Used by the keyboard's coach() flow which tolerates multiple server
    /// response shapes and needs to canonicalize the result itself.
    fileprivate func postRaw<In: Encodable>(
        path: String, body: In, authorize: Bool
    ) async throws -> (Data, URLResponse) {
        let req = try buildRequest(path: path, method: "POST", body: body, authorize: authorize)
        do {
            return try await URLSession.shared.data(for: req)
        } catch let urlErr as URLError where urlErr.code == .notConnectedToInternet {
            throw TonoBackendError.offline
        } catch {
            throw TonoBackendError.network(error.localizedDescription)
        }
    }

    private func put<In: Encodable, Out: Decodable>(
        path: String, body: In, authorize: Bool
    ) async throws -> Out {
        let req = try buildRequest(path: path, method: "PUT", body: body, authorize: authorize)
        return try await execute(req)
    }

    private func buildRequest<In: Encodable>(
        path: String, method: String, body: In?, authorize: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw TonoBackendError.network("invalid url: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorize {
            guard let token = SharedKeychain.get(KeychainKeys.apiToken), !token.isEmpty else {
                throw TonoBackendError.notRegistered
            }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.httpBody = try JSONEncoder().encode(body)
        }
        req.timeoutInterval = 30
        return req
    }

    private func execute<Out: Decodable>(_ req: URLRequest) async throws -> Out {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let urlErr as URLError where urlErr.code == .notConnectedToInternet {
            throw TonoBackendError.offline
        } catch {
            throw TonoBackendError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TonoBackendError.network("no http response")
        }
        if http.statusCode == 429 {
            // The body has `{error: {message, used_today, daily_limit}}`
            // — surface the message but the UI uses Me().usedToday for
            // the live counter.
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? ""
            throw TonoBackendError.http(429, msg)
        }
        if !(200...299).contains(http.statusCode) {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message ?? ""
            throw TonoBackendError.http(http.statusCode, msg)
        }
        do {
            return try JSONDecoder().decode(Out.self, from: data)
        } catch {
            throw TonoBackendError.decoding(error.localizedDescription)
        }
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String; let used_today: Int?; let daily_limit: Int? }
        let error: Inner
    }
}