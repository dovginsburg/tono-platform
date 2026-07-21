// LiveToneOpportunity.swift
// Tono Live Tone — positive-opportunity classifier (build 97).
//
// Implements the binding "Tono Live Tone Positive Opportunity Version
// Contract — 2026-07-21". Deterministic, local, versioned, fail-closed.
// Evaluation is a pure function of the isolated current draft string:
// no I/O, no clock, no randomness, no networking, no clipboard, no
// persistence.
//
// The opportunity lane is the LOWEST-priority Live Tone surface. It is
// evaluated only when the red/crisis classifier is fully silent (see the
// integration precedence) — crisis silence stays TOTAL silence, and any
// red warning wins. Its microcopy describes the TEXT, never the person:
// no "you seem", "you sound", or "are you" constructions.
//
// Build 97 ships O1–O3 active. O4 (brisk request) and O5 (flat refusal)
// are modeled but permanently silent here pending the build-98 physical-
// world counter-evidence gate and a fresh founder decision.
//
// Governing rules (verbatim from the contract):
//   O1 Hedge stack / confidence opportunity (FLAGSHIP)
//      Fire on at least two distinct lexicon hits in one sentence or
//      three across the message; message length at least five words.
//      "Just" and "I think" count only immediately before a
//      cognition/request verb; "just landed" and a lone "I think X"
//      remain silent.
//      Microcopy: "Reads more tentative than it may need to."
//   O2 Apology stack
//      Fire on at least two sorry/apolog* tokens. Condolence phrases
//      such as "sorry for your loss" and "sorry to hear" do not count.
//      Microcopy: "Reads more apologetic than it may need to."
//   O3 Caps emphasis
//      Fire on at least one all-caps alphabetic token of at least four
//      letters in a message of at least three words. Bundled, updatable
//      allowlist covers conversational abbreviations and standard
//      acronyms/proper nouns.
//      Microcopy: "All caps can read as shouting."
//
// Pure Foundation. Static source guards in `LiveToneV1AcceptanceTests`
// assert this file contains no networking, clipboard, timer, or UIKit
// tokens.

import Foundation

// MARK: - Family

/// The five positive-opportunity families. `code` is the contract label
/// ("O1"…"O5"); `rawValue` is the stable counter/suppression key.
public enum LiveToneOpportunityFamily: String, Equatable, Codable, CaseIterable {
    /// O1 — hedge stack / confidence opportunity. Flagship signal.
    case hedge
    /// O2 — apology stack.
    case apology
    /// O3 — caps emphasis.
    case caps
    /// O4 — brisk request. Deferred; silent in build 97.
    case briskRequest
    /// O5 — flat refusal. Deferred; silent in build 97.
    case flatRefusal

    /// Contract identifier ("O1"…"O5").
    public var code: String {
        switch self {
        case .hedge: return "O1"
        case .apology: return "O2"
        case .caps: return "O3"
        case .briskRequest: return "O4"
        case .flatRefusal: return "O5"
        }
    }

    /// True for the families that may surface in build 97. O4/O5 are
    /// modeled for the fixture matrix but never fire until build 98.
    public var isActiveInBuild97: Bool {
        switch self {
        case .hedge, .apology, .caps: return true
        case .briskRequest, .flatRefusal: return false
        }
    }

    /// Exact contract microcopy. Describes the text, never the person.
    /// O4/O5 carry no copy — they never surface in build 97.
    public var microcopy: String {
        switch self {
        case .hedge: return LiveToneCopy.opportunityHedge
        case .apology: return LiveToneCopy.opportunityApology
        case .caps: return LiveToneCopy.opportunityCaps
        case .briskRequest, .flatRefusal: return ""
        }
    }
}

// MARK: - Verdict

/// A single opportunity signal. A draft surfaces at most one family
/// (O1 flagship precedence first). `signals` and `sentenceSignature` feed
/// the session's one-fire / same-sentence-refire logic; both are held only
/// in memory and never persisted — the local counters store integers only.
public struct LiveToneOpportunityVerdict: Equatable {

    public let family: LiveToneOpportunityFamily

    /// The distinct signal identifiers that produced the fire (hedge
    /// lexemes, apology tokens, or offending caps tokens). Content-free
    /// lexeme keys, in memory only.
    public let signals: Set<String>

    /// Stable, content-free hash of the triggering sentence (or the whole
    /// message for the O1 cross-message rule). A hash, never raw text.
    public let sentenceSignature: Int

    public init(
        family: LiveToneOpportunityFamily,
        signals: Set<String>,
        sentenceSignature: Int
    ) {
        self.family = family
        self.signals = signals
        self.sentenceSignature = sentenceSignature
    }
}

// MARK: - Classifier

public struct LiveToneOpportunityClassifier {

    /// Bump on any change to precedence order, normalization, or the
    /// bundled lexicons / allowlist.
    public static let version = 1

    /// Longest draft scanned. Mirrors `LiveToneClassifier` so evaluation
    /// cost stays O(1) in the size of the field.
    public static let maxScannedCharacters = 2_000

    // MARK: Tunable thresholds (contract "Alert discipline")

    /// O1: distinct hedge lexemes required WITHIN one sentence. Build-97
    /// value is 2. Raised to >= 3 only after TestFlight counters show O1
    /// above roughly 3% alone. Parameterized so the release gate can tune
    /// it without a logic change.
    public let hedgeSentenceThreshold: Int

    /// O1: distinct hedge lexemes required ACROSS the whole message.
    public let hedgeMessageThreshold: Int

    /// O1: minimum message length in words.
    public let hedgeMinWords: Int

    /// O3: minimum message length in words.
    public let capsMinWords: Int

    /// O3: minimum all-caps alphabetic token length in letters.
    public let capsMinLetters: Int

    /// O3: bundled, updatable allowlist. Injectable so the app bundle can
    /// ship a refreshed allowlist (conversational abbreviations + standard
    /// acronyms / proper nouns) without a classifier code change.
    public let capsAllowlist: Set<String>

    /// The families permitted to surface. Release-gated per the contract:
    ///   * Build 96 — empty (every family silent).
    ///   * Build 97 — O1–O3 (`build97Active`, the default here).
    ///   * Build 98 — O1–O5, only after the physical-world evidence gate.
    /// A family that is not active never fires even if its pattern matches,
    /// so the same fixture matrix is executable under every build gate.
    public let activeFamilies: Set<LiveToneOpportunityFamily>

    /// Build-97 active set: O1 hedge, O2 apology, O3 caps.
    public static let build97Active: Set<LiveToneOpportunityFamily> = [.hedge, .apology, .caps]

    public init(
        hedgeSentenceThreshold: Int = 2,
        hedgeMessageThreshold: Int = 3,
        hedgeMinWords: Int = 5,
        capsMinWords: Int = 3,
        capsMinLetters: Int = 4,
        capsAllowlist: Set<String> = LiveToneCapsAllowlist.bundled,
        activeFamilies: Set<LiveToneOpportunityFamily> = LiveToneOpportunityClassifier.build97Active
    ) {
        self.hedgeSentenceThreshold = hedgeSentenceThreshold
        self.hedgeMessageThreshold = hedgeMessageThreshold
        self.hedgeMinWords = hedgeMinWords
        self.capsMinWords = capsMinWords
        self.capsMinLetters = capsMinLetters
        // Normalize the allowlist to upper-case once so lookups are a
        // simple membership test on the token's upper-cased form.
        self.capsAllowlist = Set(capsAllowlist.map { $0.uppercased() })
        self.activeFamilies = activeFamilies
    }

    // MARK: Public entry

    /// Classify an isolated draft into at most one opportunity family.
    /// Pure and total: never throws, never touches global state, returns
    /// `nil` for empty / benign input. O1 flagship precedence first, then
    /// O2, then O3. O4/O5 never fire in build 97.
    public func classify(_ draft: String) -> LiveToneOpportunityVerdict? {
        guard !draft.isEmpty else { return nil }
        let doc = OpportunityTokenizer.tokenize(
            String(draft.prefix(Self.maxScannedCharacters))
        )
        guard doc.wordCount > 0 else { return nil }

        // Release-gated: a family fires only when it is active for this
        // build. O1 flagship precedence first, then O2, then O3.
        if activeFamilies.contains(.hedge), let hedge = matchHedge(doc) { return hedge }
        if activeFamilies.contains(.apology), let apology = matchApology(doc) { return apology }
        if activeFamilies.contains(.caps), let caps = matchCaps(doc) { return caps }
        return nil
    }

    // MARK: - O1 Hedge stack (flagship)

    private func matchHedge(_ doc: OpportunityDocument) -> LiveToneOpportunityVerdict? {
        guard doc.wordCount >= hedgeMinWords else { return nil }

        var messageDistinct = Set<String>()
        var best: (index: Int, hedges: Set<String>)?

        for (index, sentence) in doc.sentences.enumerated() {
            let hedges = HedgeLexicon.distinctHedges(in: sentence)
            guard !hedges.isEmpty else { continue }
            messageDistinct.formUnion(hedges)
            if hedges.count > (best?.hedges.count ?? 0) {
                best = (index, hedges)
            }
        }

        // Concentrated stacking within a single sentence.
        if let best, best.hedges.count >= hedgeSentenceThreshold {
            return LiveToneOpportunityVerdict(
                family: .hedge,
                signals: best.hedges,
                sentenceSignature: doc.signature(ofSentence: best.index)
            )
        }
        // Diffuse stacking spread across the message.
        if messageDistinct.count >= hedgeMessageThreshold {
            return LiveToneOpportunityVerdict(
                family: .hedge,
                signals: messageDistinct,
                sentenceSignature: doc.messageSignature
            )
        }
        return nil
    }

    // MARK: - O2 Apology stack

    private func matchApology(_ doc: OpportunityDocument) -> LiveToneOpportunityVerdict? {
        let words = doc.allWords
        var counted: [String] = []
        for (index, word) in words.enumerated() {
            let lower = word.lower
            let isSorry = (lower == "sorry")
            let isApolog = lower.hasPrefix("apolog")
            guard isSorry || isApolog else { continue }
            // Condolence "sorry" (sympathy, not self-apology) does not count.
            if isSorry, CondolenceDetector.isCondolenceSorry(at: index, in: words) {
                continue
            }
            counted.append(lower)
        }
        guard counted.count >= 2 else { return nil }
        return LiveToneOpportunityVerdict(
            family: .apology,
            signals: Set(counted),
            sentenceSignature: doc.messageSignature
        )
    }

    // MARK: - O3 Caps emphasis

    private func matchCaps(_ doc: OpportunityDocument) -> LiveToneOpportunityVerdict? {
        guard doc.wordCount >= capsMinWords else { return nil }

        var offenders = Set<String>()
        var firstSentence: Int?
        for (index, sentence) in doc.sentences.enumerated() {
            for word in sentence {
                guard OpportunityCase.isAllCapsAlpha(word.original, minLetters: capsMinLetters) else {
                    continue
                }
                if capsAllowlist.contains(word.original.uppercased()) { continue }
                offenders.insert(word.lower)
                if firstSentence == nil { firstSentence = index }
            }
        }
        guard !offenders.isEmpty, let firstSentence else { return nil }
        return LiveToneOpportunityVerdict(
            family: .caps,
            signals: offenders,
            sentenceSignature: doc.signature(ofSentence: firstSentence)
        )
    }
}

// MARK: - Tokenization

/// One word token with its original-case and lower-case forms. Original
/// case is preserved so O3 caps detection is exact; lower case drives O1/O2
/// lexeme matching.
struct OpportunityWord: Equatable {
    let original: String
    let lower: String
}

/// A draft split into sentences of word tokens. Sentences break on
/// `. ! ? \n`. Punctuation and whitespace are dropped; in-word apostrophes
/// stay glued (`i'm`, `don't`, `that's`).
struct OpportunityDocument {
    let sentences: [[OpportunityWord]]

    var allWords: [OpportunityWord] { sentences.flatMap { $0 } }
    var wordCount: Int { sentences.reduce(0) { $0 + $1.count } }

    /// Content-free hash of one sentence's lower-cased words.
    func signature(ofSentence index: Int) -> Int {
        guard index >= 0, index < sentences.count else { return messageSignature }
        var hasher = Hasher()
        hasher.combine("s")
        for word in sentences[index] { hasher.combine(word.lower) }
        return hasher.finalize()
    }

    /// Content-free hash of the whole message's lower-cased words.
    var messageSignature: Int {
        var hasher = Hasher()
        hasher.combine("m")
        for word in allWords { hasher.combine(word.lower) }
        return hasher.finalize()
    }
}

enum OpportunityTokenizer {

    static func tokenize(_ raw: String) -> OpportunityDocument {
        var sentences: [[OpportunityWord]] = []
        var current: [OpportunityWord] = []
        var word = ""

        let scalars = Array(raw.unicodeScalars)

        func flushWord() {
            guard !word.isEmpty else { return }
            current.append(OpportunityWord(original: word, lower: word.lowercased()))
            word = ""
        }
        func flushSentence() {
            flushWord()
            if !current.isEmpty {
                sentences.append(current)
                current = []
            }
        }

        var i = 0
        while i < scalars.count {
            let scalar = fold(scalars[i])
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if scalar == "'" {
                // Keep an apostrophe only when it is glued between two
                // letters (i'm, don't, that's); otherwise it is a quote /
                // separator and ends the word.
                let prevIsLetter = word.unicodeScalars.last.map { CharacterSet.letters.contains($0) } ?? false
                let nextIsLetter: Bool = {
                    guard i + 1 < scalars.count else { return false }
                    return CharacterSet.letters.contains(fold(scalars[i + 1]))
                }()
                if prevIsLetter && nextIsLetter {
                    word.unicodeScalars.append("'")
                } else {
                    flushWord()
                }
            } else if scalar == "." || scalar == "!" || scalar == "?" || scalar == "\n" || scalar == "\r" {
                flushSentence()
            } else {
                // whitespace or other punctuation: a word boundary only.
                flushWord()
            }
            i += 1
        }
        flushSentence()
        return OpportunityDocument(sentences: sentences)
    }

    /// Fold smart apostrophes to ASCII so `that's` matches `that's`.
    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{2018}", "\u{2019}", "\u{02BC}": return "'"
        default: return scalar
        }
    }
}

// MARK: - Case helper

enum OpportunityCase {

    /// True when `s` is a purely alphabetic, all-upper-case token of at
    /// least `minLetters` letters. Requires at least one cased letter so a
    /// caseless script never trips the rule.
    static func isAllCapsAlpha(_ s: String, minLetters: Int) -> Bool {
        let scalars = s.unicodeScalars
        guard scalars.count >= minLetters else { return false }
        for scalar in scalars where !CharacterSet.letters.contains(scalar) {
            return false
        }
        return s == s.uppercased() && s != s.lowercased()
    }
}

// MARK: - O1 hedge lexicon (bundled)

enum HedgeLexicon {

    /// Single-word epistemic hedges / softeners. Deliberately tight to keep
    /// the flagship's false-positive rate under the 2% opportunity-lane
    /// target. `just` and `i think` are NOT here — they are context-gated
    /// below.
    static let singleWord: Set<String> = [
        "maybe", "perhaps", "possibly", "probably", "presumably",
        "arguably", "somewhat", "kinda", "sorta", "hopefully"
    ]

    /// Multi-word softeners. Each entry is (identifier, contiguous
    /// lower-cased token sequence). The identifier is the distinct-hit key.
    static let multiWord: [(id: String, tokens: [String])] = [
        ("kind of", ["kind", "of"]),
        ("sort of", ["sort", "of"]),
        ("a bit", ["a", "bit"]),
        ("a little", ["a", "little"]),
        ("i guess", ["i", "guess"]),
        ("i suppose", ["i", "suppose"]),
        ("i mean", ["i", "mean"]),
        ("not sure", ["not", "sure"]),
        ("if that's ok", ["if", "that's", "ok"]),
        ("if that makes sense", ["if", "that", "makes", "sense"]),
        ("no worries if not", ["no", "worries", "if", "not"]),
        ("or something", ["or", "something"]),
        ("i feel like", ["i", "feel", "like"]),
        ("if you don't mind", ["if", "you", "don't", "mind"]),
        ("no rush", ["no", "rush"])
    ]

    /// Cognition / request verbs that license the gated hedges `just` and
    /// `i think` (contract: they "count only immediately before a
    /// cognition/request verb").
    static let cognitionRequestVerbs: Set<String> = [
        "wondering", "wonder", "wondered",
        "wanted", "want", "wanna",
        "thinking", "think", "thought",
        "checking", "check", "checked",
        "asking", "ask", "asked",
        "hoping", "hope", "hoped",
        "guessing", "guess",
        "figured", "figure", "figuring",
        "saying", "say", "said",
        "suggesting", "suggest",
        "mentioning", "mention",
        "need", "needed", "needing"
    ]

    /// The distinct hedge lexemes present in one sentence.
    static func distinctHedges(in sentence: [OpportunityWord]) -> Set<String> {
        let lower = sentence.map { $0.lower }
        var found = Set<String>()

        for entry in multiWord where contains(subsequence: entry.tokens, in: lower) {
            found.insert(entry.id)
        }
        for (index, word) in lower.enumerated() {
            if singleWord.contains(word) {
                found.insert(word)
            } else if word == "just" {
                // "just" counts only immediately before a cognition/request
                // verb ("just wondering"); "just landed" stays silent.
                if index + 1 < lower.count,
                   cognitionRequestVerbs.contains(lower[index + 1]) {
                    found.insert("just")
                }
            } else if word == "i", index + 1 < lower.count, lower[index + 1] == "think" {
                // "i think" is itself a cognition phrase, so it counts only
                // when it immediately precedes a request/cognition verb.
                // A lone "I think X" remains silent.
                if index + 2 < lower.count,
                   cognitionRequestVerbs.contains(lower[index + 2]) {
                    found.insert("i think")
                }
            }
        }
        return found
    }

    private static func contains(subsequence needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        outer: for start in 0...(haystack.count - needle.count) {
            for (offset, token) in needle.enumerated() where haystack[start + offset] != token {
                continue outer
            }
            return true
        }
        return false
    }
}

// MARK: - O2 condolence detector

enum CondolenceDetector {

    /// True when the `sorry` at `index` heads a condolence phrase and so
    /// must NOT count toward the apology stack. Covers "sorry to hear ..."
    /// and "sorry {for|about} [your|the] ... loss" (the contract's
    /// non-exhaustive "such as" set).
    static func isCondolenceSorry(at index: Int, in words: [OpportunityWord]) -> Bool {
        func word(_ offset: Int) -> String {
            let j = index + offset
            guard j >= 0, j < words.count else { return "" }
            return words[j].lower
        }
        // "sorry to hear ..."
        if word(1) == "to", word(2) == "hear" { return true }
        // "sorry for/about ... loss(es)" within a short window.
        if word(1) == "for" || word(1) == "about" {
            for offset in 2...5 where !word(offset).isEmpty {
                if word(offset) == "loss" || word(offset) == "losses" { return true }
            }
        }
        return false
    }
}

// MARK: - O3 caps allowlist (bundled, updatable)

public enum LiveToneCapsAllowlist {

    /// Bundled default allowlist of conversational abbreviations and
    /// standard acronyms / proper nouns that read as normal at any case.
    /// Updatable: ship a refreshed set into
    /// `LiveToneOpportunityClassifier(capsAllowlist:)` without a code
    /// change. Entries below the four-letter caps floor are harmless — the
    /// floor already excludes them — but are kept for documentation.
    public static let bundled: Set<String> = [
        // Conversational abbreviations
        "LOL", "LMAO", "LMAOO", "ROFL", "OMG", "OMFG", "IMO", "IMHO",
        "IDK", "IDC", "TBH", "SMH", "IIRC", "AFAIK", "IDGAF", "FWIW",
        "ICYMI", "TLDR", "TIL", "YOLO", "ASAP", "FYI", "BTW", "NVM",
        "IKR", "TTYL", "BRB", "AFK", "IRL", "DM", "PM", "AMA",
        // Standard acronyms / proper nouns
        "NASA", "NATO", "IKEA", "JSON", "HTML", "HTTP", "HTTPS", "COVID",
        "GDPR", "USPS", "SCUBA", "LASER", "RADAR", "WIFI", "USA", "NYC",
        "CEO", "CFO", "CTO", "API", "SDK", "PDF", "USB", "GPS", "URL",
        "FAQ", "RSVP", "ETA", "EOD", "PTO", "WFH", "OOO", "SQL", "AWS"
    ]
}
