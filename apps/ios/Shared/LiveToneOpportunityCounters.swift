// LiveToneOpportunityCounters.swift
// Tono Live Tone — positive-opportunity local counters + coordinator.
//
// The contract binds the opportunity lane to privacy-safe, CONTENT-FREE
// counters: "Counters contain no message content." This file persists
// per-family `shown` / `dismissed` integer counts to App Group
// `UserDefaults` under a dedicated key, separate from the red-lane
// `LiveToneLocalCounters`. Nothing but integers is stored; no triggering
// text, no per-recipient data, and no network call.
//
// It also provides `LiveToneOpportunityCoordinator`, a pure composition of
// the classifier, the session state machine, and the counter store, so the
// integration lane can drive the whole opportunity lane through one seam
// while the shipping red/crisis engine stays untouched.
//
// Pure Foundation + App Group `UserDefaults`. No UIKit, no timers, no
// networking.

import Foundation

// MARK: - Bucket

public struct LiveToneOpportunityBucket: Equatable, Codable {
    public var shown: Int
    public var dismissed: Int
    public init(shown: Int = 0, dismissed: Int = 0) {
        self.shown = shown
        self.dismissed = dismissed
    }
}

// MARK: - Counters

public struct LiveToneOpportunityCounters: Equatable, Codable {

    /// Per-family counts, keyed by `LiveToneOpportunityFamily.rawValue`.
    /// Missing families default to zero on read. Integers only — the store
    /// never holds message content.
    public private(set) var buckets: [String: LiveToneOpportunityBucket]

    public init(buckets: [String: LiveToneOpportunityBucket] = [:]) {
        self.buckets = buckets
    }

    public func bucket(for family: LiveToneOpportunityFamily) -> LiveToneOpportunityBucket {
        buckets[family.rawValue] ?? LiveToneOpportunityBucket()
    }

    public func incrementShown(family: LiveToneOpportunityFamily) -> LiveToneOpportunityCounters {
        var copy = self
        let current = copy.buckets[family.rawValue] ?? LiveToneOpportunityBucket()
        copy.buckets[family.rawValue] = LiveToneOpportunityBucket(
            shown: current.shown + 1,
            dismissed: current.dismissed
        )
        return copy
    }

    public func incrementDismissed(family: LiveToneOpportunityFamily) -> LiveToneOpportunityCounters {
        var copy = self
        let current = copy.buckets[family.rawValue] ?? LiveToneOpportunityBucket()
        copy.buckets[family.rawValue] = LiveToneOpportunityBucket(
            shown: current.shown,
            dismissed: current.dismissed + 1
        )
        return copy
    }
}

// MARK: - Store

public final class LiveToneOpportunityCounterStore {

    /// Dedicated App Group key, namespaced away from the red-lane
    /// `LiveToneKeys.localCounters` so the two lanes never collide.
    public static let storageKey = "tc.liveTone.opportunityCounters"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func load() -> LiveToneOpportunityCounters {
        guard let stored = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(LiveToneOpportunityCounters.self, from: stored)
        else {
            return LiveToneOpportunityCounters()
        }
        return decoded
    }

    public func save(_ counters: LiveToneOpportunityCounters) {
        guard let encoded = try? JSONEncoder().encode(counters) else { return }
        defaults.set(encoded, forKey: Self.storageKey)
    }
}

// MARK: - Coordinator

/// Pure composition of the opportunity classifier, the session discipline,
/// and the content-free counters. The integration lane drives this with the
/// current draft; the red/crisis engine is entirely separate and always
/// wins (this coordinator is consulted only when the red verdict is fully
/// silent — crisis silence stays total silence).
public final class LiveToneOpportunityCoordinator {

    private let classifier: LiveToneOpportunityClassifier
    private var session: LiveToneOpportunitySession
    private let store: LiveToneOpportunityCounterStore?

    /// The family currently surfaced, if any. Dismissal targets this.
    public private(set) var current: LiveToneOpportunityFamily?

    public init(
        classifier: LiveToneOpportunityClassifier = LiveToneOpportunityClassifier(),
        store: LiveToneOpportunityCounterStore? = nil
    ) {
        self.classifier = classifier
        self.session = LiveToneOpportunitySession()
        self.store = store
    }

    /// Snapshot of the session for tests / debug surfaces.
    public var debugSession: LiveToneOpportunitySession { session }

    /// Evaluate an isolated draft. Returns the family to surface now, or
    /// `nil` to stay silent. A fresh surface bumps the per-family `shown`
    /// counter exactly once.
    @discardableResult
    public func observe(draft: String) -> LiveToneOpportunityFamily? {
        let verdict = classifier.classify(draft)
        guard let family = session.consider(verdict) else { return nil }
        current = family
        if let store {
            store.save(store.load().incrementShown(family: family))
        }
        return family
    }

    /// Dismiss the currently surfaced nudge: suppresses its family for the
    /// rest of the session and bumps the per-family `dismissed` counter.
    public func dismissCurrent() {
        guard let family = current else { return }
        session.dismiss(family)
        if let store {
            store.save(store.load().incrementDismissed(family: family))
        }
        current = nil
    }

    /// A new host-app session began. Clears one-fire marks and dismissals.
    public func hostSessionReset() {
        session.hostSessionReset()
        current = nil
    }
}
