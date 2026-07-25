// SetupDoctorTests.swift
// Setup Doctor — freshness, schema, derivation, navigation, and the two
// source-level contracts that keep the consumer surface honest.
//
// The Doctor's whole justification is that it refuses to claim more than it
// can verify, so most of what is worth testing here is negative: a stale
// check-in must NOT read as success, an unreadable one must NOT default to
// true, and a pane iOS won't open must NOT get a button. Those are the cases
// a future well-meaning "just make it green" change would break first, so
// they are pinned hardest.
//
// Everything under test is pure `Foundation` by construction — the rules live
// in `Shared/SetupDoctor.swift`, not in the SwiftUI layer — so this suite
// needs no simulator, no host app, and no network. The same assertions are
// mirrored in `Scripts/verify_setup_doctor.swift` so they can be run with
// `swiftc` when the Xcode lane is busy.

import XCTest

// The test target compiles `Shared/SetupDoctor.swift` directly but not
// `Shared/SharedUserDefaults.swift`, whose Keychain and analyzer dependencies
// the unit-test binary deliberately avoids (see the note above the existing
// `SharedKeys`/`SharedStore` stand-ins in `KeyboardControlGeometryTests.swift`,
// which this extends rather than duplicates).
//
// These two stand-ins supply exactly what the Setup Doctor reads from that
// file. `testTestModuleStandInsMatchProduction` re-reads the real source and
// fails if either drifts, so this convenience cannot quietly become fiction.
// `EntitlementState` is `public` because it appears in `SetupEntitlementSnapshot`'s
// public signature.

extension SharedKeys {
    static let keyboardLoaded = "tc.keyboardLoaded"
}

extension SharedStore {
    static let suiteName = "group.com.tonoit.shared"
}

// `CaseIterable` is the one addition over the production declaration: it lets
// the drift test below enumerate the stand-in's cases. `SetupDoctor.swift`
// consumes only the case values, so the extra conformance changes nothing it
// can observe.
public enum EntitlementState: String, CaseIterable {
    case entitled
    case notEntitled
    case unknown
}

final class SetupDoctorTests: XCTestCase {

    // A fixed instant: every freshness assertion below is expressed as an
    // offset from this so nothing depends on wall-clock time.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func isolatedDefaults() -> UserDefaults {
        let suite = "SetupDoctorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func entitled(_ state: EntitlementState?, checkedAt: Date?, registered: Bool = true) -> SetupEntitlementSnapshot {
        SetupEntitlementSnapshot(isRegistered: registered, state: state, checkedAt: checkedAt)
    }

    private func derive(
        heartbeat: KeyboardHeartbeat?,
        entitlement: SetupEntitlementSnapshot? = nil,
        testStartedAt: Date? = nil
    ) -> SetupDoctorState {
        SetupDoctorState.derive(
            heartbeat: heartbeat,
            entitlement: entitlement ?? entitled(.entitled, checkedAt: now),
            testStartedAt: testStartedAt,
            now: now
        )
    }

    // MARK: - Heartbeat freshness

    func testHeartbeatInsideTheLiveWindowCompletesTheKeyboardStep() {
        let beat = KeyboardHeartbeat(observedAt: now.addingTimeInterval(-30), fullAccess: true)
        XCTAssertEqual(derive(heartbeat: beat).step(.keyboardEnabled).status, .complete)
    }

    func testHeartbeatExactlyAtTheWindowEdgeStillCounts() {
        let edge = now.addingTimeInterval(-SetupDoctorPolicy.liveWindow)
        let beat = KeyboardHeartbeat(observedAt: edge, fullAccess: true)
        XCTAssertEqual(derive(heartbeat: beat).step(.keyboardEnabled).status, .complete)
    }

    /// The core anti-false-green rule. One second past the window and the
    /// keyboard step must stop claiming the present tense.
    func testStaleHeartbeatDegradesToConfirmedEarlierAndIsNotComplete() {
        let stale = now.addingTimeInterval(-SetupDoctorPolicy.liveWindow - 1)
        let step = derive(heartbeat: KeyboardHeartbeat(observedAt: stale, fullAccess: true)).step(.keyboardEnabled)
        XCTAssertEqual(step.status, .confirmedEarlier(at: stale))
        XCTAssertFalse(step.status.isComplete, "a stale check-in must never read as success")
    }

    func testMissingHeartbeatCannotConfirmRatherThanReportingNotEnabled() {
        let step = derive(heartbeat: nil).step(.keyboardEnabled)
        XCTAssertEqual(step.status, .cannotConfirm)
        // Absence of evidence is not evidence of absence: the copy must not
        // tell a correctly-configured user that their keyboard is missing.
        XCTAssertFalse(step.detail.lowercased().contains("not enabled"))
    }

    /// A device clock moved backwards leaves a future-stamped record. That is
    /// a clock change, not proof of anything, and must not be treated as live.
    func testFutureDatedHeartbeatIsNotTreatedAsLive() {
        let future = now.addingTimeInterval(3_600)
        let state = derive(heartbeat: KeyboardHeartbeat(observedAt: future, fullAccess: true))
        XCTAssertFalse(state.step(.keyboardEnabled).status.isComplete)
        XCTAssertEqual(state.step(.fullAccess).status, .cannotConfirm)
    }

    // MARK: - Full Access

    func testFullAccessCompletesOnlyWhenALiveHeartbeatReportsItOn() {
        let beat = KeyboardHeartbeat(observedAt: now, fullAccess: true)
        XCTAssertEqual(derive(heartbeat: beat).step(.fullAccess).status, .complete)
    }

    func testFullAccessOffIsActionNeeded() {
        let beat = KeyboardHeartbeat(observedAt: now, fullAccess: false)
        XCTAssertEqual(derive(heartbeat: beat).step(.fullAccess).status, .actionNeeded)
    }

    /// An old heartbeat that said Full Access was on proves nothing about now —
    /// the user may have revoked it since — so it must fall back to unknown
    /// rather than carrying the old `true` forward.
    func testStaleFullAccessTrueDoesNotSurviveAsComplete() {
        let stale = now.addingTimeInterval(-SetupDoctorPolicy.liveWindow - 1)
        let step = derive(heartbeat: KeyboardHeartbeat(observedAt: stale, fullAccess: true)).step(.fullAccess)
        XCTAssertEqual(step.status, .cannotConfirm)
    }

    // MARK: - Content-free schema

    func testHeartbeatSerializesExactlyThreeNonSensitiveFields() {
        let encoded = KeyboardHeartbeat(observedAt: now, fullAccess: true).encoded()
        XCTAssertEqual(
            Set(encoded.keys), KeyboardHeartbeat.encodedKeys,
            "the heartbeat wire shape is a privacy contract — adding a field is a deliberate decision, not a refactor"
        )
        XCTAssertEqual(KeyboardHeartbeat.encodedKeys, ["schema", "observedAt", "fullAccess"])
    }

    func testPersistedHeartbeatContainsNothingBeyondTheContract() {
        let defaults = isolatedDefaults()
        KeyboardHeartbeatStore(defaults: defaults).record(hasFullAccess: true, now: now)
        let raw = defaults.object(forKey: SetupDoctorKeys.heartbeat) as? [String: Any]
        XCTAssertNotNil(raw)
        XCTAssertEqual(Set(raw!.keys), KeyboardHeartbeat.encodedKeys)
    }

    func testHeartbeatRoundTripsThroughTheStore() {
        let defaults = isolatedDefaults()
        let store = KeyboardHeartbeatStore(defaults: defaults)
        store.record(hasFullAccess: false, now: now)
        let read = store.read()
        XCTAssertEqual(read?.fullAccess, false)
        XCTAssertEqual(read?.observedAt.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(read?.schema, KeyboardHeartbeat.currentSchema)
    }

    func testClearRemovesTheRecordSoARecheckMeasuresANewAppearance() {
        let defaults = isolatedDefaults()
        let store = KeyboardHeartbeatStore(defaults: defaults)
        store.record(hasFullAccess: true, now: now)
        store.clear()
        XCTAssertNil(store.read())
    }

    /// Every malformed shape must decode to nil. A reader that fell back to a
    /// default-constructed heartbeat would manufacture a `fullAccess` answer
    /// nobody observed.
    func testMalformedOrFutureSchemaHeartbeatsDecodeToNil() {
        XCTAssertNil(KeyboardHeartbeat.decoded(from: nil))
        XCTAssertNil(KeyboardHeartbeat.decoded(from: "not a dictionary"))
        XCTAssertNil(KeyboardHeartbeat.decoded(from: [:] as [String: Any]))
        XCTAssertNil(KeyboardHeartbeat.decoded(from: ["schema": 1, "observedAt": 1.0] as [String: Any]),
                     "a record missing fullAccess must not decode")
        XCTAssertNil(KeyboardHeartbeat.decoded(from: ["schema": 1, "fullAccess": true] as [String: Any]),
                     "a record missing its timestamp must not decode")
        XCTAssertNil(KeyboardHeartbeat.decoded(from: ["schema": 0, "observedAt": 0.0, "fullAccess": true] as [String: Any]),
                     "a zero timestamp is not a real observation")
        XCTAssertNil(
            KeyboardHeartbeat.decoded(from: [
                "schema": KeyboardHeartbeat.currentSchema + 1, "observedAt": 1.0, "fullAccess": true,
            ] as [String: Any]),
            "a schema from the future must be refused, not guessed at"
        )
    }

    func testAnUnreadableHeartbeatPresentsAsUnknownEndToEnd() {
        let defaults = isolatedDefaults()
        defaults.set(["schema": 99, "observedAt": now.timeIntervalSince1970, "fullAccess": true], forKey: SetupDoctorKeys.heartbeat)
        let state = derive(heartbeat: KeyboardHeartbeatStore(defaults: defaults).read())
        XCTAssertEqual(state.step(.keyboardEnabled).status, .cannotConfirm)
        XCTAssertEqual(state.step(.fullAccess).status, .cannotConfirm)
    }

    // MARK: - Entitlement rendering

    func testSignedOutIsActionNeeded() {
        let step = derive(heartbeat: nil, entitlement: entitled(nil, checkedAt: nil, registered: false)).step(.account)
        XCTAssertEqual(step.status, .actionNeeded)
    }

    func testFreshEntitledIsComplete() {
        let step = derive(heartbeat: nil, entitlement: entitled(.entitled, checkedAt: now)).step(.account)
        XCTAssertEqual(step.status, .complete)
    }

    func testNotEntitledIsActionNeeded() {
        let step = derive(heartbeat: nil, entitlement: entitled(.notEntitled, checkedAt: now)).step(.account)
        XCTAssertEqual(step.status, .actionNeeded)
    }

    /// Mirrors `TonePreferences.isProAuthoritative`: unknown and never-checked
    /// both fail closed. Neither may render as an active subscription.
    func testUnknownAndNeverCheckedEntitlementsFailClosed() {
        XCTAssertEqual(derive(heartbeat: nil, entitlement: entitled(.unknown, checkedAt: now)).step(.account).status, .cannotConfirm)
        XCTAssertEqual(derive(heartbeat: nil, entitlement: entitled(nil, checkedAt: nil)).step(.account).status, .cannotConfirm)
    }

    func testStaleEntitledVerdictStopsClaimingAnActiveSubscription() {
        let old = now.addingTimeInterval(-SetupDoctorPolicy.entitlementWindow - 1)
        let step = derive(heartbeat: nil, entitlement: entitled(.entitled, checkedAt: old)).step(.account)
        XCTAssertEqual(step.status, .cannotConfirm)
        XCTAssertFalse(step.status.isComplete)
    }

    func testEntitledWithNoRecordedCheckTimeIsNotComplete() {
        let step = derive(heartbeat: nil, entitlement: entitled(.entitled, checkedAt: nil)).step(.account)
        XCTAssertEqual(step.status, .cannotConfirm)
    }

    // MARK: - Test drive derivation

    func testTestDriveNeedsAHeartbeatNewerThanTheMomentTheTestBegan() {
        let started = now.addingTimeInterval(-10)
        // A check-in from BEFORE the test began is a replay, not a test.
        let earlier = KeyboardHeartbeat(observedAt: now.addingTimeInterval(-60), fullAccess: true)
        XCTAssertEqual(derive(heartbeat: earlier, testStartedAt: started).step(.testDrive).status, .cannotConfirm)

        let during = KeyboardHeartbeat(observedAt: now.addingTimeInterval(-5), fullAccess: true)
        XCTAssertEqual(derive(heartbeat: during, testStartedAt: started).step(.testDrive).status, .complete)
    }

    func testTestDriveIsUnconfirmedUntilTheUserStartsIt() {
        let beat = KeyboardHeartbeat(observedAt: now, fullAccess: true)
        XCTAssertEqual(derive(heartbeat: beat, testStartedAt: nil).step(.testDrive).status, .cannotConfirm)
    }

    /// The success copy must not claim more than the evidence supports: a
    /// heartbeat proves the keyboard became active, not which field it was in.
    func testTestDriveSuccessCopyDoesNotClaimTheSpecificTextField() {
        let started = now.addingTimeInterval(-10)
        let beat = KeyboardHeartbeat(observedAt: now, fullAccess: true)
        let detail = derive(heartbeat: beat, testStartedAt: started).step(.testDrive).detail.lowercased()
        XCTAssertFalse(detail.contains("this field"))
        XCTAssertFalse(detail.contains("in this text field"))
    }

    // MARK: - Whole-surface derivation

    func testEveryStepIsAlwaysProducedExactlyOnce() {
        let ids = derive(heartbeat: nil).steps.map(\.id)
        XCTAssertEqual(ids, SetupStepID.allCases)
    }

    func testFullySetUpRequiresAllFourStepsLiveVerified() {
        let started = now.addingTimeInterval(-10)
        let beat = KeyboardHeartbeat(observedAt: now, fullAccess: true)
        XCTAssertTrue(derive(heartbeat: beat, testStartedAt: started).isFullySetUp)

        // Drop any single pillar and the summary must stop claiming success.
        XCTAssertFalse(derive(heartbeat: beat, testStartedAt: nil).isFullySetUp)
        XCTAssertFalse(
            derive(
                heartbeat: KeyboardHeartbeat(observedAt: now, fullAccess: false),
                testStartedAt: started
            ).isFullySetUp
        )
        XCTAssertFalse(
            derive(heartbeat: beat, entitlement: entitled(.unknown, checkedAt: now), testStartedAt: started).isFullySetUp
        )
    }

    func testNoStepEverReportsCompleteWithoutAnyEvidence() {
        let barren = SetupDoctorState.derive(
            heartbeat: nil,
            entitlement: SetupEntitlementSnapshot(isRegistered: false, state: nil, checkedAt: nil),
            testStartedAt: nil,
            now: now
        )
        XCTAssertTrue(barren.steps.allSatisfy { !$0.status.isComplete })
        XCTAssertFalse(barren.isFullySetUp)
    }

    // MARK: - Navigation capability

    /// iOS has no public deep link into Settings ▸ General ▸ Keyboard ▸
    /// Keyboards. The model must say so, and the button caption must not
    /// promise to land there.
    func testAddKeyboardAdmitsItCannotLandOnTheKeyboardsPane() throws {
        let nav = SetupNavigation.addKeyboard
        XCTAssertFalse(nav.landsOnExactPane)
        XCTAssertFalse(nav.writtenSteps.isEmpty, "written steps are the only guarantee, so they must always exist")
        XCTAssertEqual(nav.buttonTitle, "Open Settings")
        let footnote = try XCTUnwrap(nav.buttonFootnote)
        XCTAssertTrue(
            footnote.contains("can’t jump straight"),
            "the caption must tell the user the button lands short of the keyboard list"
        )
    }

    func testFullAccessDeepLinkLandsOnTonosOwnSettingsPage() {
        let nav = SetupNavigation.fullAccess
        XCTAssertTrue(nav.landsOnExactPane)
        XCTAssertTrue(nav.opensAppSettingsRoot)
        XCTAssertEqual(nav.buttonTitle, "Open Settings")
    }

    /// Switching keyboards happens on the keyboard, not in Settings. Offering
    /// a Settings button here would be misdirection, so there must be none.
    func testSwitchingKeyboardsOffersNoSettingsButton() {
        let nav = SetupNavigation.switchToTono
        XCTAssertFalse(nav.opensAppSettingsRoot)
        XCTAssertNil(nav.buttonTitle)
        XCTAssertNil(nav.buttonFootnote)
        XCTAssertFalse(nav.writtenSteps.isEmpty)
    }

    func testEveryNavigationBlockCarriesWrittenStepsWhetherOrNotItHasAButton() {
        for nav in [SetupNavigation.addKeyboard, .fullAccess, .switchToTono] {
            XCTAssertFalse(nav.writtenSteps.isEmpty)
            // A button may only exist where a real API opens something.
            if nav.buttonTitle != nil { XCTAssertTrue(nav.opensAppSettingsRoot) }
        }
    }

    // MARK: - Source contracts

    /// Consumer copy must never leak infrastructure. Scans string LITERALS
    /// (not comments or type names) in both Setup Doctor files, since those
    /// literals are what a user can actually read on screen.
    func testConsumerSurfaceExposesNoEndpointsTokensOrEnvironmentLabels() throws {
        let banned = ["http", "://", "/v1", "/api", ".com", ".io", "bearer", "token",
                      "localhost", "staging", "endpoint", "backendurl", "api key"]
        for file in ["App/SetupDoctorView.swift", "Shared/SetupDoctor.swift"] {
            for literal in Self.stringLiterals(in: try Self.source(file)) {
                let haystack = literal.lowercased()
                for needle in banned {
                    XCTAssertFalse(
                        haystack.contains(needle),
                        "consumer-visible string in \(file) leaks “\(needle)”: \(literal)"
                    )
                }
            }
        }
    }

    /// The Full Access explanation must stay narrower than the truth. Coach
    /// genuinely transmits the draft, so a blanket "nothing leaves your device"
    /// claim would be false advertising.
    func testFullAccessCopyDoesNotOverclaimPrivacy() {
        let copy = (FullAccessExplainer.body + FullAccessExplainer.neverCollected)
            .joined(separator: " ").lowercased()
        XCTAssertFalse(copy.contains("nothing leaves your device"))
        XCTAssertFalse(copy.contains("never leaves your device"))
        XCTAssertFalse(copy.contains("we don’t collect anything"))
        XCTAssertFalse(copy.contains("no data is sent"))
        // ...and it must positively disclose the round-trip it does make.
        XCTAssertTrue(copy.contains("coach"))
        XCTAssertTrue(copy.contains("sends that one draft"))
    }

    /// The write path must be incapable of carrying content. Pinned at the API
    /// shape AND the single call site, so neither can drift alone.
    func testHeartbeatWritePathCannotCarryTypedContent() throws {
        let api = try Self.source("Shared/SetupDoctor.swift")
        XCTAssertTrue(
            api.contains("public func record(hasFullAccess: Bool, now: Date)"),
            "the recording API must accept only a Bool and a timestamp"
        )

        let controller = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(
            controller.contains("KeyboardHeartbeatStore().record(hasFullAccess: hasFullAccess, now: Date())"),
            "the extension must record only the live Full Access reading and the time"
        )
        XCTAssertEqual(
            controller.components(separatedBy: "KeyboardHeartbeatStore(").count - 1, 1,
            "there must be exactly one heartbeat write site to review"
        )

        // Nothing document-shaped may appear inside the recording function.
        let body = try XCTUnwrap(Self.functionBody(named: "recordSetupHeartbeat", in: controller))
        for forbidden in ["documentProxy", "documentContext", "textDocumentProxy", "bundleIdentifier",
                          "hostSession", "recipient", "draft"] {
            XCTAssertFalse(body.contains(forbidden), "heartbeat write must not touch \(forbidden)")
        }
    }

    /// Full Access can only be read where iOS exposes it. If the recording call
    /// ever passed a literal instead of the live property, every downstream
    /// green tick would be fabricated.
    func testFullAccessIsReadFromTheInputViewControllerNotAssumed() throws {
        let controller = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertFalse(controller.contains("record(hasFullAccess: true"))
        XCTAssertFalse(controller.contains("record(hasFullAccess: false"))
    }

    /// The stand-ins at the top of this file must keep matching the shipping
    /// declarations, or every assertion below would be verifying a fiction.
    func testTestModuleStandInsMatchProduction() throws {
        let shared = try Self.source("Shared/SharedUserDefaults.swift")
        XCTAssertTrue(
            shared.contains("public static let keyboardLoaded = \"tc.keyboardLoaded\""),
            "the keyboardLoaded key stand-in has drifted from SharedUserDefaults.swift"
        )
        XCTAssertTrue(
            shared.contains("public static let suiteName = \"group.com.tonoit.shared\""),
            "the App Group suite stand-in has drifted from SharedUserDefaults.swift"
        )
        for state in ["entitled", "notEntitled", "unknown"] {
            XCTAssertTrue(
                shared.contains("case \(state)"),
                "EntitlementState.\(state) is missing from SharedUserDefaults.swift"
            )
        }
        XCTAssertEqual(
            EntitlementState.allCases.map(\.rawValue), ["entitled", "notEntitled", "unknown"],
            "the stand-in must model every production entitlement state"
        )
    }

    // MARK: - Source helpers

    private static func source(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Naive but sufficient literal scanner: the Setup Doctor sources contain
    /// no escaped quotes, and line comments are dropped first so prose about
    /// endpoints in a comment cannot fail a consumer-copy assertion.
    private static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let code = line.contains("//") ? String(line[..<line.range(of: "//")!.lowerBound]) : line
            var inside = false
            var current = ""
            for character in code {
                if character == "\"" {
                    if inside { literals.append(current); current = "" }
                    inside.toggle()
                } else if inside {
                    current.append(character)
                }
            }
        }
        return literals
    }

    /// Returns the brace-balanced body of a named function, so an assertion can
    /// be scoped to that function rather than the whole 170KB file.
    private static func functionBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
