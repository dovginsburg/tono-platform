// LiveTonePrivacy.swift
// Tono Live Tone v1 — shipping release control surface.
//
// The v1 contract collapses the build-90 experiment's three-axis gate
// (opt-in + user-paused + remote-disable + host-category allowlist) into
// a single default-ON master toggle persisted in App Group
// `UserDefaults`. The keyboard and host app share the same store via
// `LiveToneKeys.appGroupSuite`.
//
// Pure `Foundation` + App Group `UserDefaults`. No networking, no timer,
// no background work, no analytics. Every read returns the freshest
// value the host wrote — the engine consults the toggle before every
// classification invocation so a flip is observed on the very next
// keystroke.

import Foundation

// MARK: - Keys (kept here for backward-compatible reference).

public enum LiveTonePrivacyKeys {
    /// App Group suite used by all Tono extensions. Mirrors
    /// `SharedStore.suiteName`.
    public static let appGroupSuite = "group.com.tonoit.shared"

    /// Master toggle key. Absent ⇒ default ON.
    public static let masterEnabled = "tc.liveTone.masterEnabled"

    /// JSON-encoded `LiveToneLocalCounters`.
    public static let localCounters = "tc.liveTone.localCounters"
}

// MARK: - Preference facade

/// A value type over an injected `UserDefaults` instance so the host
/// app, the keyboard extension, and the tests can each point at the
/// right defaults. Caches nothing — every read is fresh.
public struct LiveTonePreference {

    /// Exact wording for the Settings disclosure row. Must match
    /// `LiveToneCopy.settingsDisclosure` byte-for-byte.
    public static let settingsCopy = LiveToneCopy.settingsDisclosure

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Convenience initializer pointing at the shared App Group store.
    /// Falls back to `.standard` only when the suite is unavailable.
    public init() {
        self.defaults = UserDefaults(suiteName: LiveTonePrivacyKeys.appGroupSuite) ?? .standard
    }

    /// The contract-binding default-ON master toggle. `true` means the
    /// heuristic runs (subject to per-field eligibility); `false` means
    /// zero evaluation runs.
    public var masterEnabled: Bool {
        if defaults.object(forKey: LiveTonePrivacyKeys.masterEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: LiveTonePrivacyKeys.masterEnabled)
    }

    public func setMasterEnabled(_ on: Bool) {
        defaults.set(on, forKey: LiveTonePrivacyKeys.masterEnabled)
    }

    /// Synchronous read used by the engine on every classification pass.
    public func evaluateNow() -> Bool { masterEnabled }
}