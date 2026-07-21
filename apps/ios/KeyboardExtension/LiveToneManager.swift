// LiveToneManager.swift
// Tono Live Tone v1 — shipping release integration glue.
//
// Owns the engine + indicator + App Group reads and wires them to the
// keyboard view controller. The manager is a pure observer — it never
// modifies the keystroke path, never opens a rewrite flow uninvited,
// and never blocks send.
//
// Master toggle (default ON per the contract) is sourced from App
// Group `UserDefaults` so the host app's Settings view and the keyboard
// extension observe each other's writes without networking.

import UIKit
import Foundation

public final class LiveToneManager {

    // MARK: - Owned

    public let indicator: LiveToneIndicatorView
    private let engine: LiveToneEngine
    private let masterToggle: LiveToneMasterToggle
    private let counters: LiveToneCounterStore
    private let preference: LiveTonePreference

    /// The opportunity classifier wired into the shipping engine. When
    /// present, O1/O2/O3 are surfaced through the same passive
    /// indicator the red lane uses; O4/O5 stay silent under the
    /// classifier's `activeFamilies` gate.
    public let opportunityClassifier: LiveToneOpportunityClassifier

    /// Per-family session store for the opportunity lane's one-fire /
    /// dismissal discipline. Held on the manager so the integration
    /// lane can update it on user dismissal of an opportunity chip.
    /// `var` because `dismissOpportunity(...)` mutates the per-host-
    /// session dismissal set.
    private var opportunitySession: LiveToneOpportunitySession

    /// Per-family counter store for the opportunity lane.
    private let opportunityCounters: LiveToneOpportunityCounterStore

    // MARK: - Init

    public init(
        appGroupDefaults: UserDefaults? = nil
    ) {
        // Resolve the App Group store lazily so this type stays usable in
        // targets that do not pull in `Shared/SharedUserDefaults.swift`
        // (e.g. the TonoTests target, which carries its own internal
        // `SharedStore` for the geometry suite).
        let resolved: UserDefaults = {
            if let provided = appGroupDefaults { return provided }
            return UserDefaults(suiteName: LiveToneKeys.appGroupSuite) ?? .standard
        }()
        let toggle = LiveToneMasterToggle(defaults: resolved)
        let counterStore = LiveToneCounterStore(defaults: resolved)
        let opportunity = LiveToneOpportunityClassifier()
        let opportunitySession = LiveToneOpportunitySession()
        let opportunityCounterStore = LiveToneOpportunityCounterStore(defaults: resolved)
        let engine = LiveToneEngine(
            classifier: LiveToneClassifier(),
            masterToggle: toggle,
            counters: counterStore,
            opportunityClassifier: opportunity,
            opportunitySession: opportunitySession,
            opportunityCounters: opportunityCounterStore
        )
        self.masterToggle = toggle
        self.counters = counterStore
        self.preference = LiveTonePreference(defaults: resolved)
        self.engine = engine
        self.opportunityClassifier = opportunity
        self.opportunitySession = opportunitySession
        self.opportunityCounters = opportunityCounterStore
        self.indicator = LiveToneIndicatorView()
        self.indicator.onDismiss = { [weak self] in
            self?.engine.userTappedDismiss()
        }
        self.indicator.onOpportunityDismiss = { [weak self] family in
            self?.dismissOpportunity(family: family)
        }
        self.engine.onWarningChange = { [weak self] warning in
            self?.indicator.apply(warning)
        }
    }

    // MARK: - Public API

    /// Read the current master toggle directly from the App Group store.
    /// Used by the Settings view.
    public var isMasterEnabled: Bool { masterToggle.isEnabled }

    /// Flip the master toggle. Persisted through the App Group. The
    /// engine's next evaluation observes the change on the very next
    /// read; while OFF, the classifier is never invoked.
    public func setMasterEnabled(_ on: Bool) {
        masterToggle.setEnabled(on)
        if !on {
            engine.fieldDidReset()
        }
    }

    /// Field / editing-session boundary. Clears every per-draft
    /// suppression and any pending evaluation.
    public func fieldDidReset() {
        engine.fieldDidReset()
    }

    /// Observe a single character keystroke on the keyboard. The
    /// keystroke path itself is never modified — this call is a passive
    /// observer that schedules a debounced evaluation.
    public func observe(character: Character, draft: String) {
        engine.textDidCommit(draft: draft, committedCharacter: character)
    }

    /// Observe a bulk insertion (paste / autocomplete accept). Resets
    /// the debounce; never flushes immediately.
    public func observeBulkInsertion(draft: String) {
        engine.textDidCommit(draft: draft, committedCharacter: nil)
    }

    /// The user deleted the offending span. The contract says the
    /// warning must clear within one cycle; the engine handles that.
    public func clearWithinOneSecond(draft: String) {
        engine.textDidCommit(draft: draft, committedCharacter: ".")
    }

    /// Wire the [Rewrite] button to a user-invoked handler. The closure
    /// is invoked only on explicit tap — Live Tone never opens the
    /// rewrite flow uninvited.
    public func setRewriteHandler(_ handler: @escaping () -> Void) {
        indicator.onRewrite = handler
    }

    /// Update the opportunity per-family session store when the user
    /// dismisses an amber chip. The dismissal MUST route through the
    /// engine (which holds the canonical `opportunitySession` consulted
    /// by `evaluate(draft:)`); mutating only the manager's copy would
    /// silently diverge and let the next draft re-fire the same family.
    /// Pure side effect: clears the visible chip when it matches the
    /// dismissed family.
    public func dismissOpportunity(family: LiveToneOpportunityFamily) {
        opportunitySession.dismiss(family)
        engine.userDismissedOpportunity(family)
    }

    // MARK: - Test seams

    /// The engine driving this manager. Tests may inspect it directly.
    public var debugEngine: LiveToneEngine { engine }

    /// The preference facade driving this manager. Tests may inspect it.
    public var debugPreference: LiveTonePreference { preference }

    /// The per-family session store. Tests may inspect or reset it.
    public var debugOpportunitySession: LiveToneOpportunitySession { opportunitySession }

    /// The per-family counter store. Tests may inspect or reset it.
    public var debugOpportunityCounters: LiveToneOpportunityCounterStore { opportunityCounters }
}