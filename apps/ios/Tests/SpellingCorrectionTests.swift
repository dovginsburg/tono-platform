import XCTest
import UIKit

final class SpellingCorrectionTests: XCTestCase {
    private final class MockChecker: SpellingChecking {
        var values: [String: SpellingLookup]
        private(set) var lookedUp: [String] = []

        init(_ values: [String: SpellingLookup]) {
            self.values = values
        }

        func lookup(word: String, language: String) -> SpellingLookup {
            lookedUp.append(word)
            return values[word] ?? SpellingLookup(
                isMisspelled: true,
                corrections: [],
                completions: []
            )
        }
    }

    private let english = SpellingHostPolicy(
        language: "en-US",
        fieldKind: .ordinary,
        allowsAutocorrection: true,
        allowsSpellChecking: true
    )

    private func request(_ context: String, host: SpellingHostPolicy? = nil) -> SpellingRequest {
        SpellingRequest(token: SpellingToken.current(in: context)!, host: host ?? english)
    }

    func testTehStrongCorrectionAndOriginalCandidate() {
        let checker = MockChecker([
            "teh": SpellingLookup(isMisspelled: true, corrections: ["the"], completions: [])
        ])
        let decision = SpellingPolicy.evaluate(request: request("teh"), checker: checker)

        XCTAssertEqual(decision?.candidates, ["teh", "the"])
        XCTAssertEqual(decision?.automaticReplacement, "the")
    }

    func testRecieveUsesInjectedChecker() {
        let checker = MockChecker([
            "recieve": SpellingLookup(isMisspelled: true, corrections: ["receive"], completions: [])
        ])
        let decision = SpellingPolicy.evaluate(request: request("recieve"), checker: checker)

        XCTAssertEqual(decision?.automaticReplacement, "receive")
        XCTAssertEqual(checker.lookedUp, ["recieve"])
    }

    func testUnknownAndProperNounArePreserved() {
        let checker = MockChecker([
            "blorple": SpellingLookup(isMisspelled: true, corrections: [], completions: []),
            "ezra": SpellingLookup(isMisspelled: true, corrections: ["era"], completions: [])
        ])
        let unknown = SpellingPolicy.evaluate(request: request("blorple"), checker: checker)
        let proper = SpellingPolicy.evaluate(request: request("hello Ezra"), checker: checker)

        XCTAssertEqual(unknown?.candidates, ["blorple"])
        XCTAssertNil(unknown?.automaticReplacement)
        XCTAssertNil(proper?.automaticReplacement)
    }

    func testURLemailAndNumericFieldsAreSuppressedWithoutCheckerCall() {
        let checker = MockChecker([:])
        for kind in [SpellingFieldKind.url, .email, .numeric, .secureLike] {
            let host = SpellingHostPolicy(
                language: "en-US",
                fieldKind: kind,
                allowsAutocorrection: true,
                allowsSpellChecking: true
            )
            XCTAssertNil(SpellingPolicy.evaluate(request: request("teh", host: host), checker: checker))
        }
        XCTAssertNil(SpellingPolicy.evaluate(request: request("me@teh"), checker: checker))
        XCTAssertTrue(checker.lookedUp.isEmpty)
    }

    func testDisabledHostTraitsAndSupplementaryLexiconAreSuppressed() {
        let checker = MockChecker([:])
        let noAutocorrect = SpellingHostPolicy(
            language: "en-US",
            fieldKind: .ordinary,
            allowsAutocorrection: false,
            allowsSpellChecking: true
        )
        XCTAssertNil(SpellingPolicy.evaluate(request: request("teh", host: noAutocorrect), checker: checker))
        // Build 106: the flat supplementary-word set became `LocalLexicon`,
        // which distinguishes "the user's device knows this word" from "the
        // user configured this shortcut". Membership still suppresses.
        XCTAssertNil(SpellingPolicy.evaluate(
            request: request("Tono"),
            checker: checker,
            lexicon: LocalLexicon(words: ["tono"], expansions: [:])
        ))
    }

    func testAllCapsAndMixedAlphanumericIdentifiersAreSuppressed() {
        let checker = MockChecker([:])
        XCTAssertNil(SpellingPolicy.evaluate(request: request("NASA"), checker: checker))
        XCTAssertNil(SpellingPolicy.evaluate(request: request("item2teh"), checker: checker))
        XCTAssertNil(SpellingPolicy.evaluate(request: request("item_teh"), checker: checker))
        XCTAssertTrue(checker.lookedUp.isEmpty)
    }

    func testCapitalizationIsPreserved() {
        XCTAssertEqual(SpellingPolicy.preserveCase(of: "Teh", in: "the"), "The")
        XCTAssertEqual(SpellingPolicy.preserveCase(of: "TEH", in: "the"), "THE")
        XCTAssertEqual(SpellingPolicy.preserveCase(of: "teh", in: "THE"), "the")
    }

    func testPunctuationTokenAndCandidateReplacementPlan() {
        let token = SpellingToken.current(in: "Well, teh")!
        XCTAssertEqual(token.text, "teh")
        let plan = SpellingMutationPlan.candidate(
            liveToken: token,
            expected: token,
            replacement: "the"
        )
        XCTAssertEqual(plan, SpellingMutationPlan(deleteCount: 3, insertion: "the"))
    }

    func testMidTokenCandidateReplacementDeletesTheWholeToken() {
        let token = SpellingToken.current(before: "Please hl", after: "p now")!
        XCTAssertEqual(token.text, "hlp")
        XCTAssertEqual(token.caretOffset, 2)

        let plan = SpellingMutationPlan.candidate(
            liveToken: token,
            expected: token,
            replacement: "help"
        )

        XCTAssertEqual(
            plan,
            SpellingMutationPlan(deleteCount: 3, insertion: "help", cursorAdvance: 1)
        )
    }

    func testStaleCandidateTapDoesNotMutateChangedToken() {
        let expected = SpellingToken.current(before: "Please hl", after: "p now")!
        let live = SpellingToken.current(before: "Please help", after: " now")!

        XCTAssertNil(SpellingMutationPlan.candidate(
            liveToken: live,
            expected: expected,
            replacement: "help"
        ))
    }

    func testBoundaryAutocorrectInsertsPunctuationExactlyOnce() {
        let token = SpellingToken.current(in: "teh")!
        let decision = SpellingDecision(
            original: "teh",
            candidates: ["teh", "the"],
            automaticReplacement: "the"
        )
        let plan = SpellingMutationPlan.boundary(
            liveToken: token,
            expected: token,
            decision: decision,
            boundary: "."
        )

        XCTAssertEqual(plan.deleteCount, 3)
        XCTAssertEqual(plan.insertion, "the.")
        XCTAssertEqual(plan.insertion.filter { $0 == "." }.count, 1)
    }

    func testUndoRecordPreservesBoundary() {
        let record = AutoCorrectionRecord(original: "teh", replacement: "the", boundary: " ")
        XCTAssertEqual(record.correctedSuffix, "the ")
        XCTAssertEqual(record.restoredText, "teh ")
    }

    func testDoubleSpacePeriodRequiresOrdinaryPermittedFieldAndNoPendingUndo() {
        XCTAssertTrue(DoubleSpacePolicy.shouldTransform(
            contextSuffix: "Hello ",
            host: english,
            hasPendingAutocorrectionUndo: false
        ))
        XCTAssertFalse(DoubleSpacePolicy.shouldTransform(
            contextSuffix: "Hello. ",
            host: english,
            hasPendingAutocorrectionUndo: false
        ))
        XCTAssertFalse(DoubleSpacePolicy.shouldTransform(
            contextSuffix: "the ",
            host: english,
            hasPendingAutocorrectionUndo: true
        ))
        let email = SpellingHostPolicy(
            language: "en-US",
            fieldKind: .email,
            allowsAutocorrection: true,
            allowsSpellChecking: true
        )
        XCTAssertFalse(DoubleSpacePolicy.shouldTransform(
            contextSuffix: "name ",
            host: email,
            hasPendingAutocorrectionUndo: false
        ))
    }

    func testStaleGenerationIsRejectedDeterministically() {
        let service = SpellingCorrectionService(checker: MockChecker([:]), debounce: 0)
        let stale = service.beginGeneration()
        let current = service.beginGeneration()

        XCTAssertFalse(service.accepts(generation: stale))
        XCTAssertTrue(service.accepts(generation: current))
    }

    /// Build 106 changed this contract deliberately.
    ///
    /// Build 105 answered "is this English?" and returned the requested tag
    /// verbatim. That disabled the whole local lane for every non-English
    /// keyboard even when iOS had the dictionary installed, which is half of
    /// the "offline mode did not visibly utilize local intelligence" finding.
    /// Build 106 answers "which INSTALLED dictionary should serve this
    /// keyboard?", so the result is one of `UITextChecker.availableLanguages`
    /// in that API's own spelling (which is `en_US`, not `en-US`, on current
    /// OS versions) and a non-English language resolves when it is installed.
    func testResolvesToAnInstalledDictionaryRatherThanEnglishOnly() throws {
        let available = UITextChecker.availableLanguages
        try XCTSkipIf(available.isEmpty, "no dictionaries installed on this runner")

        let resolvedEnglish = try XCTUnwrap(english.supportedLanguage)
        XCTAssertTrue(
            available.contains(resolvedEnglish),
            "the resolved language must be one UITextChecker actually published"
        )
        XCTAssertTrue(resolvedEnglish.lowercased().hasPrefix("en"))

        // A language with no installed dictionary still yields nothing.
        XCTAssertNil(SpellingHostPolicy(
            language: "zz-ZZ",
            fieldKind: .ordinary,
            allowsAutocorrection: true,
            allowsSpellChecking: true
        ).supportedLanguage)

        // Injected sets keep the resolution deterministic regardless of runner.
        let french = SpellingHostPolicy(
            language: "fr-FR",
            fieldKind: .ordinary,
            allowsAutocorrection: true,
            allowsSpellChecking: true,
            availableLanguages: ["en_US", "fr_FR"]
        )
        XCTAssertEqual(french.supportedLanguage, "fr_FR", "Build 105 returned nil here")
    }

    func testRealUITextCheckerSmokeWhenEnglishIsAvailable() throws {
        guard UITextChecker.availableLanguages.contains(where: { $0.hasPrefix("en") }) else {
            throw XCTSkip("English UITextChecker dictionary unavailable")
        }
        let result = SystemSpellingChecker().lookup(word: "hello", language: "en-US")
        XCTAssertFalse(result.isMisspelled)
    }
}
