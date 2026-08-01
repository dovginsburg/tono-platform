// PrivateCloudCompute.swift
// Apple Intelligence readiness — the Private Cloud Compute (PCC) routing seam.
//
// HONEST FRAMING FIRST. As of the iOS 26.5 SDK (Xcode 26.5, the installed
// stable toolchain), there is NO developer-addressable Private Cloud Compute
// rewrite API. `SystemLanguageModel` (Foundation Models) is the on-device
// surface; Apple may route some system requests to PCC transparently, but an
// app cannot itself target PCC through a documented public symbol. Pretending
// otherwise — by guessing a symbol name or hard-coding a model — is exactly the
// kind of fabricated capability this codebase refuses to ship.
//
// So this file implements the SEAM and the STATES, fail-closed, and quarantines
// any real Xcode-27 wiring behind a compile condition (`TONO_PCC_XCODE27`) that
// the checked-in project never defines. The seam is fully testable today: it
// reports the truth, which is "not available", and the router treats that
// exactly as it treats an unavailable on-device model.
//
// Nothing here transmits text, grants an entitlement, or mutates an Apple
// account. It only answers a yes/no availability question, and today the honest
// answer is no.

import Foundation

// MARK: - Availability states (fail-closed)

/// What the PCC seam reports about itself.
///
/// The default a caller should assume, and the value the production probe
/// returns on the current toolchain, is anything BUT `.available`. Every
/// non-`.available` case is a distinct, honest reason — there is no "unknown =
/// maybe yes" state, because the whole contract is fail-closed.
public enum PCCAvailability: String, Codable, Sendable, CaseIterable, Equatable {
    /// Not yet probed / no basis to claim anything. Treated as unavailable.
    case unknown
    /// The running SDK/OS exposes no PCC-capable developer surface (today's
    /// truth on iOS 26.5).
    case unsupportedOS
    /// A PCC surface exists, but the app/device lacks the entitlement that would
    /// authorize it. Fail-closed: no entitlement, no PCC.
    case entitlementMissing
    /// Entitled, but the runtime reports PCC not usable at this moment.
    case runtimeUnavailable
    /// Proven usable this instant. The ONLY case the router may act on.
    case available

    /// The single gate. Only an explicit `.available` counts.
    public var isAvailable: Bool { self == .available }

    /// A privacy-safe reason string for metrics/breadcrumbs (never text).
    public var reasonCode: String { rawValue }
}

// MARK: - The probe seam

/// Reports PCC availability WITHOUT generating anything or sending any text.
///
/// The seam exists so the routing decision can be driven deterministically in a
/// unit test (inject a probe that returns `.available`) while the shipping build
/// uses `DefaultPCCAvailabilityProbe`, which fails closed on the current
/// toolchain.
public protocol PCCAvailabilityProbing: Sendable {
    func probe() -> PCCAvailability
}

/// A fixed-answer probe. Used by tests to exercise every branch of the router,
/// and available to callers that already know the answer.
public struct StaticPCCAvailabilityProbe: PCCAvailabilityProbing {
    public let value: PCCAvailability
    public init(_ value: PCCAvailability) { self.value = value }
    public func probe() -> PCCAvailability { value }
}

/// The production probe.
///
/// On Xcode 26.5 it returns `.unsupportedOS` — there is no public PCC rewrite
/// API to interrogate, so it says so rather than guessing. When (and only when)
/// a build defines `TONO_PCC_XCODE27`, it delegates to the quarantined adapter
/// below, which is itself still fail-closed until a confirmed SDK symbol fills
/// it in.
public struct DefaultPCCAvailabilityProbe: PCCAvailabilityProbing {
    public init() {}

    public func probe() -> PCCAvailability {
        #if TONO_PCC_XCODE27
        return TonoPCCXcode27Adapter.probe()
        #else
        // iOS 26.5 SDK: no developer-addressable Private Cloud Compute surface.
        // Fail closed and say why.
        return .unsupportedOS
        #endif
    }
}

// MARK: - Xcode 27 integration point (quarantined, NOT active)

#if TONO_PCC_XCODE27
/// XCODE-27 INTEGRATION POINT — compiled ONLY when the build explicitly defines
/// `TONO_PCC_XCODE27`, which the checked-in `project.pbxproj` never does.
///
/// This block deliberately references NO SDK symbol that has not been confirmed
/// present. Guessing an availability API name here is how a build breaks, or —
/// far worse — how a fabricated "PCC is available" ships. So even when enabled,
/// this returns fail-closed until a human replaces the body with a CONFIRMED
/// query.
///
/// EXACT REMAINING PROOF (do not mark PCC_RUNTIME_VERIFIED without all of it):
///   1. Install the first toolchain that ships a developer-addressable Private
///      Cloud Compute Foundation Models surface (expected: Xcode 27 / iOS 27
///      SDK). Confirm the concrete availability symbol EXISTS — read the SDK
///      headers or probe with `swift -e` — do NOT assume a name from a WWDC
///      slide or a memory of one.
///   2. Replace the body below with that confirmed availability query and map
///      its states onto `PCCAvailability`. Never hard-code an informal model
///      name; ask the API what it supports.
///   3. Add the PCC entitlement to `App/Tono.entitlements`, prove it is granted
///      on a physical device (PCC_ENTITLEMENT_GRANTED), and prove a real request
///      succeeds end-to-end (PCC_RUNTIME_VERIFIED). Only then may this return
///      `.available`.
enum TonoPCCXcode27Adapter {
    static func probe() -> PCCAvailability {
        // No confirmed symbol yet → fail closed. Intentional and honest.
        return .runtimeUnavailable
    }
}
#endif

// MARK: - Entitlement inspection (source-declared, not runtime-granted)

/// The identifier a future PCC entitlement would carry. Declared as a constant
/// so tests and docs can name the exact key, and so nothing anywhere hard-codes
/// a guessed string inline. It is NOT added to `Tono.entitlements` — granting an
/// entitlement is explicitly out of scope, and a source constant is not a grant.
public enum PCCEntitlement {
    /// Placeholder identifier. The REAL key must come from Apple's PCC
    /// documentation once it exists; until then this is a named unknown, not a
    /// claim that this string is correct.
    public static let candidateIdentifier = "com.apple.developer.private-cloud-compute"

    /// Whether the running process actually carries the entitlement.
    ///
    /// Fail-closed and honest: with no confirmed key and no grant, the answer is
    /// always `false` on the current toolchain. A source constant naming a key
    /// is not evidence the key is real or granted.
    public static var isGrantedInThisBuild: Bool { false }
}
