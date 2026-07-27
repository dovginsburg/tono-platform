// LocalCoachRewrite.swift
// Build 115 — the offline-first Coach route for the LIVE UIKit keyboard.
//
// Build 114 shipped a complete on-device Apple Intelligence service
// (`OnDeviceAppleRewrite.swift`) and a bridge to it (`AppleRewriteBridge.swift`)
// that the shipping keyboard could not reach. `KeyboardExtension/Info.plist`
// names `KeyboardViewController` as the principal class, and that controller
// contained zero call sites for `SystemLanguageModel` — every Foundation Models
// call lived in `KeyboardRootView`, a SwiftUI surface the extension compiles but
// never mounts. With no connection there was therefore no rewrite at all.
//
// This file is the POLICY half of the repair, and it is deliberately pure
// Foundation: no UIKit, no FoundationModels, no network, no I/O beyond the App
// Group preference store. Everything here is directly unit-testable on any
// machine, including the parts that decide whether the on-device model may run
// at all. The FoundationModels half lives in `OnDeviceAppleRewrite.swift` and is
// reached through `AppleRewriteBridge`, which conforms to
// `LocalCoachRewriteEngine` below.
//
// The contract this file owns:
//
//   • ONE user action → ONE local request → up to four validated options.
//   • Local first: the route is decided, and the model invoked, before any
//     network object exists. `KeyboardViewController` only constructs its
//     `TonoCoachClient` on the branch that actually needs it.
//   • Local rewriting defaults ON when — and only when — runtime availability
//     is `.available`. The user can turn it off explicitly and that choice is
//     stored separately from the backend feature-flag cache, so a `/v1/features`
//     refresh can never silently revert it.
//   • The Safer axis keeps its corpus-quality gate. Safer is generated locally
//     only when the gate is explicitly open; otherwise the user is told the
//     truth and offered the on-device tones that were actually produced.
//   • Nothing here persists, logs, or transmits draft text. The metrics are
//     durations, byte counts and enum names.

import Foundation

// MARK: - Runtime availability

/// What the on-device model reports about itself, flattened into a value the
/// rest of the app can hold without importing FoundationModels.
///
/// Mirrors `SystemLanguageModel.Availability` one case at a time, plus the two
/// conditions that are ours rather than Apple's: the OS floor and locale
/// support. `AppleRewriteBridge.availability(locale:)` is the only producer.
public enum LocalRewriteAvailability: String, Codable, Sendable, Equatable, CaseIterable {
    /// The model is present, enabled, ready, and speaks the requested language.
    case available
    /// Built for iOS 26 but running on an older OS, or FoundationModels was not
    /// linkable in this build.
    case unsupportedOS
    /// The hardware does not support Apple Intelligence.
    case deviceNotEligible
    /// Supported hardware, but the person has not turned Apple Intelligence on.
    case appleIntelligenceNotEnabled
    /// Enabled, but still downloading assets or otherwise not ready this second.
    case modelNotReady
    /// Ready, but it does not speak the keyboard's current language.
    case unsupportedLocale
    /// Reported unavailable for a reason this OS knows and this build does not.
    case unspecifiedUnavailable

    public var isAvailable: Bool { self == .available }
}

// MARK: - User preference (tri-state, stored on its own)

/// The explicit opt-out required by the Build 115 contract.
///
/// Tri-state on purpose. A plain `Bool` cannot distinguish "the person turned
/// this off" from "nobody has ever touched it", and the contract asks for
/// different behaviour in each case: untouched means ON wherever the model is
/// actually available, and OFF means OFF even on a device that could run it.
public enum LocalRewritePreference: String, Codable, Sendable, Equatable, CaseIterable {
    /// Never chosen. Resolves to ON exactly when runtime availability is
    /// `.available` — never on a device that would only fail.
    case unset
    /// Explicitly on.
    case on
    /// Explicitly off. Honoured even when the model is available.
    case off

    /// The effective switch for a given runtime availability.
    public func resolved(availability: LocalRewriteAvailability) -> Bool {
        switch self {
        case .on:    return true
        case .off:   return false
        case .unset: return availability.isAvailable
        }
    }

    /// Whether the person has made a choice. Settings shows the derived state
    /// for `.unset` rather than pretending they picked it.
    public var isExplicit: Bool { self != .unset }
}

/// App Group persistence for the opt-out.
///
/// Deliberately NOT a `FeatureFlag`. `FeatureFlags.update(from:)` REPLACES the
/// whole cached dictionary with whatever `/v1/features` returned, so any
/// user-set value in that dictionary is only as durable as the next feature
/// fetch. A privacy preference must not evaporate on a network round trip, so
/// it gets its own key and is never written by the flag refresh path.
///
/// `FeatureFlag.appleIntelligenceRewriteEnabled` remains — as a REMOTE kill
/// switch that can force the route off for everyone. It can no longer be the
/// user's switch, because it never was one that survived.
public struct LocalRewritePreferenceStore: Sendable {
    public static let key = "tc.localRewritePreference.v1"

    /// The App Group the keyboard extension and the host app share. Spelled out
    /// rather than taken from `SharedStore`, because a `public` default argument
    /// may not reference an internal declaration and this type is read from the
    /// extension, the host app and the test target alike.
    public static let appGroupSuite = "group.com.tonoit.shared"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appGroupSuite)
            ?? .standard
    }

    public func load() -> LocalRewritePreference {
        guard let raw = defaults.string(forKey: Self.key),
              let preference = LocalRewritePreference(rawValue: raw)
        else { return .unset }
        return preference
    }

    public func save(_ preference: LocalRewritePreference) {
        defaults.set(preference.rawValue, forKey: Self.key)
    }

    /// The Settings toggle writes an explicit choice in both directions, so
    /// turning it back on is a real `.on` rather than a return to `.unset`.
    public func setEnabled(_ enabled: Bool) {
        save(enabled ? .on : .off)
    }
}

// MARK: - Refusal reasons

/// Every way the local route can decline, as one closed vocabulary.
///
/// One reason per distinguishable cause: the contract requires that an
/// ineligible OS, a disabled Apple Intelligence, an unready model, an
/// unsupported language, memory pressure, a guardrail, a refusal and an
/// outright generation failure are told apart rather than flattened into a
/// single apology.
public enum LocalCoachUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    // Policy
    case remoteKillSwitch
    case userTurnedOff
    // Runtime availability
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedLocale
    case unspecifiedUnavailable
    // Input bounds
    case emptyDraft
    case draftTooLong
    /// Build 115 repair — the draft is too short for the local model to rewrite
    /// rather than reply to. Its own reason, because "type more" and "type
    /// less" are opposite instructions and must never share a sentence.
    case draftTooShort
    // Runtime failures
    case memoryPressure
    case busy
    case cancelled
    case guardrail
    case refusal
    case generationFailed
    /// Build 115 repair — guided decoding threw on an incomplete object: the
    /// model was still writing when the response budget ran out, or it looped.
    /// Distinct from `generationFailed` because it is the ONE failure that says
    /// the device was producing an answer, which makes "check your connection"
    /// the wrong thing to tell the person.
    case rewriteDidNotFinish
    case noValidRewrite
    // Axis policy
    case saferNeedsReview
    case toneNeedsConnection
    case customStyleNeedsConnection

    /// Availability maps onto a refusal one-to-one, so a new availability case
    /// cannot silently land on a wrong sentence.
    public init(availability: LocalRewriteAvailability) {
        switch availability {
        case .available:                   self = .generationFailed
        case .unsupportedOS:               self = .unsupportedOS
        case .deviceNotEligible:           self = .deviceNotEligible
        case .appleIntelligenceNotEnabled: self = .appleIntelligenceNotEnabled
        case .modelNotReady:               self = .modelNotReady
        case .unsupportedLocale:           self = .unsupportedLocale
        case .unspecifiedUnavailable:      self = .unspecifiedUnavailable
        }
    }
}

/// The typed failure the engine throws. Never carries draft or rewrite text.
public struct LocalCoachFailure: Error, Sendable, Equatable {
    public let reason: LocalCoachUnavailableReason

    public init(_ reason: LocalCoachUnavailableReason) {
        self.reason = reason
    }
}

/// User-facing sentences for the local route.
///
/// Reviewed against the Build 112 consumer-copy contract: no implementation
/// vocabulary, no status codes, no "temporarily unavailable", and every
/// sentence names either a next step the person can take or the plain fact
/// that their message was left alone.
public enum LocalCoachCopy {
    public static func sentence(for reason: LocalCoachUnavailableReason) -> String {
        switch reason {
        case .remoteKillSwitch:
            return "On-device rewriting is switched off right now."
        case .userTurnedOff:
            return "On-device rewriting is off. Turn it on in Tono under Settings."
        case .unsupportedOS:
            return "On-device rewriting needs iOS 26 or later."
        case .deviceNotEligible:
            return "This iPhone doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to rewrite on this iPhone."
        case .modelNotReady:
            return "Apple Intelligence is still getting ready on this iPhone. Try again in a moment."
        case .unsupportedLocale:
            return "Apple Intelligence doesn't handle this language yet."
        case .unspecifiedUnavailable:
            return "Apple Intelligence can't rewrite on this iPhone right now."
        case .emptyDraft:
            return "Type a message first."
        case .draftTooLong:
            return "That message is too long to rewrite on this iPhone. Shorten it and try again."
        case .draftTooShort:
            return "That message is too short to rewrite on this iPhone. Write a bit more and try again."
        case .memoryPressure:
            return "Not enough free memory to rewrite on this iPhone. Close a few apps and try again."
        case .busy:
            return "A rewrite is already running."
        case .cancelled:
            return "Rewrite stopped. Your message is unchanged."
        case .guardrail:
            return "Apple Intelligence won't rewrite this message. Your message is unchanged."
        case .refusal:
            return "Apple Intelligence declined this rewrite. Your message is unchanged."
        case .generationFailed:
            return "The on-device rewrite didn't work out. Your message is unchanged."
        case .rewriteDidNotFinish:
            return "This iPhone ran out of room finishing that rewrite. Try a shorter message."
        case .noValidRewrite:
            return "Nothing usable came back. Your message is unchanged."
        case .saferNeedsReview:
            return "Safer needs a connection — Tono checks it against a sensitive-language review."
        case .toneNeedsConnection:
            return "That tone needs a connection."
        case .customStyleNeedsConnection:
            return "Your Custom style needs a connection."
        }
    }

    /// Shown beside a local result set when the tapped tone was NOT one of the
    /// tones that were produced on the device. Names the missing tone and the
    /// tones the person is actually looking at — it never implies the missing
    /// tone was generated, which is the whole point of showing it.
    public static func substitutionNote(
        requested: String, reason: LocalCoachUnavailableReason, produced: [LocalCoachAxis]
    ) -> String {
        let tones = LocalCoachAxis.spokenList(produced)
        let head: String
        switch reason {
        case .saferNeedsReview:
            head = sentence(for: .saferNeedsReview)
        case .customStyleNeedsConnection:
            head = sentence(for: .customStyleNeedsConnection)
        default:
            head = "\(requested.capitalized) needs a connection."
        }
        return "\(head) \(tones) were written on this iPhone."
    }

    /// The route label. Only ever set from a result that actually executed
    /// where it claims to have executed.
    public static let onDeviceRouteLabel = "On this iPhone"
    public static let cloudRouteLabel = "Checked with Tono"
}

// MARK: - Axes

/// The tones the on-device route can produce.
///
/// The three base tones are fixed by the Build 115 contract: Warmer, Clearer
/// and Funnier, every time, from one request. `safer` is separate — it exists
/// only behind the corpus-quality gate and is never part of the base set.
///
/// Raw values are the keyboard's own axis vocabulary (`TonoCoachPalette.Axis`),
/// so a produced option renders through the existing card path with the right
/// label and accent and no translation layer in between.
public enum LocalCoachAxis: String, Codable, Sendable, Equatable, CaseIterable {
    case warmer
    case clearer
    case funnier
    case safer

    /// The three tones one local request always produces.
    public static let base: [LocalCoachAxis] = [.warmer, .clearer, .funnier]

    public var displayName: String {
        switch self {
        case .warmer:  return "Warmer"
        case .clearer: return "Clearer"
        case .funnier: return "Funnier"
        case .safer:   return "Safer"
        }
    }

    /// "Warmer, Clearer and Funnier" — for the substitution note.
    public static func spokenList(_ axes: [LocalCoachAxis]) -> String {
        let names = axes.map(\.displayName)
        guard let last = names.last else { return "no tones" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

// MARK: - The route decision

/// What one local request will ask for, plus anything the person must be told
/// about a tone that will NOT be in the answer.
public struct LocalCoachPlan: Sendable, Equatable {
    public let axes: [LocalCoachAxis]
    /// Non-nil when the tapped tone is absent from `axes`. Rendered beside the
    /// results so the substitution is visible rather than silent.
    public let substitutionNote: String?

    public init(axes: [LocalCoachAxis], substitutionNote: String?) {
        self.axes = axes
        self.substitutionNote = substitutionNote
    }
}

/// The decision itself. `KeyboardViewController` switches on exactly this.
public enum LocalCoachRoute: Sendable, Equatable {
    /// Run the on-device model. No network object is constructed on this branch.
    case local(LocalCoachPlan)
    /// The on-device route declined; the connected route is the one to use, and
    /// `reason` is why local was not used.
    case cloud(LocalCoachUnavailableReason)
}

/// The single authority for "may this run locally, and with which tones".
///
/// Pure and total: every input combination yields a decision, and the decision
/// never depends on ambient state, so the whole matrix is unit-testable without
/// a device, a model, or a network.
public enum LocalCoachRoutePolicy {
    // MARK: Bounds — one measured chain, not three independent numbers
    //
    // Build 115 as first written declared three bounds that contradicted each
    // other: drafts up to 1,200 characters were admitted, each option was
    // capped at 1,200 characters, and the generation was given
    // `min(1_024, 180 × axisCount)` = 540 response tokens for the three-tone
    // set. Measured on the iOS 26.5 Simulator with the shipping call shape
    // (`sampling: .greedy`, `includeSchemaInPrompt: true`):
    //
    //   | draft | tokens | outcome                                        |
    //   |-------|--------|------------------------------------------------|
    //   |   400 |    540 | ok                                             |
    //   |   545 |    540 | THREW decodingFailure (16–18 s)                |
    //   |   919 |    540 | THREW decodingFailure, 3/3 runs                |
    //   |   919 |   none | ok — 977/951/979 chars out                     |
    //   |   545 |   none | ok, but a mid-word-truncated 550 ran 80 s and  |
    //   |       |        | died on exceededContextWindowSize              |
    //   |  1197 |  1,173 | ok — and 1221/1221/1222 chars out, so ALL      |
    //   |       |        | THREE options fail the 1,200-char option cap   |
    //   |   991 |  1,576 | ok once (1199/1120/1154 out), and once the     |
    //   |       |        | model returned the draft VERBATIM three times  |
    //   |       |        | (991/991/991) — every option dropped as a      |
    //   |       |        | no-op, whole request failed noValidRewrite     |
    //   |  1197 |  1,556 | 4 tones: 1222 × 4 out, and 30.9 s — past the   |
    //   |       |        | 30 s on-device watchdog                        |
    //
    // Guided decoding does not truncate gracefully: the emitted JSON object
    // stops mid-field and the decode throws. So the token budget was not a
    // safety margin, it was a defect for any message beyond a couple of
    // sentences — and in airplane mode it produced exactly the founder-reported
    // symptom (a long shimmer, then "Coach needs internet", on a phone that
    // could have answered).
    //
    // The three numbers below are now ONE chain, derived in one direction:
    //
    //     admitted draft  ──×expansion──▶  option cap  ──÷chars-per-token──▶  token budget
    //
    // so raising or lowering any of them moves the others with it and they
    // cannot drift apart again. Both ends are pinned by tests, and the middle
    // is pinned against the real model by
    // `testTheRealModelServesEveryAdmittedDraftLength`.

    /// How much longer than the draft a rewrite may legitimately be.
    ///
    /// Measured worst case across clean drafts of 545 / 919 / 996 / 1,197
    /// characters: 1.18× (the short drafts expand most, because a warmer
    /// rewrite of two sentences adds proportionally more). 1.4 is that with
    /// room, and it is deliberately an ALLOWANCE rather than a prediction —
    /// anything beyond it is a runaway and is meant to be refused.
    public static let outputExpansionAllowance = 1.4

    /// Bounded input, per requested tone count.
    ///
    /// Scaled by tone count because the cost is per tone, in both directions:
    /// the four-tone (gated Safer) generation writes a third more text than the
    /// three-tone one and takes a third longer, and at 1,197 characters it
    /// measured 30.9 s — past `coachLocalVisibleDeadline`. The bound is what
    /// the model can actually serve inside the watchdog with output that
    /// survives validation, not what a keyboard field can hold.
    ///
    /// HONEST LIMIT, and the whole reason this is 930 rather than the 1,200
    /// first declared. Two independent things break above it, and only the
    /// first is a token-budget problem:
    ///
    ///   * At ~1,200 characters the model writes ~1,222 characters per option
    ///     and takes 30.9 s for the four-tone set — past
    ///     `coachLocalVisibleDeadline`, so the watchdog would cancel a
    ///     generation the model actually completed.
    ///   * At ~1,000 characters the model becomes BISTABLE: measured twice on
    ///     the same ~991-character draft it returned three genuine rewrites
    ///     once, and all three tones as the draft VERBATIM the other time
    ///     (991/991/991 characters out). A verbatim echo is not a rewrite, so
    ///     `LocalCoachValidator` drops all three as no-ops and the whole
    ///     request fails `.noValidRewrite`. No token budget fixes that; it is
    ///     what the model does with a message that long.
    ///
    /// 930 is the longest length measured to deliver a usable answer on every
    /// observation (3/3 survivors twice, 2/3 once). Sweeping 300 → 930 in eight
    /// steps, every length delivered at least one validated rewrite. A draft
    /// longer than this goes to the connected route, which handles it exactly
    /// as it always has.
    ///
    /// The four-tone bound is lower again for latency: 749 characters × 4 tones
    /// measured 23.7 s against a 30 s watchdog, which is not enough margin for
    /// hardware slower than an M-series simulator.
    public static func maximumDraftCharacters(forAxisCount axisCount: Int) -> Int {
        axisCount >= 4 ? 700 : 930
    }

    /// The largest draft ANY local plan admits — the three-tone bound, because
    /// the base plan is three tones. Checked first so an over-long draft is
    /// refused before anything is claimed about Apple Intelligence.
    public static let maximumDraftCharacters = maximumDraftCharacters(forAxisCount: 3)

    /// Bounded output per option, derived from the input bound rather than
    /// chosen beside it. A rewrite may be up to 40% longer than the message it
    /// rewrites; beyond that it is not a rewrite of that message.
    public static let maximumOptionCharacters =
        Int((Double(LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 3))
             * LocalCoachRoutePolicy.outputExpansionAllowance).rounded(.up))

    // MARK: The response-token budget
    //
    // Third link in the chain, and the one that was broken. Sized from the
    // option cap and the tone count so it can never again be a number chosen
    // independently of the input it has to serve, and scaled by the ACTUAL
    // draft so a short message gets a small budget — which is what bounds a
    // runaway generation in time. (A mid-word-truncated 550-character draft
    // reproducibly sends the model into a loop; uncapped it ran 80 s and died
    // on `exceededContextWindowSize`, which is worse for the person than a
    // bounded refusal. The cap is a safety device and stays.)

    /// Conservative characters-per-token for guided JSON output.
    ///
    /// English prose runs ~3.5–4 characters per token; structured output pays
    /// extra for field names, quotes and escapes. 2.8 under-counts on purpose:
    /// under-counting characters per token OVER-counts the tokens budgeted,
    /// and the failure this bound exists to prevent is running out of them.
    public static let charactersPerResponseToken = 2.8

    /// Absolute ceiling. The on-device context window is shared between prompt
    /// and completion; the largest admitted request (750 characters × 4 tones)
    /// budgets ~1,876 tokens against roughly 440 of prompt, so this leaves the
    /// window comfortable while still ending a runaway.
    public static let responseTokenCeiling = 2_048

    /// The bounded output budget for one request.
    public static func maximumResponseTokens(axisCount: Int, draftCharacters: Int) -> Int {
        let axes = max(axisCount, 1)
        // Even a very short draft needs room for a complete sentence per tone.
        let perOptionCharacters = min(
            maximumOptionCharacters,
            Int((Double(max(draftCharacters, 0)) * outputExpansionAllowance).rounded(.up)) + 200
        )
        let perOptionTokens = Int((Double(perOptionCharacters) / charactersPerResponseToken).rounded(.up))
        // The JSON object itself: braces, four field names, quoting, escapes.
        let scaffolding = 40 + 12 * axes
        return min(responseTokenCeiling, scaffolding + axes * perOptionTokens)
    }

    // MARK: The minimum useful draft
    //
    // The instructions tell the model "never answer the message, never reply to
    // it". Measured on iOS 26.5 with those exact instructions, that holds for
    // messages that say something and fails for messages that do not: a draft
    // of `ok` came back as `Hey there!`, `no` came back as a 165-character
    // apology, and `Thanks!` came back as `You're welcome! I'm glad I could
    // help.` — the model answered the message because there was nothing in it
    // to rewrite. Validation checks emptiness, length, fences and no-op
    // identity; none of those catch an invented reply, and `Use rewrite` would
    // have replaced the person's `no` with an apology.
    //
    // The gate below is deliberately a LENGTH gate and not a fidelity check.
    // A fidelity check on the device would have to claim two texts mean the
    // same thing, and the only tools available locally are lexical — a
    // legitimate rewrite of "send it now" as "could you get that over to me
    // right away?" shares no content word with its draft, so lexical overlap
    // would reject good rewrites while claiming a semantic guarantee it cannot
    // make. A truthful bound on the INPUT is worth more than a false claim
    // about the output.
    //
    // Trade-off, stated rather than hidden: this route declines to rewrite
    // one- and two-word messages, including real ones like "call me". The
    // person is told plainly, and the connected route — which has the tone
    // corpus behind it — still takes them.

    /// Fewer characters than this and there is nothing to rewrite.
    public static let minimumDraftCharacters = 12

    /// Fewer words than this and the model answers instead of rewriting.
    public static let minimumDraftWords = 3

    /// Whether a draft carries enough for the local model to rewrite rather
    /// than reply to. Both bounds must hold: `Thanks!!!!!!` clears the
    /// character bound on punctuation alone, and `ok sure` clears the word
    /// bound on nothing at all.
    public static func draftIsLongEnoughToRewrite(_ draft: String) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumDraftCharacters else { return false }
        let words = trimmed
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .filter { !$0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty }
        return words.count >= minimumDraftWords
    }

    /// Axes the connected route owns outright. `custom` is a free-text
    /// instruction the backend validates and bounds; reproducing that policy on
    /// the device would be a second copy of it, so the local route declines.
    public static let connectedOnlyAxes: Set<String> = ["custom"]

    /// Build a local route only when the plan's own tone count admits the
    /// draft. The four-tone (gated Safer) generation writes a third more text
    /// and takes a third longer than the three-tone one, so it admits less —
    /// and the check belongs where the axes are known, not before.
    private static func localRoute(_ plan: LocalCoachPlan, draft: String) -> LocalCoachRoute {
        guard draft.count <= maximumDraftCharacters(forAxisCount: plan.axes.count) else {
            return .cloud(.draftTooLong)
        }
        return .local(plan)
    }

    public static func decide(
        requestedAxis: String,
        draft: String,
        remoteKillSwitchAllows: Bool,
        preference: LocalRewritePreference,
        availability: LocalRewriteAvailability,
        saferCorpusGateOpen: Bool,
        connectivityKnownAbsent: Bool
    ) -> LocalCoachRoute {
        let axis = requestedAxis.lowercased()

        // 1. Input bounds come first: a draft the local route cannot accept is
        //    not a reason to report anything about Apple Intelligence.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .cloud(.emptyDraft) }
        guard draft.count <= maximumDraftCharacters else { return .cloud(.draftTooLong) }
        // …including the bound at the other end. A message with nothing in it
        // to rewrite is answered rather than rewritten (see §"minimum useful
        // draft"), and an invented reply is a worse outcome than a truthful
        // decline — `Use rewrite` would put it in the person's message.
        guard draftIsLongEnoughToRewrite(draft) else { return .cloud(.draftTooShort) }

        // 2. Remote kill switch. Force-off for everyone, and not a preference.
        guard remoteKillSwitchAllows else { return .cloud(.remoteKillSwitch) }

        // 3. The person's explicit opt-out outranks an available model.
        if preference == .off { return .cloud(.userTurnedOff) }

        // 4. Runtime availability. `.unset` resolves ON only here, against the
        //    real reported availability — never against a stored guess.
        guard preference.resolved(availability: availability) else {
            return .cloud(LocalCoachUnavailableReason(availability: availability))
        }
        guard availability.isAvailable else {
            return .cloud(LocalCoachUnavailableReason(availability: availability))
        }

        // 5. Axes the connected route owns. With a route, it runs there exactly
        //    as before. With no route at all, the person gets the tones that
        //    CAN be written here plus a note naming the one that cannot —
        //    which beats a shimmer that ends in "Coach needs internet" on a
        //    phone that could have answered.
        if connectedOnlyAxes.contains(axis) {
            guard connectivityKnownAbsent else { return .cloud(.customStyleNeedsConnection) }
            return localRoute(LocalCoachPlan(
                axes: LocalCoachAxis.base,
                substitutionNote: LocalCoachCopy.substitutionNote(
                    requested: axis,
                    reason: .customStyleNeedsConnection,
                    produced: LocalCoachAxis.base
                )
            ), draft: draft)
        }

        // 6. Safer keeps its corpus-quality gate, which is closed by default.
        //
        //    Gate open  → Safer is generated on the device alongside the base
        //                 tones, because somebody deliberately allowed that.
        //    Gate closed, no route → the person gets the three tones that WERE
        //                 written on the device, and is told plainly that Safer
        //                 is not among them. Nothing unvetted is labelled Safer.
        //    Gate closed, route may exist → the connected route runs, exactly as
        //                 it does today, and produces the reviewed Safer answer.
        if axis == LocalCoachAxis.safer.rawValue {
            if saferCorpusGateOpen {
                return localRoute(LocalCoachPlan(
                    axes: LocalCoachAxis.base + [.safer], substitutionNote: nil
                ), draft: draft)
            }
            guard connectivityKnownAbsent else { return .cloud(.saferNeedsReview) }
            return localRoute(LocalCoachPlan(
                axes: LocalCoachAxis.base,
                substitutionNote: LocalCoachCopy.substitutionNote(
                    requested: LocalCoachAxis.safer.rawValue,
                    reason: .saferNeedsReview,
                    produced: LocalCoachAxis.base
                )
            ), draft: draft)
        }

        // 7. Everything else runs locally and produces the base three. When the
        //    tapped tone is not one of them — Affectionate, Professional,
        //    Concise — the substitution is stated rather than implied.
        let requestedIsProduced = LocalCoachAxis.base.contains { $0.rawValue == axis }
        return localRoute(LocalCoachPlan(
            axes: LocalCoachAxis.base,
            substitutionNote: requestedIsProduced ? nil : LocalCoachCopy.substitutionNote(
                requested: axis,
                reason: .toneNeedsConnection,
                produced: LocalCoachAxis.base
            )
        ), draft: draft)
    }
}

// MARK: - Validation

/// One validated option. `text` has already passed every check below, so a
/// consumer never has to re-decide whether it is safe to insert.
public struct LocalCoachOption: Sendable, Equatable {
    public let axis: LocalCoachAxis
    public let text: String

    public init(axis: LocalCoachAxis, text: String) {
        self.axis = axis
        self.text = text
    }
}

/// Local validation of model output. Nothing reaches the card that has not
/// been through here.
///
/// The rules are the ones a rewrite can actually violate: empty, over-long,
/// wrapped in the fences or quotes a language model likes to add, prefixed with
/// its own field label, or not a rewrite at all because it came back as the
/// draft. An option that fails is DROPPED, never repaired into a pass — and if
/// every option fails the whole request fails with `.noValidRewrite`, so the
/// person is told rather than shown an empty card.
public enum LocalCoachValidator {
    /// Case/whitespace/punctuation-insensitive normalization for the no-op
    /// comparison.
    ///
    /// This is the canonical implementation and lives here because
    /// `LocalCoachRewrite.swift` is a member of all four shipped targets, which
    /// `CoachVariantSettings.swift` is not. `ShortcutRewrite.normalizedForNoOp`
    /// forwards to it, so the keyboard lane and the Shortcut lane cannot
    /// disagree about what "the same message" means — there is one rule, not a
    /// copy per surface.
    public static func normalizedForNoOp(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Labels the model sometimes prefixes onto a field it was asked for.
    private static let labelPrefixes = [
        "warm:", "warmer:", "clear:", "clearer:", "funny:", "funnier:",
        "safe:", "safer:", "rewrite:", "rewritten:", "message:",
    ]

    public static func validate(
        _ raw: String,
        axis: LocalCoachAxis,
        draft: String,
        maximumCharacters: Int = LocalCoachRoutePolicy.maximumOptionCharacters
    ) -> LocalCoachOption? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = strippingCodeFence(text)
        text = strippingLabelPrefix(text)
        text = strippingWrappingQuotes(text)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty, text.count <= maximumCharacters else { return nil }
        // A rewrite that IS the draft is not a rewrite.
        guard normalizedForNoOp(text) != normalizedForNoOp(draft) else { return nil }

        return LocalCoachOption(axis: axis, text: text)
    }

    /// Validate a whole set. Order is the caller's; invalid members drop out.
    /// Returns nil when nothing survived, which the caller turns into
    /// `.noValidRewrite`.
    public static func validateSet(
        _ raw: [(axis: LocalCoachAxis, text: String)],
        draft: String,
        maximumCharacters: Int = LocalCoachRoutePolicy.maximumOptionCharacters
    ) -> [LocalCoachOption]? {
        var seen = Set<String>()
        var options: [LocalCoachOption] = []
        for candidate in raw {
            guard let option = validate(
                candidate.text, axis: candidate.axis, draft: draft,
                maximumCharacters: maximumCharacters
            ) else { continue }
            // Two tones that produced the identical sentence are one choice,
            // not two. Keep the first and drop the duplicate rather than
            // showing the person the same words twice under different labels.
            guard seen.insert(normalizedForNoOp(option.text)).inserted
            else { continue }
            options.append(option)
        }
        return options.isEmpty ? nil : options
    }

    private static func strippingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func strippingLabelPrefix(_ text: String) -> String {
        let lowered = text.lowercased()
        for prefix in labelPrefixes where lowered.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
        }
        return text
    }

    private static func strippingWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("'", "'"),
        ]
        for (open, close) in pairs
        where text.count >= 2 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}

// MARK: - Memory budget

/// The extension memory ceiling the local route pre-flights against.
///
/// HONEST LIMIT: Apple publishes no exact custom-keyboard footprint limit for
/// iOS 26. 45 MB is a deliberately conservative operating ceiling derived from
/// the historical ~48 MB custom-keyboard budget, and it is a PRE-FLIGHT check —
/// if the extension is already near the cliff before the request, the route
/// declines with `.memoryPressure` instead of taking the process down mid-tap.
///
/// Measured on the iOS 26.5 Simulator (see the Build 115 handoff): the client
/// side of a four-field structured generation peaks around 10 MB of footprint,
/// because the model itself runs out of process. The ceiling is headroom, not a
/// prediction.
public enum LocalCoachMemoryBudget {
    public static let preflightCeilingBytes: UInt64 = 45 * 1_024 * 1_024

    /// `true` when there is room to run.
    ///
    /// Two deliberate refusals to refuse:
    ///
    ///   * An unreadable footprint is treated as room. The probe failing is not
    ///     evidence of pressure, and refusing on a failed measurement would
    ///     disable the feature wherever `task_info` stops answering.
    ///   * The ceiling is an APP-EXTENSION budget, so it is only applied inside
    ///     an app extension. The host app, the Share sheet's own process and the
    ///     XCTest runner routinely sit above 45 MB while having gigabytes of
    ///     headroom; applying a keyboard's budget to them would refuse a request
    ///     that was never in danger. (Found by
    ///     `testRealOnDeviceEngineProducesThreeValidatedRewrites`, which failed
    ///     with `.memoryPressure` in a test host using ~90 MB.)
    public static func hasHeadroom(
        residentBytes: UInt64?,
        isAppExtension: Bool = LocalCoachMemoryBudget.runningInAppExtension
    ) -> Bool {
        guard isAppExtension, let residentBytes else { return true }
        return residentBytes < preflightCeilingBytes
    }

    /// Whether this process is an app extension. `Bundle.main` is the extension
    /// bundle inside an `.appex`, which is the documented way to tell.
    public static var runningInAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }
}

// MARK: - Metrics

/// Privacy-safe record of one local request. Durations, byte counts and enum
/// names only — no draft text, no rewrite text, no identifiers.
public struct LocalCoachMetrics: Sendable, Equatable, Codable {
    public let availabilityReason: String
    public let requestedAxisCount: Int
    public let validatedOptionCount: Int
    public let bytesIn: Int
    public let bytesOut: Int
    public let completionMilliseconds: Double
    public let peakFootprintBytes: UInt64?

    public init(
        availabilityReason: String,
        requestedAxisCount: Int,
        validatedOptionCount: Int,
        bytesIn: Int,
        bytesOut: Int,
        completionMilliseconds: Double,
        peakFootprintBytes: UInt64?
    ) {
        self.availabilityReason = availabilityReason
        self.requestedAxisCount = requestedAxisCount
        self.validatedOptionCount = validatedOptionCount
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.completionMilliseconds = completionMilliseconds
        self.peakFootprintBytes = peakFootprintBytes
    }
}

/// What one successful local request returns.
public struct LocalCoachSetResult: Sendable, Equatable {
    public let options: [LocalCoachOption]
    public let metrics: LocalCoachMetrics

    public init(options: [LocalCoachOption], metrics: LocalCoachMetrics) {
        self.options = options
        self.metrics = metrics
    }
}

/// One local request.
public struct LocalCoachSetRequest: Sendable, Equatable {
    public let draft: String
    public let axes: [LocalCoachAxis]
    public let locale: Locale

    public init(draft: String, axes: [LocalCoachAxis], locale: Locale = .current) {
        self.draft = draft
        self.axes = axes
        self.locale = locale
    }
}

// MARK: - The engine seam

/// What the keyboard needs from the on-device model, and nothing more.
///
/// `AppleRewriteBridge` is the production conformer and the only one that ships;
/// the seam exists so the routing, validation, cancellation, error-mapping and
/// zero-network contracts can be driven deterministically in a unit test on a
/// machine where Apple Intelligence may be unavailable — and so the SAME tests
/// can be pointed at the real FoundationModels engine where it IS available.
public protocol LocalCoachRewriteEngine: Sendable {
    /// Reported without generating anything. Cheap enough to call per tap.
    func availability(locale: Locale) async -> LocalRewriteAvailability

    /// One request. Throws `LocalCoachFailure` and nothing else.
    func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult
}

/// The honest null object: an engine that reports the OS is too old and refuses
/// to generate anything.
///
/// It exists for exactly one caller — the XCTest module, which compiles the
/// keyboard controller into its own module where the real bridge's types are
/// not nameable. It is deliberately not "an engine that quietly succeeds": if it
/// ever reached a shipped build, the on-device route would visibly report
/// `unsupportedOS` rather than silently claiming to have run locally.
public struct UnavailableLocalCoachEngine: LocalCoachRewriteEngine {
    public init() {}

    public func availability(locale: Locale) async -> LocalRewriteAvailability { .unsupportedOS }

    public func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
        throw LocalCoachFailure(.unsupportedOS)
    }
}
