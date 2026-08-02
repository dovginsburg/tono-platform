// PurchaseCapability.swift
// Tono build 122 — the fail-closed Apple purchase-initiation capability contract.
//
// Build 121 was quarantined because the app could reach `product.purchase(...)`
// while the LIVE backend reported `apple_configured: false`: Apple took the
// money and the backend could not verify or honor the transaction, leaving a
// charged user without Pro. The fix is an INITIATION-time gate — a charge may
// never start unless the backend readiness contract is a well-formed, explicit
// `true`. A later `/v1/me` entitlement reconciliation cannot refund a charge,
// so it is not a substitute.
//
// This file is deliberately dependency-free (Foundation only) so the pure gate
// can be compiled into every shipping target AND the test target, and pinned by
// red-capable deterministic tests without a network, a secret, or a simulated
// production success.

import Foundation

/// Fail-closed verdict on whether the LIVE backend can actually verify and honor
/// an Apple StoreKit purchase, read from the existing `/health` contract's
/// `apple_configured` boolean (true iff the server holds `TONO_APPLE_ROOT_CA_PEM`
/// to validate Apple-signed transactions).
///
/// The ONLY state that permits initiating a charge is `.ready`; every other
/// state — including "could not tell" — refuses, because a charge cannot be
/// undone by a later reconciliation.
public enum ApplePurchaseCapability: Equatable, Sendable {
    /// Not probed yet. Fail-closed: no charge may start from this state.
    case unknown
    /// Backend reported a well-formed `apple_configured: true`. The only state
    /// that permits initiating an Apple charge.
    case ready
    /// Backend reported `apple_configured: false` — it cannot honor an Apple
    /// charge. This is the exact live condition that quarantined Build 121.
    case notConfigured
    /// The readiness contract could not be reached (offline / DNS / TLS /
    /// timeout / non-2xx). Configuration is unknown, so no charge may start.
    case unavailable
    /// The readiness response was received but carried no boolean
    /// `apple_configured` (missing key, wrong type, or non-JSON) — a renamed,
    /// typo'd, or otherwise unrecognized contract. Refused, never assumed true.
    case malformed

    /// Fail-closed: only an explicit, well-formed `true` permits a charge.
    public var allowsPurchaseInitiation: Bool { self == .ready }
}

/// Pure, total interpretation of an observed `/health` result into a fail-closed
/// `ApplePurchaseCapability`. No I/O and no globals, so a red-capable test can
/// pin every branch deterministically.
public enum PurchaseCapabilityGate {
    private struct HealthCapability: Decodable {
        let appleConfigured: Bool
        enum CodingKeys: String, CodingKey { case appleConfigured = "apple_configured" }
    }

    /// - Parameters:
    ///   - httpStatus: the status the readiness request returned, or `nil` when
    ///     the transport itself failed before any response arrived.
    ///   - body: the response body, or `nil` when none was received.
    public static func evaluate(httpStatus: Int?, body: Data?) -> ApplePurchaseCapability {
        guard let status = httpStatus, (200...299).contains(status), let data = body else {
            return .unavailable
        }
        guard let decoded = try? JSONDecoder().decode(HealthCapability.self, from: data) else {
            // Missing key, wrong type (a `"true"` string or a `1` number), or a
            // body that is not JSON at all — anything but a real JSON boolean is
            // refused as malformed, never coerced into a `true`.
            return .malformed
        }
        return decoded.appleConfigured ? .ready : .notConfigured
    }
}
