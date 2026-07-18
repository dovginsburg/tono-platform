// SpellingCorrection.swift
// Tono keyboard extension — build 86 on-device spelling policy.

import Foundation
import UIKit

protocol SpellingChecking: AnyObject {
    func lookup(word: String, language: String) -> SpellingLookup
}

struct SpellingLookup: Equatable {
    let isMisspelled: Bool
    let corrections: [String]
    let completions: [String]
}

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

    var supportedLanguage: String? {
        guard let language = language?.replacingOccurrences(of: "_", with: "-") else {
            return nil
        }
        let prefix = language.split(separator: "-").first?.lowercased()
        return prefix == "en" ? language : nil
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
        supplementaryWords: Set<String> = []
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
              !isAllCapsAcronym(word),
              !supplementaryWords.contains(folded)
        else { return nil }

        let lookup = checker.lookup(word: folded, language: language)
        var seen = Set<String>()
        var replacements: [String] = []
        for raw in lookup.corrections + lookup.completions {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let replacement = preserveCase(of: word, in: trimmed)
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
        let correctionDistances = lookup.corrections
            .map { damerauLevenshtein(folded, $0.lowercased()) }
        let uniqueBestCorrection = correctionDistances.first.map { first in
            first <= 1 && correctionDistances.dropFirst().allSatisfy { $0 > first }
        } == true
        let strong = lookup.isMisspelled
            && !looksLikeProperNoun
            && uniqueBestCorrection
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
    /// high-confidence typos such as "teh" and "recieve".
    static func damerauLevenshtein(_ lhs: String, _ rhs: String) -> Int {
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

final class SpellingCorrectionService {
    typealias Completion = (Int, SpellingDecision?) -> Void

    private struct CacheKey: Hashable {
        let word: String
        let language: String
        let fieldKind: SpellingFieldKind
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
    private var supplementaryWords = Set<String>()

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

    func updateSupplementaryWords(_ words: Set<String>) {
        lock.lock()
        supplementaryWords = Set(words.lazy.map { $0.lowercased() }.prefix(256))
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        lock.unlock()
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
            fieldKind: request.host.fieldKind
        )
        lock.lock()
        if let boxed = cache[key] {
            touch(key)
            lock.unlock()
            return boxed
        }
        let lexicon = supplementaryWords
        lock.unlock()

        let decision = SpellingPolicy.evaluate(
            request: request,
            checker: checker,
            supplementaryWords: lexicon
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
