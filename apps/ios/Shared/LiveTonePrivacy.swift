// LiveTonePrivacy.swift
// Local, deterministic control surface for Tono "Live Tone" (build-90
// experiment). Holds the explicit opt-in, the user kill switch, the
// user-declared host allowlist, and the local-only remote-disable directive.
//
// Everything here is App Group `UserDefaults` I/O plus `Codable`. There is no
// networking, no timer, and no background work in this file — the keyboard
// process observes state by reading fresh from the shared store, so a user
// kill or an applied remote directive takes effect on the very next read.
//
// The remote-disable *refresh* is intentionally NOT performed here: per the
// contract it may only ride an existing, deliberate Coach round-trip. This
// file defines the typed directive, the pure flag→directive parser, and the
// local persistence; the integration lane calls `refreshRemoteDirective`
// from the Coach completion handler it already owns. No new network client,
// polling loop, or timer is introduced.
//
// Preference keys live here (not in SharedKeys) so this control surface and
// its verifier stay self-contained; SharedUserDefaults.swift carries a
// pointer comment. All keys share the existing `tc.` namespace and the
// existing App Group suite.

import Foundation

// MARK: - Keys

public enum LiveTonePrivacyKeys {
    /// Existing shared App Group suite (matches SharedStore.suiteName).
    public static let appGroupSuite = "group.com.tonoit.shared"

    /// Bool. Explicit, deliberate opt-in. Absent ⇒ false ⇒ Live Tone OFF.
    public static let optIn = "tc.liveTone.optIn"
    /// Bool. User kill switch. Absent ⇒ false ⇒ not paused. Setting true
    /// disables Live Tone immediately without discarding the opt-in/allowlist.
    public static let userPaused = "tc.liveTone.userPaused"
    /// Data (JSON `LiveToneRemoteDirective`). Absent ⇒ allowed.
    public static let remoteDirective = "tc.liveTone.remoteDirective"
    /// [String] of `LiveToneHostCategory` raw values the user has allowed.
    public static let allowedHostCategories = "tc.liveTone.allowedHostCategories"
}

// MARK: - Remote-disable directive

/// Typed, versioned remote-disable contract. It is refreshed only during an
/// existing Coach round-trip and stored locally; it is never fetched on a
/// timer or background schedule.
public struct LiveToneRemoteDirective: Equatable, Codable {
    public static let currentSchema = 1

    public let schema: Int
    public let disabled: Bool
    /// Optional coarse, non-PII reason code for diagnostics (e.g. "rollback").
    public let reasonCode: String?

    public init(disabled: Bool, reasonCode: String? = nil, schema: Int = LiveToneRemoteDirective.currentSchema) {
        self.schema = schema
        self.disabled = disabled
        self.reasonCode = reasonCode
    }

    /// The default, permissive directive used before any Coach round-trip.
    public static let allowed = LiveToneRemoteDirective(disabled: false)

    public var isDisabled: Bool { disabled }
}

// MARK: - Preference facade

/// Reads/writes the Live Tone control state in App Group `UserDefaults`.
/// A value type over an injected store so the keyboard, the host app, and
/// tests can each point at the right defaults; it caches nothing.
public struct LiveTonePreference {

    /// Sentinel `flags` value the backend can include in an ordinary Coach
    /// response (`CoachResponse.flags`) to disable Live Tone client-side. No
    /// new endpoint or payload field is required.
    public static let disableFlag = "live_tone_disabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Points at the shared App Group store used by the app and extensions.
    /// Falls back to `.standard` only if the suite is somehow unavailable.
    public init() {
        self.defaults = UserDefaults(suiteName: LiveTonePrivacyKeys.appGroupSuite) ?? .standard
    }

    // MARK: Opt-in (default false)

    public var isOptedIn: Bool {
        get { defaults.bool(forKey: LiveTonePrivacyKeys.optIn) }
        nonmutating set { defaults.set(newValue, forKey: LiveTonePrivacyKeys.optIn) }
    }

    // MARK: User kill switch

    public var isUserPaused: Bool {
        get { defaults.bool(forKey: LiveTonePrivacyKeys.userPaused) }
        nonmutating set { defaults.set(newValue, forKey: LiveTonePrivacyKeys.userPaused) }
    }

    /// Immediate user kill: the next fresh read in the keyboard sees it.
    public func kill() { isUserPaused = true }

    /// Undo a kill without touching the opt-in or allowlist.
    public func resume() { isUserPaused = false }

    // MARK: Host allowlist

    public var allowedHostCategories: Set<LiveToneHostCategory> {
        get {
            let raw = defaults.array(forKey: LiveTonePrivacyKeys.allowedHostCategories) as? [String] ?? []
            return Set(raw.compactMap(LiveToneHostCategory.init(rawValue:)))
        }
        nonmutating set {
            // Stored sorted for a deterministic on-disk representation.
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: LiveTonePrivacyKeys.allowedHostCategories)
        }
    }

    // MARK: Remote directive

    public var remoteDirective: LiveToneRemoteDirective {
        guard let data = defaults.data(forKey: LiveTonePrivacyKeys.remoteDirective),
              let decoded = try? JSONDecoder().decode(LiveToneRemoteDirective.self, from: data) else {
            return .allowed
        }
        return decoded
    }

    public var isRemoteDisabled: Bool { remoteDirective.isDisabled }

    /// Persist a directive locally. Called only from the Coach completion
    /// handler (integration) — never on a timer or background task.
    public func applyRemoteDirective(_ directive: LiveToneRemoteDirective) {
        guard let data = try? JSONEncoder().encode(directive) else { return }
        defaults.set(data, forKey: LiveTonePrivacyKeys.remoteDirective)
    }

    /// Pure map from an existing Coach response's `flags` array to a directive.
    /// Kept static + pure so it can be unit-tested without any store.
    public static func directive(fromCoachFlags flags: [String]) -> LiveToneRemoteDirective {
        LiveToneRemoteDirective(disabled: flags.contains(disableFlag))
    }

    /// Convenience the integration calls from the Coach completion handler:
    /// derive the directive from the flags it already received and persist it.
    /// This is the ONLY sanctioned refresh path — it piggybacks the deliberate
    /// round-trip the user initiated and adds no new network activity.
    @discardableResult
    public func refreshRemoteDirective(fromCoachFlags flags: [String]) -> LiveToneRemoteDirective {
        let directive = LiveTonePreference.directive(fromCoachFlags: flags)
        applyRemoteDirective(directive)
        return directive
    }

    // MARK: Resolved master gate

    /// The single gate eligibility consults: the user opted in, has not killed
    /// it, and no remote directive has disabled it. Any of the three flipping
    /// off disables Live Tone on the next read.
    public var masterEnabled: Bool {
        isOptedIn && !isUserPaused && !isRemoteDisabled
    }
}
