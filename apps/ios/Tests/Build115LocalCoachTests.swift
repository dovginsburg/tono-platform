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
    /// BUILD 116 UPDATE — the expected plan, and only the expected plan.
    ///
    /// Build 115 answered every tap with one flat `LocalCoachAxis.base` set.
    /// Build 116 asks for the SELECTED tone first and the rest behind it, so
    /// the plan for a Clearer tap is Clearer, then Warmer and Funnier. The
    /// contract this test is actually about — every availability state reports
    /// itself rather than a generic failure — is unchanged and still exhaustive.
    func testEveryAvailabilityStateMapsToItsOwnReason() {
        XCTAssertEqual(decide(availability: .available), .local(
            LocalCoachPlan(
                primaryAxis: .clearer, secondaryAxes: [.warmer, .funnier],
                substitutionNote: nil
            )
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
        // BUILD 116 — the fourth case is an explicit ON, so it resolves the
        // switch exactly as `.on` does. What it adds is asserted separately in
        // `Build116SelectedFirstTests`.
        XCTAssertTrue(LocalRewritePreference.onlyOnDevice.isExplicit)
        XCTAssertTrue(LocalRewritePreference.onlyOnDevice.resolved(availability: .available))
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
        // BUILD 116 — and the substitute is staged like any other plan: the
        // first tone that CAN be written here leads, the rest follow it.
        XCTAssertEqual(plan.primaryAxis, .warmer)
        XCTAssertEqual(plan.secondaryAxes, [.clearer, .funnier])
        XCTAssertFalse(plan.axes.contains(.safer), "unvetted Safer must never be generated")
        let note = try XCTUnwrap(plan.substitutionNote, "the substitution must be stated")
        XCTAssertTrue(note.contains("Safer"), "the note must name the missing tone")
        XCTAssertTrue(note.contains("Warmer"), "the note must name what IS below")
        // BUILD 116 (physical-iPad correction) — platform-neutral. Dov read
        // "this iPhone" on an iPad; the copy now says "this device", which is
        // true everywhere Tono runs.
        XCTAssertTrue(note.contains("this device"))
        XCTAssertFalse(note.contains("iPhone"), "no device-name wording may remain")
    }

    /// Gate explicitly open → and only then — Safer joins the set.
    ///
    /// BUILD 116 UPDATE — and it joins it FIRST, because it is the tone that
    /// was tapped. Build 115 appended it after the base three.
    func testSaferIsGeneratedLocallyOnlyWhenTheGateIsOpen() throws {
        guard case .local(let plan) = decide(axis: "safer", saferGate: true) else {
            return XCTFail("an open gate must permit the on-device Safer route")
        }
        XCTAssertEqual(plan.primaryAxis, .safer, "the tapped tone leads")
        XCTAssertEqual(plan.secondaryAxes, LocalCoachAxis.base)
        XCTAssertEqual(plan.axes, [.safer] + LocalCoachAxis.base)
        XCTAssertNil(plan.substitutionNote, "nothing is missing, so nothing is claimed missing")
    }

    /// The gate is a real flag with a fail-closed default, not decoration.
    func testTheSaferGateFlagDefaultsClosed() {
        XCTAssertFalse(FeatureFlag.appleIntelligenceAllowsSaferRoute.defaultValue)
    }

    // ── Tones the local set does not contain ───────────────────────────

    /// BUILD 116 UPDATE — this test encoded the superseded answer, and the
    /// change is the point of the build rather than a side effect of it.
    ///
    /// Build 115 ran Affectionate, Professional and Concise on the device
    /// anyway, produced Warmer/Clearer/Funnier, and named the substitution in a
    /// caption. Truthful, and still the wrong answer: the tone someone picked
    /// IS the request, and a set that does not contain it is a different
    /// request rather than a smaller one. Build 116 sends those tones to the
    /// connected route, which produces the tone that was actually tapped — and
    /// keeps the Build 115 substitution for the case where the transport has
    /// PROVED there is no route, because then the alternative is no answer at
    /// all. Both halves are asserted here.
    func testATappedToneThatIsNotProducedGoesToTheRouteThatCanProduceIt() throws {
        for axis in ["affectionate", "professional", "concise"] {
            XCTAssertEqual(
                decide(axis: axis), .cloud(.toneNeedsConnection),
                "\(axis) must be fetched as \(axis), not substituted for"
            )
            guard case .local(let plan) = decide(axis: axis, offline: true) else {
                return XCTFail("with no route at all, \(axis) should still get the local tones")
            }
            XCTAssertEqual(plan.axes, LocalCoachAxis.base)
            XCTAssertEqual(plan.primaryAxis, .warmer)
            let note = try XCTUnwrap(plan.substitutionNote, "\(axis) is absent and must be named")
            XCTAssertTrue(note.lowercased().contains(axis), "the note must name \(axis)")
        }
        for axis in ["warmer", "clearer", "funnier"] {
            guard case .local(let plan) = decide(axis: axis) else {
                return XCTFail("\(axis) should run on the device")
            }
            XCTAssertEqual(plan.primaryAxis.rawValue, axis, "the tapped tone leads its own plan")
            XCTAssertNil(plan.substitutionNote, "\(axis) is present, so there is nothing to explain")
        }
    }

    func testCustomStyleStaysConnectedButStillAnswersWithNoRoute() throws {
        XCTAssertEqual(decide(axis: "custom"), .cloud(.customStyleNeedsConnection))
        guard case .local(let plan) = decide(axis: "custom", offline: true) else {
            return XCTFail("with no route, Custom should still offer the on-device tones")
        }
        XCTAssertEqual(plan.axes, LocalCoachAxis.base)
        XCTAssertEqual(plan.primaryAxis, .warmer)
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
        XCTAssertTrue(settings.contains("Rewrite on this device"),
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
    ///
    /// BUILD 116 UPDATE — same scenario, same three tones, same zero network.
    /// Two things changed and both are the build's purpose: the TAPPED tone is
    /// now the first card rather than the second, and the three tones arrive as
    /// three sequential requests rather than one. Everything this test was
    /// written to protect — a fresh controller, one action, locally-written
    /// rewrites, and nothing reaching the URL loading system — is asserted
    /// exactly as before.
    @MainActor
    func testFreshOfflineCoachProducesWarmClearAndFunnyWithZeroNetwork() throws {
        let engine = StubEngine()
        let (controller, _) = makeController(engine: engine)

        controller.beginCoachRewrite(
            before: "hey I really need that report today", after: "", axis: "clearer"
        )
        waitUntil({ controller.coachDeliveredRouteForTesting != nil }, "no route ever delivered")
        waitUntil(
            { controller.coachSecondaryAxesForTesting.count == 2 },
            "the two secondary tones never arrived"
        )
        controller.view.layoutIfNeeded()

        // 1. It ran on the device, and says so.
        XCTAssertEqual(controller.coachDeliveredRouteForTesting, "onDevice")
        let badge = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachRoute") as? UILabel
        )
        XCTAssertEqual(badge.text, LocalCoachCopy.onDeviceRouteLabel)

        // 2. Warm, Clear and Funny are all on screen — with the tapped tone
        //    first, which is the Build 116 contract.
        let cards = Self.findViews(controller.view, prefix: "TonoKB.rewrite.")
        XCTAssertEqual(
            cards.compactMap { $0.accessibilityIdentifier },
            ["TonoKB.rewrite.clearer.0", "TonoKB.rewrite.warmer.1", "TonoKB.rewrite.funnier.2"]
        )

        // 3. One request per tone, the selected one first, and never Safer.
        XCTAssertEqual(engine.requests.map(\.axes), [[.clearer], [.warmer], [.funnier]])
        XCTAssertFalse(engine.requests.contains { $0.axes.contains(.safer) })

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
        // BUILD 116 — the FIRST `Use rewrite` belongs to the tone that was
        // tapped. Build 115 sorted Warmer to the top whatever was asked for, so
        // this reached for the Warmer text; tapping Clearer now inserts the
        // Clearer rewrite, which is the whole point of the build.
        XCTAssertEqual(proxy.text, "Please send the report today.")
    }

    /// BUILD 116 UPDATE — this is the Apple-terminal-era contract the founder
    /// asked to be superseded, and the reason it existed is gone.
    ///
    /// Build 115 delivered the whole set in one request, so a local answer was
    /// never a version sequence and `Try another` on it would have been a
    /// control that could not act. Build 116 delivers ONE tone — the tone that
    /// was tapped — and the extras are appended behind it, so "give me a
    /// different wording of this one" means exactly what it means online.
    ///
    /// What survives verbatim is the rule the old test was really protecting: a
    /// control that cannot act must not exist. Version controls belong to the
    /// SELECTED card only. The secondary cards must have none of them, and the
    /// steppers must be absent on version 1 because there is nothing to step to.
    @MainActor
    func testOnlyTheSelectedCardCarriesTheVersionControls() throws {
        let (controller, _) = makeController(
            engine: StubEngine(), before: "hey I really need that report today"
        )
        controller.beginCoachRewrite(
            before: "hey I really need that report today", after: "", axis: "clearer"
        )
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        waitUntil({ controller.coachSecondaryAxesForTesting.count == 2 })
        controller.view.layoutIfNeeded()

        // The selected card offers exactly one Try another, and it can act.
        let tryAnothers = Self.findViews(controller.view, prefix: "TonoKB.tryAnother")
        XCTAssertEqual(tryAnothers.count, 1, "only the selected card may offer Try another")
        let another = try XCTUnwrap(tryAnothers.first as? UIControl)
        XCTAssertTrue(another.isEnabled)
        XCTAssertFalse(another.isHidden)

        // …and it belongs to the selected card, not to a secondary one.
        let cards = Self.findViews(controller.view, prefix: "TonoKB.rewrite.")
        XCTAssertEqual(cards.first?.accessibilityIdentifier, "TonoKB.rewrite.clearer.0")
        XCTAssertTrue(
            another.isDescendant(of: try XCTUnwrap(cards.first)),
            "Try another must sit on the selected tone's card"
        )

        // Nothing to step to yet, so no stepper exists in either direction.
        for identifier in ["TonoKB.versionBack", "TonoKB.versionForward"] {
            let control = Self.findView(controller.view, identifier: identifier) as? UIControl
            XCTAssertTrue(
                control == nil || control?.isHidden == true,
                "\(identifier) has nowhere to go on version 1 and must not be actionable"
            )
        }
        XCTAssertEqual(controller.coachSequenceStateForTesting?.displayed, 1)
        XCTAssertEqual(controller.coachSequenceStateForTesting?.canRequestAnother, true)
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

        // BUILD 116 — the substituted set is staged like any other, so Warmer
        // is asked for first and the rest follow. What has NOT changed, and is
        // what this test exists for: nothing ever asks for Safer.
        XCTAssertEqual(engine.requests.first?.axes, [.warmer])
        XCTAssertFalse(
            engine.requests.contains { $0.axes.contains(.safer) },
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
        // BUILD 116 — counted per PRIMARY request. Stage 2 adds one request per
        // remaining tone behind the answer, so the invariant "five notifications
        // produced one substitution" is now measured as "the primary tone was
        // asked for exactly once".
        XCTAssertEqual(
            engine.requests.filter { $0.axes == [.warmer] }.count, 1,
            "five notifications, one substituted on-device request"
        )
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

        // BUILD 116 — the tapped tone is the first card, so that is the card a
        // stale completion must fail to disturb.
        let before = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.rewrite.clearer.0")
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
            try XCTUnwrap(Self.findView(controller.view, identifier: "TonoKB.rewrite.clearer.0"))
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
    ///
    /// BUILD 117 — `local` is now the value the keyboard actually uses rather
    /// than a number scraped out of its source. The constant delegates to
    /// `LocalCoachRoutePolicy.visibleDeadlineSeconds`, so a source scrape reads
    /// no digits at all; scraping was always the weaker method anyway, because
    /// it agrees with a literal rather than with the deadline that ships. The
    /// other two are still scraped: they ARE literals in that file, and this
    /// test compiles the controller into its own module, so it can read the
    /// on-device authority directly but not the keyboard's private `Const`.
    func testTheOnDeviceDeadlineIsBoundedAndDeclared() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        let local = Tono.LocalCoachRoutePolicy.visibleDeadlineSeconds
        let offline = try XCTUnwrap(Self.constant("coachOfflineVisibleDeadline", in: source))
        let visible = try XCTUnwrap(Self.constant("coachVisibleDeadline", in: source))
        XCTAssertGreaterThan(local, visible, "the on-device budget is its own, not the connected one")
        XCTAssertLessThanOrEqual(local, offline, "a keyboard must not wait longer than it already does")
        XCTAssertLessThanOrEqual(local, 60)

        // And there is exactly one authority for it. A second literal here is
        // how this bound and the test that guards it drift apart in silence —
        // which is precisely what happened to the real-model timing assertion.
        XCTAssertTrue(
            source.contains("coachLocalVisibleDeadline: TimeInterval =\n            LocalCoachRoutePolicy.visibleDeadlineSeconds"),
            "the keyboard must read the on-device deadline from LocalCoachRoutePolicy, not redeclare it"
        )
        XCTAssertNil(
            Self.constant("coachLocalVisibleDeadline", in: source),
            "the on-device deadline is declared once, in LocalCoachRoutePolicy — not as a literal here"
        )
    }

    /// The staged watchdog scales with the number of generations, and only with
    /// that.
    ///
    /// BUILD 117 — the deterministic half of the F10 repair. The real-model
    /// test measures a live model and is therefore a *measurement*; this is the
    /// *contract*, and it holds on any machine at any load in microseconds.
    ///
    /// The property that matters: N sequential generations get N budgets, so
    /// the watchdog never cancels a model that is answering at a normal speed —
    /// and the per-generation allowance stays FLAT as N grows, so the watchdog
    /// cannot quietly become more permissive the more work the product asks
    /// for. Those two together are what the flickering assertion was gesturing
    /// at without ever checking.
    func testTheStagedWatchdogScalesWithTheGenerationsAndNothingElse() {
        let one = LocalCoachRoutePolicy.visibleDeadlineSeconds
        XCTAssertEqual(LocalCoachRoutePolicy.visibleDeadline(forGenerations: 1), one)

        for generations in 1...6 {
            let deadline = LocalCoachRoutePolicy.visibleDeadline(forGenerations: generations)
            XCTAssertEqual(
                deadline, one * Double(generations), accuracy: 0.000_1,
                "\(generations) sequential generations must get \(generations) budgets"
            )
            XCTAssertEqual(
                deadline / Double(generations), one, accuracy: 0.000_1,
                "the per-generation allowance grew at \(generations) axes — the watchdog got "
                    + "more permissive the more the product asked for"
            )
        }

        // Never zero. A watchdog scheduled at `.now()` fires immediately and
        // cancels a request that has not been made. Stage 2 guards the empty
        // set already, so this is defence in depth rather than a live fix.
        XCTAssertEqual(LocalCoachRoutePolicy.visibleDeadline(forGenerations: 0), one)
        XCTAssertEqual(LocalCoachRoutePolicy.visibleDeadline(forGenerations: -3), one)
    }

    /// Stage 2 schedules that function rather than its own arithmetic.
    ///
    /// The test above proves the policy is right; this proves the keyboard uses
    /// it. Without this pair the controller could keep a private
    /// `* Double(axes.count)` that drifts from the bound the timing test checks
    /// — which is the exact failure mode this build was sent back for.
    func testTheKeyboardSchedulesTheStagedWatchdogFromThePolicy() throws {
        let source = SwiftSource.stripComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        XCTAssertTrue(
            source.contains("LocalCoachRoutePolicy.visibleDeadline("),
            "Stage 2 must schedule the policy's deadline"
        )
        XCTAssertFalse(
            source.contains("coachLocalVisibleDeadline * Double("),
            "the staged watchdog is computed in one place, not re-derived in the controller"
        )

        // BUILD 117 REPAIR — and the scaling function is used in exactly ONE
        // place, which is the only place that performs N sequential requests.
        //
        // The hazard this closes is the mirror image of the one above: not a
        // second copy of the arithmetic, but the SAME arithmetic reaching a
        // user-visible action that makes one request. Stage 1 and `Try another`
        // each issue a single-axis `rewriteSet`, so each gets exactly one
        // budget; if either ever scheduled `visibleDeadline(forGenerations:)`,
        // the promise "the tone you tapped appears within 30 seconds" would
        // have been quietly widened to a multiple of it without a single test
        // going red.
        XCTAssertEqual(
            source.components(separatedBy: "LocalCoachRoutePolicy.visibleDeadline(").count - 1, 1,
            "the scaling deadline is scheduled once — by Stage 2, which is the only site that "
                + "loops the axes and awaits a separate request for each one"
        )
        XCTAssertEqual(
            source.components(separatedBy: "Const.coachLocalVisibleDeadline").count - 1, 2,
            "the two user-visible one-generation actions — Stage 1 and Try another — must each "
                + "schedule ONE budget"
        )

        // And the shipping call shape those two sites use really is one axis.
        // A `LocalCoachSetRequest` with more than one axis is ONE
        // `session.respond`, so scheduling N budgets around it would be granting
        // a single uninterruptible call N deadlines.
        for site in ["axes: [plan.primaryAxis]", "axes: [axis]"] {
            XCTAssertTrue(
                source.contains(site),
                "the user-visible on-device request must ask for exactly one tone (\(site))"
            )
        }
    }

    /// `rewriteSet` is ONE model call, whatever it is asked to produce.
    ///
    /// BUILD 117 REPAIR — the F10 repair's premise was that a four-axis
    /// `rewriteSet` is four generations, and it is not. This pins the fact the
    /// premise got wrong, in the engine's own source, so a future reader cannot
    /// re-derive "N axes means N budgets" from the shape of the API.
    func testAMultiAxisRewriteSetIsOneModelCallNotN() throws {
        let source = SwiftSource.stripComments(
            try Self.source("Shared/OnDeviceAppleRewrite.swift")
        )
        // One `respond` per branch: four single-tone schemas (one per axis,
        // mutually exclusive), one quartet, one trio.
        let responds = source.components(separatedBy: "await session.respond(").count - 1
        XCTAssertEqual(
            responds, 6,
            "performRewriteSet's branches changed. It must remain ONE `session.respond` per "
                + "call — four mutually exclusive single-tone branches plus the trio and the "
                + "quartet — because the watchdog arithmetic in LocalCoachRoutePolicy depends "
                + "on a multi-axis set being one uninterruptible generation, not N."
        )
        XCTAssertFalse(
            source.contains("for axis in request.axes"),
            "a loop over the requested axes would make one rewriteSet N generations, which is "
                + "the premise the Build 117 timing repair was wrongly built on"
        )
    }

    func testInputAndOutputAreBounded() {
        XCTAssertGreaterThan(LocalCoachRoutePolicy.maximumDraftCharacters, 0)
        XCTAssertLessThanOrEqual(LocalCoachRoutePolicy.maximumDraftCharacters, 4_000)
        XCTAssertGreaterThan(LocalCoachRoutePolicy.maximumOptionCharacters, 0)
        XCTAssertLessThanOrEqual(LocalCoachRoutePolicy.maximumOptionCharacters, 4_000)
    }

    /// Every shipped bundle is Build 117 and the marketing version is unchanged.
    ///
    /// BUILD 117 UPDATE — the number moves because the build number is a
    /// reviewed release input and this is a new release object. The marketing
    /// version does not: nothing here is a new product version.
    func testAllFourShippedBundlesAreBuild117() throws {
        let guardScript = try Self.source("Scripts/bump-build.sh")
        var expected: String?
        for line in guardScript.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("EXPECTED_BUILD=") else { continue }
            expected = trimmed.dropFirst("EXPECTED_BUILD=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        XCTAssertEqual(expected, "117", "the build guard must pin the reviewed number")
        for relative in ["App/Info.plist", "KeyboardExtension/Info.plist",
                         "ShareExtension/Info.plist", "TonoMessagesExtension/Info.plist"] {
            let data = try Data(contentsOf: Self.sourceRoot().appendingPathComponent(relative))
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            XCTAssertEqual(plist?["CFBundleVersion"] as? String, "117", "\(relative)")
            XCTAssertEqual(plist?["CFBundleShortVersionString"] as? String, "1.1", "\(relative)")
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // 7b. The independent review's NO-GO findings, each with its own test
    //
    // Everything in this section was RED on 43628d3, the first cut of Build
    // 115. Each test names the finding it closes.
    // ═══════════════════════════════════════════════════════════════════

    // ── F1 · the bounds are one derived chain, not three loose numbers ──

    /// The three bounds move together, in one direction, so they cannot drift
    /// apart again. This is the structural half of F1; the empirical half is
    /// `testTheRealModelServesEveryAdmittedDraftLength`.
    func testTheAdmittedDraftOptionCapAndTokenBudgetAreOneChain() {
        // option cap is DERIVED from the draft bound, not chosen beside it
        XCTAssertEqual(
            LocalCoachRoutePolicy.maximumOptionCharacters,
            Int((Double(LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 3))
                 * LocalCoachRoutePolicy.outputExpansionAllowance).rounded(.up)),
            "the option cap must be the draft bound times the measured expansion allowance"
        )
        XCTAssertGreaterThan(
            LocalCoachRoutePolicy.maximumOptionCharacters,
            LocalCoachRoutePolicy.maximumDraftCharacters,
            "a rewrite is routinely longer than its draft; an option cap at or below "
                + "the input bound drops the model's own output"
        )
        // the four-tone generation writes more and takes longer, so it admits less
        XCTAssertLessThan(
            LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 4),
            LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 3)
        )
        XCTAssertEqual(
            LocalCoachRoutePolicy.maximumDraftCharacters,
            LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 3),
            "the headline bound is the bound of the plan that actually ships"
        )
    }

    /// THE F1 REGRESSION. The budget must cover the output the admitted input
    /// actually produces — asserted against the shipped option cap rather than
    /// against a remembered number, and asserted to be strictly larger than the
    /// formula that shipped in 43628d3 at exactly the lengths that failed.
    func testTheResponseTokenBudgetCoversEveryAdmittedDraftLength() {
        for axes in [3, 4] {
            let bound = LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: axes)
            let budget = LocalCoachRoutePolicy.maximumResponseTokens(
                axisCount: axes, draftCharacters: bound
            )
            // Enough tokens for every requested tone to come back as long as
            // the measured expansion allowance says a rewrite of THIS draft may
            // be. Derived from the allowance rather than from the budget
            // function's own internals, so it is a check and not a restatement:
            // shrink the budget and this fails.
            let needed = Double(axes) * Double(bound)
                * LocalCoachRoutePolicy.outputExpansionAllowance
                / LocalCoachRoutePolicy.charactersPerResponseToken
            XCTAssertGreaterThanOrEqual(
                Double(budget), needed,
                "\(axes) tones × \(bound) chars needs ≥\(Int(needed.rounded(.up))) tokens, budgeted \(budget)"
            )
            XCTAssertLessThanOrEqual(
                budget, LocalCoachRoutePolicy.responseTokenCeiling,
                "the budget must stay bounded — an uncapped generation ran 80 s and died "
                    + "on exceededContextWindowSize"
            )
        }

        // The shipped-in-43628d3 formula, and the two draft lengths the
        // independent review reproduced as `decodingFailure` under it.
        func build115FirstCut(_ axisCount: Int) -> Int { min(1_024, 180 * max(axisCount, 1)) }
        for length in [550, 930] {
            XCTAssertGreaterThan(
                LocalCoachRoutePolicy.maximumResponseTokens(axisCount: 3, draftCharacters: length),
                build115FirstCut(3),
                "a \(length)-character draft threw decodingFailure on \(build115FirstCut(3)) tokens; "
                    + "the repaired budget must exceed it"
            )
        }

        // Monotone in both inputs: a longer draft or another tone never buys a
        // smaller budget.
        var previous = 0
        for length in stride(from: 0, through: LocalCoachRoutePolicy.maximumDraftCharacters, by: 50) {
            let budget = LocalCoachRoutePolicy.maximumResponseTokens(axisCount: 3, draftCharacters: length)
            XCTAssertGreaterThanOrEqual(budget, previous, "budget shrank at \(length) characters")
            previous = budget
        }
        XCTAssertGreaterThan(
            LocalCoachRoutePolicy.maximumResponseTokens(axisCount: 4, draftCharacters: 700),
            LocalCoachRoutePolicy.maximumResponseTokens(axisCount: 3, draftCharacters: 700)
        )
    }

    /// A draft the four-tone plan cannot serve is refused by the PLAN, not by
    /// the headline bound — the gated Safer set admits less than the base set.
    func testTheGatedSaferSetAdmitsLessThanTheBaseSet() {
        let between = String(repeating: "a b ", count: 220)   // 880 characters
        XCTAssertGreaterThan(between.count, LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 4))
        XCTAssertLessThanOrEqual(between.count, LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 3))

        XCTAssertEqual(
            Self.localAxisSet(axis: "clearer", draft: between), Set(LocalCoachAxis.base),
            "the three-tone plan still admits it"
        )
        guard case .cloud(let reason) = LocalCoachRoutePolicy.decide(
            requestedAxis: "safer", draft: between, remoteKillSwitchAllows: true,
            preference: .unset, availability: .available,
            saferCorpusGateOpen: true, connectivityKnownAbsent: true
        ) else { return XCTFail("the four-tone plan must refuse a draft it cannot serve") }
        XCTAssertEqual(reason, .draftTooLong)
    }

    /// An incomplete generation is terminal and never blames the connection.
    ///
    /// F1's user-visible half: `decodingFailure` used to land in the generic
    /// catch as `.generationFailed`, which hands over to the connected route —
    /// so in airplane mode the person waited out the connectivity budget and
    /// was told to check their internet, after this iPhone had spent ~17 s
    /// writing the answer.
    @MainActor
    func testAnIncompleteGenerationIsTerminalAndNeverBlamesTheConnection() throws {
        let engine = StubEngine(outcome: .failure(LocalCoachFailure(.rewriteDidNotFinish)))
        let (controller, _) = makeController(engine: engine)
        controller.beginCoachRewrite(
            before: "hey I really need that report today", after: "", axis: "clearer"
        )
        waitUntil({
            Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") != nil
        }, "no terminal surface appeared")
        controller.view.layoutIfNeeded()

        let detail = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") as? UILabel
        )
        XCTAssertEqual(
            detail.text,
            LocalCoachCopy.sentence(for: .rewriteDidNotFinish),
            "the person must be told the device ran out of room, not that the network failed"
        )
        XCTAssertEqual(
            controller.coachProviderCallCountForTesting, 0,
            "an incomplete on-device generation must not escalate to the network"
        )
        XCTAssertEqual(OfflineSpyProtocol.requestCount, 0)
        XCTAssertFalse(controller.coachIsBusyForTesting)
        XCTAssertNil(controller.coachDeliveredRouteForTesting, "nothing was delivered")
    }

    /// …and the sentence it shows says nothing about connectivity.
    func testTheIncompleteGenerationSentenceNeverMentionsTheNetwork() {
        let sentence = LocalCoachCopy.sentence(for: .rewriteDidNotFinish).lowercased()
        for forbidden in ["internet", "connection", "offline", "network", "online"] {
            XCTAssertFalse(
                sentence.contains(forbidden),
                "the one failure that proves the device WAS answering must not mention \(forbidden)"
            )
        }
    }

    // ── F2 · the on-device route issues no request of any kind ─────────

    /// Counts every request the PROCESS issues, with no exclusions at all.
    ///
    /// Deliberately not the session-scoped spy: the defect F2 names is a
    /// `URLSession.shared` beacon, which a session-scoped protocol cannot see
    /// by construction. Attribution is by identity rather than by total,
    /// because a process-wide count would also charge the host application's
    /// own launch traffic to this keyboard — see the F6 note in the handoff.
    final class ProcessWideRequestLog: URLProtocol {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var _urls: [String] = []
        /// Every URL seen since the process started, which `reset()` does NOT
        /// clear. The per-arm list is what the counting assertions use; this one
        /// is what the production-host guard uses, because an escape that
        /// happens between two `reset()` calls is still an escape.
        private nonisolated(unsafe) static var _allURLs: [String] = []

        static var urls: [String] { lock.withLock { _urls } }
        static var allURLs: [String] { lock.withLock { _allURLs } }
        static func reset() { lock.withLock { _urls = [] } }
        static func urls(containing needle: String) -> [String] {
            urls.filter { $0.contains(needle) }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            let url = request.url?.absoluteString ?? "<nil>"
            lock.withLock { _urls.append(url); _allURLs.append(url) }
            return true
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}
    }

    /// THE F2 REGRESSION, on the COMPLETE route — including `completeLocalCoach`,
    /// which is where the beacon actually was.
    ///
    /// `startLocalCoach` was already covered and was already clean; the two
    /// `TonoAnalytics.track` calls sat in the delivery function after it, on
    /// BOTH the success and the failure arm, and `TonoAnalytics.track` ends in
    /// `URLSession.shared.dataTask(with:).resume()` against `/v1/events`.
    ///
    /// Run with a provisioned-style device ID, because `track` early-returns on
    /// an empty one — which is exactly why the shipped suite could not see this.
    @MainActor
    func testTheCompleteOnDeviceRouteIssuesZeroRequestsOnSuccessAndOnFailure() throws {
        // BUILD 117 REPAIR (N5) — where this test's beacon is aimed is now
        // stated, not inherited.
        //
        // The precondition below fires a REAL analytics event, on purpose, to
        // prove the instrument works. Its URL came from `TonoBackend.baseURL`,
        // whose last-resort fallback is `127.0.0.1` under DEBUG and
        // `https://api.tonoit.com` — the live production host — otherwise. So
        // the same test aimed at localhost in a Debug gate and at production in
        // a Release gate, and an independent reviewer observed exactly that:
        // one real outbound attempt at production per Release run. Nothing was
        // exchanged and the request timed out, but a test suite must never aim
        // at production by default, and "which host" must not be a property of
        // the build configuration.
        useLocalBackendForTesting()
        URLProtocol.registerClass(ProcessWideRequestLog.self)
        defer { URLProtocol.unregisterClass(ProcessWideRequestLog.self) }
        let restoreDeviceID = Self.provisionDeviceIDForTesting()
        addTeardownBlock(restoreDeviceID)

        // PRECONDITION — the instrument works. Without this the zeroes below
        // would prove only that nothing was watching. One real analytics event,
        // fired deliberately, must be visible as an outbound `/v1/events` POST.
        ProcessWideRequestLog.reset()
        TonoAnalytics.reset()
        Tono.TonoAnalytics.track(.suggestionTapped)
        let sawBeacon = Self.spinUntil {
            !ProcessWideRequestLog.urls(containing: "/v1/events").isEmpty
        }
        XCTAssertTrue(
            sawBeacon,
            """
            precondition failed: a deliberately fired analytics event did not reach the URL \
            loading system, so this test cannot detect the defect it exists for. \
            Observed: \(ProcessWideRequestLog.urls)
            """
        )

        // Two arms that stay on the on-device route to the end: a delivered
        // set, and a TERMINAL refusal. Both used to fire a beacon.
        for (label, engine) in [
            ("success", StubEngine()),
            ("terminal-failure", StubEngine(outcome: .failure(LocalCoachFailure(.rewriteDidNotFinish)))),
        ] as [(String, StubEngine)] {
            ProcessWideRequestLog.reset()
            TonoAnalytics.reset()
            let (controller, _) = makeController(engine: engine, installSpyClient: false)
            controller.beginCoachRewrite(
                before: "hey I really need that report today", after: "", axis: "clearer"
            )
            waitUntil(
                { controller.coachDeliveredRouteForTesting != nil || !controller.coachIsBusyForTesting },
                "\(label): the on-device route never completed"
            )
            // Let any beacon this route might have fired reach the loading
            // system before the count is read.
            _ = Self.spinUntil(timeout: 0.35) { false }

            XCTAssertEqual(
                ProcessWideRequestLog.urls(containing: "/v1/events"), [],
                "\(label): the on-device route sent an analytics beacon"
            )
            XCTAssertEqual(
                ProcessWideRequestLog.urls(containing: "analyze"), [],
                "\(label): the on-device route reached the Coach endpoint"
            )
            XCTAssertTrue(
                TonoAnalytics.recorded.isEmpty,
                "\(label): the on-device route recorded \(TonoAnalytics.recorded.map(\.name))"
            )
            XCTAssertFalse(
                controller.coachNetworkClientWasConstructedForTesting,
                "\(label): the on-device route built a URLSession-backed client"
            )
            MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() }
        }

        // The third arm: a RECOVERABLE local failure hands over to the
        // connected route, which is a different route and is supposed to make
        // its one request. What must still be zero is the beacon — the defect
        // was that the on-device delivery path reported itself over the network
        // on the way past.
        do {
            ProcessWideRequestLog.reset()
            TonoAnalytics.reset()
            let (controller, _) = makeController(
                engine: StubEngine(outcome: .failure(LocalCoachFailure(.noValidRewrite)))
            )
            controller.beginCoachRewrite(
                before: "hey I really need that report today", after: "", axis: "clearer"
            )
            waitUntil(
                { controller.coachLocalRefusalForTesting != nil },
                "hand-off: the on-device route never declined"
            )
            _ = Self.spinUntil(timeout: 0.35) { false }

            XCTAssertEqual(
                ProcessWideRequestLog.urls(containing: "/v1/events"), [],
                "hand-off: the declining on-device route sent an analytics beacon"
            )
            XCTAssertTrue(
                TonoAnalytics.recorded.isEmpty,
                "hand-off: the declining on-device route recorded \(TonoAnalytics.recorded.map(\.name))"
            )
            XCTAssertEqual(
                controller.coachLocalRefusalForTesting, "noValidRewrite",
                "precondition: this arm must be the hand-off, or it proves nothing"
            )
            MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() }
        }

        // Nothing this test caused — including the deliberate positive-control
        // beacon — may have been addressed to a host real people use.
        Self.assertNoProductionHostWasTargeted(ProcessWideRequestLog.allURLs)
    }

    // MARK: N5 — no test aims at production

    /// Hosts that serve real people. A test that reaches one of these is a test
    /// that can affect somebody's data, bill somebody's account, or show up in
    /// production telemetry as traffic nobody sent.
    static let productionHosts = ["api.tonoit.com", "tonoit.com", "parentscript.app"]

    /// Point every backend URL this test can cause at a local address, whatever
    /// the build configuration would otherwise fall back to.
    ///
    /// `TonoBackend.baseURL` resolves the runtime override FIRST, so writing it
    /// here is the same lever the shipping app uses for staging — not a stub
    /// standing in for the resolution logic.
    @MainActor
    func useLocalBackendForTesting(_ address: String = "http://127.0.0.1:8765") {
        let defaults = Tono.SharedStore.defaults
        let previous = defaults.string(forKey: Tono.SharedKeys.backendURL)
        addTeardownBlock {
            if let previous {
                defaults.set(previous, forKey: Tono.SharedKeys.backendURL)
            } else {
                defaults.removeObject(forKey: Tono.SharedKeys.backendURL)
            }
        }
        defaults.set(address, forKey: Tono.SharedKeys.backendURL)
        XCTAssertEqual(
            Tono.TonoBackend.shared.baseURL.absoluteString, address,
            "the local backend override did not take, so this test is still aimed "
                + "wherever the build configuration points"
        )
    }

    /// The guard. Fails if any URL in `urls` names a production host.
    static func assertNoProductionHostWasTargeted(
        _ urls: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        let escaped = urls.filter { url in productionHosts.contains { url.contains($0) } }
        XCTAssertTrue(
            escaped.isEmpty,
            "a test put \(escaped.count) request(s) on a production host: "
                + "\(Set(escaped).sorted().prefix(5).joined(separator: ", ")). "
                + "Inject a local backend explicitly; never let the build "
                + "configuration decide which host a test talks to.",
            file: file, line: line
        )
    }

    /// The standing guard, independent of any one test.
    ///
    /// The test above proves its OWN traffic is local. This proves it for every
    /// request any test in this class caused, because `ProcessWideRequestLog`
    /// keeps an all-time list — and because the escape an independent reviewer
    /// found was a fire-and-forget beacon that could land outside the window
    /// any single test was watching.
    func testNoRequestFromThisSuiteWasEverAddressedToProduction() {
        Self.assertNoProductionHostWasTargeted(ProcessWideRequestLog.allURLs)
    }

    /// The source-level half, covering the WHOLE delivery path rather than the
    /// dispatch function. `testTheOnDeviceBranchNeverReadsTheNetworkClient`
    /// reads `startLocalCoach` only, which is why it was green while
    /// `completeLocalCoach` posted to `/v1/events` twice.
    func testTheOnDeviceDeliveryPathReachesNoAnalyticsOrTransport() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        let body = try XCTUnwrap(
            Self.functionBody(named: "func completeLocalCoach", in: code),
            "completeLocalCoach must exist — it is the on-device delivery path"
        )
        for banned in ["TonoAnalytics", "URLSession", "dataTask", "coachClient", "TonoBackend"] {
            XCTAssertFalse(
                body.contains(banned),
                "completeLocalCoach must not reach \(banned): the on-device route's whole "
                    + "claim is that a delivered local rewrite made no request"
            )
        }
        // …and the file as a whole no longer reaches analytics at all, so the
        // connected and on-device routes stay symmetric.
        XCTAssertFalse(
            code.contains("TonoAnalytics."),
            "KeyboardViewController reached analytics; it had zero such call sites before "
                + "Build 115 and must have zero after the repair"
        )
    }

    // ── F3 · sequence controls key on a sequence, never on card count ──

    /// THE F3 REGRESSION. A local set that validates down to ONE option used to
    /// satisfy `shown.count == 1` and get the full version UI with
    /// `coachSequence == nil` behind it — `Try another` visible, enabled, and
    /// inert, because `tryAnotherTapped` returns on the same nil.
    ///
    /// BUILD 116 UPDATE — the F3 RULE is unchanged and still what is asserted:
    /// no control may be visible and enabled with nothing behind it to act on.
    /// What changed is which side of the rule this case falls on. Build 115's
    /// local delivery set `coachSequence = nil`, so `Try another` was inert and
    /// had to be absent. Build 116 delivers the selected tone as version 1 of a
    /// real sequence, so the control is backed and must be present AND able to
    /// act. The steppers still have nowhere to go on version 1, and must still
    /// not be actionable.
    @MainActor
    func testAOneOptionLocalSetOffersAWorkingTryAnotherAndNoDeadSteppers() throws {
        // The two secondary tones come back as the draft itself, so the
        // validator drops them as no-ops and exactly one card survives.
        let draft = "hey I really need that report today"
        let engine = StubEngine(outcome: .success([
            .warmer: draft,
            .clearer: "Please send the report today.",
            .funnier: draft,
        ]))
        let (controller, _) = makeController(engine: engine, before: draft)
        controller.beginCoachRewrite(before: draft, after: "", axis: "clearer")
        waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
        waitUntil({ !controller.coachSecondaryInFlightForTesting }, "Stage 2 never finished")
        controller.view.layoutIfNeeded()

        // PRECONDITION: it really is a one-card set, or this proves nothing.
        let cards = Self.findViews(controller.view, prefix: "TonoKB.rewrite.")
        XCTAssertEqual(
            cards.count, 1,
            "precondition: the validator must have dropped both secondary tones"
        )
        XCTAssertEqual(controller.coachSecondaryAxesForTesting, [])

        // The control that IS backed: one sequence, one enabled Try another.
        XCTAssertEqual(controller.coachSequenceStateForTesting?.displayed, 1)
        XCTAssertEqual(controller.coachSequenceStateForTesting?.canRequestAnother, true)
        let another = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.tryAnother") as? UIControl
        )
        XCTAssertTrue(another.isEnabled, "the selected tone's Try another must be able to act")
        XCTAssertFalse(another.isHidden)

        // The controls that are NOT backed: nowhere to step on version 1.
        for identifier in ["TonoKB.versionBack", "TonoKB.versionForward"] {
            let control = Self.findView(controller.view, identifier: identifier) as? UIControl
            XCTAssertTrue(
                control == nil || control?.isHidden == true,
                "\(identifier) has nowhere to go on version 1 and must not be actionable"
            )
        }
    }

    /// The F3 rule stated directly, at every card count Build 116 can produce:
    /// exactly ONE `Try another` exists, it belongs to the selected card, and it
    /// is backed by a real sequence. A secondary card never carries one.
    @MainActor
    func testExactlyOneBackedTryAnotherExistsAtEveryCardCount() throws {
        for optionCount in 1...3 {
            let draft = "hey I really need that report today"
            var texts: [LocalCoachAxis: String] = [.clearer: "Please send the report today."]
            if optionCount >= 2 { texts[.warmer] = "Would you mind sending the report over today?" }
            if optionCount >= 3 { texts[.funnier] = "The report and I are ready whenever you are." }
            for axis in LocalCoachAxis.base where texts[axis] == nil { texts[axis] = draft }

            let (controller, _) = makeController(
                engine: StubEngine(outcome: .success(texts)), before: draft
            )
            controller.beginCoachRewrite(before: draft, after: "", axis: "clearer")
            waitUntil({ controller.coachDeliveredRouteForTesting == "onDevice" })
            waitUntil({ !controller.coachSecondaryInFlightForTesting })
            controller.view.layoutIfNeeded()

            XCTAssertEqual(
                Self.findViews(controller.view, prefix: "TonoKB.rewrite.").count, optionCount,
                "precondition: expected \(optionCount) card(s)"
            )
            let controls = Self.findViews(controller.view, prefix: "TonoKB.tryAnother")
            XCTAssertEqual(
                controls.count, 1,
                "\(optionCount)-card set: exactly one Try another, on the selected card"
            )
            XCTAssertNotNil(
                controller.coachSequenceStateForTesting,
                "\(optionCount)-card set: the control must be backed by a real sequence"
            )
            MainActor.assumeIsolated { controller.invalidateCoachWorkForTesting() }
        }
    }

    /// The guard is the sequence, not the count — pinned at the source level so
    /// a future edit cannot quietly go back to counting cards.
    func testTheSequenceGuardReadsTheSequenceAndNotTheCardCount() throws {
        let code = Self.strippingComments(
            try Self.source("KeyboardExtension/KeyboardViewController.swift")
        )
        XCTAssertTrue(
            code.contains("let offersSequence = coachSequence != nil"),
            "sequence controls must be gated on a real sequence"
        )
        XCTAssertFalse(
            code.contains("let offersSequence = shown.count == 1"),
            "card count is not a sequence: a local trio can validate down to one card"
        )
    }

    // ── F4 · short drafts are declined, not answered ────────────────────

    /// THE F4 REGRESSION, on the exact drafts the independent review measured.
    ///
    /// With the shipping instructions ("never answer the message, never reply
    /// to it"), iOS 26.5 returned `Hey there!` for `ok`, a 165-character
    /// apology for `no`, and `You're welcome! I'm glad I could help.` for
    /// `Thanks!`. Validation checks emptiness, length, fences and no-op
    /// identity — none of which catch an invented reply — so all three would
    /// have rendered as cards and `Use rewrite` would have put them in the
    /// person's message.
    func testAcknowledgementsTooShortToRewriteAreRefusedNotAnswered() {
        // Every one of these was measured on iOS 26.5 returning an invented
        // reply rather than a rewrite.
        for draft in ["ok", "no", "Thanks!", "sure", "fine", "call me", "no thanks", "not today"] {
            guard case .cloud(let reason) = Self.decision(axis: "clearer", draft: draft) else {
                return XCTFail("‘\(draft)’ must not be rewritten on the device")
            }
            XCTAssertEqual(
                reason, .draftTooShort,
                "‘\(draft)’ must be refused as too short, with its own reason"
            )
        }
        // …and punctuation is not content: the character bound alone is not enough.
        XCTAssertFalse(LocalCoachRoutePolicy.draftIsLongEnoughToRewrite("Thanks!!!!!!!!!!"))
        XCTAssertFalse(LocalCoachRoutePolicy.draftIsLongEnoughToRewrite("ok . . . ."))
    }

    /// The other side of the trade-off: a short message that really says
    /// something is still rewritten on the device. Every draft here was
    /// measured returning a faithful rewrite.
    func testUsefulShortMessagesAreStillRewrittenLocally() {
        for draft in [
            "I'm running late",            // 16 chars, 3 words — the boundary case
            "sorry I'm late",              // 14 chars, 3 words
            "can you send it?",
            "please send the report today",
            "I can't make it tonight",
            "need the deck by 5",
        ] {
            XCTAssertTrue(
                LocalCoachRoutePolicy.draftIsLongEnoughToRewrite(draft),
                "‘\(draft)’ is a real message and must still be rewritten on the device"
            )
            XCTAssertEqual(
                Self.localAxisSet(axis: "clearer", draft: draft), Set(LocalCoachAxis.base),
                "‘\(draft)’ must take the local route"
            )
        }
    }

    /// The gate is stated as a threshold pair, and both halves bind.
    func testTheMinimumUsefulDraftThresholdIsDeclaredAndBindsBothWays() {
        XCTAssertEqual(LocalCoachRoutePolicy.minimumDraftWords, 3)
        XCTAssertEqual(LocalCoachRoutePolicy.minimumDraftCharacters, 12)
        // long enough in characters, too few words
        XCTAssertFalse(LocalCoachRoutePolicy.draftIsLongEnoughToRewrite("aaaaaaaaaaaaaaaaaaaa"))
        // enough words, too few characters
        XCTAssertFalse(LocalCoachRoutePolicy.draftIsLongEnoughToRewrite("a b c"))
        // both satisfied
        XCTAssertTrue(LocalCoachRoutePolicy.draftIsLongEnoughToRewrite("I am running late"))
        XCTAssertLessThan(
            LocalCoachRoutePolicy.minimumDraftCharacters,
            LocalCoachRoutePolicy.maximumDraftCharacters,
            "the two bounds must leave a range between them"
        )
    }

    /// A draft below the threshold never reaches the model at all.
    @MainActor
    func testATooShortDraftIsNeverSentToTheOnDeviceModel() {
        let engine = StubEngine()
        let (controller, _) = makeController(engine: engine, before: "ok")
        controller.beginCoachRewrite(before: "ok", after: "", axis: "clearer")
        waitUntil({ controller.coachLocalRefusalForTesting != nil }, "no route decision was taken")

        XCTAssertEqual(controller.coachLocalRefusalForTesting, "draftTooShort")
        XCTAssertTrue(
            engine.requests.isEmpty,
            "a draft with nothing in it to rewrite must not be handed to the model — "
                + "that is exactly when it invents a reply"
        )
    }

    /// …and with no route at all, the person is told the true reason rather
    /// than being told to check a connection that is not what stopped this.
    @MainActor
    func testATooShortDraftOfflineSaysWhyRatherThanBlamingTheConnection() throws {
        let (controller, _) = makeController(engine: StubEngine(), before: "ok")
        controller.beginCoachRewrite(before: "ok", after: "", axis: "clearer")
        // Wait for the ROUTE decision, not merely for a request id: the
        // availability probe hops off the main queue, so the refusal that this
        // test is about is not recorded yet when the id first appears.
        waitUntil({ controller.coachLocalRefusalForTesting == "draftTooShort" },
                  "the route decision never recorded the too-short refusal")
        let id = try XCTUnwrap(controller.activeCoachRequestIDForTesting)

        // The transport reports what airplane mode reports: no route.
        controller.handleCoachWaitingForConnectivity(
            requestID: id, tapTime: .now(), axis: "clearer"
        )
        controller.view.layoutIfNeeded()

        let detail = try XCTUnwrap(
            Self.findView(controller.view, identifier: "TonoKB.coachErrorDetail") as? UILabel
        )
        XCTAssertEqual(detail.text, LocalCoachCopy.sentence(for: .draftTooShort))
        XCTAssertFalse(controller.coachIsBusyForTesting)
    }

    /// The two length refusals are opposite instructions and must never share
    /// a sentence — "write a bit more" and "shorten it" cannot both be shown
    /// for the same cause.
    func testTooShortAndTooLongAreToldApart() {
        let short = LocalCoachCopy.sentence(for: .draftTooShort)
        let long = LocalCoachCopy.sentence(for: .draftTooLong)
        XCTAssertNotEqual(short, long)
        XCTAssertTrue(short.lowercased().contains("short"))
        XCTAssertTrue(long.lowercased().contains("long"))
    }

    // ── F8 · the operator switch is actually operable ───────────────────

    /// The flag the iOS side calls an operator kill switch must exist as a row
    /// the backend can return. `/v1/features` returns exactly the rows in the
    /// `feature_flags` table, and this key was never seeded — so `cached()[key]`
    /// was always nil, `isEnabled` always resolved the ON default, and the
    /// switch could not say off. Seeded ENABLED, so nothing changes except that
    /// `PATCH /admin/flags/{key}` now matches a row.
    func testTheOnDeviceKillSwitchIsSeededInTheBackendFlagTable() throws {
        let store = try String(
            contentsOf: Self.sourceRoot()
                .deletingLastPathComponent()
                .appendingPathComponent("backend/store.py"),
            encoding: .utf8
        )
        let header = try XCTUnwrap(
            store.range(of: "_DEFAULT_FLAGS = ["),
            "_DEFAULT_FLAGS must exist — it is what /v1/features can return"
        )
        // Terminated by the line that closes the list, not by the first `]`
        // character: the comments inside it may legitimately contain brackets.
        var rows: [String] = []
        for line in store[header.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == "]" { break }
            rows.append(String(line))
        }
        let defaults = rows.joined(separator: "\n")
        XCTAssertTrue(
            defaults.contains(FeatureFlag.appleIntelligenceRewriteEnabled.rawValue),
            """
            \(FeatureFlag.appleIntelligenceRewriteEnabled.rawValue) is not seeded, so \
            /v1/features cannot emit it and the iOS side must not describe it as a \
            remote kill switch.
            """
        )
        // Seeded ENABLED: the resolved value must not change for anyone.
        let row = try XCTUnwrap(
            defaults.split(separator: "\n").first {
                $0.contains(FeatureFlag.appleIntelligenceRewriteEnabled.rawValue)
            }.map(String.init)
        )
        XCTAssertTrue(
            row.contains(", 1,") || defaults.contains("\"apple_intelligence_rewrite_enabled\", 1,"),
            "the seed must be ON so shipping this changes no device's behaviour: \(row)"
        )
        XCTAssertEqual(
            FeatureFlag.appleIntelligenceRewriteEnabled.defaultValue, true,
            "the client default and the seeded row must agree"
        )
    }

    // ── Section 7b helpers ──────────────────────────────────────────────

    private static func decision(axis: String, draft: String) -> LocalCoachRoute {
        LocalCoachRoutePolicy.decide(
            requestedAxis: axis, draft: draft, remoteKillSwitchAllows: true,
            preference: .unset, availability: .available,
            saferCorpusGateOpen: false, connectivityKnownAbsent: false
        )
    }

    /// The axes a decision would ask the model for, or nil when it went to the
    /// connected route — so a route assertion reads as one comparable value.
    private static func localAxes(axis: String, draft: String) -> [LocalCoachAxis]? {
        guard case .local(let plan) = decision(axis: axis, draft: draft) else { return nil }
        return plan.axes
    }

    /// BUILD 116 — the same question asked without regard to order.
    ///
    /// The two callers below ask "does the local route ADMIT this draft, and
    /// with which tones", which is what they have always been about. Build 116
    /// makes the ORDER of those tones depend on which one was tapped, and that
    /// is a different contract with its own tests in
    /// `Build116SelectedFirstTests`. Comparing as a set keeps each test asking
    /// one question.
    private static func localAxisSet(axis: String, draft: String) -> Set<LocalCoachAxis>? {
        localAxes(axis: axis, draft: draft).map(Set.init)
    }

    /// Spin the run loop until `condition` holds, or the budget runs out.
    /// Returns whether it held — callers assert on the result rather than on a
    /// sleep having been long enough.
    @discardableResult
    private static func spinUntil(
        timeout: TimeInterval = 2, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Give `TonoAnalytics` the provisioned-style device ID it needs to fire.
    /// Returns the restore action. `track` early-returns on an empty device ID,
    /// which is exactly why the shipped suite could not see F2.
    private static func provisionDeviceIDForTesting() -> () -> Void {
        let previous = Tono.SharedKeychain.get(Tono.KeychainKeys.deviceID)
        Tono.SharedKeychain.set("build115-fixture-device", forKey: Tono.KeychainKeys.deviceID)
        return {
            if let previous {
                Tono.SharedKeychain.set(previous, forKey: Tono.KeychainKeys.deviceID)
            } else {
                Tono.SharedKeychain.delete(Tono.KeychainKeys.deviceID)
            }
        }
    }

    /// The whole cached feature-flag dictionary, so a test that writes one flag
    /// can put back everything `update(from:)` replaced.
    static func captureFeatureFlagCache() -> Data? {
        Tono.SharedStore.defaults.data(forKey: Tono.SharedKeys.featureFlags)
    }

    static func restoreFeatureFlagCache(_ data: Data?) {
        if let data {
            Tono.SharedStore.defaults.set(data, forKey: Tono.SharedKeys.featureFlags)
        } else {
            Tono.SharedStore.defaults.removeObject(forKey: Tono.SharedKeys.featureFlags)
        }
    }

    /// The body of a named function, brace-matched. Used so a source contract
    /// can be asserted about ONE function rather than about a whole file.
    static func functionBody(named signature: String, in code: String) -> String? {
        guard let start = code.range(of: signature),
              let open = code.range(of: "{", range: start.upperBound..<code.endIndex)
        else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[open.upperBound..<index]) }
            }
            index = code.index(after: index)
        }
        return nil
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
        // Build 115 repair — `FeatureFlags.update(from:)` REPLACES the whole
        // cached dictionary in the shared App Group defaults, so setting one
        // flag here silently reset every other flag in the process to its
        // default for every test that ran afterwards. Harmless only by
        // coincidence (the defaults happened to agree); as a latent
        // order-dependent flake it is exactly the kind of thing that makes a
        // suite's counts stop reproducing. Restored unconditionally.
        let flagsBefore = Self.captureFeatureFlagCache()
        addTeardownBlock { Self.restoreFeatureFlagCache(flagsBefore) }
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

    /// THE F1 ACCEPTANCE TEST. The real model, through the SHIPPED bridge and
    /// the shipped parameters, at every length the route policy admits.
    ///
    /// The suite could not see F1 because its only real-model test used a
    /// 61-character draft. Under the budget that shipped in 43628d3
    /// (`min(1_024, 180 × axisCount)` = 540 tokens for the trio) a 550-character
    /// draft threw `decodingFailure` and a 930-character draft threw it 3 runs
    /// out of 3 — measured on this simulator, on macOS, and reproduced here
    /// before the repair.
    ///
    /// What this asserts is not "the model answered" but "every option came
    /// back INSIDE the bounds this route publishes": the option cap the
    /// validator enforces, and the on-device watchdog. Those are the two things
    /// the token budget has to be consistent with.
    ///
    /// Slow on purpose — four real generations, ~80 s total on an M1 simulator.
    func testTheRealModelServesEveryAdmittedDraftLength() async throws {
        let bridge = AppleRewriteBridge.shared
        let availability = await bridge.availability(locale: Locale(identifier: "en_US"))
        try XCTSkipUnless(
            availability.isAvailable,
            "SystemLanguageModel reports \(availability.rawValue) on this machine — "
                + "the real-model path cannot be exercised here"
        )
        let flagsBefore = Self.captureFeatureFlagCache()
        addTeardownBlock { Self.restoreFeatureFlagCache(flagsBefore) }
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])

        let threeToneBound = Tono.LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 3)
        let fourToneBound = Tono.LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 4)
        // 930 is both the second reproduced failure AND the three-tone bound,
        // which is not a coincidence: the bound was set to the longest length
        // measured to deliver on every observation.
        XCTAssertEqual(threeToneBound, 930, "the admitted bound is the proven one")
        let cases: [(label: String, length: Int, axes: [Tono.LocalCoachAxis])] = [
            // The two lengths the independent review reproduced as
            // `decodingFailure` under the 540-token budget…
            ("550", 550, Tono.LocalCoachAxis.base),
            ("930-bound", threeToneBound, Tono.LocalCoachAxis.base),
            // …and the gated four-tone set at its own, smaller bound.
            ("700-bound-4", fourToneBound, Tono.LocalCoachAxis.base + [.safer]),
        ]

        for testCase in cases {
            let draft = Self.realisticDraft(ofAtMost: testCase.length)
            XCTAssertGreaterThan(
                draft.count, testCase.length - 20,
                "\(testCase.label): the fixture must actually be that long"
            )
            let started = Date()
            let result: Tono.LocalCoachSetResult
            do {
                result = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
                    draft: draft, axes: testCase.axes, locale: Locale(identifier: "en_US")
                ))
            } catch let failure as Tono.LocalCoachFailure {
                // `.rewriteDidNotFinish` is the F1 signature specifically: the
                // response budget ran out mid-object. Naming it separately
                // keeps this test diagnostic rather than merely red.
                XCTAssertNotEqual(
                    failure.reason, .rewriteDidNotFinish,
                    "\(testCase.label): a \(draft.count)-character draft the route policy ADMITS "
                        + "ran out of response tokens. The admitted input and the token budget "
                        + "have come apart again — this is F1, exactly as first reported."
                )
                return XCTFail(
                    "\(testCase.label): a \(draft.count)-character draft the route policy "
                        + "ADMITS was refused with \(failure.reason.rawValue)"
                )
            }
            let elapsed = Date().timeIntervalSince(started)

            // Deliberately NOT "all three tones came back". At these lengths the
            // model frequently returns one tone as the draft almost verbatim,
            // and the validator drops it as a no-op — which is the validator
            // working, and is why a one-option local set is an ordinary outcome
            // rather than a corner case (see F3). What this route publishes is
            // that an admitted draft yields a usable answer, and that is what is
            // asserted.
            XCTAssertGreaterThanOrEqual(
                result.options.count, 1,
                "\(testCase.label): an admitted draft must yield at least one usable rewrite"
            )
            for option in result.options {
                XCTAssertLessThanOrEqual(
                    option.text.count, Tono.LocalCoachRoutePolicy.maximumOptionCharacters,
                    "\(testCase.label): \(option.axis) came back at \(option.text.count) characters, "
                        + "past the cap the validator enforces — it would have been dropped, "
                        + "and a set where every option is dropped fails as noValidRewrite"
                )
                XCTAssertFalse(option.text.isEmpty)
                XCTAssertNotEqual(
                    Tono.LocalCoachValidator.normalizedForNoOp(option.text),
                    Tono.LocalCoachValidator.normalizedForNoOp(draft),
                    "\(testCase.label): \(option.axis) returned the draft rather than a rewrite"
                )
            }
            // NO WALL-CLOCK ASSERTION HERE, AND THAT IS THE REPAIR.
            //
            // BUILD 117 — this block used to divide `elapsed` by `axes.count`
            // and call the result "one staged generation", then bound the whole
            // call by `visibleDeadline(forGenerations: axes.count)`. Both rest
            // on the same false premise: that a multi-axis `rewriteSet` is N
            // generations. It is not. `OnDeviceAppleRewrite.performRewriteSet`
            // issues exactly ONE `session.respond` per call in every branch —
            // one guided trio for three axes, one quartet for four — so the
            // division understated the measured generation by 3–4×, and the
            // whole-set bound handed a single uninterruptible call four
            // watchdog budgets.
            //
            // No shipping site issues this call shape. Stage 1, Stage 2's loop
            // body and `Try another` all pass a single-element `axes` array, so
            // there is no product deadline that applies to a trio or a quartet
            // and inventing one is what went wrong the first time. What this
            // case is for is the TOKEN BUDGET — F1 — and that is asserted
            // above, in full. The wall clock is REPORTED, honestly, per call.
            //
            // The deadline that a person actually waits on is measured by
            // `testTheRealModelMeetsTheVisibleDeadlineOnEveryShippingGeneration`
            // against the real, unchanged 30s watchdog and the real shipping
            // call shape.
            //
            // Lengths and durations only — never the text.
            print("BUILD115 F1 real-model \(testCase.label): draft=\(draft.count) "
                  + "axes=\(testCase.axes.count) ONE-generation-total-ms=\(Int(elapsed * 1000)) "
                  + "kept=\(result.options.count)/\(testCase.axes.count) "
                  + "out=\(result.options.map { $0.text.count }) "
                  + "[not a shipping call shape — no product deadline applies]")
        }

        // The 1,200-character boundary, in the form that is actually true: the
        // policy refuses it before the model is asked. Measured at ~1,200 the
        // model writes ~1,222 characters per option and takes 30.9 s for the
        // four-tone set, and at ~1,000 it is bistable between three genuine
        // rewrites and three verbatim echoes — so the bound was lowered rather
        // than claimed. The connected route still takes drafts this long.
        let overLong = Self.realisticDraft(ofAtMost: 1_200)
        XCTAssertGreaterThan(overLong.count, threeToneBound)
        guard case .cloud(let refusal) = Tono.LocalCoachRoutePolicy.decide(
            requestedAxis: "clearer", draft: overLong, remoteKillSwitchAllows: true,
            preference: .unset, availability: .available,
            saferCorpusGateOpen: false, connectivityKnownAbsent: true
        ) else {
            return XCTFail("a 1,200-character draft must not be admitted by the local route")
        }
        XCTAssertEqual(refusal, .draftTooLong)
    }

    /// THE SHIPPING-SHAPE ACCEPTANCE TEST — added in Build 117.
    ///
    /// Every user-visible on-device action issues ONE `rewriteSet` with ONE
    /// axis, and is given `visibleDeadlineSeconds` — 30s — to produce it:
    ///
    ///   * Stage 1 (`KeyboardViewController.startLocalCoach`) — the tone the
    ///     person tapped, `axes: [plan.primaryAxis]`;
    ///   * `Try another` (`startLocalCoachAlternative`) — `axes: [axis]`;
    ///   * Stage 2's loop body — `axes: [axis]`, once per secondary tone, each
    ///     awaited in turn.
    ///
    /// Nothing in the suite measured that shape. The only real-model timing
    /// test asked for three or four tones in ONE call, which no shipping site
    /// does, and the only test that did perform real single-axis generations
    /// (`Build116SelectedFirstTests.testTheRealModelServesEachSelectedToneOn‐
    /// ItsOwn`) used ~60-character drafts and asserted no timing at all. So the
    /// number the product actually promises a person was never checked.
    ///
    /// This checks it: every axis a shipping action can select, at the longest
    /// draft the single-axis route ADMITS, against the real unchanged 30s
    /// watchdog. No fraction, no tripwire, no derived allowance — the bound is
    /// the deadline the keyboard schedules, so a failure here means a real
    /// person really would see the watchdog fire.
    ///
    /// WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT.
    ///
    /// The promise attached to the watchdog is that the person is ANSWERED
    /// before it fires — with a rewrite, or with a truthful refusal. So every
    /// axis is held to the deadline whichever way it ends, and a refusal must
    /// additionally be one of the bounded generation outcomes rather than a
    /// hang. What is NOT asserted is "every tone delivers every time": the
    /// validator dropping a runaway is the validator working, and measured on
    /// this object two of the four tones do end in a bounded refusal at this
    /// length (see `boundedLocalRefusals`, which carries the numbers and the
    /// evidence that loosening the token budget makes it strictly worse). What
    /// IS asserted is that the route can still do its job at the length it
    /// admits — a bound that admits a draft no tone can serve is a bound that
    /// is lying.
    ///
    /// Slow on purpose: four real generations at the admitted bound.
    func testTheRealModelMeetsTheVisibleDeadlineOnEveryShippingGeneration() async throws {
        let bridge = AppleRewriteBridge.shared
        let availability = await bridge.availability(locale: Locale(identifier: "en_US"))
        try XCTSkipUnless(
            availability.isAvailable,
            "SystemLanguageModel reports \(availability.rawValue) on this machine — "
                + "the real-model path cannot be exercised here"
        )
        let flagsBefore = Self.captureFeatureFlagCache()
        addTeardownBlock { Self.restoreFeatureFlagCache(flagsBefore) }
        FeatureFlags.update(from: ["apple_intelligence_rewrite_enabled": true])

        // The bound the single-axis route admits, from the policy rather than
        // from memory. 930 at the time of writing, and the assertion is that
        // this is the same number the trio is held to — a single-axis request
        // is admitted at the widest bound there is.
        let singleAxisBound = Tono.LocalCoachRoutePolicy.maximumDraftCharacters(forAxisCount: 1)
        XCTAssertEqual(singleAxisBound, 930, "the admitted single-axis bound moved")
        let draft = Self.realisticDraft(ofAtMost: singleAxisBound)
        XCTAssertGreaterThan(draft.count, singleAxisBound - 20, "the fixture must be that long")

        let deadline = Tono.LocalCoachRoutePolicy.visibleDeadlineSeconds
        var measured: [(axis: String, seconds: Double)] = []
        var delivered: [String] = []
        var refused: [(axis: String, reason: String, seconds: Double)] = []

        // Every axis a shipping action can ask for on its own: the three base
        // tones Stage 1 and Stage 2 select between, plus Safer, which the
        // gated four-tone plan and `Try another` can both reach.
        // Every axis is measured and REPORTED even when one of them fails.
        // Returning on the first refusal threw away the measurements already
        // taken and left the log with nothing to read, which is the opposite of
        // reporting the total per call honestly.
        for axis in Tono.LocalCoachAxis.base + [.safer] {
            let started = Date()
            let result: Tono.LocalCoachSetResult
            do {
                result = try await bridge.rewriteSet(Tono.LocalCoachSetRequest(
                    draft: draft, axes: [axis], locale: Locale(identifier: "en_US")
                ))
            } catch let failure as Tono.LocalCoachFailure {
                let elapsed = Date().timeIntervalSince(started)
                measured.append((axis.rawValue, elapsed))
                refused.append((axis.rawValue, failure.reason.rawValue, elapsed))
                print("BUILD117 shipping-shape real-model axis=\(axis.rawValue) "
                      + "draft=\(draft.count) total_ms=\(Int(elapsed * 1000)) "
                      + "deadline_s=\(Int(deadline)) "
                      + "margin=\(String(format: "%.2f", deadline / elapsed))x "
                      + "REFUSED=\(failure.reason.rawValue)")
                // A refusal is not automatically a failure of THIS test. What
                // the watchdog promises is that the person is answered — one way
                // or the other — before it fires. What a refusal must be is
                // BOUNDED and truthful, and inside the deadline. See
                // `boundedLocalRefusals` for why loosening the budget to remove
                // these refusals is the wrong repair, with the measurement.
                XCTAssertTrue(
                    Self.boundedLocalRefusals.contains(failure.reason.rawValue),
                    "\(axis): refused with \(failure.reason.rawValue), which is not one of the "
                        + "bounded generation outcomes this route may end in at a draft it ADMITS"
                )
                XCTAssertLessThan(
                    elapsed, deadline,
                    "\(axis): the route took \(String(format: "%.1f", elapsed))s to refuse a "
                        + "draft it ADMITS — past its own \(Int(deadline))s watchdog, so the "
                        + "person watched a spinner get cancelled instead of being answered"
                )
                continue
            }
            let elapsed = Date().timeIntervalSince(started)
            measured.append((axis.rawValue, elapsed))
            delivered.append(axis.rawValue)
            print("BUILD117 shipping-shape real-model axis=\(axis.rawValue) "
                  + "draft=\(draft.count) total_ms=\(Int(elapsed * 1000)) "
                  + "deadline_s=\(Int(deadline)) "
                  + "margin=\(String(format: "%.2f", deadline / elapsed))x "
                  + "out=\(result.options.map { $0.text.count })")

            XCTAssertGreaterThanOrEqual(
                result.options.count, 1,
                "\(axis): a single-axis request must yield the tone it asked for"
            )
            // The whole point. One call, one budget, the real number.
            XCTAssertLessThan(
                elapsed, deadline,
                "\(axis): the tone the person tapped took \(String(format: "%.1f", elapsed))s of "
                    + "its \(Int(deadline))s watchdog at a \(draft.count)-character draft the "
                    + "route ADMITS. The watchdog would have fired and the person would have been "
                    + "told the rewrite did not finish. Fix the generation or stop admitting the "
                    + "draft — do not raise the deadline."
            )
        }

        // The worst call, called out, so the margin is a number somebody can
        // read rather than a claim. Lengths and durations only, never the text.
        let worst = measured.max(by: { $0.seconds < $1.seconds })
        if let worst {
            print("BUILD117 shipping-shape real-model WORST axis=\(worst.axis) "
                  + "total_ms=\(Int(worst.seconds * 1000)) "
                  + "margin=\(String(format: "%.2f", deadline / worst.seconds))x")
        }
        print("BUILD117 shipping-shape real-model delivered=\(delivered) "
              + "refused=\(refused.map { "\($0.axis):\($0.reason)" })")

        // The route must still be able to do its job at the length it admits.
        // Not "every tone every time" — the validator dropping a runaway is the
        // validator working — but a bound that admits a draft no tone can serve
        // is a bound that is lying about what this route does.
        XCTAssertFalse(
            delivered.isEmpty,
            "no tone produced a local rewrite at the \(draft.count)-character draft this "
                + "route ADMITS: \(refused.map { "\($0.axis)=\($0.reason)" })"
        )
    }

    /// The generation outcomes a bounded on-device request is allowed to end in.
    ///
    /// `rewriteDidNotFinish` is in this list on purpose, and it is the whole
    /// reason the response-token cap exists. Measured on this object: at the
    /// admitted 919-character bound the `clearer` single-axis generation runs
    /// away. Capped, it stops at **17.7s** (Debug) / **17.9s** (Release) with a
    /// truthful refusal, inside the 30s watchdog. With the cap lifted to the
    /// 2,048-token ceiling it ran **45.3s** and STILL did not close its JSON
    /// object — past the watchdog, so the person would have watched a spinner
    /// until it was cancelled. Loosening the budget makes this worse, not
    /// better, which is exactly why the cap is a safety device and stays.
    static let boundedLocalRefusals: Set<String> = [
        "rewriteDidNotFinish", "noValidRewrite", "generationFailed",
    ]

    /// Realistic, non-repetitive prose truncated at a WORD boundary.
    ///
    /// Truncating mid-word matters and is deliberately avoided here: a
    /// mid-word-truncated draft reproducibly sends the model into a loop
    /// (measured 80 s to `exceededContextWindowSize` uncapped, and
    /// `decodingFailure` at 27 s capped). That is the adversarial input the
    /// `.rewriteDidNotFinish` mapping exists for, not the ordinary message this
    /// test is about.
    static func realisticDraft(ofAtMost length: Int) -> String {
        let corpus = """
        Hi Priya, I wanted to put everything in one message so nothing gets lost. \
        The Q3 revenue deck is now at version 7 and lives in the Finance folder, not the old \
        Marketing one. Devansh moved the client call from Tuesday 2pm to Thursday 9:30am because \
        Bergstrom's team is in Zurich that week. We still owe them the churn cohort breakdown, \
        the updated CAC by channel, and the one-pager on the pricing test. I have the churn \
        numbers, Marcus has CAC, and nobody has picked up the pricing one-pager yet, which \
        worries me. Also, the invoice for the March retainer is 41 days overdue and accounting \
        flagged it twice. Can you chase Bergstrom's AP contact, Lena, directly rather than going \
        through the shared inbox? Last thing: I'm out from the 18th to the 24th for my sister's \
        wedding in Lisbon and will not have reliable signal. If anything urgent comes up in that \
        window, please route it to Devansh, and copy Marcus so he is not surprised. One more \
        scheduling note: the design review pencilled in for Friday afternoon has to move earlier, \
        because the print vendor needs final artwork by noon and Anneliese cannot approve \
        anything after eleven.
        """
        guard corpus.count > length else { return corpus }
        let prefix = String(corpus.prefix(length))
        guard let lastSpace = prefix.lastIndex(of: " ") else { return prefix }
        return String(prefix[prefix.startIndex..<lastSpace])
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
