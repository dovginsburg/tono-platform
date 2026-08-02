// verify_apple_intelligence_routing.swift
//
// Focused source tests for the Apple Intelligence provider abstraction and the
// routing seam. Compiles the REAL shared sources with `swiftc` — no Xcode, no
// Simulator, no FoundationModels, no AppIntents, no network — and exercises the
// pure `RewriteProviderKind` / `RewriteProviderRouter` / `PCCAvailability`
// types. Because it links the production source directly, these assertions
// cannot drift from shipping code.
//
// Covers the reviewer's checklist:
//   * provider privacy properties (what leaves the device)
//   * PCC availability is fail-closed (unknown/unsupported/entitlementMissing/
//     runtimeUnavailable are all "not available"; only .available is)
//   * routing: Safer stays on backend unless the corpus gate is open
//   * routing: Funnier is the on-device Apple spike
//   * routing: no fan-out (one primary; ordered chain is distinct; most private
//     first; backend last)
//   * routing: the on-device-only promise forbids PCC and backend (PCC leaves
//     the device too), and yields terminal when no local engine can serve
//   * routing: fail-closed — unknown PCC is never chosen; kill switch / opt-out
//     / unavailable model all fall to the proven backend or a terminal refusal
//
// Usage:  swiftc -o /tmp/verify_ai_routing \
//            Shared/RewriteProvider.swift Shared/PrivateCloudCompute.swift \
//            Shared/LocalCoachRewrite.swift \
//            Scripts/verify_apple_intelligence_routing.swift && /tmp/verify_ai_routing
// Exit 0 = all pass; 1 = at least one failure (details on stderr).

import Foundation

var failures: [String] = []
var checks = 0

func check(_ cond: Bool, _ label: String) {
    checks += 1
    if !cond { failures.append(label) }
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    checks += 1
    if a != b { failures.append("\(label): got \(a), want \(b)") }
}

let router = RewriteProviderRouter() // default spike: [.funnier]

func decide(
    _ axis: String,
    kill: Bool = true,
    pref: LocalRewritePreference = .unset,
    onDevice: LocalRewriteAvailability = .available,
    pcc: PCCAvailability = .unknown,
    saferGate: Bool = false,
    offline: Bool = false
) -> RewriteRoutingDecision {
    router.decide(
        requestedAxis: axis,
        remoteKillSwitchAllows: kill,
        preference: pref,
        onDeviceAvailability: onDevice,
        pccAvailability: pcc,
        saferCorpusGateOpen: saferGate,
        connectivityKnownAbsent: offline
    )
}

@main
struct VerifyAIRouting {
static func main() {

// ---------------------------------------------------------------------------
// 1. Provider privacy properties — what leaves the device.
// ---------------------------------------------------------------------------
expectEqual(RewriteProviderKind.appleOnDevice.leavesDevice, false, "on-device never leaves the device")
expectEqual(RewriteProviderKind.applePrivateCloudCompute.leavesDevice, true,
            "PCC leaves the device (private cloud is still off-device)")
expectEqual(RewriteProviderKind.tonoBackend.leavesDevice, true, "backend leaves the device")
expectEqual(RewriteProviderKind.appleOnDevice.isAppleIntelligence, true, "on-device is Apple Intelligence")
expectEqual(RewriteProviderKind.applePrivateCloudCompute.isAppleIntelligence, true, "PCC is Apple Intelligence")
expectEqual(RewriteProviderKind.tonoBackend.isAppleIntelligence, false, "backend is not Apple Intelligence")

// RoutePlan can never encode a fan-out or a duplicate.
let plan = RewriteRoutePlan(primary: .appleOnDevice, fallbacks: [.appleOnDevice, .tonoBackend, .tonoBackend])
expectEqual(plan.ordered, [.appleOnDevice, .tonoBackend], "route plan de-dupes primary + fallbacks")

// ---------------------------------------------------------------------------
// 2. PCC availability is fail-closed.
// ---------------------------------------------------------------------------
for a in PCCAvailability.allCases where a != .available {
    check(!a.isAvailable, "\(a) is not available (fail-closed)")
}
check(PCCAvailability.available.isAvailable, "only .available is available")
// The production probe fails closed on this toolchain (no TONO_PCC_XCODE27).
expectEqual(DefaultPCCAvailabilityProbe().probe(), .unsupportedOS,
            "default PCC probe is .unsupportedOS on Xcode 26.5")
expectEqual(StaticPCCAvailabilityProbe(.available).probe(), .available, "static probe returns its value")
check(!PCCEntitlement.isGrantedInThisBuild, "PCC entitlement is not granted in this build")

// ---------------------------------------------------------------------------
// 3. Safer stays on the backend unless the corpus gate is open.
// ---------------------------------------------------------------------------
let saferClosed = decide("safer", onDevice: .available, saferGate: false)
expectEqual(saferClosed.primaryProvider, .tonoBackend, "Safer (gate closed) → backend primary")
check(!saferClosed.orderedProviders.contains(.appleOnDevice), "Safer (gate closed) never routes on-device")
check(!saferClosed.orderedProviders.contains(.applePrivateCloudCompute), "Safer (gate closed) never routes PCC")

let saferOpen = decide("safer", onDevice: .available, saferGate: true)
expectEqual(saferOpen.primaryProvider, .appleOnDevice, "Safer (gate open) → on-device primary")

// ---------------------------------------------------------------------------
// 4. Funnier is the on-device Apple spike; other axes are not (by default).
// ---------------------------------------------------------------------------
let funnier = decide("funnier", onDevice: .available)
expectEqual(funnier.primaryProvider, .appleOnDevice, "Funnier → on-device primary (the spike)")
expectEqual(funnier.orderedProviders, [.appleOnDevice, .tonoBackend],
            "Funnier chain is on-device then backend fallback")

let warmer = decide("warmer", onDevice: .available)
expectEqual(warmer.primaryProvider, .tonoBackend, "Warmer is not in the default spike → backend primary")
check(!warmer.orderedProviders.contains(.appleOnDevice), "Warmer does not lead on-device by default")

// A widened spike set proves the axis gate is the only thing holding Warmer back.
let widened = RewriteProviderRouter(appleOnDeviceSpikeAxes: [.funnier, .warmer])
let warmerWide = widened.decide(
    requestedAxis: "warmer", remoteKillSwitchAllows: true, preference: .unset,
    onDeviceAvailability: .available, pccAvailability: .unknown,
    saferCorpusGateOpen: false, connectivityKnownAbsent: false
)
expectEqual(warmerWide.primaryProvider, .appleOnDevice, "Warmer leads on-device once added to the spike set")

// ---------------------------------------------------------------------------
// 5. No fan-out, and ordering is most-private-first / backend-last.
// ---------------------------------------------------------------------------
for axis in ["safer", "warmer", "clearer", "funnier", "custom"] {
    for pcc in PCCAvailability.allCases {
        for onDevice in [LocalRewriteAvailability.available, .deviceNotEligible] {
            let d = decide(axis, onDevice: onDevice, pcc: pcc, saferGate: true)
            let ordered = d.orderedProviders
            if case .route = d {
                check(Set(ordered).count == ordered.count, "no duplicate provider in \(axis)/\(pcc)/\(onDevice)")
                check(!ordered.isEmpty, "a route has at least one provider (\(axis)/\(pcc)/\(onDevice))")
                if let apple = ordered.firstIndex(of: .appleOnDevice) {
                    expectEqual(apple, 0, "on-device is most-private-first for \(axis)/\(pcc)/\(onDevice)")
                }
                if let backend = ordered.firstIndex(of: .tonoBackend) {
                    expectEqual(backend, ordered.count - 1, "backend is last for \(axis)/\(pcc)/\(onDevice)")
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 6. The on-device-only promise forbids PCC and the backend.
// ---------------------------------------------------------------------------
let onlyLocalOK = decide("funnier", pref: .onlyOnDevice, onDevice: .available)
expectEqual(onlyLocalOK.orderedProviders, [.appleOnDevice],
            "on-device-only + available → on-device ONLY, no fallback")

// Even with PCC 'available', on-device-only must not use it — PCC leaves device.
let onlyLocalPCC = decide("funnier", pref: .onlyOnDevice, onDevice: .deviceNotEligible, pcc: .available)
if case .terminal = onlyLocalPCC {
    check(true, "on-device-only forbids PCC even when PCC is available")
} else {
    check(false, "on-device-only must be terminal when only off-device engines remain (got \(onlyLocalPCC))")
}

let onlyLocalUnavailable = decide("funnier", pref: .onlyOnDevice, onDevice: .appleIntelligenceNotEnabled)
if case .terminal(let reason) = onlyLocalUnavailable {
    expectEqual(reason, .appleIntelligenceNotEnabled, "on-device-only terminal names the availability reason")
} else {
    check(false, "on-device-only with an unavailable model is terminal")
}

// ---------------------------------------------------------------------------
// 7. Fail-closed — kill switch, opt-out, unavailable model all fall back safely.
// ---------------------------------------------------------------------------
expectEqual(decide("funnier", kill: false, onDevice: .available).primaryProvider, .tonoBackend,
            "kill switch off → no Apple engine, backend primary")
expectEqual(decide("funnier", pref: .off, onDevice: .available).primaryProvider, .tonoBackend,
            "explicit opt-out → no Apple engine, backend primary")
expectEqual(decide("funnier", onDevice: .deviceNotEligible).primaryProvider, .tonoBackend,
            "on-device unavailable → backend primary")

// PCC is chosen ONLY when the seam proves it available, and never otherwise.
let pccPath = decide("funnier", onDevice: .deviceNotEligible, pcc: .available)
expectEqual(pccPath.primaryProvider, .applePrivateCloudCompute,
            "on-device unavailable + PCC available → PCC primary")
expectEqual(pccPath.orderedProviders, [.applePrivateCloudCompute, .tonoBackend],
            "PCC leads, backend is the fallback")
for pcc in PCCAvailability.allCases where pcc != .available {
    let d = decide("funnier", onDevice: .deviceNotEligible, pcc: pcc)
    check(!d.orderedProviders.contains(.applePrivateCloudCompute),
          "PCC (\(pcc)) is never chosen unless .available")
}

// ---------------------------------------------------------------------------
// 8. Offline: only on-device can run; a non-local axis is terminal.
// ---------------------------------------------------------------------------
let offlineFunnier = decide("funnier", onDevice: .available, offline: true)
expectEqual(offlineFunnier.orderedProviders, [.appleOnDevice],
            "offline + on-device available → on-device only, no backend fallback")
let offlineWarmer = decide("warmer", onDevice: .available, offline: true)
if case .terminal(let r) = offlineWarmer {
    expectEqual(r, .toneNeedsConnection, "offline + non-spike axis → terminal toneNeedsConnection")
} else {
    check(false, "offline + non-spike axis with no network should be terminal")
}
let offlineCustom = decide("custom", onDevice: .available, offline: true)
if case .terminal(let r) = offlineCustom {
    expectEqual(r, .customStyleNeedsConnection, "offline + custom → terminal customStyleNeedsConnection")
} else {
    check(false, "offline + custom with no network should be terminal")
}

// ---------------------------------------------------------------------------
if failures.isEmpty {
    print("PASS: Apple Intelligence routing focused source tests (\(checks) checks)")
    exit(0)
} else {
    FileHandle.standardError.write(Data(("FAIL (\(failures.count)/\(checks)):\n  - "
        + failures.joined(separator: "\n  - ") + "\n").utf8))
    exit(1)
}
}
}
