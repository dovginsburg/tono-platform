// LocalIntelligence.swift
// Build 106 — physical finding #2: "offline mode did not visibly utilize local
// intelligence."
//
// ── What was actually shipping in Build 105 ─────────────────────────────────
// One `UITextChecker` lookup, hard-gated to English (`supportedLanguage`
// returned nil unless the host language began with "en"), returning the
// original word plus at most two raw guesses in `UITextChecker`'s own order.
// No personal vocabulary, no context, no completions ranking, no next word, and
// nothing anywhere in the UI that said the work happened on the device. The
// founder's reading — that offline mode was not visibly using local
// intelligence — was accurate about both halves: the intelligence was thin, and
// it was invisible.
//
// ── What Build 106 ships ────────────────────────────────────────────────────
// A Tono-owned, on-device pipeline built only from documented public API plus
// deterministic local tables:
//
//   1. LANGUAGE RESOLUTION — `SpellingLanguageResolver` maps the host's input
//      language onto an installed `UITextChecker` language instead of refusing
//      everything that is not English.
//   2. PERSONAL VOCABULARY — `LocalLexicon` carries `UILexicon` entries: the
//      user's own contacts/shortcuts vocabulary suppresses false corrections,
//      and shortcut expansions ("omw" → "On my way!") become real candidates.
//   3. CONTEXTUAL RANKING — `LocalCandidateRanker` scores corrections by edit
//      distance, keyboard adjacency of the substituted key, transposition,
//      prefix agreement, personal-vocabulary membership and a compact bigram
//      prior taken from the word actually preceding the caret.
//   4. NEXT WORD / CONTINUATION — `LocalNextWordModel`, a small fixed English
//      bigram table, offers continuations at a word boundary.
//   5. VISIBILITY — `LocalIntelligenceCopy` supplies the keyboard badge label,
//      the VoiceOver provenance string on every candidate, and the host-app
//      settings copy, so the local lane is inspectable rather than implied.
//   6. SELF-TEST — `LocalIntelligenceSelfTest` runs the real shipping resolver
//      and ranker over fixed fixtures with no network and no text mutation, and
//      returns pass / fail / disabled.
//
// ── Honest limits, stated once and not walked back ──────────────────────────
// * Apple's QuickType engine and Apple Intelligence / Writing Tools are NOT
//   available to third-party keyboard extensions. Nothing here is connected to
//   them and no copy in this build says or implies otherwise.
// * `LocalNextWordModel` is a fixed high-frequency bigram table, not a learned
//   language model. It is deliberately small enough to be reviewed by eye and
//   it never invents a word that is not in the table. Where it has nothing to
//   say it stays silent — no decorative random words.
// * Ranking signals are heuristic and deterministic. There is no on-device
//   neural model in this build.
// * Nothing in this file performs I/O. Ordinary keystrokes are never uploaded.

import Foundation
import UIKit

// ───────────────────────────────────────────────────────────────────────────
// Spell-checker seam
// ───────────────────────────────────────────────────────────────────────────

/// The only thing the local pipeline needs from a dictionary.
///
/// Declared here rather than alongside the keyboard's policy types so the host
/// app can compile and run `LocalIntelligenceSelfTest` against the REAL
/// protocol the keyboard uses. `SystemSpellingChecker` below is the shipping
/// `UITextChecker` implementation both of them share.
public protocol SpellingChecking: AnyObject {
    func lookup(word: String, language: String) -> SpellingLookup
}

public struct SpellingLookup: Equatable {
    public let isMisspelled: Bool
    public let corrections: [String]
    public let completions: [String]

    public init(isMisspelled: Bool, corrections: [String], completions: [String]) {
        self.isMisspelled = isMisspelled
        self.corrections = corrections
        self.completions = completions
    }
}

/// Damerau-Levenshtein distance, where one adjacent transposition costs one
/// edit — which is what makes "teh"→"the" and "recieve"→"receive" cheap.
///
/// Lives here so the ranker and the host-app self-test can use it without the
/// keyboard-only policy types. `SpellingPolicy.damerauLevenshtein` forwards to
/// it, so every existing caller and test is unchanged.
public enum LocalEditDistance {

    public static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var matrix = Array(
            repeating: Array(repeating: 0, count: b.count + 1),
            count: a.count + 1
        )
        for i in 0...a.count { matrix[i][0] = i }
        for j in 0...b.count { matrix[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
                if i > 1, j > 1,
                   a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    matrix[i][j] = min(matrix[i][j], matrix[i - 2][j - 2] + 1)
                }
            }
        }
        return matrix[a.count][b.count]
    }
}

/// The shipping `UITextChecker` implementation. Compiled into the keyboard
/// extension AND the host app, so the in-app self-test exercises the same
/// object the keyboard uses rather than a stand-in.
final class SystemSpellingChecker: SpellingChecking {
    private let checker = UITextChecker()

    func lookup(word: String, language: String) -> SpellingLookup {
        let range = NSRange(location: 0, length: word.utf16.count)
        let misspelled = checker.rangeOfMisspelledWord(
            in: word,
            range: range,
            startingAt: 0,
            wrap: false,
            language: language
        ).location != NSNotFound
        let corrections = misspelled
            ? (checker.guesses(forWordRange: range, in: word, language: language) ?? [])
            : []
        let completions = checker.completions(
            forPartialWordRange: range,
            in: word,
            language: language
        ) ?? []
        return SpellingLookup(
            isMisspelled: misspelled,
            corrections: corrections,
            completions: completions
        )
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Copy
// ───────────────────────────────────────────────────────────────────────────

/// Every user-visible string that makes a claim about where computation runs.
/// Centralised so the claims can be tested, and so no surface can drift into
/// implying a capability the extension does not have.
public enum LocalIntelligenceCopy {

    /// Accessibility label of the keyboard's on-device dot.
    public static let badgeAccessibilityLabel =
        "On-device suggestions active. Spelling runs on this iPhone."

    /// Read after each suggestion by VoiceOver.
    public static let candidateProvenance = "on-device suggestion"

    /// Settings: what works with no connection.
    public static let offlineCapabilitySummary =
        "Spelling, suggestions and Live Tone warnings run entirely on this device and work with no internet connection."

    /// Settings: what does not.
    public static let onlineRequirementSummary =
        "Coach rewrites are the only feature that needs internet. Tono sends the draft you choose to rewrite, and only when you tap a tone."

    /// Settings: the limit, stated plainly.
    public static let localModelDisclosure =
        "Tono's on-device suggestions use Apple's system spell checker, your own keyboard vocabulary, and Tono's local ranking. They are not Apple Intelligence or QuickType, which iOS does not make available to third-party keyboards."

    /// Shown when a Coach rewrite is attempted with no connection.
    public static let coachRequiresInternet =
        "Coach rewrites need an internet connection. Spelling and Live Tone keep working offline."
}

// ───────────────────────────────────────────────────────────────────────────
// Language resolution
// ───────────────────────────────────────────────────────────────────────────

/// Resolves the host's declared input language onto a language the installed
/// spell checker actually supports.
///
/// Build 105 answered this question with `prefix == "en"`, which silently
/// disabled the entire local lane for every other keyboard language even when
/// the device had that dictionary installed. The resolution order below is the
/// conventional one: exact tag, then same language with a different region,
/// then the language's own default, and only then nothing.
public enum SpellingLanguageResolver {

    /// - Parameters:
    ///   - requested: BCP-47-ish tag from the host or the input mode. Accepts
    ///     the underscore form UIKit sometimes reports ("en_GB").
    ///   - available: `UITextChecker.availableLanguages`, injected so this is
    ///     testable without a device dictionary set.
    public static func resolve(requested: String?, available: [String]) -> String? {
        guard let requested, !requested.isEmpty, !available.isEmpty else { return nil }
        let wanted = normalize(requested)

        // Both sides are normalised before comparison because UIKit is not
        // self-consistent here: `primaryLanguage` reports "en-US" while
        // `UITextChecker.availableLanguages` reports "en_US" on some OS
        // versions. Comparing raw strings silently disabled the entire local
        // lane on exactly those devices. The ORIGINAL spelling is returned, so
        // the value handed back to `UITextChecker` is in the form it published.
        if let exact = available.first(where: { normalize($0) == wanted }) {
            return exact
        }
        guard let base = wanted.split(separator: "-").first.map(String.init), !base.isEmpty else {
            return nil
        }
        // Same language, any region. Sorted by the normalised form so the
        // choice is deterministic across launches rather than dependent on
        // enumeration order.
        return available
            .filter { normalize($0) == base || normalize($0).hasPrefix(base + "-") }
            .sorted { normalize($0) < normalize($1) }
            .first
    }

    private static func normalize(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Personal vocabulary
// ───────────────────────────────────────────────────────────────────────────

/// The user's own keyboard vocabulary, as published by `UILexicon`.
///
/// Two distinct uses, and they must not be confused:
///   * `words` — everything the user's device considers spelled correctly
///     (contact names, learned words). Membership SUPPRESSES a correction.
///   * `expansions` — shortcut → replacement pairs the user configured in
///     Settings ("omw" → "On my way!"). These are OFFERED as candidates.
///
/// Stored lowercased and bounded so a pathological lexicon cannot grow the
/// extension's memory footprint.
public struct LocalLexicon: Equatable {

    public static let entryLimit = 512

    public private(set) var words: Set<String>
    public private(set) var expansions: [String: String]

    public static let empty = LocalLexicon(words: [], expansions: [:])

    public init(words: Set<String>, expansions: [String: String]) {
        self.words = Set(words.lazy.map { $0.lowercased() }.prefix(Self.entryLimit))
        var bounded: [String: String] = [:]
        for (key, value) in expansions.sorted(by: { $0.key < $1.key }) {
            guard bounded.count < Self.entryLimit else { break }
            let folded = key.lowercased()
            guard !folded.isEmpty, !value.isEmpty, folded != value.lowercased() else { continue }
            bounded[folded] = value
        }
        self.expansions = bounded
    }

    /// Build from `(userInput, documentText)` pairs — the shape `UILexicon`
    /// hands back. A pair whose two halves match is a plain vocabulary word;
    /// a pair whose halves differ is a shortcut expansion. Both are also
    /// vocabulary, since the user typed them deliberately.
    public init(lexiconEntries: [(userInput: String, documentText: String)]) {
        var words: Set<String> = []
        var expansions: [String: String] = [:]
        for entry in lexiconEntries {
            let input = entry.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = entry.documentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, !output.isEmpty else { continue }
            words.insert(input.lowercased())
            words.insert(output.lowercased())
            if input.lowercased() != output.lowercased() {
                expansions[input.lowercased()] = output
            }
        }
        self.init(words: words, expansions: expansions)
    }

    public func contains(_ word: String) -> Bool { words.contains(word.lowercased()) }

    public func expansion(for word: String) -> String? { expansions[word.lowercased()] }
}

// ───────────────────────────────────────────────────────────────────────────
// Contextual ranking
// ───────────────────────────────────────────────────────────────────────────

/// Deterministic scorer that reorders spell-checker output using signals the
/// system checker does not consider: which key is next to which on the QWERTY
/// layout the user is actually typing on, whether the user's own vocabulary
/// contains the word, and what word precedes the caret.
///
/// Deliberately transparent: every score is a small integer sum, so a wrong
/// ranking can be explained from the inputs rather than probed.
public enum LocalCandidateRanker {

    /// One candidate plus its reason codes, kept for the self-test and tests.
    public struct Scored: Equatable {
        public let value: String
        public let score: Int
        public let reasons: [String]
    }

    /// QWERTY neighbours. A single-substitution typo between adjacent keys is
    /// far more likely than between distant ones — this is the cheapest real
    /// signal available and it costs no memory worth measuring.
    static let adjacency: [Character: Set<Character>] = [
        "q": ["w", "a"], "w": ["q", "e", "s", "a"], "e": ["w", "r", "d", "s"],
        "r": ["e", "t", "f", "d"], "t": ["r", "y", "g", "f"], "y": ["t", "u", "h", "g"],
        "u": ["y", "i", "j", "h"], "i": ["u", "o", "k", "j"], "o": ["i", "p", "l", "k"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z"], "s": ["a", "w", "e", "d", "x", "z"],
        "d": ["s", "e", "r", "f", "c", "x"], "f": ["d", "r", "t", "g", "v", "c"],
        "g": ["f", "t", "y", "h", "b", "v"], "h": ["g", "y", "u", "j", "n", "b"],
        "j": ["h", "u", "i", "k", "m", "n"], "k": ["j", "i", "o", "l", "m"],
        "l": ["k", "o", "p"],
        "z": ["a", "s", "x"], "x": ["z", "s", "d", "c"], "c": ["x", "d", "f", "v"],
        "v": ["c", "f", "g", "b"], "b": ["v", "g", "h", "n"], "n": ["b", "h", "j", "m"],
        "m": ["n", "j", "k"],
    ]

    static func areAdjacent(_ lhs: Character, _ rhs: Character) -> Bool {
        adjacency[Character(lhs.lowercased())]?.contains(Character(rhs.lowercased())) == true
    }

    /// True when `typed` and `candidate` differ by exactly one substitution and
    /// the two differing characters are neighbours on the keyboard.
    public static func isAdjacentKeySlip(typed: String, candidate: String) -> Bool {
        let a = Array(typed.lowercased()), b = Array(candidate.lowercased())
        guard a.count == b.count else { return false }
        var difference: (Character, Character)?
        for i in a.indices where a[i] != b[i] {
            guard difference == nil else { return false }
            difference = (a[i], b[i])
        }
        guard let (x, y) = difference else { return false }
        return areAdjacent(x, y)
    }

    /// True when the two strings differ only by swapping one adjacent pair.
    public static func isTransposition(typed: String, candidate: String) -> Bool {
        let a = Array(typed.lowercased()), b = Array(candidate.lowercased())
        guard a.count == b.count, a.count >= 2, a != b else { return false }
        var mismatches: [Int] = []
        for i in a.indices where a[i] != b[i] {
            mismatches.append(i)
            if mismatches.count > 2 { return false }
        }
        guard mismatches.count == 2 else { return false }
        let (i, j) = (mismatches[0], mismatches[1])
        return j == i + 1 && a[i] == b[j] && a[j] == b[i]
    }

    /// Score and order `candidates` for `typed`, given the preceding word.
    ///
    /// Stable: equal scores keep the checker's own order, so the ranking never
    /// shuffles between identical keystrokes.
    public static func rank(
        typed: String,
        candidates: [String],
        precedingWord: String?,
        lexicon: LocalLexicon,
        nextWordModel: LocalNextWordModel = .shared
    ) -> [Scored] {
        let folded = typed.lowercased()
        let scored = candidates.enumerated().map { index, candidate -> (Int, Scored) in
            let value = candidate
            let low = candidate.lowercased()
            var score = 0
            var reasons: [String] = []

            let distance = LocalEditDistance.damerauLevenshtein(folded, low)
            // Nearer edits first; distance dominates every other signal so a
            // context prior can reorder ties but never promote a wild guess.
            score += max(0, 12 - distance * 6)
            reasons.append("distance:\(distance)")

            if isTransposition(typed: folded, candidate: low) {
                score += 4
                reasons.append("transposition")
            }
            if isAdjacentKeySlip(typed: folded, candidate: low) {
                score += 3
                reasons.append("adjacent-key")
            }
            if low.hasPrefix(String(folded.prefix(2))), folded.count >= 2 {
                score += 2
                reasons.append("prefix")
            }
            if lexicon.contains(low) {
                score += 3
                reasons.append("personal")
            }
            if let previous = precedingWord,
               nextWordModel.follows(previous: previous, candidate: low) {
                score += 2
                reasons.append("bigram")
            }
            // Contractions are a common miss: "cant" → "can't" should not be
            // outranked by an unrelated same-distance word.
            if low.contains("'") || low.contains("\u{2019}") {
                let stripped = low.replacingOccurrences(of: "'", with: "")
                    .replacingOccurrences(of: "\u{2019}", with: "")
                if stripped == folded {
                    score += 5
                    reasons.append("contraction")
                }
            }
            return (index, Scored(value: value, score: score, reasons: reasons))
        }
        return scored
            .sorted { lhs, rhs in
                lhs.1.score == rhs.1.score ? lhs.0 < rhs.0 : lhs.1.score > rhs.1.score
            }
            .map(\.1)
    }

    /// The word immediately before the caret, for the bigram prior. Reads at
    /// most the last 64 characters of context and never retains them.
    public static func precedingWord(inContextBefore context: String, skipping token: String) -> String? {
        var tail = String(context.suffix(64))
        if !token.isEmpty, tail.hasSuffix(token) { tail = String(tail.dropLast(token.count)) }
        // Walk backwards: skip any separators sitting between the caret and the
        // previous word, collect that word, stop at the separator before it.
        var word: [Character] = []
        var reachedWord = false
        for character in tail.reversed() {
            let isWordCharacter = character.isLetter || character == "'" || character == "\u{2019}"
            if isWordCharacter {
                word.append(character)
                reachedWord = true
            } else if reachedWord {
                break
            }
        }
        guard !word.isEmpty else { return nil }
        return String(word.reversed()).lowercased()
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Next word / continuation
// ───────────────────────────────────────────────────────────────────────────

/// A compact, fixed English bigram table.
///
/// This is NOT a learned language model and does not pretend to be one. It is a
/// hand-reviewed list of high-frequency continuations, used for two bounded
/// jobs: a small ranking prior for corrections, and a continuation offer at a
/// word boundary. Unknown context produces an empty result — the strip stays
/// empty rather than showing filler.
///
/// The gap this leaves is stated in the Build-106 handoff: Tono does not ship a
/// learned or personalised next-word model in this build, because a model large
/// enough to be useful does not fit the keyboard extension's memory budget
/// alongside the layout, Live Tone and the emoji panel, and shipping a tiny
/// learned model would be worse than shipping an honest table.
public struct LocalNextWordModel: Equatable {

    public static let shared = LocalNextWordModel(table: LocalNextWordModel.defaultTable)

    private let table: [String: [String]]

    public init(table: [String: [String]]) {
        self.table = table
    }

    /// Continuations for `previous`, most likely first. Empty when unknown.
    public func continuations(after previous: String) -> [String] {
        table[previous.lowercased()] ?? []
    }

    /// Whether `candidate` is a known continuation of `previous`.
    public func follows(previous: String, candidate: String) -> Bool {
        continuations(after: previous).contains(candidate.lowercased())
    }

    /// Hand-reviewed high-frequency English continuations.
    static let defaultTable: [String: [String]] = [
        "i": ["am", "will", "think", "have", "was"],
        "im": ["going", "sorry", "not"],
        "you": ["are", "can", "should", "want"],
        "we": ["should", "can", "are", "need"],
        "they": ["are", "were", "have"],
        "it": ["is", "was", "would"],
        "that": ["is", "was", "works", "sounds"],
        "this": ["is", "was", "week", "morning"],
        "let": ["me", "us"],
        "thanks": ["for", "so"],
        "thank": ["you"],
        "sorry": ["for", "about", "i"],
        "can": ["you", "we", "i"],
        "could": ["you", "we", "i"],
        "would": ["you", "be", "love"],
        "should": ["be", "we", "i"],
        "please": ["let", "send", "call"],
        "going": ["to", "be"],
        "want": ["to"],
        "need": ["to", "a"],
        "have": ["to", "a", "been"],
        "will": ["be", "you", "let"],
        "on": ["my", "the", "it"],
        "in": ["the", "a", "my"],
        "at": ["the", "a"],
        "see": ["you", "the"],
        "talk": ["to", "later", "soon"],
        "call": ["you", "me"],
        "let's": ["do", "go", "talk"],
        "good": ["morning", "luck", "to"],
        "how": ["are", "is", "about"],
        "what": ["do", "is", "time"],
        "when": ["you", "is", "are"],
        "the": ["same", "other", "first"],
        "of": ["the", "course"],
        "to": ["be", "the", "you"],
        "be": ["there", "able", "the"],
        "is": ["that", "the", "it"],
        "are": ["you", "we", "they"],
        "not": ["sure", "the", "going"],
        "just": ["wanted", "got", "a"],
        "about": ["the", "it", "that"],
    ]
}

// ───────────────────────────────────────────────────────────────────────────
// Self-test
// ───────────────────────────────────────────────────────────────────────────

/// Runs the REAL shipping resolver, lexicon and ranker over fixed fixtures.
///
/// The host app's "Check on-device intelligence" control calls exactly this —
/// it does not re-implement the pipeline and it does not call a simplified copy
/// of it, so a green self-test on a user's device is evidence about the code
/// that ships. It performs no network I/O and mutates no document.
public enum LocalIntelligenceSelfTest {

    public enum Result: Equatable {
        /// Every check passed. `checks` is the ordered per-check log.
        case pass(checks: [Check])
        /// At least one check failed.
        case fail(checks: [Check])
        /// The local lane is unavailable on this device for a stated reason —
        /// e.g. no installed dictionary matches the keyboard language.
        case disabled(reason: String)

        public var isPass: Bool { if case .pass = self { return true }; return false }

        /// One-line summary for the UI. Unmistakable by design.
        public var summary: String {
            switch self {
            case .pass(let checks):
                return "On-device intelligence is working — \(checks.count) of \(checks.count) checks passed, no network used."
            case .fail(let checks):
                let failed = checks.filter { !$0.passed }
                return "On-device intelligence FAILED — \(failed.count) of \(checks.count) checks failed."
            case .disabled(let reason):
                return "On-device intelligence is unavailable: \(reason)"
            }
        }
    }

    public struct Check: Equatable {
        public let name: String
        public let passed: Bool
        public let detail: String

        public init(name: String, passed: Bool, detail: String) {
            self.name = name
            self.passed = passed
            self.detail = detail
        }
    }

    /// - Parameters:
    ///   - language: the keyboard's current language tag.
    ///   - availableLanguages: `UITextChecker.availableLanguages`.
    ///   - checker: the real system checker (or a double in tests).
    ///   - lexicon: the user's real `UILexicon`-derived vocabulary.
    static func run(
        language: String?,
        availableLanguages: [String],
        checker: SpellingChecking,
        lexicon: LocalLexicon
    ) -> Result {
        guard let resolved = SpellingLanguageResolver.resolve(
            requested: language,
            available: availableLanguages
        ) else {
            return .disabled(
                reason: "iOS has no spelling dictionary installed for this keyboard language."
            )
        }

        var checks: [Check] = []
        checks.append(Check(
            name: "Language",
            passed: true,
            detail: "Resolved to \(resolved) from the installed dictionaries."
        ))

        // The checker must actually flag a known-bad word. If this fails the
        // system dictionary is not answering and the whole lane is dead.
        let misspelled = checker.lookup(word: "recieve", language: resolved)
        let flags = misspelled.isMisspelled || !misspelled.corrections.isEmpty
        checks.append(Check(
            name: "Spell checker",
            passed: flags,
            detail: flags
                ? "System checker responded with \(misspelled.corrections.count) correction(s)."
                : "System checker returned nothing for a known misspelling."
        ))

        // Ranking must be able to reorder. Uses the real ranker.
        let ranked = LocalCandidateRanker.rank(
            typed: "teh",
            candidates: ["ted", "the"],
            precedingWord: "in",
            lexicon: lexicon
        )
        let rankOK = ranked.first?.value == "the"
        checks.append(Check(
            name: "Contextual ranking",
            passed: rankOK,
            detail: rankOK
                ? "Transposition and context promoted the expected candidate."
                : "Ranker did not promote the expected candidate."
        ))

        // Personal vocabulary is reported truthfully, including when empty.
        checks.append(Check(
            name: "Personal vocabulary",
            passed: true,
            detail: lexicon.words.isEmpty
                ? "No personal keyboard vocabulary is available yet on this device."
                : "\(lexicon.words.count) personal word(s), \(lexicon.expansions.count) shortcut expansion(s)."
        ))

        // Continuations come from the fixed table and must be non-empty for a
        // word that is in it.
        let continuations = LocalNextWordModel.shared.continuations(after: "thanks")
        checks.append(Check(
            name: "Continuations",
            passed: !continuations.isEmpty,
            detail: continuations.isEmpty
                ? "Continuation table returned nothing for a known word."
                : "Offered \(continuations.count) continuation(s) after a known word."
        ))

        return checks.allSatisfy(\.passed) ? .pass(checks: checks) : .fail(checks: checks)
    }
}
