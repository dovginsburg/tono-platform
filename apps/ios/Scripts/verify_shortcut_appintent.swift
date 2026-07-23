// verify_shortcut_appintent.swift
//
// Focused source tests for the Apple Shortcut / App Intent rewrite lane.
// Compiles the REAL shared contract (Shared/CoachVariantSettings.swift) with
// `swiftc` — no Xcode, no iOS Simulator, no AppIntents, no network — and
// exercises the pure `ShortcutRewriteStyle` / `ShortcutRewrite` types the App
// Intent (App/CoachDraftIntent.swift) delegates to. Because it links the
// production source directly, these assertions cannot drift from shipping code.
//
// Covers the reviewer's checklist:
//   * style choices (7 keyboard-source labels + axes, mandatory-Safer-first)
//   * selected-axis request mapping (style -> backend variant axis)
//   * Custom validation + 120-char cap (reject empty / >120, trim)
//   * no-op failure (source draft is never returned as a successful rewrite)
//   * account / entitlement failure reasons are honest
//   * rewritten String output on a genuine, distinct rewrite
//
// Usage:  swiftc -o /tmp/verify_shortcut Shared/CoachVariantSettings.swift \
//                 Scripts/verify_shortcut_appintent.swift && /tmp/verify_shortcut
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

@main
struct VerifyShortcut {
static func main() {
// ---------------------------------------------------------------------------
// 1. Style choices — the 7 selectable styles mirror the keyboard tone chips,
//    mandatory Safer first, then the six optional tones in declaration order.
// ---------------------------------------------------------------------------
let order = ShortcutRewriteStyle.selectableOrder
expectEqual(order, [.safer, .clearer, .funnier, .affectionate, .professional, .concise, .custom],
            "selectableOrder is Safer-first + six optional tones")
expectEqual(order.count, 7, "exactly 7 selectable styles")
expectEqual(order.map(\.label),
            ["Safer", "Clearer", "Funnier", "Affectionate", "Professional", "Concise", "Custom"],
            "labels are the keyboard-source labels")
// The AppEnum in CoachDraftIntent uses the same raw values, so allCases parity
// guards against a case being added on one side only.
expectEqual(Set(ShortcutRewriteStyle.allCases), Set(order), "allCases == selectableOrder set")

// ---------------------------------------------------------------------------
// 2. Selected-axis request — each style maps to exactly its backend variant
//    axis (== the keyboard chip axis == a member of the server allowlist).
// ---------------------------------------------------------------------------
expectEqual(order.map(\.axis),
            ["safer", "clearer", "funnier", "affectionate", "professional", "concise", "custom"],
            "style -> backend variant axis map")
for s in ShortcutRewriteStyle.allCases {
    expectEqual(s.axis, s.rawValue, "axis equals rawValue for \(s)")
    expectEqual(s.label, CoachToneChipContract.label(for: s.axis), "label matches chip contract for \(s)")
    expectEqual(s.requiresCustomText, s == .custom, "only Custom requires custom text for \(s)")
}

// ---------------------------------------------------------------------------
// 3. Custom validation + 120-char cap.
// ---------------------------------------------------------------------------
expectEqual(ShortcutRewrite.maxCustomLength, 120, "Custom cap is 120")
expectEqual(ShortcutRewrite.maxCustomLength, CoachVariantSettings.maximumCustomLength,
            "Custom cap matches the keyboard settings contract")

func customFailure(_ raw: String?) -> ShortcutRewrite.Failure? {
    if case .failure(let f) = ShortcutRewrite.validatedCustomText(raw) { return f }
    return nil
}
func customSuccess(_ raw: String?) -> String? {
    if case .success(let v) = ShortcutRewrite.validatedCustomText(raw) { return v }
    return nil
}
expectEqual(customFailure(nil), .customRequired, "nil Custom -> customRequired")
expectEqual(customFailure(""), .customRequired, "empty Custom -> customRequired")
expectEqual(customFailure("   \n  "), .customRequired, "whitespace-only Custom -> customRequired")
expectEqual(customSuccess("  Make it playful  "), "Make it playful", "Custom is trimmed on success")
let exactly120 = String(repeating: "a", count: 120)
expectEqual(customSuccess(exactly120), exactly120, "120 chars is accepted")
let over120 = String(repeating: "a", count: 121)
expectEqual(customFailure(over120), .customTooLong(max: 120), "121 chars -> customTooLong(120)")
// A too-long directive is rejected, NOT silently truncated into a success.
check(customSuccess(over120) == nil, "over-120 Custom never silently succeeds")

// ---------------------------------------------------------------------------
// 4. No-op failure — the source draft is NEVER returned as a successful
//    rewrite. Covers distinct success, exact echo, case/punctuation churn,
//    empty text, and blocked envelopes.
// ---------------------------------------------------------------------------
let source = "Hey, could you help me with something?"

func resolve(_ status: String, _ text: String?, _ reason: String?) -> Result<String, ShortcutRewrite.Failure> {
    ShortcutRewrite.resolve(status: status, text: text, reason: reason, source: source)
}
func resolvedValue(_ status: String, _ text: String?, _ reason: String?) -> String? {
    if case .success(let v) = resolve(status, text, reason) { return v }
    return nil
}
func resolvedFailure(_ status: String, _ text: String?, _ reason: String?) -> ShortcutRewrite.Failure? {
    if case .failure(let f) = resolve(status, text, reason) { return f }
    return nil
}

// Genuine distinct rewrite -> success returns the exact rewritten String.
expectEqual(resolvedValue("ok", "With care, could you help me with something?", nil),
            "With care, could you help me with something?",
            "distinct rewrite returns the rewritten String")
// Exact echo of the source -> no-op failure, source NOT returned.
expectEqual(resolvedFailure("ok", source, nil), .noDistinctRewrite, "exact echo -> noDistinctRewrite")
check(resolvedValue("ok", source, nil) == nil, "exact source echo is never a success")
// Only casing / punctuation churn -> still a no-op (normalized comparison).
expectEqual(resolvedFailure("ok", "HEY!! could you HELP me, with something???", nil),
            .noDistinctRewrite, "case/punctuation churn -> noDistinctRewrite")
// Whitespace-padded echo -> no-op.
expectEqual(resolvedFailure("ok", "   \(source)   ", nil), .noDistinctRewrite, "padded echo -> noDistinctRewrite")
// Empty / nil text on an ok envelope -> emptyResult (never the source).
expectEqual(resolvedFailure("ok", "", nil), .emptyResult, "empty ok text -> emptyResult")
expectEqual(resolvedFailure("ok", nil, nil), .emptyResult, "nil ok text -> emptyResult")
// Blocked envelopes -> honest failure, never the source draft.
expectEqual(resolvedFailure("blocked", nil, "no_distinct_rewrite"), .noDistinctRewrite,
            "blocked no_distinct_rewrite -> noDistinctRewrite")
expectEqual(resolvedFailure("blocked", nil, "provider_failed"), .blocked(reason: "provider_failed"),
            "blocked provider_failed -> blocked(provider_failed)")
expectEqual(resolvedFailure("blocked", source, "validation_failed"), .blocked(reason: "validation_failed"),
            "a blocked envelope that echoes source is still a failure")
check(resolvedValue("blocked", source, "validation_failed") == nil, "blocked never returns source as success")

// ---------------------------------------------------------------------------
// 5. Account / entitlement failure reasons are honest and user-facing.
// ---------------------------------------------------------------------------
check(ShortcutRewrite.Failure.notRegistered.message.lowercased().contains("account"),
      "notRegistered message names the account setup")
check(ShortcutRewrite.Failure.entitlementRequired.message.lowercased().contains("subscription"),
      "entitlementRequired message names the subscription/trial")
check(!ShortcutRewrite.Failure.noDistinctRewrite.message.isEmpty, "noDistinctRewrite has a message")
check(ShortcutRewrite.Failure.customTooLong(max: 120).message.contains("120"),
      "customTooLong message states the 120 cap")

// ---------------------------------------------------------------------------
if failures.isEmpty {
    print("PASS: Shortcut App Intent focused source tests (\(checks) checks)")
    exit(0)
} else {
    FileHandle.standardError.write(Data(("FAIL (\(failures.count)/\(checks)):\n  - "
        + failures.joined(separator: "\n  - ") + "\n").utf8))
    exit(1)
}
}
}
