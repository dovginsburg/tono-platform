// LiveToneKeys.swift
// Tono Live Tone v1 — App Group keys and App Group suite.
//
// All Live Tone control state lives in the App Group `UserDefaults` suite
// shared by the host app, the keyboard extension, and the tests. Keys are
// namespaced under `tc.liveTone.*` to avoid collision with other Tono
// features. Reads and writes are local-only — no key crosses the device
// boundary for Live Tone purposes.

import Foundation

public enum LiveToneKeys {

    /// App Group suite used by all Tono extensions. Matches
    /// `SharedStore.suiteName` so the host app and keyboard extension
    /// read the same store.
    public static let appGroupSuite = "group.com.tonoit.shared"

    /// Bool. Master toggle. Absent ⇒ default ON per the binding
    /// `Live Tone v1 Acceptance Contract`.
    public static let masterEnabled = "tc.liveTone.masterEnabled"

    /// JSON `LiveToneLocalCounters`. Absent ⇒ empty.
    public static let localCounters = "tc.liveTone.localCounters"
}