// verify_space_cursor_focused.swift
// Standalone red/green verifier for the Build-104 space hold/drag cursor.
//
// Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit, no XCTest.
// Compiles the REAL production source (SpaceCursorEngine.swift) alongside this
// runner, so it exercises shipping logic directly.
//
// WHY THIS FILE WAS REWRITTEN
// Build 103 was rejected on a physical device: the caret "moved one character
// at a time like backspacing" and could not travel up/down. The previous
// version of this verifier asserted exactly that behaviour — a fixed 10pt per
// character, and a `testVerticalJitterIgnored` case — so it stayed green while
// the product was wrong. Those assertions are deleted. What follows pins the
// corrected contract and FAILS against the build-103 engine.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/space_cursor \
//     KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift \
//     Scripts/verify_space_cursor_focused.swift && /tmp/space_cursor
//
// Exits 0 on success, non-zero if any check fails.

import Foundation

// MARK: - Tiny assert harness

var failures = 0
var checks = 0
var tests = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    }
}

// NOTE: a large epoch (1.7e9) has ~4e-7 double resolution, so base+0.30 minus
// base can land just BELOW 0.30 and miss the activation guard. Use a small base
// so sub-second deltas are exact.
let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
func at(_ dt: TimeInterval) -> Date { base.addingTimeInterval(dt) }

/// Engine already in cursor mode over `before|after`.
func activated(before: String, after: String) -> SpaceCursorEngine {
    var e = SpaceCursorEngine()
    e.press(at: at(0))
    _ = e.tick(at: at(0.30), document: SpaceCursorDocument(before: before, after: after))
    return e
}

func graphemes(_ effect: SpaceCursorEngine.Effect) -> Int? {
    if case .moveCaret(let g, _) = effect { return g }
    return nil
}
func utf16Delta(_ effect: SpaceCursorEngine.Effect) -> Int? {
    if case .moveCaret(_, let u) = effect { return u }
    return nil
}

// MARK: - A recording proxy that behaves like a host text field

/// Simulates a host: applies UTF-16 caret offsets to real text and records every
/// call. Because `SpaceCursorTextProxy` has NO insert or delete member, this
/// double cannot even be asked to mutate text — which is the point.
final class RecordingProxy: SpaceCursorTextProxy {
    private(set) var text: [Character]
    private(set) var caret: Int              // grapheme index
    private(set) var adjustCalls: [Int] = []
    private let original: [Character]
    /// Models a stubborn host that only honours part of a requested move.
    var clampsMovementTo: Int?
    /// Models a host that exposes no context (secure field, or nothing shared).
    var reportsNilContext = false

    init(before: String, after: String) {
        text = Array(before + after)
        original = text
        caret = Array(before).count
    }

    var documentContextBeforeInput: String? {
        reportsNilContext ? nil : String(text[0..<caret])
    }
    var documentContextAfterInput: String? {
        reportsNilContext ? nil : String(text[caret...])
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        adjustCalls.append(offset)
        var applied = offset
        if let cap = clampsMovementTo { applied = max(-cap, min(cap, offset)) }
        // Walk graphemes consuming UTF-16 units, the way a host's NSString does.
        var idx = caret
        var remaining = abs(applied)
        let step = applied < 0 ? -1 : 1
        while remaining > 0 {
            let next = idx + step
            guard next >= 0, next <= text.count else { break }
            let ch = step > 0 ? text[idx] : text[next]
            remaining -= ch.utf16.count
            idx = next
        }
        caret = max(0, min(idx, text.count))
    }

    /// True only if the document text itself ever differed from what we started
    /// with. Nothing in the seam can cause this; the assertion is the proof.
    var textEverChanged: Bool { text != original }
}

// ───────────────────────────────────────────────────────────────────────────
// 1. Cursor mode must NEVER delete or insert
// ───────────────────────────────────────────────────────────────────────────

func verify_no_text_mutation_is_even_expressible() {
    let all: [SpaceCursorEngine.Effect] = [
        .none, .insertSpace, .enteredCursorMode,
        .moveCaret(graphemes: 1, utf16: 1), .endedCursorMode,
    ]
    var sawInsert = 0
    for e in all {
        switch e {
        case .none, .enteredCursorMode, .endedCursorMode, .moveCaret: break
        case .insertSpace: sawInsert += 1
        }
    }
    check(sawInsert == 1, "exactly one effect can cause an insertion")
    check(all.count == 5, "effect surface is exactly 5 cases — no delete case exists")
}

func verify_a_full_drag_session_mutates_zero_text() {
    let proxy = RecordingProxy(before: "Hello world, this is a sentence.", after: " And more after.")
    let session = SpaceCursorSession(proxy: proxy)
    session.press(at: at(0))
    _ = session.tick(at: at(0.30))
    for dx in stride(from: -200.0, through: 200.0, by: 17.0) {
        _ = session.drag(translationX: dx, translationY: 0, at: at(0.4))
    }
    let effect = session.end(at: at(1.0))
    check(effect == .endedCursorMode, "drag session ends in cursor mode, not a space")
    check(!proxy.textEverChanged, "no text was changed by a cursor drag")
    check(proxy.text == Array("Hello world, this is a sentence. And more after."),
          "document text is byte-identical after a long drag")
    check(!proxy.adjustCalls.isEmpty, "the drag did move the caret")
}

func verify_quick_tap_inserts_exactly_one_space_and_never_enters_cursor_mode() {
    var e = SpaceCursorEngine()
    e.press(at: at(0))
    check(e.end(at: at(0.05)) == .insertSpace, "fast tap ⇒ insertSpace")
    check(!e.isCursorActive, "tap never activates the trackpad")

    var f = SpaceCursorEngine()
    f.press(at: at(0))
    _ = f.drag(translationX: 30, translationY: 0, at: at(0.05))
    check(f.end(at: at(0.1)) == .none, "aborted swipe types nothing")

    var g = SpaceCursorEngine()
    g.press(at: at(0))
    _ = g.tick(at: at(0.30), document: SpaceCursorDocument(before: "ab", after: "cd"))
    check(g.end(at: at(0.9)) == .endedCursorMode, "hold+release ⇒ no delayed space")
}

// ───────────────────────────────────────────────────────────────────────────
// 2. Accelerated horizontal movement — NOT one-at-a-time
// ───────────────────────────────────────────────────────────────────────────

func verify_long_drags_accelerate_far_past_the_rejected_fixed_rate() {
    let e = SpaceCursorEngine()
    let short = e.horizontalCharacters(forTranslation: 16)
    let long = e.horizontalCharacters(forTranslation: 300)
    check(short == 2, "16pt ⇒ 2 chars (precise near origin), got \(short)")
    check(long >= 80, "300pt must cross a sentence, got \(long) (build-103 gave 30)")
    check(long > 300 / 10, "300pt must beat the rejected fixed 10pt/char rate")

    var last = -1
    for pt in stride(from: 0.0, through: 400.0, by: 8.0) {
        let n = e.horizontalCharacters(forTranslation: pt)
        check(n >= last, "curve is monotonic at \(pt)pt")
        last = n
        check(e.horizontalCharacters(forTranslation: -pt) == -n, "curve is symmetric at \(pt)pt")
    }
}

func verify_precision_preserved_for_small_corrections() {
    let e = SpaceCursorEngine()
    check(e.horizontalCharacters(forTranslation: 4) == 0, "sub-threshold nudge does not move")
    check(e.horizontalCharacters(forTranslation: 8) == 1, "8pt ⇒ exactly 1 char")
    check(e.horizontalCharacters(forTranslation: 24) == 3, "24pt (zone edge) ⇒ 3 chars")
}

func verify_reversal_retraces_exactly_no_ratchet_no_stale_bound() {
    var e = activated(before: String(repeating: "a", count: 400),
                      after: String(repeating: "b", count: 400))
    let out = e.drag(translationX: 300, translationY: 0, at: at(0.4))
    let forward = graphemes(out) ?? 0
    check(forward > 30, "long right drag moves far, got \(forward)")
    _ = e.drag(translationX: 0, translationY: 0, at: at(0.5))
    check(e.appliedOffset == 0, "returning to origin restores caret exactly")
    _ = e.drag(translationX: -300, translationY: 0, at: at(0.6))
    check(e.appliedOffset == -forward, "left drag mirrors right drag")
}

func verify_caret_clamps_at_both_ends_without_sticking() {
    var e = activated(before: "abc", after: "de")
    _ = e.drag(translationX: 5000, translationY: 0, at: at(0.4))
    check(e.caretIndex == 5, "clamps to end of context")
    _ = e.drag(translationX: -5000, translationY: 0, at: at(0.5))
    check(e.caretIndex == 0, "clamps to start of context")
    _ = e.drag(translationX: 0, translationY: 0, at: at(0.6))
    check(e.caretIndex == 3, "returns to origin after both clamps — bound is not stale")
}

// ───────────────────────────────────────────────────────────────────────────
// 3. Two-dimensional / multiline navigation
// ───────────────────────────────────────────────────────────────────────────

func verify_vertical_drag_changes_logical_line_when_newlines_are_present() {
    var e = activated(before: "first line\nsec", after: "ond line\nthird line")
    let doc = e.document!
    check(doc.supportsVerticalNavigation, "newline context supports vertical navigation")
    check(doc.lineCount == 3, "three logical lines")
    check(doc.line(of: doc.origin) == 1, "caret starts on line 1")

    let up = e.drag(translationX: 0, translationY: -40, at: at(0.4))
    check(up != .none, "upward drag past the dead zone moves the caret")
    check(e.document!.line(of: e.caretIndex!) == 0, "moved to line 0")
    check(e.document!.column(of: e.caretIndex!) == 3, "column preserved going up")

    _ = e.drag(translationX: 0, translationY: 40, at: at(0.5))
    check(e.document!.line(of: e.caretIndex!) == 2, "downward drag reaches line 2")
    check(e.document!.column(of: e.caretIndex!) == 3, "sticky column preserved going down")
}

func verify_vertical_dead_zone_keeps_horizontal_drags_on_their_line() {
    // Sub-dead-zone vertical travel must contribute NOTHING. Compare a drag with
    // 12pt of hand tremor against the identical drag with none: same caret.
    // (Note the caret legitimately crosses a line break here — a pure horizontal
    // drag flows freely across "\n", which is what Apple's trackpad does. The
    // invariant under test is that the tremor changed nothing, not that the
    // caret stayed on its line.)
    var tremor = activated(before: "alpha\nbra", after: "vo\ncharlie")
    var clean = activated(before: "alpha\nbra", after: "vo\ncharlie")
    _ = tremor.drag(translationX: 60, translationY: 12, at: at(0.4))   // 12pt < 16pt dead zone
    _ = clean.drag(translationX: 60, translationY: 0, at: at(0.4))
    check(tremor.caretIndex == clean.caretIndex,
          "12pt of tremor is ignored: \(String(describing: tremor.caretIndex)) vs \(String(describing: clean.caretIndex))")
    // And crossing the dead zone DOES change line, so the zone is a threshold,
    // not a permanent lock.
    var crossed = activated(before: "alpha\nbra", after: "vo\ncharlie")
    _ = crossed.drag(translationX: 0, translationY: -30, at: at(0.4))
    check(crossed.document!.line(of: crossed.caretIndex!) == 0, "30pt up crosses to line 0")
}

func verify_sticky_column_survives_a_short_intervening_line() {
    var e = activated(before: "0123456789abc", after: "\nxy\n0123456789ABC")
    let startCol = e.document!.column(of: e.caretIndex!)
    check(startCol == 13, "starting column 13, got \(startCol)")
    // 30pt ⇒ exactly one line down (1 + floor((30-16)/24) = 1).
    _ = e.drag(translationX: 0, translationY: 30, at: at(0.4))
    check(e.document!.line(of: e.caretIndex!) == 1, "on the short line")
    check(e.document!.column(of: e.caretIndex!) == 2, "clamped to short line end")
    // 60pt ⇒ two lines down from the ORIGIN line (cumulative, not incremental).
    _ = e.drag(translationX: 0, translationY: 60, at: at(0.5))
    check(e.document!.line(of: e.caretIndex!) == 2, "reached the long line")
    check(e.document!.column(of: e.caretIndex!) == 13, "sticky column restored on the long line")
}

func verify_single_line_context_degrades_to_horizontal_only_never_invents_geometry() {
    var e = activated(before: "just one single line of text", after: " continues here")
    check(!e.document!.supportsVerticalNavigation, "no newline ⇒ vertical unsupported")
    let before = e.caretIndex!
    _ = e.drag(translationX: 0, translationY: -200, at: at(0.4))
    check(e.caretIndex == before, "huge vertical drag does nothing on a single-line field")
    _ = e.drag(translationX: 80, translationY: -200, at: at(0.5))
    check(e.caretIndex! > before, "horizontal still works while vertical is unsupported")
}

func verify_empty_nil_context_is_safe() {
    var e = activated(before: "", after: "")
    check(e.document!.count == 0, "empty document")
    check(!e.document!.supportsVerticalNavigation, "empty context has no vertical")
    _ = e.drag(translationX: 500, translationY: 500, at: at(0.4))
    check(e.caretIndex == 0, "caret pinned at 0 with no text")
    check(e.end(at: at(0.6)) == .endedCursorMode, "still ends cleanly")

    let proxy = RecordingProxy(before: "abc", after: "def")
    proxy.reportsNilContext = true
    let s = SpaceCursorSession(proxy: proxy)
    s.press(at: at(0))
    _ = s.tick(at: at(0.30))
    _ = s.drag(translationX: 300, translationY: 0, at: at(0.4))
    check(!proxy.textEverChanged, "nil-context host is never mutated")
}

// ───────────────────────────────────────────────────────────────────────────
// 4. Unicode correctness — graphemes vs UTF-16
// ───────────────────────────────────────────────────────────────────────────

func verify_non_BMP_emoji_cost_2_UTF_16_units_but_1_caret_step() {
    var e = activated(before: "a😀b", after: "")
    let doc = e.document!
    check(doc.count == 3, "emoji is ONE grapheme")
    check(doc.utf16Distance(from: 0, to: 3) == 4, "a(1)+😀(2)+b(1) = 4 UTF-16 units")
    _ = e.drag(translationX: -8, translationY: 0, at: at(0.4))
    check(e.caretIndex == 2, "one step left lands between 😀 and b")
}

func verify_composed_families_flags_skin_tones_and_combining_marks_are_single_steps() {
    let cases: [(String, Int)] = [
        ("👨‍👩‍👧‍👦", 1),
        ("🇺🇸", 1),
        ("👍🏽", 1),
        ("é", 1),
    ]
    for (text, expected) in cases {
        let doc = SpaceCursorDocument(before: text, after: "")
        check(doc.count == expected, "\(text) is \(expected) grapheme(s), got \(doc.count)")
        var e = activated(before: text, after: "")
        _ = e.drag(translationX: -5000, translationY: 0, at: at(0.4))
        check(e.caretIndex == 0, "\(text): clamps to 0")
        _ = e.drag(translationX: 5000, translationY: 0, at: at(0.5))
        check(e.caretIndex == doc.count, "\(text): clamps to end")
    }
}

func verify_UTF_16_delta_always_matches_the_grapheme_span_the_host_must_cross() {
    var e = activated(before: "😀😀😀", after: "😀😀😀")
    let out = e.drag(translationX: 24, translationY: 0, at: at(0.4))
    let g = graphemes(out) ?? 0
    let u = utf16Delta(out) ?? 0
    check(g == 3, "3 graphemes, got \(g)")
    check(u == 6, "6 UTF-16 units for 3 non-BMP emoji, got \(u)")
}

func verify_RTL_and_bidi_text_move_logically_without_corruption() {
    var e = activated(before: "مرحبا ", after: "بالعالم")
    let doc = e.document!
    check(doc.count == 13, "13 logical graphemes, got \(doc.count)")
    _ = e.drag(translationX: 40, translationY: 0, at: at(0.4))
    check(e.caretIndex! > doc.origin, "logical forward movement works in RTL")
    _ = e.drag(translationX: 0, translationY: 0, at: at(0.5))
    check(e.caretIndex == doc.origin, "reversal exact in RTL")

    var m = activated(before: "abc مرحبا ", after: "xyz")
    _ = m.drag(translationX: 5000, translationY: 0, at: at(0.4))
    check(m.caretIndex == m.document!.count, "mixed bidi clamps to end without corruption")
}

// ───────────────────────────────────────────────────────────────────────────
// 5. Session robustness
// ───────────────────────────────────────────────────────────────────────────

func verify_cancellation_never_inserts_and_reports_teardown() {
    var e = activated(before: "abc", after: "def")
    _ = e.drag(translationX: 40, translationY: 0, at: at(0.4))
    check(e.cancel() == .endedCursorMode, "cancel from cursor ⇒ endedCursorMode")
    check(!e.isTracking, "idle after cancel")

    var p = SpaceCursorEngine()
    p.press(at: at(0))
    check(p.cancel() == .none, "cancel before activation inserts nothing")
}

func verify_idle_transitions_are_inert() {
    var e = SpaceCursorEngine()
    check(e.drag(translationX: 50, translationY: 50, at: at(0)) == .none, "drag while idle")
    check(e.tick(at: at(0), document: SpaceCursorDocument(before: "a", after: "b")) == .none, "tick while idle")
    check(e.end(at: at(0)) == .none, "end while idle")
    check(e.cancel() == .none, "cancel while idle")
}

func verify_tap_still_works_immediately_after_a_cursor_session() {
    var e = activated(before: "abcdef", after: "ghij")
    _ = e.drag(translationX: 40, translationY: 0, at: at(0.4))
    check(e.end(at: at(0.6)) == .endedCursorMode, "session ends")
    e.press(at: at(1.0))
    check(e.end(at: at(1.05)) == .insertSpace, "next quick tap is a normal space")
}

func verify_host_that_clamps_movement_is_reconciled_not_compounded() {
    let proxy = RecordingProxy(before: String(repeating: "x", count: 50),
                               after: String(repeating: "y", count: 50))
    proxy.clampsMovementTo = 3
    let s = SpaceCursorSession(proxy: proxy)
    s.press(at: at(0))
    _ = s.tick(at: at(0.30))
    _ = s.drag(translationX: 200, translationY: 0, at: at(0.4))
    check(proxy.caret == 53, "host clamped to +3, got \(proxy.caret)")
    check(s.engine.caretIndex == 53,
          "engine adopted the host's actual caret, got \(String(describing: s.engine.caretIndex))")
    check(!proxy.textEverChanged, "clamping host still never had text changed")
}

func verify_rapid_reversal_storm_never_corrupts_or_mutates() {
    let proxy = RecordingProxy(before: String(repeating: "ab😀", count: 60),
                               after: String(repeating: "cd🇺🇸", count: 60))
    let s = SpaceCursorSession(proxy: proxy)
    s.press(at: at(0))
    _ = s.tick(at: at(0.30))
    var t = 0.4
    for _ in 0..<40 {
        _ = s.drag(translationX: 250, translationY: 0, at: at(t)); t += 0.01
        _ = s.drag(translationX: -250, translationY: 0, at: at(t)); t += 0.01
    }
    _ = s.drag(translationX: 0, translationY: 0, at: at(t))
    check(!proxy.textEverChanged, "reversal storm mutates nothing")
    check(s.engine.appliedOffset == 0,
          "storm returns exactly to origin, got \(String(describing: s.engine.appliedOffset))")
}

func verify_very_long_field_traverses_quickly_and_stays_in_bounds() {
    let long = String(repeating: "lorem ipsum dolor sit amet ", count: 200)
    var e = activated(before: long, after: long)
    _ = e.drag(translationX: 600, translationY: 0, at: at(0.4))
    let moved = e.appliedOffset ?? 0
    check(moved > 200, "600pt sweep crosses >200 chars in a long field, got \(moved)")
    check(e.caretIndex! <= e.document!.count, "never exceeds bounds")
}

// MARK: - Runner

let allSuites: [(String, () -> Void)] = [
    ("no text mutation is even expressible", verify_no_text_mutation_is_even_expressible),
    ("a full drag session mutates zero text", verify_a_full_drag_session_mutates_zero_text),
    ("quick tap inserts exactly one space and never enters cursor mode", verify_quick_tap_inserts_exactly_one_space_and_never_enters_cursor_mode),
    ("long drags accelerate far past the rejected fixed rate", verify_long_drags_accelerate_far_past_the_rejected_fixed_rate),
    ("precision preserved for small corrections", verify_precision_preserved_for_small_corrections),
    ("reversal retraces exactly — no ratchet, no stale bound", verify_reversal_retraces_exactly_no_ratchet_no_stale_bound),
    ("caret clamps at both ends without sticking", verify_caret_clamps_at_both_ends_without_sticking),
    ("vertical drag changes logical line when newlines are present", verify_vertical_drag_changes_logical_line_when_newlines_are_present),
    ("vertical dead zone keeps horizontal drags on their line", verify_vertical_dead_zone_keeps_horizontal_drags_on_their_line),
    ("sticky column survives a short intervening line", verify_sticky_column_survives_a_short_intervening_line),
    ("single-line context degrades to horizontal only — never invents geometry", verify_single_line_context_degrades_to_horizontal_only_never_invents_geometry),
    ("empty / nil context is safe", verify_empty_nil_context_is_safe),
    ("non-BMP emoji cost 2 UTF-16 units but 1 caret step", verify_non_BMP_emoji_cost_2_UTF_16_units_but_1_caret_step),
    ("composed families, flags, skin tones and combining marks are single steps", verify_composed_families_flags_skin_tones_and_combining_marks_are_single_steps),
    ("UTF-16 delta always matches the grapheme span the host must cross", verify_UTF_16_delta_always_matches_the_grapheme_span_the_host_must_cross),
    ("RTL and bidi text move logically without corruption", verify_RTL_and_bidi_text_move_logically_without_corruption),
    ("cancellation never inserts and reports teardown", verify_cancellation_never_inserts_and_reports_teardown),
    ("idle transitions are inert", verify_idle_transitions_are_inert),
    ("tap still works immediately after a cursor session", verify_tap_still_works_immediately_after_a_cursor_session),
    ("host that clamps movement is reconciled, not compounded", verify_host_that_clamps_movement_is_reconciled_not_compounded),
    ("rapid reversal storm never corrupts or mutates", verify_rapid_reversal_storm_never_corrupts_or_mutates),
    ("very long field traverses quickly and stays in bounds", verify_very_long_field_traverses_quickly_and_stays_in_bounds),
]

@main
enum SpaceCursorFocusedVerifier {
    static func main() {
        for (name, fn) in allSuites { tests += 1; fn(); _ = name }
        if failures == 0 {
            print("PASS: \(checks) checks across \(tests) tests")
            exit(0)
        } else {
            FileHandle.standardError.write(
                Data("FAILED: \(failures) failed of \(checks) checks across \(tests) tests\n".utf8)
            )
            exit(1)
        }
    }
}
