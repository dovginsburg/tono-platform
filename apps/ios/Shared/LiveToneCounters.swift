// LiveToneCounters.swift
// Tono Live Tone v1 — local-only counter store.
//
// The contract says "Analytics are local counters only: warning
// shown/dismissed, by category. Never retain triggering text. Never
// record per-recipient data." This file persists per-category
// `shown` / `dismissed` counts to App Group `UserDefaults`. Nothing
// leaves the device — the store is read by the host app's debug
// surfaces only and never transmitted.

import Foundation

// MARK: - Bucket

public struct LiveToneBucket: Equatable, Codable {
    public var shown: Int
    public var dismissed: Int
    public init(shown: Int = 0, dismissed: Int = 0) {
        self.shown = shown
        self.dismissed = dismissed
    }
}

// MARK: - Counters

public struct LiveToneLocalCounters: Equatable, Codable {

    /// Per-category counts. Missing categories default to zero on read.
    public private(set) var buckets: [String: LiveToneBucket]

    public init(buckets: [String: LiveToneBucket] = [:]) {
        self.buckets = buckets
    }

    public func bucket(for category: LiveToneCategory) -> LiveToneBucket {
        buckets[category.rawValue] ?? LiveToneBucket()
    }

    public func incrementShown(_ category: LiveToneCategory) -> LiveToneLocalCounters {
        var copy = self
        let current = copy.buckets[category.rawValue] ?? LiveToneBucket()
        copy.buckets[category.rawValue] = LiveToneBucket(
            shown: current.shown + 1,
            dismissed: current.dismissed
        )
        return copy
    }

    public func incrementDismissed(_ category: LiveToneCategory) -> LiveToneLocalCounters {
        var copy = self
        let current = copy.buckets[category.rawValue] ?? LiveToneBucket()
        copy.buckets[category.rawValue] = LiveToneBucket(
            shown: current.shown,
            dismissed: current.dismissed + 1
        )
        return copy
    }
}

// MARK: - Store

public final class LiveToneCounterStore {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> LiveToneLocalCounters {
        guard let data = defaults.data(forKey: LiveToneKeys.localCounters),
              let decoded = try? JSONDecoder().decode(LiveToneLocalCounters.self, from: data)
        else {
            return LiveToneLocalCounters()
        }
        return decoded
    }

    public func save(_ counters: LiveToneLocalCounters) {
        guard let data = try? JSONEncoder().encode(counters) else { return }
        defaults.set(data, forKey: LiveToneKeys.localCounters)
    }
}