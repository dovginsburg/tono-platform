// verify_tone_variant_entity.swift
//
// Focused source tests for the entities-first App Intents model
// (`ToneVariantEntity` / `ToneVariantQuery`, in App/ToneVariantEntity.swift).
// Compiles the REAL entity source with `swiftc` — no Xcode, no Simulator, no
// device — and exercises the privacy-safe identity contract and the
// discoverability query that Shortcuts and Spotlight read.
//
// AppEntity/EntityQuery compile and run under swiftc on the host macOS, so the
// entity layer — the one piece whose privacy claim ("the id is the axis string
// and NOTHING the user typed") lived only in comments and in the build's
// generated App Intents metadata — is now pinned by an executable test that
// links the shipping source directly and therefore cannot drift from it.
//
// Covers the reviewer's checklist for the entity layer:
//   * `ToneVariantEntity.all` is the full canonical Safer-first set (7 tones)
//   * PRIVACY: every entity id is a known tone AXIS (a `ShortcutRewriteStyle`
//     raw value) — never free text, never a draft, never clipboard
//   * id / label / requiresCustomText mirror the pure `ShortcutRewriteStyle`
//     contract exactly, and `style` recovery round-trips (entity ↔ style)
//   * DISCOVERABILITY: `ToneVariantQuery.suggestedEntities()` returns the whole
//     canonical set (this is what surfaces the tones in Shortcuts / Spotlight)
//   * `ToneVariantQuery.entities(for:)` resolves only known ids and returns []
//     for an unknown / text-like id — a typed-text id can never resolve to an
//     entity, so nothing user-typed round-trips through the query
//   * `displayRepresentation` title == the human label
//
// Usage:  swiftc -parse-as-library -o /tmp/verify_tone_variant_entity \
//            App/ToneVariantEntity.swift Shared/CoachVariantSettings.swift \
//            Scripts/verify_tone_variant_entity.swift && /tmp/verify_tone_variant_entity
// Exit 0 = all pass; 1 = at least one failure (details on stderr).

import AppIntents
import Foundation

var failures: [String] = []
var checks = 0
func check(_ cond: Bool, _ label: String) { checks += 1; if !cond { failures.append(label) } }
func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    checks += 1
    if a != b { failures.append("\(label): got \(a), want \(b)") }
}

@main
struct VerifyToneVariantEntity {
static func main() async {

// ---------------------------------------------------------------------------
// 1. `all` is the full canonical Safer-first set, in ShortcutRewriteStyle order.
// ---------------------------------------------------------------------------
let all = ToneVariantEntity.all
let expectedOrder = ShortcutRewriteStyle.selectableOrder
expectEqual(all.count, expectedOrder.count, "all has one entity per selectable style")
expectEqual(all.map { $0.id }, expectedOrder.map { $0.rawValue },
            "entity ids are the canonical Safer-first axis order")
expectEqual(all.first?.id, "safer", "Safer is first")
// The exact shipped set — locks the count and membership so a silent add/drop
// of a tone axis (which would change what Shortcuts suggests) fails loudly.
expectEqual(all.map { $0.id },
            ["safer", "clearer", "funnier", "affectionate", "professional", "concise", "custom"],
            "the canonical tone axes are exactly these seven, in this order")

// ---------------------------------------------------------------------------
// 2. PRIVACY — every id is a known tone AXIS, never free text.
//    This is the load-bearing entity invariant: the identity of a tone entity
//    is a tone, not a message. If any id failed to decode to a ShortcutRewriteStyle
//    the entity would be carrying something that is not an axis.
// ---------------------------------------------------------------------------
for entity in all {
    check(ShortcutRewriteStyle(rawValue: entity.id) != nil,
          "id '\(entity.id)' is a known tone axis (never user text)")
    // id must equal the axis string of the style it mirrors — not a display
    // label, not a localized string, not anything typed.
    if let style = ShortcutRewriteStyle(rawValue: entity.id) {
        expectEqual(entity.id, style.axis, "id '\(entity.id)' equals the backend axis string")
        expectEqual(entity.label, style.label, "label mirrors the ShortcutRewriteStyle label")
        expectEqual(entity.requiresCustomText, style.requiresCustomText,
                    "requiresCustomText mirrors the style contract for \(entity.id)")
    }
    // Only Custom consumes a free-text directive.
    expectEqual(entity.requiresCustomText, entity.id == "custom",
                "only Custom requires custom text (\(entity.id))")
}

// ---------------------------------------------------------------------------
// 3. `style` recovery round-trips: entity → style → entity id.
// ---------------------------------------------------------------------------
for style in expectedOrder {
    let entity = ToneVariantEntity(style: style)
    expectEqual(entity.id, style.rawValue, "init(style:) sets id to the axis raw value")
    expectEqual(entity.style, style, "entity.style recovers the originating style")
}

// ---------------------------------------------------------------------------
// 4. DISCOVERABILITY — suggestedEntities() surfaces the full canonical set.
//    This is exactly what Shortcuts' editor and Spotlight suggestions read; it
//    must be the whole set and must be text-free (guaranteed by check 2).
// ---------------------------------------------------------------------------
let query = ToneVariantQuery()
do {
    let suggested = try await query.suggestedEntities()
    expectEqual(suggested.map { $0.id }, all.map { $0.id },
                "suggestedEntities() returns the full canonical set, in order")
} catch {
    failures.append("suggestedEntities() threw: \(error)")
    checks += 1
}

// ---------------------------------------------------------------------------
// 5. entities(for:) resolves ONLY known ids — a typed-text id resolves to
//    nothing, so nothing a user typed can round-trip back through the query.
// ---------------------------------------------------------------------------
do {
    let known = try await query.entities(for: ["funnier", "safer"])
    expectEqual(Set(known.map { $0.id }), ["funnier", "safer"],
                "entities(for:) resolves the known ids it was given")

    let mixed = try await query.entities(for: ["funnier", "please break up with him gently"])
    expectEqual(mixed.map { $0.id }, ["funnier"],
                "a text-like id resolves to NO entity — only the real axis survives")

    let unknown = try await query.entities(for: ["warmer", "", "🙂 send this for me"])
    check(unknown.isEmpty, "unknown / text-like ids resolve to no entities at all")
} catch {
    failures.append("entities(for:) threw: \(error)")
    checks += 1
}

// ---------------------------------------------------------------------------
// 6. displayRepresentation title == the human label.
// ---------------------------------------------------------------------------
for entity in all {
    let title = String(localized: entity.displayRepresentation.title)
    expectEqual(title, entity.label, "displayRepresentation title == label for \(entity.id)")
}

// ---------------------------------------------------------------------------
if failures.isEmpty {
    print("PASS: Tone-variant entity focused source tests (\(checks) checks)")
    exit(0)
} else {
    FileHandle.standardError.write(Data(("FAIL (\(failures.count)/\(checks)):\n  - "
        + failures.joined(separator: "\n  - ") + "\n").utf8))
    exit(1)
}
}
}
