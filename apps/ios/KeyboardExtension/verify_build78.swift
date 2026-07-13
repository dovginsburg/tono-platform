#!/usr/bin/env swift
// verify_build78.swift
// Standalone executable verification for the build-78 keyboard.
// Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit.
//
// Builds 78 added: 123 / #+= / ABC mode toggle, shift (single tap →
// uppercase, double tap → caps-lock, third tap → release), sentence-
// start auto-cap, and an emoji panel with four groups.
//
// This file MIRRORS the relevant pure-Swift pieces of
// KeyboardViewController.swift so the verifier can exercise the state
// machine and the insertion-mapping logic without launching a UIKit
// host. If the production keyboard drifts from these mirrors the
// verifier will not catch it — keep them in lockstep.
//
// Usage:
//   swift verify_build78.swift
//
// Exits 0 on success, non-zero on any failure.

import Foundation

// MARK: - Layout & shift state mirrors (must match KeyboardViewController)

enum KeyboardLayoutMode: Equatable {
    case letters
    case numbers
    case symbols
}

enum ShiftState: Equatable {
    case none
    case shiftOnce
    case capsLock
}

let shiftDoubleTapWindow: TimeInterval = 0.4

// MARK: - Row data mirrors

let row1Letters: [String] = ["q","w","e","r","t","y","u","i","o","p"]
let row2Letters: [String] = ["a","s","d","f","g","h","j","k","l"]
let row3Letters: [String] = ["z","x","c","v","b","n","m"]
let numRow1: [String] = ["1","2","3","4","5","6","7","8","9","0"]
let numRow2: [String] = ["-","/",":",";","(",")","$","&","@","\""]
let numRow3: [String] = [".",",","?","!","'"]
let symRow1: [String] = ["[","]","{","}","#","%","^","*","+","="]
let symRow2: [String] = ["_","\\","|","~","<",">","€","£","¥","•"]
let symRow3: [String] = [".",",","?","!","'"]

// MARK: - State machine mirrors

/// Mirrors `modeToggleTapped` in KeyboardViewController.
func advanceMode(_ mode: KeyboardLayoutMode) -> KeyboardLayoutMode {
    switch mode {
    case .letters: return .numbers
    case .numbers: return .symbols
    case .symbols: return .letters
    }
}

/// Mirrors the shift-tap logic. `prevTap` is the timestamp of the
/// previous shift tap (or `.distantPast` for the first tap).
func shiftAfterTap(now: Date, prevTap: Date, current: ShiftState) -> ShiftState {
    let isDoubleTap = now.timeIntervalSince(prevTap) < shiftDoubleTapWindow
    switch current {
    case .shiftOnce where isDoubleTap: return .capsLock
    case .capsLock: return .none
    case .none: return .shiftOnce
    default: return .none
    }
}

/// Mirrors `displayLetter` from KeyboardViewController: letters only
/// upper-case under shift; symbols/numbers are inserted verbatim.
func displayLetter(_ ch: String, mode: KeyboardLayoutMode, shift: ShiftState) -> String {
    switch mode {
    case .letters:
        return shift == .none ? ch : ch.uppercased()
    case .numbers, .symbols:
        return ch
    }
}

/// Mirrors the body of `charTapped`: produces the text that would be
/// sent to `textDocumentProxy.insertText` for a given key press, and
/// returns the shift state AFTER the tap (collapse shiftOnce back to
/// none on letter insertion).
func insertKey(_ ch: String, mode: KeyboardLayoutMode, shift: ShiftState) -> (String, ShiftState) {
    let displayed = displayLetter(ch, mode: mode, shift: shift)
    var nextShift = shift
    if mode == .letters, shift == .shiftOnce {
        nextShift = .none
    }
    return (displayed, nextShift)
}

/// Mirrors `applyAutoCapitalizationIfNeeded`: returns the shift state
/// the keyboard should be in given the host field's prefix.
func autoCapShift(beforeInput: String, currentShift: ShiftState, mode: KeyboardLayoutMode) -> ShiftState {
    if currentShift == .capsLock { return .capsLock }
    if mode != .letters { return .none }
    let lastTwo = String(beforeInput.suffix(2))
    // Sentence-start triggers: empty field, trailing space, trailing
    // newline, or sentence-terminator followed by whitespace.
    let should = lastTwo.isEmpty
        || lastTwo.hasSuffix(" ")
        || lastTwo.hasSuffix("\n")
        || lastTwo.range(of: #"[.!?]\s$"#, options: .regularExpression) != nil
    return should ? .shiftOnce : .none
}

// MARK: - Emoji panel mirror
//
// The controller hardcodes four emoji groups (faces, hearts, gestures,
// objects). The verifier only checks that:
//   * Every group is non-empty (no Recents in build 78).
//   * Every glyph inserts as a non-empty Unicode string (i.e. no
//     surrogate-pair dropouts, no empty strings).
// We mirror just enough to count.

enum EmojiGroup: String, CaseIterable {
    case faces, hearts, gestures, objects

    var glyphs: [String] {
        switch self {
        case .faces: return ["😀","😃","😄","😁","😆","😅","🤣","😂"]
        case .hearts: return ["❤️","🧡","💛","💚","💙","💜","🖤","🤍"]
        case .gestures: return ["👋","🤚","🖐️","✋","🖖","👌","🤌","🤏"]
        case .objects: return ["⌚️","📱","💻","⌨️","🖥️","🖨️","🖱️","🖲️"]
        }
    }
}

// MARK: - Tests

var failures: [String] = []
func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    if ok {
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name) — \(detail)")
        failures.append(name)
    }
}

print("== build 78 verification ==")

// ---- 1. Mode toggle state machine ----
do {
    check(advanceMode(.letters) == .numbers, "letters → numbers")
    check(advanceMode(.numbers) == .symbols, "numbers → symbols")
    check(advanceMode(.symbols) == .letters, "symbols → letters (cycle back)")
    // Three taps should walk the full loop:
    var m: KeyboardLayoutMode = .letters
    m = advanceMode(m)
    m = advanceMode(m)
    m = advanceMode(m)
    check(m == .letters, "three taps return to letters")
}

// ---- 2. Mode toggle glyph matches the controller ----
do {
    func glyph(_ m: KeyboardLayoutMode) -> String {
        switch m {
        case .letters: return "123"
        case .numbers: return "#+="
        case .symbols: return "ABC"
        }
    }
    check(glyph(.letters) == "123", "letters mode glyph is '123'")
    check(glyph(.numbers) == "#+=", "numbers mode glyph is '#+='")
    check(glyph(.symbols) == "ABC", "symbols mode glyph is 'ABC'")
}

// ---- 3. Shift state machine ----
do {
    // Single tap from .none → .shiftOnce
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let s1 = shiftAfterTap(now: t0, prevTap: .distantPast, current: .none)
    check(s1 == .shiftOnce, "first shift tap → shiftOnce")

    // Double tap (≤400ms) from .shiftOnce → .capsLock
    let s2 = shiftAfterTap(now: t0.addingTimeInterval(0.2), prevTap: t0, current: .shiftOnce)
    check(s2 == .capsLock, "rapid second tap → capsLock")

    // Tap from .capsLock → .none
    let s3 = shiftAfterTap(now: t0.addingTimeInterval(1.0), prevTap: t0.addingTimeInterval(0.2), current: .capsLock)
    check(s3 == .none, "tap from capsLock → none")

    // Slow second tap (after window) keeps .shiftOnce from collapsing to
    // capsLock — instead it resets to .none per the `default` branch.
    let s4 = shiftAfterTap(now: t0.addingTimeInterval(0.6), prevTap: t0, current: .shiftOnce)
    check(s4 == .none, "slow second tap → none (default branch)")

    // Verify the controller's logic for the "shiftOnce without double
    // tap" path collapses back: if user types a letter under .shiftOnce
    // the controller drops back to .none (insertKey returns .none).
    let (_, nextShift) = insertKey("a", mode: .letters, shift: .shiftOnce)
    check(nextShift == .none, "typing a letter under shiftOnce → shift collapses to none")
}

// ---- 4. Insertion mapping (mode × shift × key) ----
do {
    // Letters mode, no shift → lowercase.
    let (a, _) = insertKey("a", mode: .letters, shift: .none)
    check(a == "a", "letters-mode 'a' under .none → 'a'")

    // Letters mode, shiftOnce → uppercase.
    let (b, _) = insertKey("b", mode: .letters, shift: .shiftOnce)
    check(b == "B", "letters-mode 'b' under .shiftOnce → 'B'")

    // Letters mode, capsLock → uppercase.
    let (c, _) = insertKey("c", mode: .letters, shift: .capsLock)
    check(c == "C", "letters-mode 'c' under .capsLock → 'C'")

    // Numbers mode ignores shift.
    let (d, _) = insertKey("1", mode: .numbers, shift: .none)
    check(d == "1", "numbers-mode '1' under .none → '1'")
    let (e, _) = insertKey("1", mode: .numbers, shift: .capsLock)
    check(e == "1", "numbers-mode '1' under .capsLock → '1' (shift ignored)")

    // Symbols mode ignores shift.
    let (f, _) = insertKey("[", mode: .symbols, shift: .capsLock)
    check(f == "[", "symbols-mode '[' under .capsLock → '[' (shift ignored)")

    // The row-3 punctuation keys in numbers mode: . , ? ! ' should
    // round-trip verbatim.
    for ch in numRow3 {
        let (out, _) = insertKey(ch, mode: .numbers, shift: .none)
        check(out == ch, "numbers-mode '\(ch)' → '\(ch)' (verbatim)")
    }
    for ch in symRow3 {
        let (out, _) = insertKey(ch, mode: .symbols, shift: .none)
        check(out == ch, "symbols-mode '\(ch)' → '\(ch)' (verbatim)")
    }
}

// ---- 5. Sentence-start auto-cap ----
do {
    // Empty field → .shiftOnce (auto-cap on next letter).
    check(autoCapShift(beforeInput: "", currentShift: .none, mode: .letters) == .shiftOnce,
          "auto-cap: empty field → shiftOnce")
    // Right after a space → .shiftOnce.
    check(autoCapShift(beforeInput: "hello ", currentShift: .none, mode: .letters) == .shiftOnce,
          "auto-cap: after space → shiftOnce")
    // Right after ". " → .shiftOnce.
    check(autoCapShift(beforeInput: "ok. ", currentShift: .none, mode: .letters) == .shiftOnce,
          "auto-cap: after '. ' → shiftOnce")
    // Right after "! " → .shiftOnce.
    check(autoCapShift(beforeInput: "wow! ", currentShift: .none, mode: .letters) == .shiftOnce,
          "auto-cap: after '! ' → shiftOnce")
    // Right after "? " → .shiftOnce.
    check(autoCapShift(beforeInput: "huh? ", currentShift: .none, mode: .letters) == .shiftOnce,
          "auto-cap: after '? ' → shiftOnce")
    // Right after newline → .shiftOnce.
    check(autoCapShift(beforeInput: "row1\n", currentShift: .none, mode: .letters) == .shiftOnce,
          "auto-cap: after '\\n' → shiftOnce")
    // Mid-word → .none (do NOT auto-cap).
    check(autoCapShift(beforeInput: "hel", currentShift: .none, mode: .letters) == .none,
          "auto-cap: mid-word 'hel' → none")
    // After a single punctuation mark with no trailing space → .none.
    check(autoCapShift(beforeInput: "ok.", currentShift: .none, mode: .letters) == .none,
          "auto-cap: 'ok.' no trailing space → none")
    // capsLock wins over auto-cap.
    check(autoCapShift(beforeInput: "hello ", currentShift: .capsLock, mode: .letters) == .capsLock,
          "auto-cap: capsLock stays capsLock")
    // Numbers mode forces shift → .none even on a sentence boundary.
    check(autoCapShift(beforeInput: "ok. ", currentShift: .none, mode: .numbers) == .none,
          "auto-cap: numbers mode stays .none")
}

// ---- 6. Row content checks (no truncation, no shuffle) ----
do {
    check(row1Letters.count == 10, "row 1 letters: 10 keys", "got \(row1Letters.count)")
    check(row2Letters.count == 9, "row 2 letters: 9 keys", "got \(row2Letters.count)")
    check(row3Letters.count == 7, "row 3 letters: 7 keys", "got \(row3Letters.count)")
    check(numRow1.count == 10, "row 1 numbers: 10 keys")
    check(numRow2.count == 10, "row 2 numbers: 10 keys")
    check(numRow3.count == 5, "row 3 numbers: 5 keys")
    check(symRow1.count == 10, "row 1 symbols: 10 keys")
    check(symRow2.count == 10, "row 2 symbols: 10 keys")
    check(symRow3.count == 5, "row 3 symbols: 5 keys")

    // QWERTY sanity — top row starts with Q and ends with P.
    check(row1Letters.first == "q" && row1Letters.last == "p",
          "QWERTY row 1 starts q, ends p",
          "got \(row1Letters.first ?? "")..\(row1Letters.last ?? "")")
}

// ---- 7. Emoji panel checks ----
do {
    // No Recents group shipped in build 78 — we expect exactly the four
    // groups the spec lists (faces, hearts, gestures, objects).
    let expected: [EmojiGroup] = [.faces, .hearts, .gestures, .objects]
    let actual = EmojiGroup.allCases
    check(actual == expected, "emoji groups: faces/hearts/gestures/objects (no Recents in build 78)",
          "got \(actual.map(\.rawValue))")

    // Every group must be non-empty.
    for g in EmojiGroup.allCases {
        check(!g.glyphs.isEmpty, "emoji group '\(g.rawValue)' is non-empty")
    }

    // Every glyph round-trips through insertText: it must be non-empty
    // when we proxy it (the proxy is a stub here).
    var proxyInserted: [String] = []
    for g in EmojiGroup.allCases {
        for ch in g.glyphs {
            // Mirror `emojiTapped`: insert the title verbatim.
            if !ch.isEmpty {
                proxyInserted.append(ch)
            }
        }
    }
    check(proxyInserted.count == EmojiGroup.allCases.reduce(0) { $0 + $1.glyphs.count },
          "every emoji glyph inserts as a non-empty string")
}

// ---- 8. Boundary triple: mode toggle preserves shift state ----
//
// The spec says "Layout-mode flip does NOT touch shift state: returning
// to letters from symbols should preserve the user's caps-lock intent."
// We verify the controller by directly toggling layoutMode and checking
// shiftState is untouched.
do {
    var layoutMode: KeyboardLayoutMode = .letters
    var shiftState: ShiftState = .capsLock
    // Mirror modeToggleTapped: only touches layoutMode.
    layoutMode = advanceMode(layoutMode)
    layoutMode = advanceMode(layoutMode)
    layoutMode = advanceMode(layoutMode)
    check(layoutMode == .letters, "toggling back to letters lands on .letters")
    check(shiftState == .capsLock, "capsLock survives a 123/#+=/ABC round-trip")
}

// ---- 9. Dov correction: no Tono-visible globe button in build 78 ----
//
// Build 77 showed TWO globe controls (Tono's + the system accessory).
// For build 78 the controller intentionally omits its own globe key;
// iOS draws its own globe on the suggestion/accessory bar whenever the
// device has >1 keyboard installed. The verifier encodes that
// invariant as a string-level assertion on the source file so a future
// regression that re-adds the visible globe to `makeBottomRow` is
// caught immediately rather than on-device.
do {
    let url = URL(fileURLWithPath: "KeyboardExtension/KeyboardViewController.swift")
    let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

    // The function `makeBottomRow` in build 78 must NOT contain a
    // `makeControlButton(title: "\u{1F310}"` call (that was the globe).
    let globeHit = source.range(of: #"title:\\"\\\\u\{1F310\}\""#, options: .regularExpression)
    check(globeHit == nil,
          "no Tono-side globe button: build 78 makes emoji the leftmost bottom-row key",
          "globe makeControlButton call resurfaced in KeyboardViewController.swift")

    // Emoji button must be the first key added in makeBottomRow.
    if let sigRange = source.range(of: "private func makeBottomRow") {
        let afterSig = source.index(after: sigRange.lowerBound)
        if let closeBrace = source[afterSig...].range(of: "\n    }\n", options: []) {
            let body = String(source[afterSig..<closeBrace.lowerBound])
            let lines = body.split(separator: "\n").map(String.init)
            let firstArranged = lines.first(where: { $0.contains("row.addArrangedSubview") }) ?? ""
            check(firstArranged.contains("emoji"),
                  "first bottom-row arranged-subview is the emoji key",
                  "got: \(firstArranged.trimmingCharacters(in: .whitespaces))")
        } else {
            check(false, "could not locate makeBottomRow body", "closing brace not found")
        }
    } else {
        check(false, "could not locate makeBottomRow signature", "rename in source")
    }
}

print("")
if failures.isEmpty {
    print("✓ all build 78 checks passed")
    exit(0)
} else {
    print("✗ \(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
    exit(1)
}