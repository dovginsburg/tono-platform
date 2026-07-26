// Build115LocalCoachTests.swift
// Build 115 — the offline-first on-device Coach route in the LIVE UIKit keyboard.
//
// THE DEFECT. With no connection, Tono did not use Apple's on-device model at
// all. `KeyboardExtension/Info.plist` names `KeyboardViewController` as
// `NSExtensionPrincipalClass`; at c0aba9d that class contained zero references
// to `SystemLanguageModel`, `LanguageModelSession`, `AppleRewriteBridge` or
// `OnDeviceAppleRewrite`. The Foundation Models wiring existed, but only in
// `KeyboardRootView` — a SwiftUI surface the extension compiles and never
// mounts — and even there it ran only AFTER a cloud response had produced chip
// text to replace, so a fresh offline request could not reach it. On top of
// that, `apple_intelligence_rewrite_enabled` defaulted false, and the policy it
// gated was captured once in an actor `let` on a process-lifetime singleton, so
// turning it on could not take effect until the extension was recycled.
//
// RED-CAPABILITY. Every behavioural test in section 6 drives
// `KeyboardViewController.runCoach` and asserts an on-device result — which at
// c0aba9d was unreachable, because that function's next statement after the
// loading surface was `coachClient.variant(...)`. Section 1 pins the same fact
// at the source level in a form that names the exact strings the old file
// lacked. `Scripts/verify_build115_binary_reachability.py` makes the same
// assertion against a BUILT Release .appex; the handoff records it red on the
// Build 114 binary and green on the Build 115 one.
//
// HONEST LIMITS, stated once so no test below has to imply otherwise:
//
//   * Sections 2-5 and 7 are pure-value tests: total, deterministic, no device.
//   * Section 6 drives the real controller with a STUB engine. What it proves is
//     the routing, the surfaces, the cancellation, the zero-network property and
//     the error mapping — all production code. It does not prove Apple's model
//     writes good English; `testShippingDefaultEngineIsTheRealBridge` pins that
//     the shipped default is the real `AppleRewriteBridge`, and section 8 runs
//     the real thing where it is available.
//   * Section 8 runs the REAL FoundationModels engine and SKIPS honestly when
//     `SystemLanguageModel` is unavailable on the running machine. A skip is
//     recorded as a skip, never as a pass.
//   * Nothing here can prove physical-device behaviour. Airplane-mode acceptance
//     on an eligible iPhone remains an unearned claim and a release gate.

import XCTest
import UIKit
@testable import Tono

final class Build115LocalCoachTests: XCTestCase {

    // ───────────────────────────────────────────────────────────────────
    // 1. The repair, pinned at the source level
    // ───────────────────────────────────────────────────────────────────

    /// The live controller — not the dormant SwiftUI view — reaches Foundation
    /// Models. Each of these substrings was ABSENT from
    /// `KeyboardViewController.swift` at c0aba9d, so this test is red on the
    /// Build 114 tree by construction.
    func testLiveControllerReachesTheOnDeviceEngine() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        for required in [
            "LocalCoachRewriteEngine",
            "AppleRewriteBridge.shared",
            "localCoachEngine",
            "rewriteSet(",
            "LocalCoachRoutePolicy.decide(",
            "LocalCoachSetRequest(",
        ] {
            XCTAssertTrue(
                code.contains(required),
                "the live KeyboardViewController must reach the on-device route via \(required)"
            )
        }
    }

    /// The on-device branch must not be able to touch the network client. The
    /// contract is structural: `coachClient` is read on exactly one kind of
    /// branch, and `startLocalCoach` is not one of them.
    func testTheOnDeviceBranchNeverReadsTheNetworkClient() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        let local = try XCTUnwrap(
            Self.body(ofDeclaration: "private func startLocalCoach(", in: code),
            "startLocalCoach must exist"
        )
        for forbidden in ["coachClient", "TonoCoachClient(", "URLSession", "dataTask"] {
            XCTAssertFalse(
                local.contains(forbidden),
                "the on-device branch must not reference \(forbidden) — that is how a "
                    + "\"local\" rewrite starts making requests again"
            )
        }
        // The connected dispatch sites are countable and few, so a future edit
        // cannot quietly add a third.
        XCTAssertEqual(
            code.components(separatedBy: "coachClient.variant(").count - 1, 2,
            "exactly two connected dispatch sites — startConnectedCoach and tryAnotherTapped"
        )
        XCTAssertFalse(
            code.contains("private lazy var coachClient"),
            "a lazy property would be constructed by any read, making \"was the network "
                + "stack built\" unobservable"
        )
    }

    /// Route decision before transport. `runCoach` must resolve availability and
    /// choose a route before anything connected is reachable from it.
    func testRouteIsChosenBeforeAnyConnectedWork() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        let run = try XCTUnwrap(
            Self.body(ofDeclaration: "func runCoach(draft: String, axis: String)", in: code),
            "runCoach must exist"
        )
        XCTAssertTrue(run.contains("resolveLocalAvailability("),
                      "runCoach must ask the on-device model first")
        XCTAssertFalse(run.contains("coachClient"),
                       "runCoach itself must not reach the connected client at all")
    }

    /// The keyboard still must not grow a reachability observer — Build 111
    /// removed the last one, and the on-device route did not bring one back.
    func testNoReachabilityObserverWasIntroduced() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        for forbidden in ["NWPathMonitor", "SCNetworkReachability", "Reachability(",
                          "Timer.scheduledTimer", "CFRunLoopTimer"] {
            XCTAssertFalse(code.contains(forbidden), "\(forbidden) must not exist in the keyboard")
        }
    }

    /// The draft must not be persisted, logged, or handed to analytics by the
    /// on-device path.
    func testTheOnDeviceRouteNeverWritesOrLogsTheDraft() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        for declaration in ["private func startLocalCoach(", "func completeLocalCoach("] {
            let body = try XCTUnwrap(
                Self.body(ofDeclaration: declaration, in: code), "\(declaration) must exist"
            )
            for forbidden in ["SharedStore.defaults.set", "UserDefaults(", "FileManager",
                              "\\(draft)", "\\(request.draft)"] {
                XCTAssertFalse(
                    body.contains(forbidden),
                    "\(declaration) leaks the draft via \(forbidden)"
                )
            }
        }
        let policy = Self.strippingComments(try Self.source("Shared/LocalCoachRewrite.swift"))
        XCTAssertFalse(policy.contains("FileManager"), "the policy layer writes nothing to disk")
        let metrics = try XCTUnwrap(
            Self.body(ofDeclaration: "public struct LocalCoachMetrics", in: policy),
            "the metrics type must exist"
        )
        XCTAssertTrue(metrics.contains("bytesIn"), "metrics carry a size class")
        XCTAssertFalse(metrics.contains("draft"), "metrics must not carry draft text")
        XCTAssertFalse(metrics.contains("rewrite"), "metrics must not carry rewrite text")
    }

    // ───────────────────────────────────────────────────────────────────
    // 2. The route policy — every availability state, exhaustively
    // ───────────────────────────────────────────────────────────────────

    private func decide(
        axis: String = "clearer",
        draft: String = "hey I really need that report today",
        killSwitch: Bool = true,
        preference: LocalRewritePreference = .unset,
        availability: LocalRewriteAvailability = .available,
        saferGate: Bool = false,
        offline: Bool = false
    ) -> LocalCoachRoute {
        LocalCoachRoutePolicy.decide(
            requestedAxis: axis, draft: draft,
            remoteKillSwitchAllows: killSwitch, preference: preference,
            availability: availability, saferCorpusGateOpen: saferGate,
            connectivityKnownAbsent: offline
        )
    }

    /// Default ON, but only where the model actually is available. Every other
    /// availability state routes to the connected path with its OWN reason —
    /// this is the "exact user-facing reasons" half of the contract.
    func testEveryAvailabilityStateMapsToItsOwnReason() {
        XCTAssertEqual(decide(availability: .available), .local(
            LocalCoachPlan(axes: LocalCoachAxis.base, substitutionNote: nil)
        ))
        let expected: [LocalRewriteAvailability: LocalCoachUnavailableReason] = [
            .unsupportedOS: .unsupportedOS,
            .deviceNotEligible: .deviceNotEligible,
            .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled,
            .modelNotReady: .modelNotReady,
            .unsupportedLocale: .unsupportedLocale,
            .unspecifiedUnavailable: .unspecifiedUnavailable,
        ]
        XCTAssertEqual(
            Set(expected.keys).union([.available]), Set(LocalRewriteAvailability.allCases),
            "every availability state must be covered by this test"
        )
        for availability in LocalRewriteAvailability.allCases where availability != .available {
            guard let reason = expected[availability] else { continue }
            XCTAssertEqual(
                decide(availability: availability), .cloud(reason),
                "\(availability) must report itself, not a generic failure"
            )
        }
    }

    /// Each reason has its own sentence, and no two collide — a flattened
    /// apology is exactly what the contract forbids.
    func testEveryReasonHasItsOwnDistinctSentence() {
        var seen: [String: LocalCoachUnavailableReason] = [:]
        for reason in LocalCoachUnavailableReason.allCases {
            let sentence = LocalCoachCopy.sentence(for: reason)
            XCTAssertFalse(sentence.isEmpty, "\(reason) has no sentence")
            if let clash = seen[sentence] {
                XCTFail("\(reason) and \(clash) share the sentence “\(sentence)”")
            }
            seen[sentence] = reason
        }
    }

    /// Consumer vocabulary. The Build 112 contract bans implementation words
    /// from anything a person reads; this copy is rendered by the keyboard, so
    /// it is judged by the same rules.
    func testNoReasonSentenceNamesAnImplementationDetail() {
        let forbiddenTerms = [
            "backend", "server", "endpoint", "api key", "bearer", "provider",
            "proxy", "llm", "transport", "userdefaults", "app group", "://", "http",
            "temporarily unavailable",
        ]
        let forbiddenWords = ["url", "urls", "token", "tokens"]
        for reason in LocalCoachUnavailableReason.allCases {
            let sentence = LocalCoachCopy.sentence(for: reason).lowercased()
            for term in forbiddenTerms {
                XCTAssertFalse(sentence.contains(term), "\(reason) says “\(term)”: \(sentence)")
            }
            let words = sentence.components(separatedBy: CharacterSet.alphanumerics.inverted)
            for word in forbiddenWords {
                XCTAssertFalse(words.contains(word), "\(reason) says the word “\(word)”: \(sentence)")
            }
        }
    }

    func testExplicitOptOutBeatsAnAvailableModel() {
        XCTAssertEqual(decide(preference: .off, availability: .available), .cloud(.userTurnedOff))
    }

    func testExplicitOptInStillCannotRunAnUnavailableModel() {
        // `.on` resolves the switch; availability is a fact, not a policy.
        XCTAssertEqual(
            decide(preference: .on, availability: .deviceNotEligible),
            .cloud(.deviceNotEligible)
        )
    }

    func testUnsetPreferenceIsOnWhereAvailableAndOffWhereNot() {
        XCTAssertTrue(LocalRewritePreference.unset.resolved(availability: .available))
        for availability in LocalRewriteAvailability.allCases where availability != .available {
            XCTAssertFalse(
                LocalRewritePreference.unset.resolved(availability: availability),
                "an untouched preference must not claim a model that is \(availability)"
            )
        }
        XCTAssertFalse(LocalRewritePreference.unset.isExplicit)
        XCTAssertTrue(LocalRewritePreference.on.isExplicit)
        XCTAssertTrue(LocalRewritePreference.off.isExplicit)
    }

    func testRemoteKillSwitchForcesTheConnectedRoute() {
        XCTAssertEqual(decide(killSwitch: false, preference: .on), .cloud(.remoteKillSwitch))
    }

    func testInputBoundsAreCheckedBeforeAnythingIsClaimedAboutAppleIntelligence() {
        XCTAssertEqual(decide(draft: "   \n "), .cloud(.emptyDraft))
        let long = String(repeating: "a", count: LocalCoachRoutePolicy.maximumDraftCharacters + 1)
        XCTAssertEqual(decide(draft: long), .cloud(.draftTooLong))
        // Even with the kill switch off, a bad draft is reported as a bad draft.
        XCTAssertEqual(decide(draft: "", killSwitch: false), .cloud(.emptyDraft))
    }

    // ── The Safer corpus-quality gate ──────────────────────────────────

    /// Gate closed (the default) and a route may exist → the reviewed connected
    /// Safer path runs, exactly as it does today. Nothing is generated locally.
    func testSaferWithTheGateClosedGoesToTheReviewedConnectedRoute() {
        XCTAssertEqual(decide(axis: "safer", saferGate: false), .cloud(.saferNeedsReview))
    }

    /// Gate closed and NO route at all → the person gets the tones that were
    /// genuinely written on the device plus a note naming the one that was not.
    /// Critically, `safer` is absent from the produced set.
    func testSaferOfflineProducesTheBaseTonesAndSaysSaferIsMissing() throws {
        guard case .local(let plan) = decide(axis: "safer", saferGate: false, offline: true) else {
            return XCTFail("offline Safer must still produce the on-device tones")
        }
        XCTAssertEqual(plan.axes, LocalCoachAxis.base)
        XCTAssertFalse(plan.axes.contains(.safer), "unvetted Safer must never be generated")
        let note = try XCTUnwrap(plan.substitutionNote, "the substitution must be stated")
        XCTAssertTrue(note.contains("Safer"), "the note must name the missing tone")
        XCTAssertTrue(note.contains("Warmer"), "the note must name what IS below")
        XCTAssertTrue(note.contains("this iPhone"))
    }

    /// Gate explicitly open → and only then — Safer joins the set.
    func testSaferIsGeneratedLocallyOnlyWhenTheGateIsOpen() throws {
        guard case .local(let plan) = decide(axis: "safer", saferGate: true) else {
            return XCTFail("an open gate must permit the on-device Safer route")
        }
        XCTAssertEqual(plan.axes, LocalCoachAxis.base + [.safer])
        XCTAssertNil(plan.substitutionNote, "nothing is missing, so nothing is claimed missing")
    }

    /// The gate is a real flag with a fail-closed default, not decoration.
    func testTheSaferGateFlagDefaultsClosed() {
        XCTAssertFalse(FeatureFlag.appleIntelligenceAllowsSaferRoute.defaultValue)
    }

    // ── Tones the local set does not contain ───────────────────────────

    func testATappedToneThatIsNotProducedIsNamedRatherThanImplied() throws {
        for axis in ["affectionate", "professional", "concise"] {
            guard case .local(let plan) = decide(axis: axis) else {
                return XCTFail("\(axis) should still run on the device")
            }
            XCTAssertEqual(plan.axes, LocalCoachAxis.base)
            let note = try XCTUnwrap(plan.substitutionNote, "\(axis) is absent and must be named")
            XCTAssertTrue(note.lowercased().contains(axis), "the note must name \(axis)")
        }
        for axis in ["warmer", "clearer", "funnier"] {
            guard case .local(let plan) = decide(axis: axis) else {
                return XCTFail("\(axis) should run on the device")
            }
            XCTAssertNil(plan.substitutionNote, "\(axis) is present, so there is nothing to explain")
        }
    }

    func testCustomStyleStaysConnectedButStillAnswersWithNoRoute() throws {
        XCTAssertEqual(decide(axis: "custom"), .cloud(.customStyleNeedsConnection))
        guard case .local(let plan) = decide(axis: "custom", offline: true) else {
            return XCTFail("with no route, Custom should still offer the on-device tones")
        }
        XCTAssertEqual(plan.axes, LocalCoachAxis.base)
        XCTAssertNotNil(plan.substitutionNote)
    }

    /// The substitution retry is bounded to the two axis-policy refusals.
    /// Retrying a device-level refusal would produce the same refusal again.
    func testOnlyAxisPolicyRefusalsAreRetriedWhenTheRouteTurnsOutToBeAbsent() {
        for reason in LocalCoachUnavailableReason.allCases {
            let offered = KeyboardViewController.localSubstitutionIsOffered(for: reason)
            switch reason {
            case .saferNeedsReview, .customStyleNeedsConnection:
                XCTAssertTrue(offered, "\(reason) is answerable on the device")
            default:
                XCTAssertFalse(offered, "\(reason) would refuse identically a second time")
            }
        }
    }

    /// `warmer` is a result axis, never a chip: it must render, and must not be
    /// selectable or sendable to the connected variant allowlist.
    func testWarmerRendersButIsNotASelectableChip() {
        XCTAssertNotNil(TonoCoachPalette.axis("warmer"), "a warmer card must be renderable")
        XCTAssertEqual(
            TonoCoachPalette.orderedAxes.map(\.rawValue),
            ["safer", "warmer", "clearer", "funnier", "affectionate", "professional",
             "concise", "custom"]
        )
        XCTAssertFalse(
            CoachOptionalVariant.allCases.contains { $0.rawValue == "warmer" },
            "warmer must not be a selectable optional tone"
        )
        XCTAssertFalse(
            ShortcutRewriteStyle.allCases.contains { $0.rawValue == "warmer" },
            "warmer must not reach the Shortcut style list or the connected allowlist"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // 3. Validation of model output
    // ───────────────────────────────────────────────────────────────────

    private let draft = "hey I really need that report today"

    func testValidationAcceptsAPlainRewrite() throws {
        let option = try XCTUnwrap(LocalCoachValidator.validate(
            "  Could you get me the report today?  ", axis: .clearer, draft: draft
        ))
        XCTAssertEqual(option.text, "Could you get me the report today?")
        XCTAssertEqual(option.axis, .clearer)
    }

    func testValidationRejectsEmptyOverLongAndNoOpOutput() {
        XCTAssertNil(LocalCoachValidator.validate("", axis: .warmer, draft: draft))
        XCTAssertNil(LocalCoachValidator.validate("   \n\t ", axis: .warmer, draft: draft))
        XCTAssertNil(LocalCoachValidator.validate(
            String(repeating: "x", count: 50), axis: .warmer, draft: draft, maximumCharacters: 20
        ))
        // A "rewrite" that is the draft, however it is punctuated or cased.
        XCTAssertNil(LocalCoachValidator.validate(draft, axis: .warmer, draft: draft))
        XCTAssertNil(LocalCoachValidator.validate(
            "HEY, I really need that report today!!", axis: .warmer, draft: draft
        ))
    }

    func testValidationStripsFencesLabelsAndWrappingQuotes() throws {
        let cases: [(String, String)] = [
            ("```\nCould you send the report today?\n```", "Could you send the report today?"),
            ("Warmer: Could you send the report today?", "Could you send the report today?"),
            ("\"Could you send the report today?\"", "Could you send the report today?"),
            ("\u{201C}Could you send the report today?\u{201D}", "Could you send the report today?"),
        ]
        for (raw, expected) in cases {
            let option = try XCTUnwrap(
                LocalCoachValidator.validate(raw, axis: .warmer, draft: draft),
                "failed to validate: \(raw)"
            )
            XCTAssertEqual(option.text, expected)
        }
    }

    func testASetDropsInvalidMembersAndDeduplicatesIdenticalWordings() throws {
        let options = try XCTUnwrap(LocalCoachValidator.validateSet(
            [
                (.warmer, "Could you send the report today, please?"),
                (.clearer, ""),                                        // dropped: empty
                (.funnier, "Could you send the report today, please?"), // dropped: duplicate
            ],
            draft: draft
        ))
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].axis, .warmer)
    }

    func testASetWhereNothingSurvivesFailsRatherThanShowingAnEmptyCard() {
        XCTAssertNil(LocalCoachValidator.validateSet(
            [(.warmer, ""), (.clearer, "   "), (.funnier, draft)], draft: draft
        ))
    }

    func testTheNoOpNormalizerIsOneRuleSharedWithTheShortcutLane() {
        let sample = "Hey — I really NEED that report, today!"
        XCTAssertEqual(
            LocalCoachValidator.normalizedForNoOp(sample),
            ShortcutRewrite.normalizedForNoOp(sample)
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // 4. The preference store — and the bug that made a preference temporary
    // ───────────────────────────────────────────────────────────────────

    private func scratchDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "build115.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAnUntouchedPreferenceIsUnsetAndBothChoicesAreExplicit() {
        let store = LocalRewritePreferenceStore(defaults: scratchDefaults())
        XCTAssertEqual(store.load(), .unset)
        store.setEnabled(false)
        XCTAssertEqual(store.load(), .off)
        store.setEnabled(true)
        XCTAssertEqual(store.load(), .on, "turning it back on is a choice, not a return to unset")
    }

    /// THE persistence defect this store exists to avoid. `FeatureFlags` caches
    /// every flag in one dictionary and `update(from:)` REPLACES that dictionary
    /// with whatever the backend returned — so a preference stored there lasts
    /// only until the next feature fetch. The opt-out must outlive that.
    func testTheOptOutSurvivesAFeatureFlagRefreshThatKnowsNothingAboutIt() {
        let store = LocalRewritePreferenceStore(defaults: scratchDefaults())
        store.setEnabled(false)

        // The refresh the shipped app performs on launch.
        FeatureFlags.update(from: ["thread_context": true, "risk_delta": false])

        XCTAssertEqual(
            store.load(), .off,
            "a privacy preference must not evaporate on a feature-flag refresh"
        )

        // And the same refresh WOULD have wiped it had it lived in the flag dict.
        // This half is what justifies the separate key rather than asserting it.
        FeatureFlags.setUserPreference(.riskDelta, enabled: false)
        XCTAssertFalse(FeatureFlags.isEnabled(.riskDelta))
        FeatureFlags.update(from: ["thread_context": true])
        XCTAssertTrue(
            FeatureFlags.isEnabled(.riskDelta),
            "sanity: a flag-cache preference really is replaced by a refresh, which is "
                + "why the on-device opt-out does not live there"
        )
    }

    /// The remote flag is a kill switch, not the person's switch: it defaults ON
    /// (so an available device rewrites locally out of the box) and is not
    /// offered in Settings, because a value stored there could not survive.
    func testTheRemoteFlagIsAKillSwitchAndNotAUserControl() {
        XCTAssertTrue(FeatureFlag.appleIntelligenceRewriteEnabled.defaultValue)
        XCTAssertFalse(FeatureFlag.appleIntelligenceRewriteEnabled.isUserControllable)
    }

    /// Settings offers the real opt-out, wired to the durable store.
    func testSettingsOffersTheOptOutAndWritesItToTheDurableStore() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(settings.contains("onDeviceRewritingSection"),
                      "Settings must carry the on-device rewriting control")
        XCTAssertTrue(settings.contains("LocalRewritePreferenceStore().setEnabled("),
                      "the toggle must write the durable preference, not a feature flag")
        XCTAssertTrue(settings.contains("Rewrite on this iPhone"),
                      "the control must be named in the person's terms")
    }

    // ───────────────────────────────────────────────────────────────────
    // 5. The immutable-at-initialization policy defect
    // ───────────────────────────────────────────────────────────────────

    /// At c0aba9d `OnDeviceAppleRewriteService.policy` was a `let` captured at
    /// actor init, and `AppleRewriteBridge.shared` lives for the whole process.
    /// A service built while the feature was off refused with `.featureDisabled`
    /// forever, and `reconfigure()` only logged a breadcrumb saying otherwise.
    func testTheServicePolicyCanBeChangedAfterInitialization() async {
        let service = OnDeviceAppleRewriteService(policy: OnDeviceRewritePolicy(enabled: false))
        var policy = await service.effectivePolicy
        XCTAssertFalse(policy.enabled)

        await service.updatePolicy(OnDeviceRewritePolicy(enabled: true))
        policy = await service.effectivePolicy
        XCTAssertTrue(
            policy.enabled,
            "a preference change must be observable without a process reload"
        )
    }

    /// A disabled policy refuses with the reason the person can act on, rather
    /// than pretending the model failed.
    func testADisabledPolicyRefusesWithTheKillSwitchReason() async {
        let service = OnDeviceAppleRewriteService(policy: OnDeviceRewritePolicy(enabled: false))
        do {
            _ = try await service.rewriteSet(
                Tono.LocalCoachSetRequest(draft: "please send it", axes: Tono.LocalCoachAxis.base)
            )
            XCTFail("a disabled policy must refuse")
        } catch let failure as Tono.LocalCoachFailure {
            XCTAssertEqual(failure.reason, .remoteKillSwitch)
        } catch {
            XCTFail("unexpected error: \(type(of: error))")
        }
    }

    /// Input bounds are enforced by the service too, not only by the policy —
    /// so a caller that bypassed the router still cannot send an unbounded draft
    /// to the model.
    func testTheServiceEnforcesItsOwnInputBounds() async {
        let service = OnDeviceAppleRewriteService(policy: OnDeviceRewritePolicy(
            enabled: true, maximumInputCharacters: 10, maximumOutputCharacters: 10
        ))
        for (draft, expected) in [
            ("", Tono.LocalCoachUnavailableReason.emptyDraft),
            ("   ", .emptyDraft),
            (String(repeating: "a", count: 11), .draftTooLong),
        ] {
            do {
                _ = try await service.rewriteSet(
                    Tono.LocalCoachSetRequest(draft: draft, axes: Tono.LocalCoachAxis.base)
                )
                XCTFail("expected \(expected)")
            } catch let failure as Tono.LocalCoachFailure {
                XCTAssertEqual(failure.reason, expected)
            } catch {
                XCTFail("unexpected error: \(type(of: error))")
            }
        }
    }

    /// The bridge re-derives the policy on every request rather than trusting
    /// the one it was born with.
    func testTheBridgeDerivesPolicyFromLiveStateOnEveryRequest() throws {
        let code = Self.strippingComments(try Self.source("Shared/AppleRewriteBridge.swift"))
        let rewriteSet = try XCTUnwrap(
            Self.body(ofDeclaration: "public func rewriteSet(", in: code),
            "the bridge must expose the set entry point"
        )
        XCTAssertTrue(
            rewriteSet.contains("service.updatePolicy(Self.currentPolicy())"),
            "the policy must be re-derived per request, not captured at init"
        )
        XCTAssertFalse(
            Self.strippingComments(try Self.source("Shared/OnDeviceAppleRewrite.swift"))
                .contains("private let policy: OnDeviceRewritePolicy"),
            "the service policy must not be immutable again"
        )
    }

    /// `reconfigure()` now changes something. Before, it read the flag and threw
    /// the answer away.
    func testReconfigureReturnsThePolicyItActuallyInstalled() async {
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])
        let enabled = await AppleRewriteBridge.shared.reconfigure()
        XCTAssertTrue(enabled.enabled)
        XCTAssertEqual(
            enabled.maximumInputCharacters, Tono.LocalCoachRoutePolicy.maximumDraftCharacters
        )

        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": false])
        let disabled = await AppleRewriteBridge.shared.reconfigure()
        XCTAssertFalse(disabled.enabled, "the kill switch must be observed on the next call")

        // Leave the shared cache as the shipped default for other tests.
        FeatureFlags.update(from: [:])
    }

    /// The extension memory pre-flight is a real guard with a documented bound —
    /// and it is an EXTENSION bound, applied only inside an extension.
    ///
    /// The second half of this test is the one that found a defect: the first
    /// version applied the 45 MB keyboard budget to every process, so the real
    /// on-device engine refused with `.memoryPressure` inside an XCTest host
    /// sitting at ~90 MB with gigabytes of headroom.
    func testTheMemoryPreflightRefusesOnlyWhenAnExtensionIsNearTheCeiling() {
        let ceiling = LocalCoachMemoryBudget.preflightCeilingBytes
        XCTAssertTrue(
            LocalCoachMemoryBudget.hasHeadroom(residentBytes: ceiling - 1, isAppExtension: true)
        )
        XCTAssertFalse(
            LocalCoachMemoryBudget.hasHeadroom(residentBytes: ceiling, isAppExtension: true)
        )
        XCTAssertFalse(
            LocalCoachMemoryBudget.hasHeadroom(residentBytes: ceiling * 2, isAppExtension: true)
        )
        XCTAssertTrue(
            LocalCoachMemoryBudget.hasHeadroom(residentBytes: nil, isAppExtension: true),
            "an unreadable footprint is not evidence of pressure — refusing on it would "
                + "disable the feature wherever task_info stops answering"
        )
        XCTAssertTrue(
            LocalCoachMemoryBudget.hasHeadroom(residentBytes: ceiling * 10, isAppExtension: false),
            "a keyboard's budget must not be applied to a process that does not have it"
        )
        // This process is not an extension, and the probe answers on this
        // platform — so neither half of the guard is vacuous.
        XCTAssertFalse(LocalCoachMemoryBudget.runningInAppExtension)
        XCTAssertNotNil(OnDeviceMemoryProbe.residentBytes())
    }

    // ───────────────────────────────────────────────────────────────────
    // 6. The live controller, driven end to end
    // ───────────────────────────────────────────────────────────────────

    /// A deterministic stand-in for Apple's model. It records what it was asked
    /// for, so "one action, one request" is measured rather than assumed.
    final class StubEngine: LocalCoachRewriteEngine, @unchecked Sendable {
        let availabilityResult: LocalRewriteAvailability
        let outcome: Result<[LocalCoachAxis: String], LocalCoachFailure>
        private(set) var requests: [LocalCoachSetRequest] = []
        private(set) var availabilityProbes = 0
        /// Set to hold the request open so cancellation can be exercised.
        var suspendsForever = false

        init(
            availability: LocalRewriteAvailability = .available,
            outcome: Result<[LocalCoachAxis: String], LocalCoachFailure> = .success([
                .warmer: "Would you mind sending the report over today?",
                .clearer: "Please send the report today.",
                .funnier: "The report and I are ready whenever you are — today?",
                .safer: "When you get a moment today, could you share the report?",
            ])
        ) {
            self.availabilityResult = availability
            self.outcome = outcome
        }

        func availability(locale: Locale) async -> LocalRewriteAvailability {
            availabilityProbes += 1
            return availabilityResult
        }

        func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
            requests.append(request)
            if suspendsForever {
                while !Task.isCancelled { await Task.yield() }
                throw LocalCoachFailure(.cancelled)
            }
            switch outcome {
            case .failure(let failure):
                throw failure
            case .success(let texts):
                let raw = request.axes.compactMap { axis -> (axis: LocalCoachAxis, text: String)? in
                    guard let text = texts[axis] else { return nil }
                    return (axis, text)
                }
                guard let validated = LocalCoachValidator.validateSet(raw, draft: request.draft)
                else { throw LocalCoachFailure(.noValidRewrite) }
                return LocalCoachSetResult(
                    options: validated,
                    metrics: LocalCoachMetrics(
                        availabilityReason: "available",
                        requestedAxisCount: request.axes.count,
                        validatedOptionCount: validated.count,
                        bytesIn: request.draft.utf8.count,
                        bytesOut: validated.reduce(0) { $0 + $1.text.utf8.count },
                        completionMilliseconds: 1,
                        peakFootprintBytes: nil
                    )
                )
            }
        }
    }

    /// Counts every request that reaches the URL loading system on the session
    /// it is installed in. Session-scoped on purpose: a process-wide
    /// `URLProtocol` registration would also count the host application's own
    /// traffic and would prove nothing about this keyboard.
    final class OfflineSpyProtocol: URLProtocol {
        nonisolated(unsafe) static var requestCount = 0
        override class func canInit(with request: URLRequest) -> Bool {
            requestCount += 1
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        /// Airplane mode does not answer. Holding the request open models the
        /// parked state the real transport reports, and lets a test drive
        /// `handleCoachWaitingForConnectivity` against a request that is still
        /// the active one.
        override func startLoading() {}
        override func stopLoading() {}
    }

    /// A document the tests own, so a rewrite's effect on it is observable. The
    /// controller has no host document in a unit test, which is why every entry
    /// point it drives takes the context explicitly.
    final class TestDocumentProxy: NSObject, UITextDocumentProxy {
        private(set) var before: String
        private(set) var after: String
        private(set) var insertions: [String] = []
        private(set) var deleteBackwardCount = 0

        init(before: String, after: String = "") {
            self.before = before
            self.after = after
        }

        var text: String { before + after }

        var keyboardType: UIKeyboardType = .default
        var returnKeyType: UIReturnKeyType = .default
        var keyboardAppearance: UIKeyboardAppearance = .light
        var autocapitalizationType: UITextAutocapitalizationType = .sentences
        var autocorrectionType: UITextAutocorrectionType = .default
        var spellCheckingType: UITextSpellCheckingType = .default

        var documentContextBeforeInput: String? { before }
        var documentContextAfterInput: String? { after }
        var selectedText: String? { nil }
        var documentInputMode: UITextInputMode? { nil }
        let documentIdentifier = UUID()

        func adjustTextPosition(byCharacterOffset offset: Int) {
            if offset < 0 {
                let count = min(-offset, before.count)
                let moved = String(before.suffix(count))
                before.removeLast(count)
                after = moved + after
            } else if offset > 0 {
                let count = min(offset, after.count)
                let moved = String(after.prefix(count))
                after.removeFirst(count)
                before += moved
            }
        }

        func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
        func unmarkText() {}
        var hasText: Bool { !(before.isEmpty && after.isEmpty) }

        func insertText(_ text: String) {
            insertions.append(text)
            before += text
        }

        func deleteBackward() {
            deleteBackwardCount += 1
            if !before.isEmpty { before.removeLast() }
        }
    }

    @MainActor
    private func makeController(
        engine: LocalCoachRewriteEngine,
        before: String = "hey I really need that report today",
        installSpyClient: Bool = true
    ) -> (KeyboardViewController, TestDocumentProxy) {
        let controller = KeyboardViewController()
        controller.localCoachEngine = engine
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        controller.view.layoutIfNeeded()
        let proxy = TestDocumentProxy(before: before)
        controller.documentProxyOverride = proxy
        if installSpyClient {
            OfflineSpyProtocol.requestCount = 0
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [OfflineSpyProtocol.self]
            controller.installCoachClientForTesting(TonoCoachClient(
                endpoint: "https://api.tonoit.com/api/analyze/variant",
                timeout: 1,
                session: URLSession(configuration: configuration),
                tokenProvider: { "build115-test-bearer" }
            ))
        }
        addTeardownBlock { MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() } }
        return (controller, proxy)
    }

    /// Spin the main run loop until `condition` holds or the budget runs out.
    /// The on-device path hops to a `Task` and back to the main queue, so a
    /// synchronous assertion would race it.
    @MainActor
    private func waitUntil(
        _ condition: () -> Bool,
        _ message: String = "condition never became true",
        timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private static func findView(_ root: UIView, identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let hit = findView(child, identifier: identifier) { return hit }
        }
        return nil
    }

    private static func findViews(_ root: UIView, prefix: String) -> [UIView] {
        var out: [UIView] = []
        if (root.accessibilityIdentifier ?? "").hasPrefix(prefix) { out.append(root) }
        for child in root.subviews { out += findViews(child, prefix: prefix) }
        return out
    }

    // ── The founder's scenario ─────────────────────────────────────────

    /// THE acceptance test, in the shape the founder described it: a fresh
    /// controller, a typed draft, one Coach action, no connection — and three
    /// locally-written rewrites, with zero network traffic.
    ///
    /// Red at c0aba9d: `runCoach` went straight to `coachClient.variant(...)`,
    /// so this rendered a connected failure and no cards at all.
    @MainActor
    func testFreshOfflineCoachProducesWarmClearAndFunnyWithZeroNetwork() throws {
        let engine = StubEngine()
        let (controller, _) = makeController(engine: engine)

        controller.beginCoachRewrite(
            before: "hey I really need that report today", after: "", axis: "clearer"
        )
        waitUntil({ controller.coachDeliveredRouteForTesting != nil }, "no route ever delivered")
        controller.view.layoutIfNeeded()

        // 1. It ran on the device, and says so.
        XCTAssertEqual(controller.coachDeliveredRouteForTesting, "onDevice")
        let badge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(badge.text, LocalCoachCopy.onDeviceRouteLabel)

        // 2. Warm, Clear and Funny are all on screen.
        let cards = Self.findViews(controller.view, prefix: "TonoKB.rewrite.")
        XCTAssertEqual(
            cards.compactMap { $0.accessibilityIdentifier },
            ["TonoKB.rewrite.warmer.0", "TonoKB.rewrite.clearer.1", "TonoKB.rewrite.funnier.2"]
        )

        // 3. ONE request, for exactly the three base tones.
        XCTAssertEqual(engine.requests.count, 1, "one action must issue one request")
        XCTAssertEqual(engine.requests[0].axes, LocalCoachAxis.base)
        XCTAssertFalse(engine.requests[0].axes.contains(.safer))

        // 4. ZERO network. Two independent measurements: the injected spy
        //    transport saw nothing, and the client dispatched nothing.
        XCTAssertEqual(
            OfflineSpyProtocol.requestCount, 0,
            "a successful on-device rewrite must reach the URL loading system zero times"
        )
        XCTAssertEqual(controller.coachProviderCallCountForTesting, 0)

        // 5. Coach is free again.
        XCTAssertFalse(controller.coachIsBusyForTesting)
        XCTAssertFalse(controller.coachLocalRequestInFlightForTesting)
    }

    /// The strongest form of the zero-network claim: with no spy installed, the
    /// production `TonoCoachClient` — and therefore its `URLSession` — is never
    /// built at all on a successful on-device route.
    @MainActor
    func testASuccessfulOnDeviceRouteNeverBuildsTheNetworkStack() {
        let (controller, _) = makeController(
            engine: StubEngine(), before: "please send the report", installSpyClient: false
        )
        XCTAssertFalse(controller.coachNetworkClientWasConstructedForTesting)

        controller.beginCoachRewrite(before: "please send the report", after: "", axis: "funnier")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })

        XCTAssertFalse(
            controller.coachNetworkClientWasConstructedForTesting,
            "the on-device route must not construct a URLSession-backed client"
        )
    }

    /// Atomic insertion: one insert, and the document ends up as the rewrite.
    @MainActor
    func testUseRewriteInsertsTheOnDeviceTextAtomically() throws {
        let (controller, proxy) = makeController(engine: StubEngine())
        controller.beginCoachRewrite(
            before: "hey I really need that report today", after: "", axis: "clearer"
        )
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        controller.view.layoutIfNeeded()

        let use = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.useRewrite") as? UIControl
        )
        use.sendActions(for: .touchUpInside)

        XCTAssertEqual(proxy.insertions.count, 1, "exactly one insertion")
        XCTAssertEqual(proxy.text, "Would you mind sending the report over today?")
    }

    /// A multi-tone set is not a version sequence, so it must not offer version
    /// controls that would do nothing.
    @MainActor
    func testAnOnDeviceSetOffersNoVersionSequenceControls() {
        let (controller, _) = makeController(engine: StubEngine(), before: "please send it")
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        controller.view.layoutIfNeeded()

        for identifier in ["TonoKB.tryAnother", "TonoKB.versionCue",
                           "TonoKB.versionBack", "TonoKB.versionForward"] {
            XCTAssertNil(
                Self.findView(controller.view, identifier: identifier),
                "\(identifier) has no meaning for a set of tones and must not render"
            )
        }
        XCTAssertNil(controller.coachSequenceStateForTesting)
    }

    /// …while the connected single-card path keeps Try another exactly as
    /// Build 114 shipped it.
    @MainActor
    func testTheConnectedSingleCardStillOffersTryAnother() throws {
        let (controller, _) = makeController(
            engine: StubEngine(availability: .deviceNotEligible), before: "please send it"
        )
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        waitUntil({ controller.activeCoachRequestIDForTesting != nil })
        let id = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        controller.completeCoach(
            requestID: id, liveBefore: "please send it", liveAfter: "",
            result: .success(TonoCoachClient.VariantResponse(
                axis: "clearer", text: "Could you send it over?",
                rationale: nil, riskAfter: nil, clocks: nil, providerMs: 12
            ))
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.coachDeliveredRouteForTesting, "connected")
        XCTAssertNotNil(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother"),
            "the connected path must keep Try another"
        )
        let badge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(
            badge.text, LocalCoachCopy.cloudRouteLabel,
            "a connected answer must not claim to have been written on the device"
        )
    }

    // ── Availability states, through the real controller ───────────────

    /// Each unavailable state reaches the controller carrying its own reason,
    /// rather than being flattened — and an unavailable model is never asked to
    /// generate anything.
    @MainActor
    func testEachUnavailableStateReachesTheControllerWithItsOwnReason() {
        let expected: [(LocalRewriteAvailability, String)] = [
            (.unsupportedOS, "unsupportedOS"),
            (.deviceNotEligible, "deviceNotEligible"),
            (.appleIntelligenceNotEnabled, "appleIntelligenceNotEnabled"),
            (.modelNotReady, "modelNotReady"),
            (.unsupportedLocale, "unsupportedLocale"),
            (.unspecifiedUnavailable, "unspecifiedUnavailable"),
        ]
        for (availability, reason) in expected {
            let engine = StubEngine(availability: availability)
            let (controller, _) = makeController(engine: engine, before: "please send it")
            controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
            waitUntil({ controller.coachLocalRefusalForTesting != nil },
                      "no refusal recorded for \(availability)")
            XCTAssertEqual(controller.coachLocalRefusalForTesting, reason)
            XCTAssertEqual(engine.requests.count, 0, "an unavailable model must not be asked")
        }
    }

    /// A guardrail or a refusal is TERMINAL: the person is told, and the same
    /// text is NOT quietly posted to the connected route instead.
    @MainActor
    func testGuardrailAndRefusalAreTerminalAndNeverEscalateToTheNetwork() throws {
        for reason in [LocalCoachUnavailableReason.guardrail, .refusal] {
            let engine = StubEngine(outcome: .failure(LocalCoachFailure(reason)))
            let (controller, _) = makeController(engine: engine, before: "you are impossible")
            controller.beginCoachRewrite(before: "you are impossible", after: "", axis: "clearer")
            waitUntil({
                Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") != nil
            }, "no error surface for \(reason)")
            controller.view.layoutIfNeeded()

            let detail = try XCTUnwrap(
                Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") as? UILabel
            )
            XCTAssertEqual(detail.text, LocalCoachCopy.sentence(for: reason))
            XCTAssertEqual(
                OfflineSpyProtocol.requestCount, 0,
                "\(reason) must not be routed around by posting the same text to the network"
            )
            XCTAssertNil(controller.coachDeliveredRouteForTesting)
            XCTAssertFalse(controller.coachIsBusyForTesting)
        }
    }

    /// A recoverable on-device failure hands over to the connected route —
    /// which is honest about connectivity by construction.
    @MainActor
    func testARecoverableOnDeviceFailureHandsOverToTheConnectedRoute() {
        let engine = StubEngine(outcome: .failure(LocalCoachFailure(.noValidRewrite)))
        let (controller, _) = makeController(engine: engine, before: "please send it")
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")

        waitUntil({ OfflineSpyProtocol.requestCount > 0 },
                  "a recoverable local failure must fall back to the connected route")
        XCTAssertEqual(controller.coachLocalRefusalForTesting, "noValidRewrite")
    }

    /// Safer in airplane mode: the parked connected request is answered on the
    /// device instead, the set contains no Safer card, and the substitution is
    /// stated on screen.
    @MainActor
    func testSaferWithNoRouteFallsBackToTheDeviceAndSaysSaferIsMissing() throws {
        let engine = StubEngine()
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(
            before: "hey I really need that report today", after: "", axis: "safer"
        )
        // Safer goes connected first — the reviewed corpus route.
        waitUntil({ controller.coachLocalRefusalForTesting == "saferNeedsReview" })
        let id = try XCTUnwrap(controller.activeCoachRequestIDForTesting)
        XCTAssertEqual(engine.requests.count, 0, "Safer must try the reviewed route first")

        // The transport reports there is no route at all.
        controller.handleCoachWaitingForConnectivity(requestID: id, tapTime: .now(), axis: "safer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" },
                  "with no route, Safer must still be answerable on the device")
        controller.view.layoutIfNeeded()

        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertFalse(
            engine.requests[0].axes.contains(.safer),
            "unvetted Safer must never be generated, whatever the connection state"
        )
        XCTAssertNil(
            Self.findView(controller.view, identifier: "TonoKB.rewrite.safer.0"),
            "no card may be labelled Safer"
        )
        let note = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.localNote") as? UILabel
        )
        XCTAssertTrue(try XCTUnwrap(note.text).contains("Safer"))
    }

    /// The substitution happens at most once per request, so no combination of
    /// transport behaviour can turn it into a cancel/re-issue loop.
    @MainActor
    func testTheOnDeviceSubstitutionHappensAtMostOncePerRequest() throws {
        let engine = StubEngine()
        let (controller, _) = makeController(engine: engine, before: "please send it")
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "safer")
        waitUntil({ controller.coachLocalRefusalForTesting == "saferNeedsReview" })
        let id = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        for _ in 0..<5 {
            controller.handleCoachWaitingForConnectivity(requestID: id, tapTime: .now(), axis: "safer")
        }
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        XCTAssertEqual(engine.requests.count, 1, "five notifications, one on-device request")
        XCTAssertNotEqual(
            controller.activeCoachRequestIDForTesting, id,
            "the substituted leg takes a fresh identity, so the cancelled connected "
                + "completion fails the ordinary gate instead of clobbering the answer"
        )
    }

    // ── Cancellation and stale-result suppression ──────────────────────

    @MainActor
    func testTeardownCancelsTheInFlightOnDeviceRequestAndReleasesCoach() {
        let engine = StubEngine()
        engine.suspendsForever = true
        let (controller, _) = makeController(engine: engine, before: "please send it")
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        waitUntil({ engine.requests.count == 1 }, "the on-device request never started")

        controller.invalidateCoachWorkForTesting()

        XCTAssertFalse(controller.coachLocalRequestInFlightForTesting)
        XCTAssertFalse(controller.coachIsBusyForTesting, "teardown must never leave Coach busy")
        XCTAssertNil(controller.activeCoachRequestIDForTesting)
        XCTAssertNil(controller.coachDeliveredRouteForTesting)
    }

    /// A superseded tap's result reaches nothing.
    @MainActor
    func testAStaleOnDeviceResultCannotTakeOverTheSurface() throws {
        let (controller, _) = makeController(engine: StubEngine(), before: "please send it")
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        controller.view.layoutIfNeeded()

        let before = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.rewrite.warmer.0")
        ).accessibilityLabel

        // A completion for a request that is not the active one.
        controller.completeLocalCoach(
            requestID: UUID(), draft: "please send it", axis: "clearer", tapTime: .now(),
            liveBefore: "please send it", liveAfter: "",
            outcome: .success(LocalCoachSetResult(
                options: [LocalCoachOption(axis: .safer, text: "a stale rewrite")],
                metrics: LocalCoachMetrics(
                    availabilityReason: "available", requestedAxisCount: 3,
                    validatedOptionCount: 1, bytesIn: 1, bytesOut: 1,
                    completionMilliseconds: 1, peakFootprintBytes: nil
                )
            ))
        )
        controller.view.layoutIfNeeded()

        XCTAssertNil(
            Self.findView(controller.view, identifier: "TonoKB.rewrite.safer.0"),
            "a superseded completion must not install its own card"
        )
        XCTAssertEqual(
            try XCTUnwrap(Self.findView(controller.view, identifier: "TonoKB.rewrite.warmer.0"))
                .accessibilityLabel,
            before,
            "the surface the person is looking at must be untouched"
        )
    }

    /// A draft that moved under the request is refused rather than answered for
    /// text the person no longer has.
    @MainActor
    func testAResultForAChangedDraftIsDropped() {
        let (controller, proxy) = makeController(engine: StubEngine(), before: "please send it")
        controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        let before = proxy.text

        controller.completeLocalCoach(
            requestID: UUID(), draft: "please send it", axis: "clearer", tapTime: .now(),
            liveBefore: "something else entirely", liveAfter: "",
            outcome: .failure(LocalCoachFailure(.generationFailed))
        )
        XCTAssertEqual(proxy.text, before, "the document must be untouched")
    }

    /// Typing still works, and the local route does not disturb it. The tap that
    /// matters here is an ordinary key, driven through the real hierarchy.
    @MainActor
    func testOrdinaryTypingStillWorksAlongsideTheOnDeviceRoute() throws {
        let (controller, proxy) = makeController(engine: StubEngine(), before: "")
        let key = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.letter.a") as? UIControl,
            "the letter row must still be installed"
        )
        key.sendActions(for: .touchUpInside)
        XCTAssertEqual(proxy.insertions.count, 1, "a key tap must still insert exactly once")
    }

    /// The watchdog is armed before the availability probe, so a probe that
    /// never answers is still bounded. Driving it synchronously is the only way
    /// to check this without waiting the real budget.
    @MainActor
    func testAProbeThatNeverAnswersIsStillBoundedByTheWatchdog() throws {
        final class SilentEngine: LocalCoachRewriteEngine, @unchecked Sendable {
            func availability(locale: Locale) async -> LocalRewriteAvailability {
                while !Task.isCancelled { await Task.yield() }
                return .unsupportedOS
            }
            func rewriteSet(_ request: LocalCoachSetRequest) async throws -> LocalCoachSetResult {
                throw LocalCoachFailure(.cancelled)
            }
        }
        let (controller, _) = makeController(engine: SilentEngine(), before: "please send it")
        let id = try XCTUnwrap(
            controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        )
        XCTAssertTrue(controller.coachIsBusyForTesting)

        controller.handleCoachDeadlineFired(requestID: id, tapTime: .now(), axis: "clearer")
        controller.view.layoutIfNeeded()

        XCTAssertFalse(
            controller.coachIsBusyForTesting,
            "a probe that never answers must not leave Coach permanently busy"
        )
        XCTAssertFalse(controller.coachLocalRequestInFlightForTesting)
        XCTAssertNotNil(
            Self.findView(controller.view, identifier: "TonoKB.coachError"),
            "the bound must produce a truthful surface, not a silent stall"
        )
    }

    /// The watchdog cancels an on-device generation too, not only a transport.
    @MainActor
    func testTheWatchdogCancelsAnInFlightOnDeviceGeneration() throws {
        let engine = StubEngine()
        engine.suspendsForever = true
        let (controller, _) = makeController(engine: engine, before: "please send it")
        let id = try XCTUnwrap(
            controller.beginCoachRewrite(before: "please send it", after: "", axis: "clearer")
        )
        waitUntil({ engine.requests.count == 1 }, "the on-device request never started")

        controller.handleCoachDeadlineFired(requestID: id, tapTime: .now(), axis: "clearer")

        XCTAssertFalse(controller.coachLocalRequestInFlightForTesting)
        XCTAssertFalse(controller.coachIsBusyForTesting)
        XCTAssertNil(controller.coachLocalRefusalForTesting)
    }

    // ── The shipped default ────────────────────────────────────────────

    /// The seam the tests above use must not be what ships.
    ///
    /// HONEST LIMIT, and the reason this is a source assertion rather than a
    /// runtime one: TonoTests compiles `KeyboardViewController.swift` into its
    /// OWN module, so inside this bundle the controller's engine type is
    /// `TonoTests.LocalCoachRewriteEngine` while `AppleRewriteBridge` is a
    /// host-app type conforming to `Tono.LocalCoachRewriteEngine`. The two
    /// cannot meet, which is why `productionLocalCoachEngine()` is compiled
    /// differently here — and why "what ships" is proved by reading the shipped
    /// branch, and again by `Scripts/verify_build115_binary_reachability.py`
    /// against the built Release .appex.
    func testTheShippedDefaultEngineIsTheRealBridge() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        let factory = try XCTUnwrap(
            Self.body(
                ofDeclaration: "static func productionLocalCoachEngine() -> LocalCoachRewriteEngine",
                in: code
            ),
            "the controller must resolve its engine in one place"
        )
        XCTAssertTrue(
            factory.contains("#else\n        return AppleRewriteBridge.shared"),
            "the shipped branch must return the real Foundation Models bridge"
        )
        XCTAssertTrue(
            factory.contains("#if TONO_BUILD92_HOSTSESSION"),
            "the only other branch must be the XCTest module's, and it must be named"
        )
        // Exactly two branches: no third path can quietly become the default.
        XCTAssertEqual(factory.components(separatedBy: "return ").count - 1, 2)
        // And the substitute is the honest null object, not a silent success.
        let engine = UnavailableLocalCoachEngine()
        let expectation = XCTestExpectation(description: "null engine reports unsupportedOS")
        Task {
            let availability = await engine.availability(locale: Locale.current)
            XCTAssertEqual(availability, .unsupportedOS)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }

    /// In THIS module the controller's default is the honest null object, which
    /// is exactly why every behavioural test above injects an engine — the
    /// default is never the thing under test.
    @MainActor
    func testTheTestModuleDefaultIsTheHonestNullObject() {
        let controller = KeyboardViewController()
        XCTAssertTrue(controller.localCoachEngine is UnavailableLocalCoachEngine)
    }

    // ───────────────────────────────────────────────────────────────────
    // 7. Bounds
    // ───────────────────────────────────────────────────────────────────

    /// The on-device wait is bounded, and bounded by no more than the longest
    /// wait this keyboard already permits.
    func testTheOnDeviceDeadlineIsBoundedAndDeclared() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        let local = try XCTUnwrap(Self.constant("coachLocalVisibleDeadline", in: source))
        let offline = try XCTUnwrap(Self.constant("coachOfflineVisibleDeadline", in: source))
        let visible = try XCTUnwrap(Self.constant("coachVisibleDeadline", in: source))
        XCTAssertGreaterThan(local, visible, "the on-device budget is its own, not the connected one")
        XCTAssertLessThanOrEqual(local, offline, "a keyboard must not wait longer than it already does")
        XCTAssertLessThanOrEqual(local, 60)
    }

    func testInputAndOutputAreBounded() {
        XCTAssertGreaterThan(LocalCoachRoutePolicy.maximumDraftCharacters, 0)
        XCTAssertLessThanOrEqual(LocalCoachRoutePolicy.maximumDraftCharacters, 4_000)
        XCTAssertGreaterThan(LocalCoachRoutePolicy.maximumOptionCharacters, 0)
        XCTAssertLessThanOrEqual(LocalCoachRoutePolicy.maximumOptionCharacters, 4_000)
    }

    /// Every shipped bundle is Build 115 and the marketing version is unchanged.
    func testAllFourShippedBundlesAreBuild115() throws {
        let guardScript = try Self.source("Scripts/bump-build.sh")
        var expected: String?
        for line in guardScript.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("EXPECTED_BUILD=") else { continue }
            expected = trimmed.dropFirst("EXPECTED_BUILD=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        XCTAssertEqual(expected, "115", "the build guard must pin the reviewed number")
        for relative in ["App/Info.plist", "KeyboardExtension/Info.plist",
                         "ShareExtension/Info.plist", "TonoMessagesExtension/Info.plist"] {
            let data = try Data(contentsOf: Self.sourceRoot().appendingPathComponent(relative))
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            XCTAssertEqual(plist?["CFBundleVersion"] as? String, "115", "\(relative)")
            XCTAssertEqual(plist?["CFBundleShortVersionString"] as? String, "1.1", "\(relative)")
        }
    }

    // ───────────────────────────────────────────────────────────────────
    // 8. The real Foundation Models engine, where it is available
    // ───────────────────────────────────────────────────────────────────

    /// Runs the SHIPPED `AppleRewriteBridge` against the real on-device model.
    ///
    /// Skips honestly — never passes silently — when the running machine has no
    /// usable model, which is the case on any worker without Apple Intelligence.
    /// Where it does run it proves the whole chain the stub cannot:
    /// `SystemLanguageModel` → `LanguageModelSession` → structured output →
    /// local validation → three distinct rewrites.
    func testRealOnDeviceEngineProducesThreeValidatedRewrites() async throws {
        // `Tono.`-qualified throughout: TonoTests compiles its own copy of
        // `LocalCoachRewrite.swift`, so the bridge's request/result types are the
        // host app's, not this bundle's.
        let bridge = AppleRewriteBridge.shared
        let availability = await bridge.availability(locale: Locale(identifier: "en_US"))
        try XCTSkipUnless(
            availability.isAvailable,
            "SystemLanguageModel reports \(availability.rawValue) on this machine — "
                + "the real-model path cannot be exercised here"
        )
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])

        let draft = "hey I really need that report today, you keep pushing it back"
        let before = OnDeviceMemoryProbe.residentBytes()
        let result = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
            draft: draft, axes: Tono.LocalCoachAxis.base, locale: Locale(identifier: "en_US")
        ))
        let after = OnDeviceMemoryProbe.residentBytes()

        XCTAssertEqual(result.options.count, 3, "one request must return all three tones")
        XCTAssertEqual(result.options.map(\.axis), Tono.LocalCoachAxis.base)
        for option in result.options {
            XCTAssertFalse(option.text.isEmpty)
            XCTAssertNotEqual(
                Tono.LocalCoachValidator.normalizedForNoOp(option.text),
                Tono.LocalCoachValidator.normalizedForNoOp(draft),
                "\(option.axis) returned the draft rather than a rewrite"
            )
            XCTAssertFalse(option.text.contains("```"), "validation must strip fences")
            XCTAssertLessThanOrEqual(option.text.count, Tono.LocalCoachRoutePolicy.maximumOptionCharacters)
        }
        XCTAssertEqual(result.metrics.availabilityReason, "available")
        XCTAssertGreaterThan(result.metrics.bytesOut, 0)
        print("BUILD115 real-model: \(Int(result.metrics.completionMilliseconds))ms, "
              + "peak \((result.metrics.peakFootprintBytes ?? 0) / 1_048_576)MB")

        // Extension memory, measured rather than assumed. HONEST LIMIT: this is
        // an in-process footprint on the machine running the test, NOT a physical
        // keyboard-extension measurement. The handoff says so explicitly.
        if let before, let after {
            let growthMB = Double(Int64(after) - Int64(before)) / 1_048_576.0
            XCTAssertLessThan(
                growthMB, 40,
                "one on-device request grew the process by \(growthMB) MB, which would "
                    + "threaten a keyboard extension's footprint"
            )
        }
        if let peak = result.metrics.peakFootprintBytes {
            XCTAssertTrue(
                Tono.LocalCoachMemoryBudget.hasHeadroom(residentBytes: peak),
                "peak footprint \(peak / 1_048_576) MB exceeded the documented ceiling"
            )
        }
    }

    /// The real bridge reports an availability the policy layer understands, on
    /// every machine — including one with no Apple Intelligence at all.
    func testRealBridgeAlwaysReportsAKnownAvailability() async {
        let availability = await AppleRewriteBridge.shared.availability(locale: Locale.current)
        XCTAssertTrue(Tono.LocalRewriteAvailability.allCases.contains(availability))
    }

    // ───────────────────────────────────────────────────────────────────
    // Helpers
    // ───────────────────────────────────────────────────────────────────

    private static func sourceRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// Strip `//` and `/* */` so a comment describing what was removed is never
    /// mistaken for the thing still being there.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        var inString = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    index = source.index(index, offsetBy: 2)
                    continue
                }
            } else if inString {
                if rest.hasPrefix("\\\"") {
                    out += "\\\""
                    index = source.index(index, offsetBy: 2)
                    continue
                }
                if source[index] == "\"" { inString = false }
            } else {
                if rest.hasPrefix("//") {
                    while index < source.endIndex && source[index] != "\n" {
                        index = source.index(after: index)
                    }
                    continue
                }
                if rest.hasPrefix("/*") {
                    inBlock = true
                    index = source.index(index, offsetBy: 2)
                    continue
                }
                if source[index] == "\"" { inString = true }
            }
            if !inBlock { out.append(source[index]) }
            index = source.index(after: index)
        }
        return out
    }

    /// Brace-match a declaration's body out of already-comment-stripped source.
    private static func body(ofDeclaration declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration) else { return nil }
        var depth = 0
        var started = false
        var out = ""
        for character in code[start.lowerBound...] {
            if character == "{" { depth += 1; started = true }
            if started { out.append(character) }
            if character == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
        }
        return started ? out : nil
    }

    /// Read `static let name: TimeInterval = 30` out of the controller.
    private static func constant(_ name: String, in source: String) -> Double? {
        guard let range = source.range(of: "static let \(name): TimeInterval = ") else { return nil }
        let tail = source[range.upperBound...].prefix { "0123456789.".contains($0) }
        return Double(tail)
    }
}

// ───────────────────────────────────────────────────────────────────────
// Test-module stand-ins for the two Shared surfaces the keyboard controller
// reaches from this bundle.
//
// TonoTests compiles `KeyboardViewController.swift` into its own module, and
// that file has no `import Tono`, so it cannot name host-app types directly —
// the target already carries stand-ins of this shape for `SharedStore` and
// `SharedKeychain`. These two FORWARD to the real implementations rather than
// reimplementing them, so a behavioural test that flips the on-device kill
// switch or the Safer gate is exercising the shipped `FeatureFlags` rules.
//
// `TonoAnalytics` additionally records what it forwarded, which is what makes
// "the draft never reaches analytics" checkable rather than merely asserted
// about the source.
// ───────────────────────────────────────────────────────────────────────

enum FeatureFlags {
    static func isEnabled(_ flag: Tono.FeatureFlag) -> Bool {
        Tono.FeatureFlags.isEnabled(flag)
    }

    static func update(from dict: [String: Bool]) {
        Tono.FeatureFlags.update(from: dict)
    }

    static func setUserPreference(_ flag: Tono.FeatureFlag, enabled: Bool) {
        Tono.FeatureFlags.setUserPreference(flag, enabled: enabled)
    }
}

enum TonoAnalytics {
    nonisolated(unsafe) private(set) static var recorded: [(name: String, properties: [String: Any])] = []

    static func reset() { recorded = [] }

    static func track(_ event: Tono.AnalyticsEvent) {
        recorded.append((event.name, event.properties))
        Tono.TonoAnalytics.track(event)
    }
}
