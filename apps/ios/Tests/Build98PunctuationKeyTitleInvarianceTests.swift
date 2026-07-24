// Build98PunctuationKeyTitleInvarianceTests.swift
// Build 98 — period-into-"letter" shipping-defect regression guard.
//
// TASK CONTEXT — t_82a01efe:
//
// Dov's screenshot of build 97 on numeric layout showed a deterministic
// shipping defect: the period key initially renders `.`, then after
// the FIRST keypress anywhere on the keyboard it becomes the literal
// word `letter`. Root cause isolated in `KeyboardViewController.swift`:
//
//   * `makeCharButton(_:)` assigns every char the identifier
//     `"TonoKB.letter.\(char)"` — so the period produces
//     `"TonoKB.letter."` (trailing dot, empty char component).
//   * `applyShiftToKey(_:)` later matches `id.hasPrefix("TonoKB.letter.")`
//     and parses with `id.split(separator: ".").last`. Swift's
//     `String.split` defaults to `omittingEmptySubsequences: true`,
//     so the trailing empty component is dropped and `.last` becomes
//     the literal substring `"letter"`.
//   * `displayLetter("letter")` returns `"letter"` (since `"letter"`
//     is not in `[a-zA-Z]`, the lowercase/uppercase branch is a
//     no-op), so the period key's title gets overwritten with
//     `"letter"`.
//
// Every punctuation/number/symbol key that breaks the identifier
// contract would hit the same bug. The fix in build 98 splits the
// identifier into a letter-only path (collision-safe parse via a
// single-ASCII-letter guard) and a non-letter path (no parse, no
// refresh). This test exercises both paths and asserts the keycap
// titles never drift to the literal word `letter` or any other
// non-self substring.
//
// Every test here is regression-grade: it would have failed against
// the build-97 `applyShiftToKey` parse.

import XCTest
import UIKit

@MainActor
final class Build98PunctuationKeyTitleInvarianceTests: XCTestCase {

    // The exact punctuation / number / symbol keys Tono ships on
    // numeric (#+=/123) and symbol layers. Each was vulnerable to
    // the same `letterId(_:)` + `id.split(separator: ".").last`
    // parsing ambiguity in build 97.
    private static let allPunctuationAndSymbols: [String] = [
        // numRow1
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
        // numRow2
        "-", "/", ":", ";", "(", ")", "$", "&", "@", "\"",
        // numRow3 (also symRow3)
        ".", ",", "?", "!", "'",
        // symRow1
        "[", "]", "{", "}", "#", "%", "^", "*", "+", "=",
        // symRow2
        "_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•",
    ]

    // MARK: - Baseline regression: bug-as-shipped

    /// The shipped build-97 bug. Build a fresh keyboard on the numeric
    /// layer, locate the period key, and trigger the exact path that
    /// causes the corruption: tap the shift key once
    /// (`shiftSingleTapped` calls `relayoutLettersForShift` →
    /// `applyShiftToKey(b)` for every button in every row). Assert
    /// the period key still shows `.`, NOT the literal `letter`.
    ///
    /// This test would FAIL against build 97 because build 97's
    /// `applyShiftToKey` would `setTitle("letter", for: .normal)`
    /// after parsing `"TonoKB.letter."`.
    func testPeriodKeyTitleSurvivesShiftRefresh() throws {
        let controller = try Self.makeController(in: .numbers, width: 402)
        let period = try Self.locateKey(in: controller.view, char: ".")
        XCTAssertEqual(
            period.title(for: .normal), ".",
            "baseline: period key on numeric layer must show '.' before any shift refresh"
        )

        // The shipping bug trigger: tapping shift calls
        // relayoutLettersForShift → applyShiftToKey(b) for every
        // button. Swift private (no @objc) means we can't perform()
        // it directly; we trigger it via the @objc shiftSingleTapped
        // selector — the exact user gesture path.
        controller.perform(NSSelectorFromString("shiftSingleTapped"))

        XCTAssertEqual(
            period.title(for: .normal), ".",
            "period key must still show '.' after shiftSingleTapped refresh — " +
            "got '\(period.title(for: .normal) ?? "<nil>")' instead. " +
            "build 97 produced 'letter' here (t_82a01efe shipping defect)."
        )
    }

    /// Same regression, but walking the WHOLE numeric layer at once via
    /// `relayoutLettersForShift` triggered by shiftSingleTapped. Every
    /// punctuation / number / symbol key must keep its exact glyph;
    /// none must collapse to `letter` or any other non-self substring.
    func testAllNumericPunctuationTitlesSurviveShiftRefresh() throws {
        for char in Self.allPunctuationAndSymbols {
            // `numRow3` keys (`.,?!\`) are also on `symRow3` — exercise
            // them in both layers; the other rows are only on one.
            let modes: [TestMode] = char == "." || char == "," || char == "?" || char == "!" || char == "'"
                ? [.numbers, .symbols]
                : (Self.symbolsOnlyKeys.contains(char) ? [.symbols] : [.numbers])
            for mode in modes {
                let controller = try Self.makeController(in: mode, width: 402)
                let key = try Self.locateKey(in: controller.view, char: char)
                let titleBefore = key.title(for: .normal)
                XCTAssertEqual(
                    titleBefore, char,
                    "baseline: \(char) key on \(mode) layer must show '\(char)' before refresh"
                )

                controller.perform(NSSelectorFromString("shiftSingleTapped"))

                let titleAfter = key.title(for: .normal)
                XCTAssertEqual(
                    titleAfter, char,
                    "\(char) key on \(mode) layer must still show '\(char)' after " +
                    "shiftSingleTapped — got '\(titleAfter ?? "<nil>")'. " +
                    "t_82a01efe regression: build 97 produced 'letter' here."
                )
            }
        }
    }

    /// Specifically targeted at the exact reported failure mode: enter
    /// numeric layer, tap the shift key (any user gesture that
    /// triggers the shift refresh), and confirm the period key still
    /// reads `.`. Simulates the user typing `. ` and the period
    /// turning into `letter` on the second keystroke (which is what
    /// Dov's screenshot shows).
    func testPeriodKeySurvivesAnyKeypressSimulation() throws {
        let controller = try Self.makeController(in: .numbers, width: 402)
        let period = try Self.locateKey(in: controller.view, char: ".")
        let otherKey = try Self.locateKey(in: controller.view, char: "5")

        // Simulate "tap any key" — fire the same refresh the keyboard
        // performs after every shift tap.
        controller.perform(NSSelectorFromString("shiftSingleTapped"))

        XCTAssertEqual(
            period.title(for: .normal), ".",
            "after refresh: period must remain '.' — got " +
            "'\(period.title(for: .normal) ?? "<nil>")'"
        )
        XCTAssertEqual(
            otherKey.title(for: .normal), "5",
            "after refresh: '5' must remain '5' — got " +
            "'\(otherKey.title(for: .normal) ?? "<nil>")'"
        )
    }

    // MARK: - Identifier-collision regression

    /// The build-97 identifier scheme produced `"TonoKB.letter."` for
    /// the period key. Build 98's fix uses a collision-proof scheme
    /// (non-`.` separator, OR single-letter-prefixed scheme) such that
    /// the parsed raw is the actual character for letters, and the
    /// identifier for non-letters cannot be parsed back through
    /// `id.split(separator: ".").last` to a non-self substring.
    ///
    /// Concrete acceptance: NO shipping key has an accessibility
    /// identifier ending in `.` followed by an empty token that, when
    /// split, parses back to `letter` or any other non-self substring.
    func testNoKeyIdentifierParsesToLiteralLetter() throws {
        for mode: TestMode in [.letters, .numbers, .symbols] {
            let controller = try Self.makeController(in: mode, width: 402)
            for key in Self.allCharButtons(in: controller.view) {
                guard let id = key.accessibilityIdentifier else { continue }
                guard id.hasPrefix("TonoKB.letter.") else {
                    // Build 98's fix moves non-letter keys to a different
                    // identifier scheme (or guards `applyShiftToKey`
                    // to only the letter path); in either case, the
                    // identifier must not be parseable as `letter`.
                    let last = id.split(separator: ".").last.map(String.init)
                    XCTAssertNotEqual(
                        last, "letter",
                        "\(mode) key '\(key.title(for: .normal) ?? "?")' identifier " +
                        "'\(id)' parses back to the literal 'letter'. This is the " +
                        "build-97 period regression applied to non-letter keys."
                    )
                    continue
                }
                // Letter keys: the parsed raw MUST be exactly one ASCII letter.
                guard let raw = id.split(separator: ".").last.map(String.init),
                      raw.count == 1,
                      raw.first?.isASCII == true,
                      raw.first?.isLetter == true else {
                    XCTFail(
                        "\(mode) letter key '\(id)' parsed raw '\(id.split(separator: ".").last.map(String.init) ?? "?")' " +
                        "is not a single ASCII letter. Identifiers must round-trip " +
                        "to the actual character."
                    )
                    continue
                }
                XCTAssertEqual(
                    raw.lowercased(), key.title(for: .normal)?.lowercased(),
                    "letter key '\(id)' parsed raw '\(raw)' must equal the rendered title"
                )
            }
        }
    }

    /// Letter keys still honor `applyShiftToKey` — the shift refresh
    /// MUST still update letter titles to lowercase/uppercase depending
    /// on the shift state. Regression guard against over-correction
    /// (the fix must NOT disable letter shift/title refresh).
    func testLetterKeysStillHonorShiftRefresh() throws {
        let controller = try Self.makeController(in: .letters, width: 402)
        let q = try Self.locateKey(in: controller.view, char: "q")

        // Default state: shift is .lowercase → title is `q`.
        XCTAssertEqual(q.title(for: .normal), "q", "baseline lowercase")

        // Toggle shift via the @objc selector — same path the user
        // gesture (UITapGestureRecognizer) invokes internally.
        controller.perform(NSSelectorFromString("shiftSingleTapped"))

        XCTAssertEqual(q.title(for: .normal), "Q", "after single-tap shift: q → Q")

        // Refresh must not corrupt Q back to `letter`.
        controller.perform(NSSelectorFromString("shiftSingleTapped"))
        XCTAssertEqual(q.title(for: .normal), "q", "after second tap: Q → q")
    }

    // MARK: - Mode-toggle regression

    /// The shift refresh must NOT corrupt punctuation keys across
    /// number↔symbol↔letter toggles. Simulates the user cycling the
    /// bottom row `123`/`ABC` mode toggle and the row-3 `#+=/123`
    /// toggle while punctuation keys are visible.
    func testPunctuationKeysSurviveModeToggles() throws {
        let controller = try Self.makeController(in: .letters, width: 402)

        // letters → numbers via @objc bottom-mode selector.
        controller.perform(NSSelectorFromString("bottomModeTapped"))

        for char in ["1", ".", "$"] {
            let key = try Self.locateKey(in: controller.view, char: char)
            XCTAssertEqual(
                key.title(for: .normal), char,
                "after letters→numbers toggle: '\(char)' must show '\(char)'"
            )
        }

        // numbers → symbols via @objc third-row-mode selector.
        controller.perform(NSSelectorFromString("thirdRowModeTapped"))

        for char in ["[", ".", "€"] {
            let key = try Self.locateKey(in: controller.view, char: char)
            XCTAssertEqual(
                key.title(for: .normal), char,
                "after numbers→symbols toggle: '\(char)' must show '\(char)'"
            )
        }
    }

    /// Per-target layout mode selector. The `KeyboardLayoutMode` enum
    /// is nested inside `KeyboardViewController` and is therefore
    /// private to the extension; we mirror the integer raw values
    /// via KVC so the test target does not need the type. Build 97
    /// confirms: `.letters` is the default (rawValue 0),
    /// `.numbers` is `1`, `.symbols` is `2`.
    private enum TestMode: Int {
        case letters = 0
        case numbers = 1
        case symbols = 2
    }

    // MARK: - Helpers

    /// Keys only on the symbols layer — exercised only there to avoid
    /// false-positive layout mismatches.
    private static let symbolsOnlyKeys: Set<String> = [
        "[", "]", "{", "}", "#", "%", "^", "*", "+", "=",
        "_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•",
    ]

    private static func makeController(in mode: TestMode, width: CGFloat) throws -> KeyboardViewController {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 320)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        // Force the layout into the requested mode via the bottom-row
        // / row-3 mode selectors — same path the user invokes. The
        // `layoutMode` storage is private Swift (no KVC); we don't
        // try to read it back. The keyboard's own NSLog prints the
        // resulting mode for diagnostic confirmation.
        switch mode {
        case .letters:
            // Already on letters (default after viewDidLoad). No-op.
            break
        case .numbers:
            controller.perform(NSSelectorFromString("bottomModeTapped"))
        case .symbols:
            // letters → numbers → symbols.
            controller.perform(NSSelectorFromString("bottomModeTapped"))
            controller.perform(NSSelectorFromString("thirdRowModeTapped"))
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return controller
    }

    private static func allCharButtons(in root: UIView) -> [UIButton] {
        var result: [UIButton] = []
        collectCharButtons(in: root, into: &result)
        return result
    }

    private static func collectCharButtons(in view: UIView, into result: inout [UIButton]) {
        if let button = view as? UIButton, button.accessibilityIdentifier != nil {
            result.append(button)
        }
        for child in view.subviews {
            collectCharButtons(in: child, into: &result)
        }
    }

    private static func locateKey(in root: UIView, char: String) throws -> UIButton {
        for candidate in allCharButtons(in: root) {
            guard let id = candidate.accessibilityIdentifier else { continue }
            // Letter keys: identifier is "TonoKB.letter.<ch>".
            if id == "TonoKB.letter.\(char)" { return candidate }
            // Non-letter keys: identifier is build-98 collision-proof
            // scheme; match by raw char in the identifier suffix OR by
            // current title (whichever is unambiguous for the char).
            if candidate.title(for: .normal) == char { return candidate }
        }
        throw NSError(
            domain: "Build98Punctuation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate key for char '\(char)'"]
        )
    }

    private static func locateShift(in root: UIView) throws -> UIButton {
        for view in allCharButtons(in: root) where view.accessibilityIdentifier == "TonoKB.shift" {
            return view
        }
        throw NSError(
            domain: "Build98Punctuation",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "could not locate shift key"]
        )
    }

    private static func locateModeToggle(in root: UIView, label: String) throws -> UIButton {
        for view in allCharButtons(in: root) {
            guard let id = view.accessibilityIdentifier else { continue }
            guard id.hasPrefix("TonoKB.modeToggle.") else { continue }
            guard view.title(for: .normal) == label else { continue }
            return view
        }
        throw NSError(
            domain: "Build98Punctuation",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "could not locate mode toggle '\(label)'"]
        )
    }

    // MARK: - Visual evidence (Dov's screenshot proof)

    /// Capture a PNG of the keyboard on a given layer, both before and
    /// after a shift refresh. The PNGs are written into
    /// `tests_artifacts/` under the test bundle and surfaced via
    /// `XCTAttachment` so xcresult carries them as durable shipping
    /// evidence. The assertion is the same as the title-text checks
    /// above; the screenshot is the receipt.
    func testCaptureScreenshotEvidenceForPunctuationSurvival() throws {
        let cases: [(TestMode, String, String)] = [
            (.numbers, "t_82a01efe-build98-numeric-before-shift", "t_82a01efe-build98-numeric-after-shift"),
            (.symbols, "t_82a01efe-build98-symbol-before-shift", "t_82a01efe-build98-symbol-after-shift"),
        ]
        for (mode, beforeName, afterName) in cases {
            let controller = try Self.makeController(in: mode, width: 402)
            controller.view.bounds = CGRect(x: 0, y: 0, width: 402, height: 320)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()

            // BEFORE: the period key (or row-3 punctuation in symbols)
            // must already show its exact glyph.
            let period = try Self.locateKey(in: controller.view, char: ".")
            XCTAssertEqual(
                period.title(for: .normal), ".",
                "pre-shift: '\(mode)' period must be '.' — got " +
                "'\(period.title(for: .normal) ?? "<nil>")'"
            )
            attachScreenshot(
                of: controller.view,
                name: beforeName,
                note: "build98 \(mode) layer BEFORE shift refresh — period = '.'"
            )

            // Trigger the exact shipping-path defect: shift tap
            // invokes relayoutLettersForShift → applyShiftToKey(b)
            // for every button in every row. Build 97 corrupted the
            // period to `letter` here; build 98 must not.
            controller.perform(NSSelectorFromString("shiftSingleTapped"))
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()

            XCTAssertEqual(
                period.title(for: .normal), ".",
                "post-shift: '\(mode)' period must STILL be '.' — got " +
                "'\(period.title(for: .normal) ?? "<nil>")'. " +
                "This is the build-97 shipping defect (t_82a01efe)."
            )
            attachScreenshot(
                of: controller.view,
                name: afterName,
                note: "build98 \(mode) layer AFTER shift refresh — period = '.' (build 97 produced 'letter')"
            )
        }
    }

    /// Render `view` into a PNG and attach it to the test via
    /// `XCTAttachment` so it ends up in the xcresult bundle. Also
    /// drops a copy into `/tmp/build98_screenshots/` for quick
    /// visual inspection from the host shell.
    private func attachScreenshot(of view: UIView, name: String, note: String) {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard let data = image.pngData() else { return }

        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        attachment.userInfo = ["note": note]
        add(attachment)

        // Also persist a copy the kanban pipeline can pick up.
        let dir = URL(fileURLWithPath: "/tmp/build98_screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outPath = dir.appendingPathComponent("\(name).png")
        try? data.write(to: outPath)
    }
}