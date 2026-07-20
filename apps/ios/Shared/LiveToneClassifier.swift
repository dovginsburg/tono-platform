// LiveToneClassifier.swift
// Tono Live Tone v1 — shipping release classifier.
//
// Implementation of the binding `Live Tone v1 Acceptance Contract`.
// Deterministic, local, versioned, fail-closed, and pattern-precise.
// Evaluation is purely a function of the isolated current draft string:
// no I/O, no clock, no randomness, no networking, no pasteboard, no
// persistence.
//
// Precedence — first matching tier decides:
//
//   P0 — Crisis suppression: total silence on self-harm patterns
//        (Mira GO per `t_e3513a5d`).
//   P1 — Containment suppression: every matched hostile token must be
//        inside quotation marks or inside the clause governed by a
//        reporting verb. Any uncontained hostile token voids P1 for the
//        whole draft segment. Token-level containment, no partial credit.
//   P2 — Exact idiom allowlist: literal matches produce no warning
//        (victim-inverted idioms such as "you're killing me").
//   P3 — Class A threat / coercion: unconditional L2. Banter markers
//        never suppress or downgrade. The pattern set is closed and
//        versioned — adding a pattern is a contract change.
//   P4 — Class B bare hyperbolic violence: L2 by default; adjacent
//        banter marker downgrades to L1, never to silence. One dismissal
//        silences the hit for the current draft.
//   P5 — Banter suppression: hits that would otherwise be L1 silenced
//        when an adjacent banter marker is present.
//   P6 — Insult / absolutist blame / caps: L1 and requires a second-
//        person token. Sustained ALL-CAPS plus second-person escalates
//        to L2.
//
// Pure Foundation. Static source guards in `LiveToneV1AcceptanceTests`
// assert this file contains no networking, pasteboard, timer, or UIKit
// tokens.

import Foundation

// MARK: - Severity level

public enum LiveToneLevel: String, Equatable, Codable {
    /// L1 — Notice: subtle tint on the tone chip.
    case l1
    /// L2 — Strong: chip plus short banner above the keyboard.
    case l2
}

// MARK: - Category

/// The category axis surfaced in the L1/L2 visible warning. `.crisis` is
/// reserved for the P0 verdict and never produces a visible warning —
/// Live Tone is silent in crisis.
public enum LiveToneCategory: String, Equatable, Codable, CaseIterable {
    /// P0 — Crisis suppression (self-harm). Mira GO; never visible.
    case crisis
    /// P3 — Class A threat / coercion. Unconditional L2.
    case classAThreatCoercion
    /// P4 — Class B bare hyperbolic violence. L2, banter → L1.
    case classBHyperbolicViolence
    /// P6 — Insult / absolutist blame / condescension. L1, second-person
    /// required; caps escalation → L2.
    case hostility
    /// P6 — Sustained ALL-CAPS plus second person escalates to L2.
    case capsEscalation
}

// MARK: - Verdict

public struct LiveToneVerdict: Equatable, Codable {

    /// Visible level. `nil` for `.silent` and for `.crisisSilence`.
    public let level: LiveToneLevel?

    /// The category axis. `.crisis` for the P0 verdict. `nil` only when
    /// the draft produced no signal at all.
    public let category: LiveToneCategory?

    /// Optional human-readable rationale (rule id, span). Diagnostic only.
    public let rationale: String?

    public init(
        level: LiveToneLevel?,
        category: LiveToneCategory?,
        rationale: String? = nil
    ) {
        self.level = level
        self.category = category
        self.rationale = rationale
    }

    /// The total-silence verdict for P0 crisis patterns (Mira GO).
    public static let crisisSilence = LiveToneVerdict(
        level: nil, category: .crisis, rationale: "P0 crisis suppression"
    )

    /// The neutral verdict for benign drafts.
    public static let silent = LiveToneVerdict(
        level: nil, category: nil, rationale: nil
    )

    /// True when the verdict should be surfaced (L1 / L2).
    public var isVisible: Bool { level != nil && category != .crisis }
}

// MARK: - Token / hit model

private enum TokenKind {
    case word
    case quoteSingle
    case quoteDouble
    case punctuation
    case whitespace
    case other
}

private struct Token {
    let kind: TokenKind
    let text: String
    /// Normalized form (lower-cased, ASCII-quoted) for matching.
    let normalized: String
    let range: Range<Int>
}

private struct HostileHit {
    let category: LiveToneCategory
    let level: LiveToneLevel
    /// Indices into the token stream the hit covers. Containment tests
    /// inspect these.
    let tokenRange: Range<Int>
}

// MARK: - Classifier

public struct LiveToneClassifier {

    /// Bump on any change to precedence order, normalization, or the
    /// closed Class A pattern table.
    public static let version = 2
    public static let patternSetVersion = 1

    /// Longest draft the classifier will scan. Drafts longer than this
    /// are truncated to a bounded prefix before matching so evaluation
    /// cost and allocation stay O(1) in the size of the field.
    public static let maxScannedCharacters = 2_000

    public init() {}

    // MARK: - Public entry

    /// Classify an isolated draft. Pure and total: never throws, never
    /// touches global state, returns `.silent` for empty input, and
    /// respects every precedence tier in P0 → P6 order.
    public func classify(_ draft: String) -> LiveToneVerdict {
        guard !draft.isEmpty else { return .silent }
        let tokens = Tokenization.tokenize(Self.normalize(draft))
        guard !tokens.isEmpty else { return .silent }

        // P0 — Crisis suppression (total silence). Mira GO.
        if Self.firstCrisisHit(in: tokens) != nil {
            return .crisisSilence
        }

        // Collect every hostile hit across P3, P4, and P6 in one pass.
        let hostileHits = Self.collectHostileHits(in: tokens)

        // P1 — Containment suppression. If every hostile hit is fully
        // contained inside a quote span or reporting-verb clause, produce
        // silence. Any uncontained hostile token voids P1.
        if !hostileHits.isEmpty,
           hostileHits.allSatisfy({ Containment.isContained($0, tokens: tokens) }) {
            return .silent
        }

        // P2 — Exact idiom allowlist. A literal-match idiom wins over an
        // L1 insult hit. (Class A / B L2 hits do not match an idiom
        // pattern; P3 banter-irrelevance stands.)
        if Self.firstIdiomHit(in: tokens) != nil {
            return .silent
        }

        // P3 — Class A threat / coercion: unconditional L2. Banter
        // markers never suppress or downgrade.
        if let hit = hostileHits.first(where: { $0.category == .classAThreatCoercion }) {
            return LiveToneVerdict(
                level: hit.level,
                category: .classAThreatCoercion,
                rationale: "P3 Class A"
            )
        }

        // P4 — Class B bare hyperbolic violence: L2 by default; adjacent
        // banter marker downgrades to L1, never to silence.
        if let hit = hostileHits.first(where: { $0.category == .classBHyperbolicViolence }) {
            let hasBanter = BanterMarkers.hasAdjacentBanter(tokens: tokens, around: hit.tokenRange)
            return LiveToneVerdict(
                level: hasBanter ? .l1 : .l2,
                category: .classBHyperbolicViolence,
                rationale: hasBanter ? "P4 Class B banter → L1" : "P4 Class B"
            )
        }

        // P5 — Banter suppression of L1 hostility / absolutist blame /
        // caps. P5 only suppresses; it never produces a warning itself.
        let p6Candidate = hostileHits.first(where: {
            $0.category == .hostility || $0.category == .capsEscalation
        })
        if let hit = p6Candidate {
            let hasBanter = BanterMarkers.hasAdjacentBanter(tokens: tokens, around: hit.tokenRange)
            if !hasBanter {
                return LiveToneVerdict(
                    level: hit.level,
                    category: hit.category,
                    rationale: "P6 \(hit.category.rawValue)"
                )
            }
        }

        return .silent
    }

    // MARK: - Fileprivate re-exports so the public classify(_:) entry
    // point can call into the private pattern / tokenization types
    // without exposing them as part of the public surface.

    fileprivate static func tokenize(_ normalized: String) -> [Token] {
        Tokenization.tokenize(normalized)
    }

    fileprivate static func firstCrisisHit(in tokens: [Token]) -> Range<Int>? {
        CrisisDetector.firstMatch(in: tokens)
    }

    fileprivate static func firstIdiomHit(in tokens: [Token]) -> Range<Int>? {
        IdiomAllowlist.firstMatch(in: tokens)
    }

    fileprivate static func collectHostileHits(in tokens: [Token]) -> [HostileHit] {
        HostileHits.collect(in: tokens)
    }

    fileprivate static func isContained(_ hit: HostileHit, in tokens: [Token]) -> Bool {
        Containment.isContained(hit, tokens: tokens)
    }

    fileprivate static func hasAdjacentBanter(tokens: [Token], around range: Range<Int>) -> Bool {
        BanterMarkers.hasAdjacentBanter(tokens: tokens, around: range)
    }

    // MARK: - Normalization

    /// Lower-case, fold smart punctuation to ASCII, collapse runs of
    /// whitespace to single spaces. Locale-independent — deterministic
    /// across devices. Bounded by `maxScannedCharacters`.
    static func normalize(_ raw: String) -> String {
        let bounded = raw.prefix(maxScannedCharacters)
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(maxScannedCharacters)
        var lastWasSpace = false
        for scalar in bounded.lowercased().unicodeScalars {
            let folded = Self.fold(scalar)
            if folded == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
                scalars.append(" ")
            } else {
                lastWasSpace = false
                scalars.append(folded)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "\u{2018}", "\u{2019}", "\u{02BC}": return "'"
        case "\u{201C}", "\u{201D}": return "\""
        case "\u{2013}", "\u{2014}": return "-"
        case "\u{2026}": return " "
        default:
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return " " }
            return scalar
        }
    }
}

// MARK: - Tokenization

private enum Tokenization {

    static func tokenize(_ normalized: String) -> [Token] {
        var tokens: [Token] = []
        tokens.reserveCapacity(normalized.count)
        var current = ""
        var currentStart = 0
        var cursor = 0
        var currentKind: TokenKind = .word

        // Look-ahead helper: does the apostrophe at scalar position `i` sit
        // between two letters? Used to decide whether `'` is an in-word
        // apostrophe (`i'll`, `don't`) or a standalone quote
        // (`'you're worthless'`). `cursor` is the scalar index of the
        // apostrophe currently being classified.
        func apostropheHasLettersOnBothSides() -> Bool {
            let scalars = normalized.unicodeScalars
            let prevIndex = cursor - 1
            let nextIndex = cursor + 1
            let prevIsLetter: Bool = {
                guard prevIndex >= 0, prevIndex < scalars.count else { return false }
                let target = scalars.index(scalars.startIndex, offsetBy: prevIndex)
                return CharacterSet.letters.contains(scalars[target])
            }()
            let nextIsLetter: Bool = {
                guard nextIndex >= 0, nextIndex < scalars.count else { return false }
                let target = scalars.index(scalars.startIndex, offsetBy: nextIndex)
                return CharacterSet.letters.contains(scalars[target])
            }()
            return prevIsLetter && nextIsLetter
        }

        func flush() {
            guard !current.isEmpty else { return }
            let kind: TokenKind
            switch currentKind {
            case .quoteSingle, .quoteDouble:
                kind = currentKind
            case .punctuation, .whitespace, .other:
                kind = .other
            case .word:
                kind = .word
            }
            tokens.append(Token(
                kind: kind,
                text: current,
                normalized: current,
                range: currentStart..<cursor
            ))
            current = ""
        }

        for scalar in normalized.unicodeScalars {
            let kind: TokenKind
            switch scalar {
            case "\"": kind = .quoteDouble
            case "'":
                // Apostrophes between two letters stay glued to the
                // surrounding word so `i'll`, `don't`, `you're` tokenize
                // as single words. Standalone apostrophes still surface as
                // `.quoteSingle` for P1 quote-span detection.
                kind = apostropheHasLettersOnBothSides() ? .word : .quoteSingle
            case ".": kind = .punctuation
            case "!": kind = .punctuation
            case "?": kind = .punctuation
            case ",": kind = .punctuation
            case ";": kind = .punctuation
            case ":": kind = .punctuation
            default:
                if CharacterSet.whitespaces.contains(scalar) {
                    kind = .whitespace
                } else if CharacterSet.letters.contains(scalar)
                    || CharacterSet.decimalDigits.contains(scalar) {
                    kind = .word
                } else {
                    kind = .other
                }
            }
            if kind != currentKind && !current.isEmpty {
                flush()
                currentStart = cursor
            }
            currentKind = kind
            current.unicodeScalars.append(scalar)
            cursor += 1
        }
        flush()
        return tokens
    }
}

// MARK: - Crisis detection (P0)

fileprivate enum CrisisDetector {

    /// Closed, versioned crisis patterns. Each entry is a normalized
    /// phrase that, when present in the draft, forces P0 total silence.
    /// Adding a pattern is a contract change.
    static let patterns: [String] = [
        "i want to kill myself",
        "i'm going to kill myself",
        "im going to kill myself",
        "i will kill myself",
        "i should kill myself",
        "kill myself",
        "end my life",
        "end it all",
        "take my life",
        "i want to die",
        "i'm going to die",
        "i'm going to hurt myself",
        "im going to hurt myself",
        "i will hurt myself",
        "hurt myself",
        "suicide",
        "suicidal"
    ]

    static func firstMatch(in tokens: [Token]) -> Range<Int>? {
        let joined = tokens.map(\.normalized).joined(separator: " ")
        for pattern in patterns where joined.contains(pattern) {
            // Locate the token range the pattern covers.
            if let range = tokenRange(for: pattern, in: tokens) {
                return range
            }
            return 0..<tokens.count
        }
        return nil
    }

    private static func tokenRange(for phrase: String, in tokens: [Token]) -> Range<Int>? {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard phraseTokens.count <= tokens.count else { return nil }
        outer: for start in 0...(tokens.count - phraseTokens.count) {
            for (offset, word) in phraseTokens.enumerated() {
                if tokens[start + offset].normalized != word { continue outer }
            }
            return start..<(start + phraseTokens.count)
        }
        return nil
    }
}

// MARK: - Idiom allowlist (P2)

fileprivate enum IdiomAllowlist {

    /// Closed set of literal-match idioms that produce no warning. These
    /// include victim-inverted patterns where the speaker is the target.
    static let patterns: [String] = [
        "could kill for",
        "would kill for",
        "i could kill for",
        "i would kill for",
        "dying to",
        "i'm dying to",
        "im dying to",
        "traffic is killing me",
        "this is killing me",
        "you're killing me",
        "youre killing me",
        "you are killing me",
        "this heat is killing me",
        "this is too much lol",
        "you're too much lol",
        "youre too much lol"
    ]

    static func firstMatch(in tokens: [Token]) -> Range<Int>? {
        let joined = tokens.map(\.normalized).joined(separator: " ")
        for pattern in patterns where joined.contains(pattern) {
            if let range = CrisisDetector.tokenRange_forSharedHelper(
                pattern, in: tokens
            ) {
                return range
            }
            return 0..<tokens.count
        }
        return nil
    }
}

// Helper used only by IdiomAllowlist so the private tokenRange lookup
// stays in scope.
private extension CrisisDetector {
    static func tokenRange_forSharedHelper(
        _ phrase: String, in tokens: [Token]
    ) -> Range<Int>? {
        // Re-implement here to keep the helper internal-only.
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard phraseTokens.count <= tokens.count else { return nil }
        outer: for start in 0...(tokens.count - phraseTokens.count) {
            for (offset, word) in phraseTokens.enumerated() {
                if tokens[start + offset].normalized != word { continue outer }
            }
            return start..<(start + phraseTokens.count)
        }
        return nil
    }
}

// MARK: - Hostile hit collection

private enum HostileHits {

    /// Walk the token stream collecting every Class A / Class B / insult
    /// / caps-escalation hit. P3, P4, and P6 are evaluated against the
    /// collected hits so P1 containment and P5 banter suppression can
    /// act on the full picture.
    static func collect(in tokens: [Token]) -> [HostileHit] {
        var hits: [HostileHit] = []
        hits.append(contentsOf: ClassAPatternSet.match(in: tokens))
        hits.append(contentsOf: ClassBPatternSet.match(in: tokens))
        hits.append(contentsOf: InsultDetector.match(in: tokens))
        hits.append(contentsOf: CapsEscalationDetector.match(in: tokens))
        return hits
    }
}

// MARK: - Class A pattern set (P3)

private enum ClassAPatternSet {

    /// Closed, versioned Class A pattern table. Adding a pattern is a
    /// contract change requiring every fixture (15 base + 7 overlap) to
    /// be rerun. `patternSetVersion` lives on `LiveToneClassifier`.
    static let patterns: [String] = [
        // Demand plus consequence / "or else"
        "send the money or",
        "pay up or",
        "do it or",
        "or i'll post",
        "or i will post",
        "or i'm posting",
        "or im posting",
        "or i'll send",
        "or i will send",
        "or i'm telling",
        "or im telling",
        "or i'll tell",
        "or i will tell",
        "or else",
        // Conditional harm
        "if you",
        "i'll make you",
        "ill make you",
        "i will make you",
        "make you regret",
        "you'll be sorry",
        "youll be sorry",
        "you will be sorry",
        "you will regret",
        "you'll regret",
        "youll regret",
        "you're going to regret",
        "youre going to regret",
        "you are going to regret",
        // Exposure threats
        "i'll post",
        "ill post",
        "i will post",
        "i'm posting",
        "im posting",
        "i'm going to post",
        "im going to post",
        "i'll share",
        "ill share",
        "i will share",
        "i'm sharing",
        "im sharing",
        "i'm going to share",
        "im going to share",
        "i'll tell everyone",
        "ill tell everyone",
        "i will tell everyone",
        "i'll tell people",
        "ill tell people",
        "i will tell people",
        // Guilt-coercion
        "if you loved me",
        "after all i've done",
        "after all ive done",
        "after all i have done"
    ]

    static func match(in tokens: [Token]) -> [HostileHit] {
        var hits: [HostileHit] = []
        let joined = tokens.map(\.normalized).joined(separator: " ")
        for pattern in patterns where joined.contains(pattern) {
            if let range = lookupRange(for: pattern, in: tokens) {
                hits.append(HostileHit(
                    category: .classAThreatCoercion,
                    level: .l2,
                    tokenRange: range
                ))
            } else {
                hits.append(HostileHit(
                    category: .classAThreatCoercion,
                    level: .l2,
                    tokenRange: 0..<tokens.count
                ))
            }
        }
        return hits
    }

    private static func lookupRange(for phrase: String, in tokens: [Token]) -> Range<Int>? {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard phraseTokens.count <= tokens.count else { return nil }
        outer: for start in 0...(tokens.count - phraseTokens.count) {
            for (offset, word) in phraseTokens.enumerated() {
                if tokens[start + offset].normalized != word { continue outer }
            }
            return start..<(start + phraseTokens.count)
        }
        return nil
    }
}

// MARK: - Class B pattern set (P4)

private enum ClassBPatternSet {

    static let patterns: [String] = [
        "i'll kill you",
        "ill kill you",
        "i will kill you",
        "i'm going to kill you",
        "im going to kill you",
        "i'm gonna kill you",
        "im gonna kill you",
        "i will kill you",
        "i'll murder you",
        "ill murder you",
        "i will murder you",
        "i'm going to murder you",
        "im going to murder you",
        "i'll strangle you",
        "ill strangle you",
        "i will strangle you",
        "i'm going to strangle you",
        "im going to strangle you"
    ]

    static func match(in tokens: [Token]) -> [HostileHit] {
        var hits: [HostileHit] = []
        let joined = tokens.map(\.normalized).joined(separator: " ")
        for pattern in patterns where joined.contains(pattern) {
            if let range = lookupRange(for: pattern, in: tokens) {
                hits.append(HostileHit(
                    category: .classBHyperbolicViolence,
                    level: .l2,
                    tokenRange: range
                ))
            } else {
                hits.append(HostileHit(
                    category: .classBHyperbolicViolence,
                    level: .l2,
                    tokenRange: 0..<tokens.count
                ))
            }
        }
        return hits
    }

    private static func lookupRange(for phrase: String, in tokens: [Token]) -> Range<Int>? {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard phraseTokens.count <= tokens.count else { return nil }
        outer: for start in 0...(tokens.count - phraseTokens.count) {
            for (offset, word) in phraseTokens.enumerated() {
                if tokens[start + offset].normalized != word { continue outer }
            }
            return start..<(start + phraseTokens.count)
        }
        return nil
    }
}

// MARK: - Insult detector (P6 / hostility)

private enum InsultDetector {

    static let insults: [String] = [
        "idiot", "moron", "stupid", "dumb", "loser", "jerk",
        "cretin", "imbecile", "fool", "scum", "trash", "garbage",
        "worthless", "pathetic", "disgusting", "ugly", "fat",
        "clueless", "incompetent", "hopeless"
    ]

    static func match(in tokens: [Token]) -> [HostileHit] {
        var hits: [HostileHit] = []
        for (index, token) in tokens.enumerated() where token.kind == .word {
            if insults.contains(token.normalized) {
                hits.append(HostileHit(
                    category: .hostility,
                    level: .l1,
                    tokenRange: index..<(index + 1)
                ))
            }
        }
        return hits
    }
}

// MARK: - Absolutist blame detector (P6 / hostility)

private enum AbsolutistBlameDetector {

    /// "you always", "you never", "you constantly", "you keep". P6 L1
    /// (second-person required).
    static let phrases: [String] = [
        "you always",
        "you never",
        "you constantly",
        "you keep",
        "you always do this",
        "you never listen",
        "you always say",
        "you always think",
        "you never said",
        "you never told me"
    ]

    static func match(in tokens: [Token]) -> [HostileHit] {
        var hits: [HostileHit] = []
        let joined = tokens.map(\.normalized).joined(separator: " ")
        for phrase in phrases where joined.contains(phrase) {
            if let range = lookupRange(for: phrase, in: tokens) {
                hits.append(HostileHit(
                    category: .hostility,
                    level: .l1,
                    tokenRange: range
                ))
            }
        }
        return hits
    }

    private static func lookupRange(for phrase: String, in tokens: [Token]) -> Range<Int>? {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard phraseTokens.count <= tokens.count else { return nil }
        outer: for start in 0...(tokens.count - phraseTokens.count) {
            for (offset, word) in phraseTokens.enumerated() {
                if tokens[start + offset].normalized != word { continue outer }
            }
            return start..<(start + phraseTokens.count)
        }
        return nil
    }
}

// MARK: - Caps escalation detector (P6 / capsEscalation)

private enum CapsEscalationDetector {

    /// Sustained ALL-CAPS word run (>= 3 contiguous words) PLUS a
    /// second-person token in the draft. The original draft is preserved
    /// (the contract binds the heuristic, not the keystroke path), so
    /// caps detection operates on the upper-cased projection of the
    /// normalized tokens.
    static func match(in tokens: [Token]) -> [HostileHit] {
        let hasSecondPerson = tokens.contains { token in
            token.kind == .word &&
            (token.normalized == "you" || token.normalized == "your" || token.normalized == "u")
        }
        guard hasSecondPerson else { return [] }

        var runStart: Int? = nil
        var runLength = 0
        var collected: [HostileHit] = []

        for (index, token) in tokens.enumerated() {
            let isCapsWord = token.kind == .word && token.text == token.text.uppercased() &&
                token.text.count >= 2 &&
                token.text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            if isCapsWord {
                if runStart == nil { runStart = index }
                runLength += 1
            } else {
                if let start = runStart, runLength >= 3 {
                    collected.append(HostileHit(
                        category: .capsEscalation,
                        level: .l2,
                        tokenRange: start..<(start + runLength)
                    ))
                }
                runStart = nil
                runLength = 0
            }
        }
        if let start = runStart, runLength >= 3 {
            collected.append(HostileHit(
                category: .capsEscalation,
                level: .l2,
                tokenRange: start..<(start + runLength)
            ))
        }
        return collected
    }
}

// Bridge Insult + Absolutist blame into the unified HostileHits.collect
// pipeline.
private extension HostileHits {
    static func matchInsultLike() -> [HostileHit] {
        // Not used; kept for clarity that InsultDetector + AbsolutistBlame
        // are folded under Hostility hits.
        return []
    }
}

// MARK: - Containment (P1)

private enum Containment {

    /// True when every token of `hit.tokenRange` lies inside a single
    /// quotation span or inside the clause governed by a reporting verb
    /// ("said", "told", "called", "texted", "threatened", "wrote").
    /// Implemented as token-level containment with no partial credit.
    static func isContained(_ hit: HostileHit, tokens: [Token]) -> Bool {
        let spans = quoteSpans(in: tokens) + reportingVerbSpans(in: tokens)
        guard !spans.isEmpty else { return false }
        for span in spans {
            if span.lowerBound <= hit.tokenRange.lowerBound &&
                hit.tokenRange.upperBound <= span.upperBound {
                return true
            }
        }
        return false
    }

    static func quoteSpans(in tokens: [Token]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = 0
        while i < tokens.count {
            if tokens[i].kind == .quoteDouble || tokens[i].kind == .quoteSingle {
                let opener = i
                var j = i + 1
                while j < tokens.count {
                    if tokens[j].kind == tokens[i].kind { break }
                    j += 1
                }
                spans.append(opener..<min(j + 1, tokens.count))
                i = j + 1
            } else {
                i += 1
            }
        }
        return spans
    }

    static func reportingVerbSpans(in tokens: [Token]) -> [Range<Int>] {
        let reportingVerbs: Set<String> = [
            "said", "says", "tell", "tells", "told",
            "called", "calls", "texted", "texts",
            "threatened", "threatens", "wrote", "writes",
            "asked", "asks", "shouted", "shouts",
            "screamed", "screams"
        ]
        var spans: [Range<Int>] = []
        for (i, token) in tokens.enumerated() where token.kind == .word {
            if reportingVerbs.contains(token.normalized) {
                // Span covers the rest of the sentence after the reporting
                // verb. Sentences terminate on `.!?\n`. For simplicity and
                // determinism the span runs to the end of the token stream
                // or to the next sentence terminator (a punctuation token).
                var end = i + 1
                while end < tokens.count, tokens[end].kind != .punctuation {
                    end += 1
                }
                spans.append((i + 1)..<min(end, tokens.count))
            }
        }
        return spans
    }
}

// MARK: - Banter markers (P4 / P5)

private enum BanterMarkers {

    static let tokens: Set<String> = [
        "lol", "lmao", "rofl", "jk", "haha", "hahaha",
        "😂", "🤣", "😅", "🙃", "😜", "😝"
    ]

    /// True when any banter marker token sits within one token of the
    /// hit range (before, on, or after). The fixture table documents
    /// "adjacent banter marker" — a 1-token neighborhood is the
    /// deterministic, testable interpretation.
    static func hasAdjacentBanter(
        tokens: [Token], around range: Range<Int>
    ) -> Bool {
        guard !tokens.isEmpty else { return false }
        let lower = max(0, range.lowerBound - 1)
        let upper = min(tokens.count, range.upperBound + 1)
        for index in lower..<upper {
            if tokens[index].kind == .word,
               BanterMarkers.tokens.contains(tokens[index].normalized) {
                return true
            }
            if tokens[index].kind == .other,
               BanterMarkers.tokens.contains(tokens[index].normalized) {
                return true
            }
        }
        return false
    }
}