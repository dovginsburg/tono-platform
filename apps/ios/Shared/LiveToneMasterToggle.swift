// LiveToneMasterToggle.swift
// Tono Live Tone v1 — master toggle (default ON).
//
// The master toggle gates the entire on-device Live Tone heuristic.
// Per the binding contract the absent state is ON — the keyboard process
// runs evaluation by default and the user must explicitly opt out.
// Reading the value uses the contract's exact default semantics; writing
// it persists the explicit user choice to the App Group.
//
// `evaluateNow()` returns the toggle's current effective state with no
// caching — the engine consults it before every classification
// invocation so a flip is observed on the very next keystroke. When OFF,
// the classifier is never invoked (zero evaluation runs).

import Foundation

public final class LiveToneMasterToggle {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The default-ON semantics. `UserDefaults.bool(forKey:)` returns
    /// `false` when the key is absent — the contract says absent ⇒ ON,
    /// so we have to inspect the underlying representation to
    /// distinguish "user set OFF" from "never set".
    public var isEnabled: Bool {
        if defaults.object(forKey: LiveToneKeys.masterEnabled) == nil {
            return true
        }
        return defaults.bool(forKey: LiveToneKeys.masterEnabled)
    }

    public func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: LiveToneKeys.masterEnabled)
    }

    /// Synchronous read used by the engine on every classification pass.
    public func evaluateNow() -> Bool { isEnabled }
}