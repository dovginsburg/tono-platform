// verify_tone_variant_config.swift
//
// Focused source tests for the local-only "Set Tono Tone Variant" App Intent's
// pure policy (`ToneVariantConfiguration`, in Shared/CoachVariantSettings.swift).
// Compiles the REAL shared contract with `swiftc` — no Xcode, no AppIntents, no
// network — so the intent's behaviour is pinned without a device.
//
// Covers:
//   * Safer is always on and cannot be toggled (no change)
//   * enabling / disabling an optional tone changes the device-local selection
//   * idempotent requests report already-on / already-off and change nothing
//   * the two-optional cap is honoured (a third enable is refused, unchanged)
//   * Custom cannot be enabled without a valid stored directive
//   * an unknown axis is refused, unchanged
//   * `didChange` is true ONLY for a real enable/disable (the intent persists
//     exactly when this is true — never claiming a change it did not make)
//   * every outcome has a truthful, non-empty message
//
// Usage:  swiftc -o /tmp/verify_tone_variant \
//            Shared/CoachVariantSettings.swift \
//            Scripts/verify_tone_variant_config.swift && /tmp/verify_tone_variant
// Exit 0 = all pass; 1 = at least one failure (details on stderr).

import Foundation

var failures: [String] = []
var checks = 0
func check(_ cond: Bool, _ label: String) { checks += 1; if !cond { failures.append(label) } }
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    checks += 1
    if a != b { failures.append("\(label): got \(a), want \(b)") }
}

typealias Outcome = ToneVariantConfiguration.Outcome

func apply(_ enable: Bool, _ axis: String, _ settings: CoachVariantSettings)
    -> (CoachVariantSettings, Outcome) {
    ToneVariantConfiguration.apply(enable: enable, variantAxis: axis, to: settings)
}

@main
struct VerifyToneVariant {
static func main() {

// ---------------------------------------------------------------------------
// 1. Safer is always on — never toggled.
// ---------------------------------------------------------------------------
let base = CoachVariantSettings(enabled: [.clearer, .funnier])
let (saferSettings, saferOutcome) = apply(false, "safer", base)
expectEqual(saferOutcome, .saferIsAlwaysOn, "disabling Safer → saferIsAlwaysOn")
expectEqual(saferSettings.enabled, base.enabled, "Safer request changes nothing")
check(!saferOutcome.didChange, "saferIsAlwaysOn does not change settings")
// Case-insensitive.
expectEqual(apply(true, "SAFER", base).1, .saferIsAlwaysOn, "Safer match is case-insensitive")

// ---------------------------------------------------------------------------
// 2. Enabling an optional tone (with room) turns it on.
// ---------------------------------------------------------------------------
let oneTone = CoachVariantSettings(enabled: [.clearer])
let (enabledSettings, enabledOutcome) = apply(true, "funnier", oneTone)
expectEqual(enabledOutcome, .enabled(.funnier), "enable funnier (room) → enabled(funnier)")
check(enabledSettings.enabled.contains(.funnier), "funnier is now enabled")
check(enabledOutcome.didChange, "a real enable changes settings")

// ---------------------------------------------------------------------------
// 3. Disabling a tone that is on turns it off.
// ---------------------------------------------------------------------------
let (disabledSettings, disabledOutcome) = apply(false, "clearer", base)
expectEqual(disabledOutcome, .disabled(.clearer), "disable clearer → disabled(clearer)")
check(!disabledSettings.enabled.contains(.clearer), "clearer is now off")
check(disabledOutcome.didChange, "a real disable changes settings")

// ---------------------------------------------------------------------------
// 4. Idempotent requests change nothing.
// ---------------------------------------------------------------------------
expectEqual(apply(true, "clearer", base).1, .alreadyEnabled(.clearer), "enable an on tone → alreadyEnabled")
check(!apply(true, "clearer", base).1.didChange, "alreadyEnabled does not change settings")
expectEqual(apply(false, "affectionate", base).1, .alreadyDisabled(.affectionate),
            "disable an off tone → alreadyDisabled")
check(!apply(false, "affectionate", base).1.didChange, "alreadyDisabled does not change settings")

// ---------------------------------------------------------------------------
// 5. The two-optional cap is honoured.
// ---------------------------------------------------------------------------
let (capSettings, capOutcome) = apply(true, "professional", base) // base already has 2
expectEqual(capOutcome, .capReached(max: CoachVariantSettings.maximumOptionalCount),
            "enabling a third optional tone → capReached")
expectEqual(capSettings.enabled, base.enabled, "cap-reached changes nothing")
check(!capOutcome.didChange, "capReached does not change settings")

// ---------------------------------------------------------------------------
// 6. Custom needs a valid stored directive.
// ---------------------------------------------------------------------------
let noCustom = CoachVariantSettings(enabled: [.clearer], customInstruction: "")
expectEqual(apply(true, "custom", noCustom).1, .customNeedsInstruction,
            "enable Custom with no directive → customNeedsInstruction")
check(!apply(true, "custom", noCustom).1.didChange, "customNeedsInstruction changes nothing")
let withCustom = CoachVariantSettings(enabled: [.clearer], customInstruction: "Make it playful")
expectEqual(apply(true, "custom", withCustom).1, .enabled(.custom),
            "enable Custom with a valid directive → enabled(custom)")

// ---------------------------------------------------------------------------
// 7. Unknown axis is refused, unchanged. (warmer is a RESULT axis, not a chip.)
// ---------------------------------------------------------------------------
expectEqual(apply(true, "warmer", base).1, .unknownVariant("warmer"), "warmer is not a togglable chip")
expectEqual(apply(true, "nonsense", base).1, .unknownVariant("nonsense"), "an unknown axis is refused")
check(!apply(true, "warmer", base).1.didChange, "unknownVariant changes nothing")

// ---------------------------------------------------------------------------
// 8. Every outcome has a truthful, non-empty message.
// ---------------------------------------------------------------------------
let allOutcomes: [Outcome] = [
    .enabled(.funnier), .disabled(.clearer), .alreadyEnabled(.clearer), .alreadyDisabled(.custom),
    .saferIsAlwaysOn, .capReached(max: 2), .customNeedsInstruction, .unknownVariant("warmer"),
]
for o in allOutcomes { check(!o.message.isEmpty, "outcome \(o) has a message") }
check(Outcome.saferIsAlwaysOn.message.lowercased().contains("safer"), "saferIsAlwaysOn message names Safer")
check(Outcome.capReached(max: 2).message.contains("2"), "capReached message states the cap")
check(Outcome.customNeedsInstruction.message.lowercased().contains("custom"),
      "customNeedsInstruction message names Custom")

// ---------------------------------------------------------------------------
if failures.isEmpty {
    print("PASS: Tone-variant configuration focused source tests (\(checks) checks)")
    exit(0)
} else {
    FileHandle.standardError.write(Data(("FAIL (\(failures.count)/\(checks)):\n  - "
        + failures.joined(separator: "\n  - ") + "\n").utf8))
    exit(1)
}
}
}
