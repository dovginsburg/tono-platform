// TonoBackend.swift
// Thin async client for the Tono backend. The host app and the keyboard
// extension both use this; the server holds the LLM API keys, enforces
// rate limits, and tracks the user's plan.
//
// Wire shape (Backend/server.py):
//   POST /v1/register   {device_id?, app_version?, platform?} ->
//                       {device_id, api_token, plan, is_pro}
//   GET  /v1/me         -> {device_id, plan, is_pro,
//                            subscription_status, ...}
//   POST /api/analyze   {text, provider?, preferred_voice?, axes?,
//                        recipient_hint?} ->
//                       {risk_level, perception, subtext, suggestions,
//                        flags, plan}
//   POST /api/analyze/variant {text, axis, custom_prompt?} ->
//                       {status, axis, text?, rationale?, risk_after?, reason?}
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
            // 402 = the server-authoritative entitlement gate (there is no free
            // tier): an active trial or subscription is required. 429 is the
            // per-IP rate limit — a DIFFERENT, honest signal that must never be
            // overloaded to mean "subscription required."
            if code == 402 { return "An active trial or subscription is required. Open Tono to continue." }
            if code == 429 { return "Too many requests right now. Please wait a minute and try again." }
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

public struct TonoVariantResult: Decodable, Equatable {
    public let status: String
    public let axis: String
    public let text: String?
    public let rationale: String?
    public let riskAfter: String?
    public let reason: String?

    private enum CodingKeys: String, CodingKey {
        case status, axis, text, rationale, reason
        case riskAfter = "risk_after"
    }
}

public struct TonoMe: Codable, Equatable {
    public let deviceId: String
    public let plan: String
    public let isPro: Bool
    public let subscriptionStatus: String?
    public let subscriptionRenewsAt: String?
    public let couponProExpiresAt: String?
    // Canonical server-issued account UUID — the only entitlement principal and
    // what a new StoreKit purchase binds as `appAccountToken` (build 91 §1).
    // Decoded as optional purely for robustness against a pre-migration server;
    // the current backend returns it required non-null. `TonoBackend` validates
    // its UUID shape and persists it to `KeychainKeys.accountID`.
    public let accountId: String?
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
        case subscriptionStatus = "subscription_status"
        case subscriptionRenewsAt = "subscription_renews_at"
        case couponProExpiresAt = "coupon_pro_expires_at"
        case accountId = "account_id"
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
    public let plan: String

    enum CodingKeys: String, CodingKey {
        case riskLevel = "risk_level"
        case reason = "risk_reason"
        case perception, subtext, suggestions, flags, plan
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
    /// Build 113: an HTTP failure carried as a status code rather than as
    /// prose. The non-streaming path throws `TonoBackendError.http(code, …)`
    /// and keeps 401, 402 and 429 apart; the streaming path used to stringify
    /// the code into `"Server error (\(code))"` before anything could read it,
    /// so the keyboard strip and the Share sheet collapsed all three into one
    /// "Try again." The status is the only fact a user's next step depends on,
    /// and a sentence is the one shape it must not travel in.
    case failure(status: Int)
    /// Build 117: the request never reached a verdict because the device has no
    /// usable connection. Like `.failure`, this is a SHAPE, not a sentence — it
    /// carries no payload — so a consumer routes it to the same "check your
    /// connection" recovery the non-streaming path already gives (by throwing
    /// `TonoBackendError.offline`), instead of the generic "try again."
    ///
    /// Before this, `analyzeStream`'s terminal catch stringified an offline
    /// `URLError` into `.error(localizedDescription)`; every consumer then
    /// re-wrapped that string as a backend error, which `ConsumerErrorCopy`
    /// maps to `.retry`. So an offline coach on the streaming keyboard/Share
    /// path read "Try again." while the non-streaming path correctly read
    /// "Check your connection…" — the F2-family collapse, for connectivity
    /// rather than HTTP status.
    case offline
}

/// Build 113: a streamed failure reduced to the fact that changes what the
/// user should do next.
///
/// Deliberately carries no message payload. A response body is exactly where
/// hosts, status lines and stack traces live, so this type gives a consumer
/// surface nothing it could render even by accident — `ConsumerErrorCopy`
/// turns the code into a sentence, the same way it does for the
/// non-streaming path.
///
/// It is intentionally *not* a `TonoBackendError`: the streaming callers
/// already catch that type in a branch that re-checks entitlement, and this
/// repair changes which sentence a user reads, not how many requests a tap
/// makes.
public enum StreamedFailure: Error, Equatable {
    case http(status: Int)
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

/// One row of the account's billing timeline. Mirrors the backend
/// PaymentHistoryItem — carries NO raw provider or transaction identifier.
public struct PaymentHistoryItem: Decodable, Identifiable {
    public let id: String
    public let provider: String
    public let productId: String
    public let entitlement: String
    public let ownershipType: String
    public let grantKind: String
    public let entitlementState: String
    public let purchaseState: String
    public let isCurrent: Bool
    public let trialConsumed: Bool
    /// Verified plan price in integer minor units (399 = $3.99), present only
    /// where the provider gave an authoritative normalized amount (Stripe).
    /// Null for providers we don't normalize (Apple/Google) — a client shows a
    /// price only when both this and `currency` are present, never a guess.
    public let amountMinor: Int?
    public let currency: String?
    public let environment: String
    public let effectiveAt: String
    public let expiresAt: String?
    public let revokedAt: String?
    public let createdAt: String
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, provider, entitlement, environment, currency
        case productId = "product_id"
        case ownershipType = "ownership_type"
        case grantKind = "grant_kind"
        case entitlementState = "entitlement_state"
        case purchaseState = "purchase_state"
        case isCurrent = "is_current"
        case trialConsumed = "trial_consumed"
        case amountMinor = "amount_minor"
        case effectiveAt = "effective_at"
        case expiresAt = "expires_at"
        case revokedAt = "revoked_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct PaymentHistoryResponse: Decodable {
    public let accountId: String
    public let plan: String
    public let isPro: Bool
    public let subscriptionStatus: String?
    public let subscriptionRenewsAt: String?
    public let couponProExpiresAt: String?
    public let items: [PaymentHistoryItem]

    enum CodingKeys: String, CodingKey {
        case plan, items
        case accountId = "account_id"
        case isPro = "is_pro"
        case subscriptionStatus = "subscription_status"
        case subscriptionRenewsAt = "subscription_renews_at"
        case couponProExpiresAt = "coupon_pro_expires_at"
    }
}

public struct TonoUsage: Codable {
    public let plan: String
    public let isPro: Bool

    public init(plan: String, isPro: Bool) {
        self.plan = plan
        self.isPro = isPro
    }

    enum CodingKeys: String, CodingKey {
        case plan
        case isPro = "is_pro"
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

        let existingToken = SharedKeychain.get(KeychainKeys.apiToken)
        let existingCredential = SharedKeychain.get(KeychainKeys.deviceCredential)
        if existingToken != nil, existingCredential != nil,
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

        struct Req: Encodable {
            let device_id: String
            let device_credential: String?
            let platform: String
            let app_version: String
        }
        struct Resp: Decodable {
            let device_id: String
            let api_token: String
            let device_credential: String?
            let plan: String
            let is_pro: Bool
            // Required non-null from the account-first backend (build 91 §1).
            let account_id: String?
        }
        let resp: Resp = try await post(
            path: "/v1/register",
            body: Req(
                device_id: did,
                device_credential: existingCredential,
                platform: platform,
                app_version: appVersion
            ),
            authorize: existingToken != nil
        )
        SharedKeychain.set(resp.device_id, forKey: KeychainKeys.deviceID)
        SharedKeychain.set(resp.api_token, forKey: KeychainKeys.apiToken)
        persistAccountID(resp.account_id)
        if let credential = resp.device_credential, !credential.isEmpty {
            SharedKeychain.set(credential, forKey: KeychainKeys.deviceCredential)
        }
        // Wipe any residual plain-text credentials from UserDefaults.
        SharedStore.defaults.removeObject(forKey: SharedKeys.apiKey)
        SharedStore.defaults.removeObject(forKey: SharedKeys.provider)
        SharedStore.defaults.removeObject(forKey: SharedKeys.apiToken)
        SharedStore.defaults.removeObject(forKey: SharedKeys.deviceID)
        return try await me()
    }

    public func me() async throws -> TonoMe {
        let me: TonoMe = try await get(path: "/v1/me")
        persistAccountID(me.accountId)
        return me
    }

    /// Sends StoreKit's Apple-signed JWS to the backend. The backend verifies
    /// it against Apple's signing chain and remains the sole Pro authority; it
    /// returns authoritative `/v1/me`-equivalent state only after a durable
    /// grant/denial commit (build 91 §3/§8).
    public func syncAppStoreSubscription(signedTransactionInfo: String) async throws -> TonoMe {
        struct Req: Encodable {
            let signed_transaction_info: String
        }
        let me: TonoMe = try await post(
            path: "/v1/app-store/subscription",
            body: Req(signed_transaction_info: signedTransactionInfo),
            authorize: true
        )
        persistAccountID(me.accountId)
        return me
    }

    /// Persist the canonical account UUID (build 91 §1) as its own secure
    /// Keychain item — never a `deviceID` alias. Validates the UUID shape and
    /// ignores a malformed/absent value so a degraded response can't clobber a
    /// good stored principal. This is the value `StoreKitManager` binds as the
    /// purchase `appAccountToken`; without it, a new purchase is disabled.
    private func persistAccountID(_ raw: String?) {
        guard let raw, let uuid = UUID(uuidString: raw) else { return }
        SharedKeychain.set(uuid.uuidString, forKey: KeychainKeys.accountID)
    }

    // ── Email identity (Build 114) ─────────────────────────────────────────
    //
    // Build 113 and earlier shipped `requestEmailLink` / `verifyEmailOTP`
    // pointing at `/v1/auth/request-link` and `/v1/auth/verify-otp`. NEITHER
    // endpoint has ever existed on the server, so every one of those calls
    // 404'd. That was not a cosmetic gap: `StoreKitManager.isIdentifiedAccount`
    // requires `KeychainKeys.signedInEmail`, and the only writer of that key
    // was the dead verify path — so `purchase(_:)` refused every purchase on
    // every device. Build 114 replaces the pair with the real endpoints.
    //
    // The whole flow is brokered by the Tono backend, which talks to the auth
    // provider server-side. This app therefore never handles a provider token,
    // a fragment, or a project key — it exchanges an email and password for an
    // ordinary Tono bearer, which is what it already knows how to keep in the
    // Keychain. Verification and reset stay link-based and provider-owned.

    /// Consumer-visible outcomes of an email request. Deliberately a closed
    /// set of SHAPES: the UI switches on these and never on a message, so no
    /// server or provider text can reach a screen.
    public enum EmailAuthOutcome: Equatable {
        /// The request was accepted. Identical for a known and an unknown
        /// address — the server is anti-enumerating and so is this app.
        case checkYourEmail
        /// The address exists but ownership has not been proven yet.
        case verificationRequired
        /// Credentials were rejected.
        case invalidCredentials
        /// Throttled. Wait and retry — never a paywall.
        case rateLimited
        /// The address isn't a usable mailbox, or the password is too short.
        case invalidInput
        /// No usable connection.
        case offline
        /// Email sign-in is down or unconfigured. Never "we sent you an email".
        case serviceUnavailable
        /// The credentials were correct, but the address is already the
        /// verified identity of a DIFFERENT canonical account — a second
        /// provider subject presenting the same spelling. The server refuses
        /// rather than merging, because merging would hand this person someone
        /// else's history and entitlement.
        ///
        /// Reachable ONLY from `/v1/auth/email/login`, and only AFTER the auth
        /// provider accepted the password for this address. Retrying can never
        /// succeed, so collapsing it into `unknownFailure` — "that didn't work,
        /// try again" — left the person in a loop with no exit. It is its own
        /// shape so it can carry its own next step.
        case addressAlreadyLinked
        /// Anything else.
        case unknownFailure

        /// Map a transport failure to an outcome by SHAPE alone.
        static func from(_ error: Error) -> EmailAuthOutcome {
            if let backend = error as? TonoBackendError {
                switch backend {
                case .offline, .network: return .offline
                case .http(let code, _):
                    switch code {
                    case 400:      return .invalidInput
                    case 401:      return .invalidCredentials
                    case 403:      return .verificationRequired
                    case 409:      return .addressAlreadyLinked
                    case 429:      return .rateLimited
                    case 500...599: return .serviceUnavailable
                    default:       return .unknownFailure
                    }
                default: return .unknownFailure
                }
            }
            if let urlError = error as? URLError {
                return Self.offlineCodes.contains(urlError.code) ? .offline : .unknownFailure
            }
            return .unknownFailure
        }

        /// The transport codes that mean "no usable connection" rather than
        /// "the request was answered badly". Mirrors the set
        /// `ConsumerErrorCopy.isOffline` uses, so both surfaces agree about
        /// when it is true to say "check your connection".
        private static let offlineCodes: Set<URLError.Code> = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dataNotAllowed,
            .internationalRoamingOff,
            .secureConnectionFailed,
        ]
    }

    /// Begin an email registration. The provider sends the verification link;
    /// nothing is signed in until it is followed and the person logs in.
    ///
    /// Returns `.checkYourEmail` for both a fresh and an already-registered
    /// address — that is the server's anti-enumerating contract, mirrored here
    /// so the app cannot become an account oracle either.
    @discardableResult
    public func registerWithEmail(email: String, password: String) async throws -> EmailAuthOutcome {
        _ = try await postObject(
            path: "/v1/auth/email/register",
            json: [
                "email": email,
                "password": password,
                "source_surface": "ios",
                "app_version": Self.appBuild,
            ],
            authorize: SharedKeychain.get(KeychainKeys.apiToken) != nil
        )
        return .checkYourEmail
    }

    /// Sign in. On success the backend has already converged this device onto
    /// the ONE canonical account for this person — the same account a web or
    /// Android sign-in resolves — so history and entitlement follow.
    @discardableResult
    public func signInWithEmail(email: String, password: String) async throws -> TonoMe {
        let resp: [String: Any] = try await postObject(
            path: "/v1/auth/email/login",
            json: [
                "email": email,
                "password": password,
                "source_surface": "ios",
                "app_version": Self.appBuild,
            ],
            authorize: SharedKeychain.get(KeychainKeys.apiToken) != nil
        )
        if let deviceID = resp["device_id"] as? String, !deviceID.isEmpty {
            SharedKeychain.set(deviceID, forKey: KeychainKeys.deviceID)
        }
        if let token = resp["api_token"] as? String, !token.isEmpty {
            SharedKeychain.set(token, forKey: KeychainKeys.apiToken)
        }
        if let credential = resp["device_credential"] as? String, !credential.isEmpty {
            SharedKeychain.set(credential, forKey: KeychainKeys.deviceCredential)
        }
        persistAccountID(resp["account_id"] as? String)
        // `signedInEmail` is what `StoreKitManager.isIdentifiedAccount` reads,
        // so it is written ONLY here — after the server confirmed a verified
        // identity. Writing it earlier would let an unverified device buy.
        if let verified = resp["email_verified"] as? Bool, verified,
           let address = resp["email"] as? String, !address.isEmpty {
            SharedKeychain.set(address, forKey: KeychainKeys.signedInEmail)
            SharedKeychain.set("true", forKey: KeychainKeys.hasRecoveryIdentity)
        }
        return try await me()
    }

    public func signInWithApple(identityToken: String, nonce: String) async throws -> TonoMe {
        try await signInWithNativeProvider(
            path: "/v1/auth/apple",
            payload: ["identity_token": identityToken, "nonce": nonce, "link": false]
        )
    }

    public func signInWithGoogle(idToken: String) async throws -> TonoMe {
        try await signInWithNativeProvider(
            path: "/v1/auth/google", payload: ["id_token": idToken, "link": false]
        )
    }

    private func signInWithNativeProvider(
        path: String, payload: [String: Any]
    ) async throws -> TonoMe {
        _ = try await registerIfNeeded(platform: "ios", appVersion: Self.appBuild)
        let response: [String: Any] = try await postObject(
            path: path, json: payload, authorize: true
        )
        persistAccountID(response["account_id"] as? String)
        SharedKeychain.set("true", forKey: KeychainKeys.hasRecoveryIdentity)
        if let address = response["email"] as? String, !address.isEmpty {
            SharedKeychain.set(address, forKey: KeychainKeys.signedInEmail)
        }
        return try await me()
    }

    /// Resend the verification link. Anti-enumerating, like register.
    @discardableResult
    public func resendVerification(email: String) async throws -> EmailAuthOutcome {
        _ = try await postObject(
            path: "/v1/auth/email/resend",
            json: ["email": email, "source_surface": "ios", "app_version": Self.appBuild],
            authorize: false
        )
        return .checkYourEmail
    }

    /// Begin password recovery. Anti-enumerating, like register.
    @discardableResult
    public func requestPasswordReset(email: String) async throws -> EmailAuthOutcome {
        _ = try await postObject(
            path: "/v1/auth/email/reset",
            json: ["email": email, "source_surface": "ios", "app_version": Self.appBuild],
            authorize: false
        )
        return .checkYourEmail
    }

    /// Sign this device out. The server rotates the bearer, so the credential
    /// this app holds stops working immediately; the canonical account and its
    /// entitlement are untouched on the server, and signing back in returns the
    /// person to exactly the same account.
    ///
    /// EVERY device secret goes, not just the bearer. Dropping the bearer alone
    /// is not a sign-out: `registerIfNeeded` re-presents the stored
    /// `deviceCredential` for the stored `deviceID`, the server recognises that
    /// pair as the same device row, and the next person to open the app lands
    /// back in the previous person's account — history, style memory and Pro
    /// included. Clearing the device identity means the app comes back as a
    /// fresh anonymous device, and only an email sign-in can reach the account
    /// again.
    ///
    /// Local state is cleared even if the network call fails: a person on a bad
    /// connection must still be able to sign out of a shared device.
    public func signOut() async {
        _ = try? await postObject(path: "/v1/auth/email/logout", json: [:], authorize: true)
        SharedKeychain.delete(KeychainKeys.apiToken)
        SharedKeychain.delete(KeychainKeys.signedInEmail)
        SharedKeychain.delete(KeychainKeys.hasRecoveryIdentity)
        SharedKeychain.delete(KeychainKeys.accountID)
        SharedKeychain.delete(KeychainKeys.deviceCredential)
        SharedKeychain.delete(KeychainKeys.deviceID)
        // Account-switch isolation: wipe this device's personal content caches
        // (drafts, learned style, memory facts, recipients) so the next person
        // to sign in on a shared device never inherits them. The canonical
        // account still owns everything server-side. The keyboard/share/iMessage
        // extensions read the same App Group, so clearing here clears them too.
        SharedStore.clearPersonalData()
    }

    /// The address this device is signed in as, or `nil` when anonymous.
    ///
    /// Read by Settings so it can describe the account truthfully. Written only
    /// by `signInWithEmail`, after the server confirmed a verified identity —
    /// so a `nil` here and a refused purchase are always the same fact.
    public var signedInEmailAddress: String? {
        guard let address = SharedKeychain.get(KeychainKeys.signedInEmail),
              !address.isEmpty else { return nil }
        return address
    }

    /// The shipped build number, used as the audit tag on registration events.
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
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

    /// Fail-closed probe of whether the live backend can honor an Apple StoreKit
    /// purchase, read from the existing `/health` contract's `apple_configured`
    /// boolean. NEVER throws: every transport or contract failure folds to a
    /// non-`.ready` verdict, because a charge must not be initiated on doubt.
    ///
    /// This is the initiation-time capability the purchase gate consults BEFORE
    /// `product.purchase(...)`. Post-payment `/v1/me` reconciliation cannot
    /// refund a charge, so it is not a substitute for this check. Uses the same
    /// short-timeout GET as `health()`; only the body interpretation differs.
    public func fetchApplePurchaseCapability() async -> ApplePurchaseCapability {
        guard let url = URL(string: "/health", relativeTo: baseURL) else {
            return .unavailable
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode
            return PurchaseCapabilityGate.evaluate(httpStatus: status, body: data)
        } catch {
            return .unavailable
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
        let response: TonoAnalysisResponse = try await post(
            path: "/api/analyze", body: req, authorize: true
        )
        if mode == .coach {
            let axes = response.suggestions.map(\.axis)
            guard axes == RewriteAxis.allCases.map(\.rawValue) else {
                throw TonoBackendError.network("incomplete Coach response")
            }
        }
        return response
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
        public let plan: String?
        public init(rewrites: [CoachRewrite], plan: String? = nil) {
            self.rewrites = rewrites
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
        let canonicalAxes = ["warmer", "clearer", "funnier", "safer"]
        func canonicalize(_ raw: [CoachRewrite]) -> [CoachRewrite]? {
            var byAxis: [String: CoachRewrite] = [:]
            for rewrite in raw {
                let axis = rewrite.axis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var text = rewrite.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard canonicalAxes.contains(axis), byAxis[axis] == nil else { return nil }
                let label = "\(axis):"
                if text.lowercased().hasPrefix(label) {
                    text = String(text.dropFirst(label.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !text.isEmpty else { return nil }
                byAxis[axis] = CoachRewrite(
                    axis: axis,
                    text: text,
                    rationale: rewrite.rationale,
                    riskAfter: rewrite.riskAfter
                )
            }
            guard raw.count == canonicalAxes.count else { return nil }
            return canonicalAxes.compactMap { byAxis[$0] }.count == canonicalAxes.count
                ? canonicalAxes.compactMap { byAxis[$0] }
                : nil
        }
        let (data, response) = try await postRaw(path: "/v1/coach", body: req, authorize: true)
        guard let http = response as? HTTPURLResponse else {
            throw TonoBackendError.network("no http response")
        }
        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            // 402 = entitlement required (server gate); 429 = per-IP rate limit.
            // Keep them distinct — 429 is NOT "subscription required".
            if http.statusCode == 402 {
                throw TonoBackendError.http(402, "Active trial or subscription required.")
            }
            if http.statusCode == 429 {
                throw TonoBackendError.http(429, "Too many requests. Please wait a minute and try again.")
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
            guard let rewrites = canonicalize(parsed.rewrites) else {
                throw TonoBackendError.network("incomplete Coach response")
            }
            let canonical = CoachResponse(
                rewrites: rewrites,
                plan: parsed.plan
            )
            return String(data: try JSONEncoder().encode(canonical), encoding: .utf8) ?? ""
        }
        if let loose = try? JSONDecoder().decode(Resp.self, from: data) {
            guard let rewrites = canonicalize(loose.rewrites ?? loose.suggestions ?? []) else {
                throw TonoBackendError.network("incomplete Coach response")
            }
            let canonical = CoachResponse(
                rewrites: rewrites,
                plan: loose.analysis?.plan
            )
            return String(data: try JSONEncoder().encode(canonical), encoding: .utf8) ?? ""
        }
        throw TonoBackendError.network("invalid Coach response")
    }

    /// True when a caught error means "no usable connection" rather than "the
    /// request was answered badly". The streaming producer classifies by SHAPE
    /// here — never by the error's message — so it can hand a payload-free
    /// `.offline` event downstream instead of a stringified `URLError`.
    ///
    /// The URLError set mirrors `ConsumerErrorCopy.isOffline` and
    /// `EmailAuthOutcome.offlineCodes` so every Tono surface agrees about when
    /// it is true to say "check your connection". Kept in sync by
    /// `Build117StreamingOfflineContractTests`.
    static func isOfflineTransport(_ error: Error) -> Bool {
        if let backend = error as? TonoBackendError, case .offline = backend { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dataNotAllowed,
             .internationalRoamingOff,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
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
                        // Build 113: hand on the status, not a sentence about
                        // it. Stringifying here is what lost the 401 / 402 /
                        // 429 distinction on every streaming surface.
                        continuation.yield(.failure(status: code))
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
                    // Hand on the SHAPE of a connectivity failure, not a
                    // stringified URLError (whose localizedDescription can name
                    // the host). Offline → the honest "check your connection"
                    // recovery; anything else stays the neutral prose the
                    // consumers already route through ConsumerErrorCopy.
                    if TonoBackend.isOfflineTransport(error) {
                        continuation.yield(.offline)
                    } else {
                        continuation.yield(.error(error.localizedDescription))
                    }
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

    /// The signed-in account's own payment/subscription timeline. Owner-scoped
    /// server-side by the bearer's account — there is no account-id parameter,
    /// so this device can only ever read its own account's billing.
    public func paymentHistory() async throws -> PaymentHistoryResponse {
        try await get(path: "/v1/account/payment-history")
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

    // MARK: - Account deletion (build 101)

    /// Permanently deletes the canonical server account bound to the current
    /// bearer token. Client contract (backend endpoint not yet deployed on this
    /// branch; URLProtocol tests in Build101RevenueTests validate the shape):
    ///
    ///   DELETE /v1/account
    ///   Authorization: Bearer <api_token>
    ///   → 200 {} — account deleted; caller must purge local secrets
    ///   → 401    — token expired/invalid; caller shows re-auth prompt
    ///   → 404    — account already deleted (idempotent OK for the caller)
    ///   → 500    — server error; do NOT purge secrets; surface support path
    ///
    /// On success the caller is responsible for:
    ///   1. `SharedKeychain.purgeAccountSecrets()` — remove all server tokens
    ///   2. `StoreKitManager.shared.resetToAnonymous()` — clear entitlement
    ///   3. `TonePreferences.recordEntitlement(.notEntitled, isPro: false)`
    ///   4. Navigate the user to the root/sign-in state
    public func deleteAccount() async throws {
        struct EmptyResp: Decodable {}
        let _: EmptyResp = try await delete(path: "/v1/account")
    }

    public func isRegistered() -> Bool {
        SharedKeychain.get(KeychainKeys.apiToken)?.isEmpty == false
    }

    /// One selected tone chip maps to one authenticated backend request.
    /// Blocked/no-op envelopes remain explicit so extension UIs cannot render
    /// the source draft as a successful rewrite.
    public func analyzeVariant(
        text: String,
        axis: String,
        customPrompt: String? = nil
    ) async throws -> TonoVariantResult {
        struct Req: Encodable {
            let text: String
            let axis: String
            let custom_prompt: String?
        }
        return try await post(
            path: "/api/analyze/variant",
            body: Req(text: text, axis: axis, custom_prompt: customPrompt),
            authorize: true
        )
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
    /// Used for the `/v1/auth/email/*` endpoints, whose responses differ by
    /// operation (an accepted registration carries no session; a login carries
    /// a whole one) and which are read field-by-field rather than decoded into
    /// one shape.
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet {
            throw TonoBackendError.offline
        } catch let urlError as URLError {
            throw TonoBackendError.network(urlError.localizedDescription)
        } catch {
            throw TonoBackendError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TonoBackendError.network("no response")
        }
        if !(200...299).contains(http.statusCode) {
            // Decode the error body — server returns {"detail": {...}} for our
            // 403 too_many_devices, or {"detail": "..."} for 401.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let detail = obj["detail"] ?? obj["error"]
                if let dict = detail as? [String: Any], let err = dict["error"] as? String {
                    if err == "too_many_devices",
                       let cur = dict["current"] as? Int,
                       let max = dict["max"] as? Int {
                        throw TonoBackendError.tooManyDevices(current: cur, max: max)
                    }
                }
                if let dict = detail as? [String: Any], let message = dict["message"] as? String {
                    throw TonoBackendError.http(http.statusCode, message)
                }
                if let message = detail as? String {
                    throw TonoBackendError.http(http.statusCode, message)
                }
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

    private func delete<Out: Decodable>(path: String) async throws -> Out {
        let req = try buildRequest(path: path, method: "DELETE", body: Optional<EmptyBody>.none, authorize: true)
        return try await execute(req)
    }

    /// Build 117 — relaxed from `private` to module-internal, and NOTHING else
    /// about it changed. `ReadTheAsk.swift` builds its request with this exact
    /// function so the new path inherits the bearer, the content type, the
    /// timeout and the `notRegistered` gate rather than growing a second,
    /// slightly-different copy of them.
    func buildRequest<In: Encodable>(
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

    /// Build 117 — relaxed from `private` to module-internal for the same
    /// reason `buildRequest` was. Read the Ask needs the 401 / 402 / 429
    /// distinction this function preserves; re-implementing it beside this one
    /// is how that distinction gets lost again.
    func execute<Out: Decodable>(_ req: URLRequest) async throws -> Out {
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
        struct Inner: Decodable { let message: String }
        let error: Inner
    }
}
