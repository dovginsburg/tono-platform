// SpellingCorrection.swift
// Tono keyboard extension — build 86 on-device spelling policy.

import Foundation
import UIKit

// `SpellingChecking`, `SpellingLookup` and `SystemSpellingChecker` live in
// LocalIntelligence.swift so the host app runs the REAL shipping checker in its
// self-test rather than a second copy of it.

enum SpellingFieldKind: Hashable {
    case ordinary
    case email
    case url
    case numeric
    case secureLike
}

struct SpellingHostPolicy: Equatable {
    let language: String?
    let fieldKind: SpellingFieldKind
    let allowsAutocorrection: Bool
    let allowsSpellChecking: Bool
    /// Dictionaries iOS actually has installed. Injected (rather than read
    /// statically) so the resolution is testable and so a test can prove the
    /// English-only Build-105 behaviour is gone.
    let availableLanguages: [String]

    init(
        language: String?,
        fieldKind: SpellingFieldKind,
        allowsAutocorrection: Bool,
        allowsSpellChecking: Bool,
        availableLanguages: [String] = UITextChecker.availableLanguages
    ) {
        self.language = language
        self.fieldKind = fieldKind
        self.allowsAutocorrection = allowsAutocorrection
        self.allowsSpellChecking = allowsSpellChecking
        self.availableLanguages = availableLanguages
    }

    /// Build 106: resolved against the installed dictionaries instead of the
    /// Build-105 `prefix == "en"` gate, which disabled the entire local lane
    /// for every non-English keyboard even when the dictionary was present.
    var supportedLanguage: String? {
        SpellingLanguageResolver.resolve(requested: language, available: availableLanguages)
    }

    var allowsSuggestions: Bool {
        supportedLanguage != nil
            && fieldKind == .ordinary
            && allowsAutocorrection
            && allowsSpellChecking
    }
}

struct SpellingToken: Equatable {
    static let maximumLength = 48

    let text: String
    let caretOffset: Int
    let hasSensitivePrefix: Bool
    let followsSentenceBoundary: Bool
    /// The host/editing session this token was observed in. Included in
    /// equality so a debounced suggestion authorized in one host cannot apply
    /// after a same-content switch to another (`SpellingMutationPlan` gates on
    /// `liveToken == expected`).
    let host: HostSessionIdentity

    static func current(in context: String, host: HostSessionIdentity = .unbound) -> SpellingToken? {
        current(before: context, after: "", host: host)
    }

    static func current(
        before: String,
        after: String,
        host: HostSessionIdentity = .unbound
    ) -> SpellingToken? {
        var left: [Character] = []
        left.reserveCapacity(16)
        for character in before.reversed() {
            guard isTokenCharacter(character) else { break }
            guard left.count < maximumLength else { return nil }
            left.append(character)
        }
        var right: [Character] = []
        right.reserveCapacity(16)
        for character in after {
            guard isTokenCharacter(character) else { break }
            guard left.count + right.count < maximumLength else { return nil }
            right.append(character)
        }
        guard !left.isEmpty || !right.isEmpty else { return nil }
        let leftText = String(left.reversed())
        let text = leftText + String(right)
        let prefix = String(before.dropLast(leftText.count).suffix(32)).lowercased()
        let sensitive = prefix.contains("@")
            || prefix.hasSuffix("http://")
            || prefix.hasSuffix("https://")
            || prefix.hasSuffix("www.")
            || prefix.hasSuffix("/")
            || prefix.last?.isNumber == true
            || prefix.last == "_"
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceBoundary = trimmed.isEmpty || ".!?\n".contains(trimmed.last ?? " ")
        return SpellingToken(
            text: text,
            caretOffset: leftText.count,
            hasSensitivePrefix: sensitive,
            followsSentenceBoundary: sentenceBoundary,
            host: host
        )
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.letters.contains($0) || $0 == "'" || $0 == "’"
        }
    }
}

struct SpellingRequest: Equatable {
    let token: SpellingToken
    let host: SpellingHostPolicy
    /// Text immediately before the token, used only for the local bigram
    /// prior. Bounded to 64 characters by `LocalCandidateRanker`, never stored,
    /// never transmitted.
    let contextBefore: String

    init(token: SpellingToken, host: SpellingHostPolicy, contextBefore: String = "") {
        self.token = token
        self.host = host
        self.contextBefore = contextBefore
    }
}

struct SpellingDecision: Equatable {
    let original: String
    let candidates: [String]
    let automaticReplacement: String?
}

enum SpellingPolicy {
    static func evaluate(
        request: SpellingRequest,
        checker: SpellingChecking,
        lexicon: LocalLexicon = .empty
    ) -> SpellingDecision? {
        let token = request.token
        let word = token.text
        let folded = word.lowercased()
        guard request.host.allowsSuggestions,
              let language = request.host.supportedLanguage,
              word.count >= 2,
              !token.hasSensitivePrefix,
              word.rangeOfCharacter(from: .decimalDigits) == nil,
              word.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) || $0 == "'" || $0 == "’" }),
              !isMixedCase(word),
              !isAllCapsAcronym(word)
        else { return nil }

        // Build 106: a word in the user's own keyboard vocabulary is spelled
        // correctly BUT may still be a configured shortcut. Build 105 bailed
        // out entirely here, so "omw" offered nothing.
        let personalExpansion = lexicon.expansion(for: folded)
        if lexicon.contains(folded), personalExpansion == nil {
            return nil
        }

        let lookup = checker.lookup(word: folded, language: language)

        // Rank the checker's raw output before truncating it — Build 105 took
        // the first two in the checker's own order, so a better candidate
        // further down the list was simply discarded.
        var pool: [String] = []
        var poolSeen = Set<String>()
        for raw in lookup.corrections + lookup.completions {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != folded else { continue }
            guard poolSeen.insert(trimmed.lowercased()).inserted else { continue }
            pool.append(trimmed)
            if pool.count == 16 { break }
        }
        let precedingWord = LocalCandidateRanker.precedingWord(
            inContextBefore: request.contextBefore,
            skipping: word
        )
        let ranked = LocalCandidateRanker.rank(
            typed: folded,
            candidates: pool,
            precedingWord: precedingWord,
            lexicon: lexicon
        )

        var seen = Set<String>()
        var replacements: [String] = []
        // A configured shortcut expansion is the user's own explicit intent and
        // outranks anything the dictionary proposes.
        if let personalExpansion {
            replacements.append(personalExpansion)
            seen.insert(personalExpansion.lowercased())
        }
        for scored in ranked {
            let replacement = preserveCase(of: word, in: scored.value)
            let key = replacement.lowercased()
            guard key != folded, seen.insert(key).inserted else { continue }
            replacements.append(replacement)
            if replacements.count == 2 { break }
        }

        guard lookup.isMisspelled || !replacements.isEmpty else {
            return SpellingDecision(original: word, candidates: [word], automaticReplacement: nil)
        }
        let candidates = [word] + replacements
        let top = replacements.first
        let looksLikeProperNoun = word.first?.isUppercase == true && !token.followsSentenceBoundary
        let correctionDistances = ranked.map { damerauLevenshtein(folded, $0.value.lowercased()) }
        let uniqueBestCorrection = correctionDistances.first.map { first in
            first <= 1 && correctionDistances.dropFirst().allSatisfy { $0 > first }
        } == true
        // An explicit user shortcut is high-confidence by definition; otherwise
        // the Build-105 conservative rule is unchanged.
        let strong = personalExpansion != nil
            || (lookup.isMisspelled && !looksLikeProperNoun && uniqueBestCorrection)
        return SpellingDecision(
            original: word,
            candidates: Array(candidates.prefix(3)),
            automaticReplacement: strong ? top : nil
        )
    }

    static func preserveCase(of original: String, in replacement: String) -> String {
        if original == original.uppercased(), original != original.lowercased() {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true,
           String(original.dropFirst()) == String(original.dropFirst()).lowercased() {
            guard let first = replacement.first else { return replacement }
            return String(first).uppercased() + replacement.dropFirst().lowercased()
        }
        return replacement.lowercased()
    }

    private static func isAllCapsAcronym(_ word: String) -> Bool {
        word.count >= 2 && word == word.uppercased() && word != word.lowercased()
    }

    private static func isMixedCase(_ word: String) -> Bool {
        let tail = String(word.dropFirst())
        return tail != tail.lowercased() && word != word.uppercased()
    }

    /// Adjacent transposition counts as one edit, covering conservative
    /// high-confidence typos such as "teh" and "recieve". Forwards to
    /// `LocalEditDistance`, which the host-app self-test also uses.
    static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
        LocalEditDistance.damerauLevenshtein(lhs, rhs)
    }
}

final class SpellingCorrectionService {
    typealias Completion = (Int, SpellingDecision?) -> Void

    private struct CacheKey: Hashable {
        let word: String
        let language: String
        let fieldKind: SpellingFieldKind
        /// Ranking is context-sensitive from Build 106, so the preceding word
        /// is part of the identity of a decision. Only the single preceding
        /// word is kept, in memory, bounded by the LRU below.
        let precedingWord: String
    }

    private let checker: SpellingChecking
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let debounce: TimeInterval
    private let cacheLimit: Int
    private let lock = NSLock()
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var cache: [CacheKey: SpellingDecision?] = [:]
    private var cacheOrder: [CacheKey] = []
    private var lexicon = LocalLexicon.empty

    init(
        checker: SpellingChecking = SystemSpellingChecker(),
        queue: DispatchQueue = DispatchQueue(label: "com.tonoit.keyboard.spelling", qos: .utility),
        callbackQueue: DispatchQueue = .main,
        debounce: TimeInterval = 0.12,
        cacheLimit: Int = 64
    ) {
        self.checker = checker
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.debounce = debounce
        self.cacheLimit = max(1, cacheLimit)
    }

    @discardableResult
    func schedule(_ request: SpellingRequest, completion: @escaping Completion) -> Int {
        let next = beginGeneration()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.accepts(generation: next) else { return }
            let result = self.cachedDecision(for: request)
            guard self.accepts(generation: next) else { return }
            self.callbackQueue.async { [weak self] in
                guard let self = self, self.accepts(generation: next) else { return }
                completion(next, result)
            }
        }
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
        return next
    }

    func cancel() {
        _ = beginGeneration()
    }

    /// Adopt the user's `UILexicon`-derived vocabulary. Invalidates the cache,
    /// since every cached decision was ranked without it.
    func updateLexicon(_ next: LocalLexicon) {
        lock.lock()
        lexicon = next
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// The vocabulary currently in force, for the in-keyboard self-test.
    var currentLexicon: LocalLexicon {
        lock.lock()
        defer { lock.unlock() }
        return lexicon
    }

    @discardableResult
    func beginGeneration() -> Int {
        lock.lock()
        generation &+= 1
        pending?.cancel()
        pending = nil
        let value = generation
        lock.unlock()
        return value
    }

    func accepts(generation candidate: Int) -> Bool {
        lock.lock()
        let accepted = candidate == generation
        lock.unlock()
        return accepted
    }

    private func cachedDecision(for request: SpellingRequest) -> SpellingDecision? {
        guard let language = request.host.supportedLanguage else { return nil }
        let key = CacheKey(
            word: request.token.text.lowercased(),
            language: language,
            fieldKind: request.host.fieldKind,
            precedingWord: LocalCandidateRanker.precedingWord(
                inContextBefore: request.contextBefore,
                skipping: request.token.text
            ) ?? ""
        )
        lock.lock()
        if let boxed = cache[key] {
            touch(key)
            lock.unlock()
            return boxed
        }
        let vocabulary = lexicon
        lock.unlock()

        let decision = SpellingPolicy.evaluate(
            request: request,
            checker: checker,
            lexicon: vocabulary
        )
        lock.lock()
        cache[key] = decision
        touch(key)
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        lock.unlock()
        return decision
    }

    private func touch(_ key: CacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }
}

struct AutoCorrectionRecord: Equatable {
    let original: String
    let replacement: String
    let boundary: String

    var correctedSuffix: String { replacement + boundary }
    var restoredText: String { original + boundary }
}

enum DoubleSpacePolicy {
    static func shouldTransform(
        contextSuffix: String,
        host: SpellingHostPolicy,
        hasPendingAutocorrectionUndo: Bool
    ) -> Bool {
        guard host.fieldKind == .ordinary,
              host.allowsAutocorrection,
              !hasPendingAutocorrectionUndo,
              contextSuffix.hasSuffix(" ")
        else { return false }
        let beforeSpace = contextSuffix.dropLast()
        guard let previous = beforeSpace.last,
              !previous.isWhitespace,
              !".!?\n".contains(previous)
        else { return false }
        return previous.isLetter || previous.isNumber || "'’\"”)]}".contains(previous)
    }
}

struct SpellingMutationPlan: Equatable {
    let deleteCount: Int
    let insertion: String
    let cursorAdvance: Int

    init(deleteCount: Int, insertion: String, cursorAdvance: Int = 0) {
        self.deleteCount = deleteCount
        self.insertion = insertion
        self.cursorAdvance = cursorAdvance
    }

    static func candidate(
        liveToken: SpellingToken?,
        expected: SpellingToken,
        replacement: String
    ) -> SpellingMutationPlan? {
        guard liveToken == expected, replacement != expected.text else { return nil }
        return SpellingMutationPlan(
            deleteCount: expected.text.count,
            insertion: replacement,
            cursorAdvance: expected.text.count - expected.caretOffset
        )
    }

    static func boundary(
        liveToken: SpellingToken?,
        expected: SpellingToken?,
        decision: SpellingDecision?,
        boundary: String
    ) -> SpellingMutationPlan {
        guard let liveToken = liveToken,
              liveToken == expected,
              liveToken.caretOffset == liveToken.text.count,
              decision?.original == liveToken.text,
              let replacement = decision?.automaticReplacement
        else { return SpellingMutationPlan(deleteCount: 0, insertion: boundary) }
        return SpellingMutationPlan(
            deleteCount: liveToken.text.count,
            insertion: replacement + boundary
        )
    }
}
