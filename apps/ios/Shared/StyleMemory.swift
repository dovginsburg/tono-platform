// StyleMemory.swift
// Per-axis tap-weight store. When the user taps a rewrite chip the keyboard
// calls StyleMemory.recordTap() so the next session surfaces their favourite
// axes first. Weights are keyed per-recipient so "Boss" gets different
// ordering from "Mom". All data lives in App Group UserDefaults so both the
// host app and the keyboard extension share the same weights.

import Foundation

public enum StyleMemory {
    /// Record that the user chose a rewrite on this axis.
    /// Against-the-grain weighting: picking the non-top axis adds +2 so the
    /// model can detect genuine preference shifts, not just noise.
    public static func recordTap(axis: RewriteAxis, recipientId: UUID? = nil) {
        let key = defaultsKey(recipientId: recipientId)
        var w = rawWeights(key: key)
        let currentTop = w.max(by: { $0.value < $1.value })?.key
        let delta = (currentTop != nil && currentTop != axis.rawValue) ? 2 : 1
        w[axis.rawValue, default: 0] += delta
        SharedStore.defaults.set(w, forKey: key)
    }

    /// Return `axes` sorted by descending tap count for the given recipient.
    /// Falls back to global weights when per-recipient data is below threshold
    /// (< 3 interactions OR top axis < 50% share).
    public static func sorted(_ axes: [RewriteAxis], recipientId: UUID? = nil) -> [RewriteAxis] {
        let key: String
        if let rid = recipientId, meetsThreshold(recipientId: rid) {
            key = defaultsKey(recipientId: rid)
        } else {
            key = SharedKeys.axisWeights
        }
        let w = rawWeights(key: key)
        return axes.enumerated()
            .sorted { a, b in
                let wa = w[a.element.rawValue] ?? 0
                let wb = w[b.element.rawValue] ?? 0
                return wa != wb ? wa > wb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// True when per-recipient history meets the confidence threshold:
    /// ≥3 total interactions AND top axis holds ≥50% share.
    public static func meetsThreshold(recipientId: UUID) -> Bool {
        let w = rawWeights(key: defaultsKey(recipientId: recipientId))
        let total = w.values.reduce(0, +)
        guard total >= 3 else { return false }
        let topCount = w.values.max() ?? 0
        return Double(topCount) / Double(total) >= 0.5
    }

    /// Per-axis recent rewrite vocabulary used by SuggestionEngine to bias
    /// the inline suggestion strip toward the user's preferred voice. Returns
    /// rewrite texts that start with the given (lowercased) prefix, in most-
    /// recently-used order. Bounded to `limit` items.
    ///
    /// We do NOT persist rewrite text indefinitely — only what fits in the
    /// shared RewriteAxisWeights dict's value as a small ring of recents.
    /// When nothing is stored yet (fresh install), returns an empty array and
    /// the SuggestionEngine falls back to DraftHistory / baked-in bigrams.
    public static func recentRewrites(matching prefix: String, limit: Int = 8) -> [String] {
        let lc = prefix.lowercased()
        guard !lc.isEmpty else { return [] }
        let key = SharedKeys.recentRewrites
        let stored = (SharedStore.defaults.array(forKey: key) as? [String]) ?? []
        // Newest first; prefix-filtered; deduped.
        var seen = Set<String>()
        var out: [String] = []
        for raw in stored {
            let lower = raw.lowercased()
            if seen.contains(lower) { continue }
            if !lower.hasPrefix(lc) { continue }
            seen.insert(lower)
            out.append(lower)
            if out.count >= limit { return out }
        }
        return out
    }

    /// Record a rewrite text into the recent-rewrites ring (max 12 entries).
    /// Newest-first, deduped. Called from `insertRewrite` whenever the user
    /// taps a chip. Storage is small enough to keep inline; eviction is
    /// simple truncation.
    public static func rememberRewrite(text: String) {
        guard !text.isEmpty else { return }
        let key = SharedKeys.recentRewrites
        var existing = (SharedStore.defaults.array(forKey: key) as? [String]) ?? []
        existing.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
        existing.insert(text, at: 0)
        if existing.count > 12 { existing = Array(existing.prefix(12)) }
        SharedStore.defaults.set(existing, forKey: key)
    }

    // MARK: - Private

    private static func defaultsKey(recipientId: UUID?) -> String {
        guard let id = recipientId else { return SharedKeys.axisWeights }
        return "\(SharedKeys.axisWeights).\(id.uuidString)"
    }

    private static func rawWeights(key: String) -> [String: Int] {
        (SharedStore.defaults.dictionary(forKey: key) as? [String: Int]) ?? [:]
    }
}
