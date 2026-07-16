// LiveToneCoreTests.swift
// Tono Live Tone v1.1 — build 90 experiment, Opus 4.8 core lane.
//
// Covers the pure core in isolation:
//   * classifier rule behavior + normalization
//   * boundary-trigger contract (commit boundaries, not per-keystroke)
//   * session state machine (fail-closed, no persistence)
//   * the >=200-message labeled corpus with an exact false-positive bound
//   * determinism across 100 offline runs
//   * bounded, sub-2ms evaluation
//   * static source guards proving the core files contain no networking,
//     pasteboard, timer, persistence, or document-mutation tokens
//
// The corpus and source files are read from disk. Path resolution prefers
// the TONO_IOS_ROOT environment variable (used by the headless SPM runner)
// and otherwise derives apps/ios from this file's own #filePath, matching
// the existing DiagnosticsSourceGuardTests convention.

import XCTest
import Foundation
@testable import Tono

// MARK: - Shared path resolution

private enum CoreTestPaths {
    static var iosRoot: URL {
        if let env = ProcessInfo.processInfo.environment["TONO_IOS_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // apps/ios/
    }

    static var corpusURL: URL {
        iosRoot
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("live_tone_corpus.json", isDirectory: false)
    }

    static func source(_ relative: String) -> URL {
        iosRoot.appendingPathComponent(relative, isDirectory: false)
    }
}

// MARK: - Classifier rules & normalization

final class LiveToneClassifierTests: XCTestCase {
    private let classifier = LiveToneClassifier()

    func testEmptyAndNilAreSilent() {
        XCTAssertEqual(classifier.classify(nil), .silent)
        XCTAssertEqual(classifier.classify(""), .silent)
        XCTAssertEqual(classifier.classify("   \n  "), .silent)
        XCTAssertFalse(classifier.classify(nil).shouldHint)
    }

    func testBenignDraftDoesNotHint() {
        for draft in ["Sounds good, see you at 7!", "Thanks for the ride!",
                      "I need to relax tonight.", "That's on the list for later."] {
            let verdict = classifier.classify(draft)
            XCTAssertFalse(verdict.shouldHint, "unexpected hint on: \(draft)")
            XCTAssertEqual(verdict.rule, LiveToneRule.none)
        }
    }

    func testEachRuleFiresOnItsCanonicalMarker() {
        let cases: [(String, LiveToneRule)] = [
            ("As per my last email, this was covered.", .priorMessageReference),
            ("That's not my problem.", .dismissiveDeflection),
            ("You need to calm down.", .condescension),
            ("Thanks for nothing.", .hostileSarcasm),
        ]
        for (draft, expected) in cases {
            let verdict = classifier.classify(draft)
            XCTAssertTrue(verdict.shouldHint, "expected hint on: \(draft)")
            XCTAssertEqual(verdict.rule, expected, "wrong rule for: \(draft)")
        }
    }

    func testNormalizationFoldsCaseSmartQuotesAndSpacing() {
        // Uppercase, curly apostrophe, em dash, and doubled spaces must all
        // still match the ASCII lower-case markers.
        XCTAssertTrue(classifier.classify("LOOK,  AS  PER  MY  LAST note.").shouldHint)
        XCTAssertTrue(classifier.classify("honestly it’s not rocket science.").shouldHint)
        XCTAssertTrue(classifier.classify("for the last time — stop.").shouldHint)
    }

    func testNearMissesStaySilentProvingPrecision() {
        // Substrings that resemble a marker but are not it.
        let nearMisses = [
            "I need to relax tonight.",            // not "you need to relax"
            "That's on the list for tomorrow.",    // not "that's on you"
            "My job is remote now.",               // not "not my job"
            "The problem is fixed.",               // not "not my problem"
            "Whatever works for you!",             // not "whatever you say"
            "Just say so if you need me.",         // not "if you say so"
            "Thanks for the ride!",                // not "thanks for nothing"
        ]
        for draft in nearMisses {
            XCTAssertFalse(classifier.classify(draft).shouldHint, "near-miss hinted: \(draft)")
        }
    }

    func testVersionIsPinned() {
        XCTAssertEqual(LiveToneClassifier.version, 1)
    }
}

// MARK: - Boundary contract

final class LiveToneBoundaryTests: XCTestCase {
    func testSentenceTerminatorsAreBoundaries() {
        let samples: [(String, Character)] = [
            ("Hi there", "."), ("What", "!"), ("Really", "?"),
            ("wait", "…"), ("done", "\n"),
        ]
        for (preceding, terminator) in samples {
            XCTAssertTrue(
                LiveToneBoundary.isEvaluationBoundary(
                    precedingText: preceding, commit: .character(terminator)
                ),
                "expected boundary for terminator \(terminator)"
            )
        }
    }

    func testSpaceClosingAWordIsABoundary() {
        XCTAssertTrue(
            LiveToneBoundary.isEvaluationBoundary(precedingText: "hello", commit: .character(" "))
        )
    }

    func testMidWordCharactersAreNotBoundaries() {
        // A letter keystroke is never a commit boundary.
        XCTAssertFalse(
            LiveToneBoundary.isEvaluationBoundary(precedingText: "hell", commit: .character("o"))
        )
    }

    func testSpaceWithNoWordYetIsNotABoundary() {
        XCTAssertFalse(
            LiveToneBoundary.isEvaluationBoundary(precedingText: "", commit: .character(" "))
        )
        XCTAssertFalse(
            LiveToneBoundary.isEvaluationBoundary(precedingText: "   ", commit: .character(" "))
        )
        XCTAssertFalse(
            LiveToneBoundary.isEvaluationBoundary(precedingText: nil, commit: .character(" "))
        )
    }

    func testWordCommitIsABoundaryWhenTextExists() {
        XCTAssertTrue(
            LiveToneBoundary.isEvaluationBoundary(precedingText: "hello", commit: .wordCommit)
        )
        XCTAssertFalse(
            LiveToneBoundary.isEvaluationBoundary(precedingText: "", commit: .wordCommit)
        )
    }
}

// MARK: - Session state machine

final class LiveToneSessionTests: XCTestCase {
    func testStartsDisabledAndSilent() {
        let session = LiveToneSession()
        XCTAssertEqual(session.state, .disabled)
        XCTAssertFalse(session.state.isDecorationVisible)
    }

    func testDisabledSwallowsBoundaries() {
        var session = LiveToneSession()
        session.handle(.boundaryReached(draft: "As per my last email."))
        XCTAssertEqual(session.state, .disabled)
    }

    func testEnableThenRiskyDraftHints() {
        var session = LiveToneSession()
        session.handle(.enable)
        XCTAssertEqual(session.state, .idle)
        session.handle(.boundaryReached(draft: "That's not my problem."))
        XCTAssertEqual(session.state, .hinted(.dismissiveDeflection))
        XCTAssertTrue(session.state.isDecorationVisible)
    }

    func testEnableThenBenignDraftStaysIdle() {
        var session = LiveToneSession()
        session.handle(.enable)
        session.handle(.boundaryReached(draft: "Sounds good, see you soon!"))
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.state.isDecorationVisible)
    }

    func testNilDraftFailsClosed() {
        var session = LiveToneSession(state: .idle)
        session.handle(.boundaryReached(draft: nil))
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.state.isDecorationVisible)
    }

    func testDismissSuppressesUntilFieldReset() {
        var session = LiveToneSession(state: .idle)
        session.handle(.boundaryReached(draft: "Thanks for nothing."))
        XCTAssertEqual(session.state, .hinted(.hostileSarcasm))
        session.handle(.hintDismissed)
        XCTAssertEqual(session.state, .suppressed)
        // Suppressed swallows further boundaries — no nagging.
        session.handle(.boundaryReached(draft: "No offense but you always do this."))
        XCTAssertEqual(session.state, .suppressed)
        // A new field clears suppression.
        session.handle(.fieldReset)
        XCTAssertEqual(session.state, .idle)
        session.handle(.boundaryReached(draft: "No offense but you always do this."))
        XCTAssertEqual(session.state, .hinted(.condescension))
    }

    func testDisableFromAnyStateReturnsToDisabled() {
        for start in [LiveToneState.idle, .evaluating, .hinted(.condescension), .suppressed] {
            var session = LiveToneSession(state: start)
            session.handle(.disable)
            XCTAssertEqual(session.state, .disabled)
        }
    }

    func testFieldResetPreservesDisabledAxis() {
        var disabled = LiveToneSession(state: .disabled)
        disabled.handle(.fieldReset)
        XCTAssertEqual(disabled.state, .disabled)

        var hinted = LiveToneSession(state: .hinted(.condescension))
        hinted.handle(.fieldReset)
        XCTAssertEqual(hinted.state, .idle)
    }

    func testNoPersistenceAcrossFreshSessions() {
        var first = LiveToneSession(state: .idle)
        first.handle(.boundaryReached(draft: "Thanks for nothing."))
        XCTAssertEqual(first.state, .hinted(.hostileSarcasm))
        // A brand-new session shares no state with the previous one.
        let second = LiveToneSession()
        XCTAssertEqual(second.state, .disabled)
    }

    func testReHintReplacesStaleRuleOnNewBoundary() {
        var session = LiveToneSession(state: .hinted(.hostileSarcasm))
        session.handle(.boundaryReached(draft: "Sounds good!"))
        XCTAssertEqual(session.state, .idle, "a benign re-evaluation must clear the stale hint")
    }
}

// MARK: - Corpus fixture

private struct CorpusMessage: Decodable {
    let id: Int
    let text: String
    let risky: Bool
}

private struct Corpus: Decodable {
    let schemaVersion: Int
    let classifierVersion: Int
    let messages: [CorpusMessage]
}

final class LiveToneCorpusTests: XCTestCase {
    private let classifier = LiveToneClassifier()

    private func loadCorpus() throws -> Corpus {
        let data = try Data(contentsOf: CoreTestPaths.corpusURL)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    func testCorpusIsAtLeast200AndVersioned() throws {
        let corpus = try loadCorpus()
        XCTAssertGreaterThanOrEqual(corpus.messages.count, 200)
        XCTAssertEqual(corpus.classifierVersion, LiveToneClassifier.version)
        // ids are unique and dense.
        XCTAssertEqual(Set(corpus.messages.map(\.id)).count, corpus.messages.count)
    }

    /// The binding product contract: false positives (a hint on a
    /// ground-truth-benign message) must be <= 1/20 of the corpus.
    func testFalsePositiveRateWithinContract() throws {
        let corpus = try loadCorpus()
        var truePos = 0, falsePos = 0, trueNeg = 0, falseNeg = 0
        for message in corpus.messages {
            let hinted = classifier.classify(message.text).shouldHint
            switch (message.risky, hinted) {
            case (true, true): truePos += 1
            case (false, true): falsePos += 1
            case (false, false): trueNeg += 1
            case (true, false): falseNeg += 1
            }
        }
        let total = corpus.messages.count
        let budget = total / 20   // 1/20 of the corpus
        print("""
        [live-tone corpus] total=\(total) \
        TP=\(truePos) FP=\(falsePos) TN=\(trueNeg) FN=\(falseNeg) \
        FP-budget=\(budget)
        """)
        XCTAssertLessThanOrEqual(
            falsePos, budget,
            "false positives \(falsePos) exceed 1/20 budget of \(budget)"
        )
        // Guard against a trivially-silent classifier passing the FP bound.
        XCTAssertGreaterThan(truePos, 0, "classifier never fired — rules are dead")
    }

    /// Determinism: identical verdicts across 100 offline passes over the
    /// whole corpus. No clock, no network, no randomness are involved.
    func testDeterministicAcross100Runs() throws {
        let corpus = try loadCorpus()
        let baseline = corpus.messages.map { classifier.classify($0.text) }
        for _ in 0..<100 {
            let again = corpus.messages.map { classifier.classify($0.text) }
            XCTAssertEqual(again, baseline)
        }
    }

    /// Performance: mean evaluation well under the 2ms target, and bounded
    /// work on a pathologically long draft (no unbounded allocation/scan).
    func testEvaluationIsFastAndBounded() throws {
        let corpus = try loadCorpus()
        let iterations = 20
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            for message in corpus.messages { _ = classifier.classify(message.text) }
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start
        let perCallMillis = Double(elapsedNanos) / 1_000_000.0
            / Double(iterations * corpus.messages.count)
        print("[live-tone perf] mean \(String(format: "%.4f", perCallMillis)) ms/eval")
        XCTAssertLessThanOrEqual(perCallMillis, 2.0, "evaluation exceeded 2ms target")

        // A pathologically long draft must normalize to a bounded prefix and
        // classify in time that does NOT scale with field size. Absolute wall
        // time is hardware/CI-dependent (the worst case scans the full
        // maxScannedCharacters prefix against every marker with no early
        // match), so we test the actual property — "not O(field size)" — by
        // comparing a draft 100x over the cap against one right at the cap.
        // Both scan the same bounded prefix, so their cost is within a small
        // constant factor regardless of hardware.
        let atCap = String(repeating: "the quick brown fox. ", count: 100)   // ~2.1k chars
        let huge = String(repeating: "the quick brown fox. ", count: 10_000) // ~210k chars
        XCTAssertGreaterThan(atCap.count, LiveToneClassifier.maxScannedCharacters)
        XCTAssertGreaterThan(huge.count, LiveToneClassifier.maxScannedCharacters)
        XCTAssertEqual(huge.count, atCap.count * 100)
        XCTAssertLessThanOrEqual(
            LiveToneClassifier.normalize(huge).count,
            LiveToneClassifier.maxScannedCharacters
        )

        func minClassifyMillis(_ text: String) -> Double {
            _ = classifier.classify(text) // warm caches/allocator
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = classifier.classify(text)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0)
            }
            return best
        }

        let capMillis = minClassifyMillis(atCap)
        let hugeMillis = minClassifyMillis(huge)
        print("[live-tone perf] atCap \(String(format: "%.4f", capMillis)) ms, huge \(String(format: "%.4f", hugeMillis)) ms")
        // If scanning were O(field size), huge (100x the input) would take ~100x
        // longer. Bounded scanning keeps it within a small constant factor.
        XCTAssertLessThanOrEqual(
            hugeMillis, max(capMillis * 4.0, 0.25),
            "large-draft evaluation scaled with field size (scan is not bounded)"
        )
    }
}

// MARK: - Static source guards

final class LiveToneSourceGuardTests: XCTestCase {
    private static let coreFiles = [
        "Shared/LiveToneClassifier.swift",
        "Shared/LiveToneSession.swift",
    ]

    /// Networking, pasteboard, timer, persistence, document-mutation, and
    /// UIKit tokens that must never appear in the local, passive core.
    private static let bannedTokens = [
        // networking
        "URLSession", "URLRequest", "NSURLConnection", "CFNetwork",
        "import Network", "NWConnection", "Socket", "dataTask", "URLComponents",
        // pasteboard
        "UIPasteboard", "NSPasteboard", "pasteboard", "Pasteboard",
        // timers / scheduling
        "Timer", "scheduledTimer", "DispatchSourceTimer", "CADisplayLink", "asyncAfter",
        // persistence / disk
        "UserDefaults", "FileManager", "NSKeyedArchiver", ".write(to", "contentsOf:",
        "Keychain", "SQLite", "CoreData",
        // document mutation / keyboard proxy
        "UITextDocumentProxy", "insertText", "deleteBackward", "setMarkedText",
        "adjustTextPosition",
        // UI frameworks — the core is headless
        "import UIKit", "import SwiftUI",
    ]

    private func sourceText(_ relative: String) throws -> String {
        try String(contentsOf: CoreTestPaths.source(relative), encoding: .utf8)
    }

    func testCoreFilesExist() throws {
        for file in Self.coreFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: CoreTestPaths.source(file).path),
                "missing core file \(file)"
            )
        }
    }

    func testCoreFilesContainNoBannedTokens() throws {
        for file in Self.coreFiles {
            let text = try sourceText(file)
            for token in Self.bannedTokens {
                XCTAssertFalse(
                    codeContains(text, token: token),
                    "banned token '\(token)' found in \(file)"
                )
            }
        }
    }

    func testCoreFilesImportOnlyFoundation() throws {
        for file in Self.coreFiles {
            let text = try sourceText(file)
            let imports = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }
            XCTAssertEqual(imports, ["import Foundation"], "unexpected imports in \(file): \(imports)")
        }
    }

    /// Scan only real code: strip `//` line comments so that documentation
    /// mentioning a token (e.g. the word "timer" in a comment) never trips
    /// the guard, while any real API use does.
    private func codeContains(_ text: String, token: String) -> Bool {
        for rawLine in text.components(separatedBy: .newlines) {
            let code: Substring
            if let range = rawLine.range(of: "//") {
                code = rawLine[rawLine.startIndex..<range.lowerBound]
            } else {
                code = rawLine[...]
            }
            if code.contains(token) { return true }
        }
        return false
    }
}
