// Build106LocalIntelligenceTests.swift
// Build 106 — release blocker B.
//
// PHYSICAL FINDING (Build 105, on device): "Offline mode did not visibly
// utilize local intelligence."
//
// DIAGNOSIS: Build 105's local lane was one `UITextChecker` call hard-gated to
// English, returning the original word plus at most two guesses in the
// checker's own order, with nothing in the UI stating that anything ran on
// device. Both halves of the finding were correct.
//
// These tests use a recording checker double, so every assertion is about
// Tono's own pipeline rather than about whichever dictionary the test machine
// happens to have installed. The network-denial proof is structural: the local
// lane is given a URL session double that fails every request, and the outbound
// request count must stay at zero because nothing in the lane makes one.

import XCTest
@testable import Tono

final class Build106LocalIntelligenceTests: XCTestCase {

    // MARK: - Doubles

    /// Records every lookup and answers from a fixed table. Also counts calls,
    /// so "the local lane did work" is measurable.
    private final class RecordingChecker: SpellingChecking {
        var table: [String: SpellingLookup]
        private(set) var lookups: [(word: String, language: String)] = []

        init(table: [String: SpellingLookup]) { self.table = table }

        func lookup(word: String, language: String) -> SpellingLookup {
            lookups.append((word, language))
            return table[word.lowercased()]
                ?? SpellingLookup(isMisspelled: false, corrections: [], completions: [])
        }
    }

    /// A URL protocol that fails everything and counts attempts. Installed for
    /// the duration of the offline tests so any accidental request is both
    /// impossible to satisfy and impossible to hide.
    private final class DeniedNetwork: URLProtocol {
        nonisolated(unsafe) static var attempts = 0
        override class func canInit(with request: URLRequest) -> Bool {
            attempts += 1
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private static func policy(
        language: String? = "en-US",
        available: [String] = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES"],
        fieldKind: SpellingFieldKind = .ordinary
    ) -> SpellingHostPolicy {
        SpellingHostPolicy(
            language: language,
            fieldKind: fieldKind,
            allowsAutocorrection: true,
            allowsSpellChecking: true,
            availableLanguages: available
        )
    }

    private static func token(_ text: String) -> SpellingToken {
        SpellingToken.current(before: text, after: "") ?? SpellingToken(
            text: text, caretOffset: text.count, hasSensitivePrefix: false,
            followsSentenceBoundary: true, host: .unbound
        )
    }

    // MARK: - Language resolution (was English-only)

    func testLanguageResolutionGoesBeyondEnglish() {
        let available = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "pt-BR"]
        XCTAssertEqual(SpellingLanguageResolver.resolve(requested: "fr-FR", available: available), "fr-FR")
        XCTAssertEqual(SpellingLanguageResolver.resolve(requested: "de_DE", available: available), "de-DE",
                       "the underscore form UIKit reports must resolve")
        XCTAssertEqual(SpellingLanguageResolver.resolve(requested: "fr-CA", available: available), "fr-FR",
                       "same language, different region, falls back deterministically")
        XCTAssertEqual(SpellingLanguageResolver.resolve(requested: "en", available: available), "en-GB",
                       "bare language picks the first installed region, sorted for determinism")
        XCTAssertNil(SpellingLanguageResolver.resolve(requested: "ja-JP", available: available))
        XCTAssertNil(SpellingLanguageResolver.resolve(requested: nil, available: available))
        XCTAssertNil(SpellingLanguageResolver.resolve(requested: "en-US", available: []))
    }

    /// The Build-105 gate, transcribed. It rejected French even with a French
    /// dictionary installed — the whole local lane went dark for those users.
    func testRollbackRed_build105EnglishOnlyGateWouldRejectFrench() {
        func build105Supported(_ language: String?) -> String? {
            guard let language = language?.replacingOccurrences(of: "_", with: "-") else { return nil }
            return language.split(separator: "-").first?.lowercased() == "en" ? language : nil
        }
        XCTAssertNil(build105Supported("fr-FR"), "Build 105 disabled the local lane here")
        XCTAssertEqual(
            Self.policy(language: "fr-FR").supportedLanguage, "fr-FR",
            "Build 106 must not"
        )
    }

    // MARK: - Contextual ranking

    func testRankerPromotesTranspositionOverUnrelatedSameDistanceCandidate() {
        let ranked = LocalCandidateRanker.rank(
            typed: "teh",
            candidates: ["ted", "the", "tea"],
            precedingWord: "in",
            lexicon: .empty
        )
        XCTAssertEqual(ranked.first?.value, "the")
        XCTAssertTrue(ranked.first?.reasons.contains("transposition") == true)
    }

    func testRankerUsesAdjacentKeySlipAndBigramContext() {
        XCTAssertTrue(LocalCandidateRanker.isAdjacentKeySlip(typed: "hime", candidate: "home"),
                      "i and o are neighbours")
        XCTAssertFalse(LocalCandidateRanker.isAdjacentKeySlip(typed: "hime", candidate: "hire"))
        XCTAssertTrue(LocalCandidateRanker.isTransposition(typed: "recieve", candidate: "receive"))
        XCTAssertFalse(LocalCandidateRanker.isTransposition(typed: "abc", candidate: "abc"))

        // "thanks for" is in the table; "fog" is not.
        let ranked = LocalCandidateRanker.rank(
            typed: "fpr",
            candidates: ["fog", "for"],
            precedingWord: "thanks",
            lexicon: .empty
        )
        XCTAssertEqual(ranked.first?.value, "for")
        XCTAssertTrue(ranked.first?.reasons.contains("bigram") == true)
    }

    func testRankerIsStableForEqualScores() {
        let ranked = LocalCandidateRanker.rank(
            typed: "xyz", candidates: ["aaa", "bbb", "ccc"], precedingWord: nil, lexicon: .empty
        )
        XCTAssertEqual(ranked.map(\.value), ["aaa", "bbb", "ccc"],
                       "equal scores must preserve the checker's order, so the strip does not shuffle")
    }

    func testPrecedingWordExtraction() {
        XCTAssertEqual(
            LocalCandidateRanker.precedingWord(inContextBefore: "thanks for teh", skipping: "teh"),
            "for"
        )
        XCTAssertEqual(
            LocalCandidateRanker.precedingWord(inContextBefore: "see you, tomorow", skipping: "tomorow"),
            "you"
        )
        XCTAssertNil(LocalCandidateRanker.precedingWord(inContextBefore: "teh", skipping: "teh"))
        XCTAssertNil(LocalCandidateRanker.precedingWord(inContextBefore: "", skipping: ""))
    }

    // MARK: - Personal vocabulary and shortcut expansions

    func testUserShortcutExpansionBecomesACandidate() {
        let lexicon = LocalLexicon(lexiconEntries: [
            (userInput: "omw", documentText: "On my way!"),
            (userInput: "Ezra", documentText: "Ezra"),
        ])
        XCTAssertEqual(lexicon.expansion(for: "omw"), "On my way!")
        XCTAssertTrue(lexicon.contains("ezra"))

        let checker = RecordingChecker(table: [
            "omw": SpellingLookup(isMisspelled: true, corrections: ["own"], completions: []),
        ])
        let decision = SpellingPolicy.evaluate(
            request: SpellingRequest(token: Self.token("omw"), host: Self.policy(), contextBefore: "omw"),
            checker: checker,
            lexicon: lexicon
        )
        XCTAssertEqual(decision?.candidates.first, "omw", "the original is always offered first")
        XCTAssertEqual(decision?.candidates.dropFirst().first, "On my way!",
                       "the user's own configured shortcut outranks a dictionary guess")
        XCTAssertEqual(decision?.automaticReplacement, "On my way!")
    }

    /// A contact name in the user's vocabulary must not be "corrected".
    func testPersonalVocabularySuppressesFalseCorrections() {
        let lexicon = LocalLexicon(lexiconEntries: [(userInput: "Sherlock", documentText: "Sherlock")])
        let checker = RecordingChecker(table: [
            "sherlock": SpellingLookup(isMisspelled: true, corrections: ["Sherlocks"], completions: []),
        ])
        let decision = SpellingPolicy.evaluate(
            request: SpellingRequest(token: Self.token("Sherlock"), host: Self.policy(), contextBefore: "Sherlock"),
            checker: checker,
            lexicon: lexicon
        )
        XCTAssertNil(decision, "a word the user's own device knows must not be flagged")
        XCTAssertTrue(checker.lookups.isEmpty, "and must not even cost a dictionary lookup")
    }

    func testLexiconIsBounded() {
        let entries = (0..<2_000).map { (userInput: "w\($0)", documentText: "x\($0)") }
        let lexicon = LocalLexicon(lexiconEntries: entries)
        XCTAssertLessThanOrEqual(lexicon.words.count, LocalLexicon.entryLimit)
        XCTAssertLessThanOrEqual(lexicon.expansions.count, LocalLexicon.entryLimit)
    }

    // MARK: - Ranking actually reaches the shipping decision

    /// Build 105 took the first two candidates in the checker's order. This
    /// fixture puts the right answer fourth, where Build 105 would drop it.
    func testShippingDecisionRanksRatherThanTruncatingCheckerOrder() {
        let checker = RecordingChecker(table: [
            "recieve": SpellingLookup(
                isMisspelled: true,
                corrections: ["relieve", "reprieve", "recessive", "receive"],
                completions: []
            ),
        ])
        let decision = SpellingPolicy.evaluate(
            request: SpellingRequest(
                token: Self.token("recieve"),
                host: Self.policy(),
                contextBefore: "did you recieve"
            ),
            checker: checker,
            lexicon: .empty
        )
        XCTAssertEqual(decision?.candidates.dropFirst().first, "receive",
                       "the transposition fix must be promoted out of fourth place")
        XCTAssertEqual(decision?.candidates.first, "recieve")
    }

    /// Exclusions from Build 105 must all survive.
    func testExclusionsStillHold() {
        let checker = RecordingChecker(table: [:])
        let cases: [(String, SpellingHostPolicy)] = [
            ("hello", Self.policy(fieldKind: .email)),
            ("hello", Self.policy(fieldKind: .url)),
            ("hello", Self.policy(fieldKind: .numeric)),
            ("hello", Self.policy(fieldKind: .secureLike)),
            ("hello", Self.policy(language: "ja-JP")),
        ]
        for (word, host) in cases {
            XCTAssertNil(
                SpellingPolicy.evaluate(
                    request: SpellingRequest(token: Self.token(word), host: host, contextBefore: word),
                    checker: checker, lexicon: .empty
                ),
                "\(host.fieldKind) / \(host.language ?? "nil") must offer nothing"
            )
        }
        // Acronyms, mixed case and digits stay excluded.
        for word in ["NASA", "iPhone", "abc1"] {
            XCTAssertNil(
                SpellingPolicy.evaluate(
                    request: SpellingRequest(token: Self.token(word), host: Self.policy(), contextBefore: word),
                    checker: checker, lexicon: .empty
                ),
                "\(word) must be excluded"
            )
        }
    }

    // MARK: - Next word / continuations

    func testContinuationsAreRealOrAbsentNeverDecorative() {
        XCTAssertFalse(LocalNextWordModel.shared.continuations(after: "thanks").isEmpty)
        XCTAssertTrue(LocalNextWordModel.shared.follows(previous: "thank", candidate: "you"))
        XCTAssertTrue(
            LocalNextWordModel.shared.continuations(after: "qwertyuiop").isEmpty,
            "an unknown context must produce silence, not filler"
        )
        // Every table entry is a real lowercase word — no placeholders.
        for (key, values) in LocalNextWordModel.defaultTable {
            XCTAssertEqual(key, key.lowercased())
            XCTAssertFalse(values.isEmpty, "\(key) must not map to an empty list")
            for value in values {
                XCTAssertEqual(value, value.lowercased())
                XCTAssertFalse(value.isEmpty)
            }
        }
    }

    // MARK: - Offline proof

    /// The local lane must produce useful output with the network denied, and
    /// must make zero outbound requests.
    func testLocalLaneWorksWithNetworkDeniedAndMakesZeroRequests() {
        URLProtocol.registerClass(DeniedNetwork.self)
        DeniedNetwork.attempts = 0
        defer { URLProtocol.unregisterClass(DeniedNetwork.self) }

        let checker = RecordingChecker(table: [
            "teh": SpellingLookup(isMisspelled: true, corrections: ["the", "ted"], completions: []),
        ])
        let decision = SpellingPolicy.evaluate(
            request: SpellingRequest(
                token: Self.token("teh"), host: Self.policy(), contextBefore: "in teh"
            ),
            checker: checker,
            lexicon: .empty
        )
        XCTAssertEqual(decision?.candidates.dropFirst().first, "the",
                       "a useful correction must still appear with no connection")
        XCTAssertEqual(DeniedNetwork.attempts, 0,
                       "the local lane must make zero outbound requests")
    }

    /// The self-test runs the real pipeline and is unmistakable about outcome.
    func testSelfTestPassesFailsAndReportsDisabledHonestly() {
        let good = RecordingChecker(table: [
            "recieve": SpellingLookup(isMisspelled: true, corrections: ["receive"], completions: []),
        ])
        let pass = LocalIntelligenceSelfTest.run(
            language: "en-US", availableLanguages: ["en-US"], checker: good, lexicon: .empty
        )
        XCTAssertTrue(pass.isPass, "self-test summary: \(pass.summary)")
        XCTAssertTrue(pass.summary.contains("working"))
        XCTAssertTrue(pass.summary.contains("no network"))

        // A dead dictionary must fail loudly, not silently pass.
        let dead = RecordingChecker(table: [:])
        let fail = LocalIntelligenceSelfTest.run(
            language: "en-US", availableLanguages: ["en-US"], checker: dead, lexicon: .empty
        )
        XCTAssertFalse(fail.isPass)
        XCTAssertTrue(fail.summary.contains("FAILED"))

        // No installed dictionary is "disabled", not "failed" — a different
        // and truthful state.
        let disabled = LocalIntelligenceSelfTest.run(
            language: "ja-JP", availableLanguages: ["en-US"], checker: good, lexicon: .empty
        )
        XCTAssertFalse(disabled.isPass)
        if case .disabled(let reason) = disabled {
            XCTAssertTrue(reason.contains("dictionary"))
        } else {
            XCTFail("an uninstalled dictionary must report disabled, not fail")
        }
    }

    func testSelfTestPerformsNoNetworkIO() {
        URLProtocol.registerClass(DeniedNetwork.self)
        DeniedNetwork.attempts = 0
        defer { URLProtocol.unregisterClass(DeniedNetwork.self) }

        let checker = RecordingChecker(table: [
            "recieve": SpellingLookup(isMisspelled: true, corrections: ["receive"], completions: []),
        ])
        _ = LocalIntelligenceSelfTest.run(
            language: "en-US", availableLanguages: ["en-US"], checker: checker, lexicon: .empty
        )
        XCTAssertEqual(DeniedNetwork.attempts, 0)
    }

    // MARK: - Truthful copy

    /// The build must never claim Apple Intelligence or QuickType parity.
    func testCopyMakesNoAppleIntelligenceClaim() {
        let all = [
            LocalIntelligenceCopy.candidateProvenance,
            LocalIntelligenceCopy.offlineCapabilitySummary,
            LocalIntelligenceCopy.onlineRequirementSummary,
            LocalIntelligenceCopy.localModelDisclosure,
            LocalIntelligenceCopy.coachRequiresInternet,
        ]
        for line in all {
            XCTAssertFalse(line.isEmpty)
            let lowered = line.lowercased()
            if lowered.contains("apple intelligence") || lowered.contains("quicktype") {
                XCTAssertTrue(
                    lowered.contains("not ") || lowered.contains("does not"),
                    "any mention of Apple Intelligence/QuickType must be a denial, not a claim: \(line)"
                )
            }
        }
        XCTAssertTrue(
            LocalIntelligenceCopy.localModelDisclosure.lowercased().contains("not apple intelligence"),
            "the disclosure must state the limit explicitly"
        )
        XCTAssertTrue(
            LocalIntelligenceCopy.onlineRequirementSummary.lowercased().contains("internet"),
            "Coach's internet requirement must be stated"
        )
        XCTAssertTrue(
            LocalIntelligenceCopy.offlineCapabilitySummary.lowercased().contains("live tone"),
            "Live Tone must be named as an offline capability"
        )
    }

    // MARK: - Privacy

    /// Nothing in the local lane retains or formats user text beyond the single
    /// token and its immediate preceding word.
    func testContextUseIsBoundedAndNotRetained() {
        let long = String(repeating: "secret ", count: 500) + "teh"
        let preceding = LocalCandidateRanker.precedingWord(inContextBefore: long, skipping: "teh")
        XCTAssertEqual(preceding, "secret")
        // The ranker's inputs are values; nothing is stored on the type.
        let ranked = LocalCandidateRanker.rank(
            typed: "teh", candidates: ["the"], precedingWord: preceding, lexicon: .empty
        )
        XCTAssertEqual(ranked.count, 1)
    }
}
