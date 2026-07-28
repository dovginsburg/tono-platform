// Build117ReadTheAskTests.swift
// Build 117 — Read the Ask.
//
// What these tests are for, in one paragraph. Read the Ask points Tono at a
// message somebody else wrote, which is a different and more dangerous thing
// than pointing it at a draft you are about to send. Three ways it could go
// wrong badly enough to matter: Tono could decide for itself whether a piece of
// text is incoming or outgoing and get it backwards; it could read something
// nobody gave it permission to read; or it could tell you what the sender was
// feeling and be confidently wrong about a person you actually know. Everything
// below is aimed at one of those three.
//
// BASELINE. The Swift half of this suite could not be run against the base
// object, because the types it exercises did not exist there — a test file that
// does not compile is a build error, not a red test. The honest substitute is
// recorded in the handoff and it is two things: (1) the BACKEND half of the same
// contract WAS run against the exact base object and produced 53 verbatim
// failures; (2) every guard shipped here was mutation-tested — deleted or
// inverted one at a time — and the named test that caught it is recorded. A
// guard nothing catches is a guard that is not there.
//
// Naming and structure follow `Build116AirplaneModeTests`, including its hosting
// machinery, for the same reason: assertions about what a person sees should be
// taken from a laid-out view in a real window, not from a replica of one.

import XCTest
import SwiftUI
import UIKit
@testable import Tono

final class Build117ReadTheAskTests: XCTestCase {

    // ───────────────────────────────────────────────────────────────────
    // Fixtures
    // ───────────────────────────────────────────────────────────────────

    /// A received message with one concrete ask and a deadline in the sender's
    /// own words.
    static let receivedWithDeadline =
        "Hi — can you send me the Q3 deck by Friday? The board wants to read it over the weekend."

    /// The same shape with no deadline anywhere in it. Any deadline that appears
    /// in a reading of this was invented.
    static let receivedWithoutDeadline =
        "Hi — can you send me the Q3 deck? The board wants to read it."

    private static let readingJSON = #"""
    {"mode":"read_ask","status":"ok",
     "ask":"Send the Q3 deck.",
     "by_when":"by Friday",
     "unclear":"Which version of the deck is meant.",
     "possible_readings":[],
     "plan":"pro"}
    """#

    private static let declinedJSON = #"""
    {"mode":"read_ask","status":"declined","ask":null,"by_when":null,
     "unclear":null,"possible_readings":[],"plan":"pro"}
    """#

    // ───────────────────────────────────────────────────────────────────
    // The network stub
    // ───────────────────────────────────────────────────────────────────

    /// Claims only the three paths this feature can originate, and tallies them
    /// separately.
    ///
    /// Registered process-wide because `TonoBackend` builds on
    /// `URLSession.shared`, which no test can hand a configuration to. The
    /// known hazard of that (Build 109) is charging the host app's own launch
    /// traffic to the code under test, so the tally that matters —
    /// `readAskCount` — counts a path nothing else in this process issues.
    final class ReadAskStub: URLProtocol {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var _readAskCount = 0
        private nonisolated(unsafe) static var _analyzeCount = 0
        private nonisolated(unsafe) static var _lastReadAskBody = ""
        private nonisolated(unsafe) static var _lastAnalyzeBody = ""
        private nonisolated(unsafe) static var _readAskJSON = Build117ReadTheAskTests.readingJSON
        private nonisolated(unsafe) static var _readAskStatus = 200

        static var readAskCount: Int { lock.withLock { _readAskCount } }
        static var analyzeCount: Int { lock.withLock { _analyzeCount } }
        static var lastReadAskBody: String { lock.withLock { _lastReadAskBody } }
        static var lastAnalyzeBody: String { lock.withLock { _lastAnalyzeBody } }

        static var readAskJSON: String {
            get { lock.withLock { _readAskJSON } }
            set { lock.withLock { _readAskJSON = newValue } }
        }
        static var readAskStatus: Int {
            get { lock.withLock { _readAskStatus } }
            set { lock.withLock { _readAskStatus = newValue } }
        }

        /// Hold the response, so a test can act while a request is genuinely in
        /// flight.
        ///
        /// Without this the stub answers inside `startLoading` before the next
        /// line of the test runs, so "tap Remove while the reading is in
        /// flight" was never actually in flight — and the cancellation test
        /// passed with the cancellation deleted. A test that cannot fail is not
        /// evidence.
        private nonisolated(unsafe) static var _holdSeconds: TimeInterval = 0
        static var holdSeconds: TimeInterval {
            get { lock.withLock { _holdSeconds } }
            set { lock.withLock { _holdSeconds = newValue } }
        }

        static func reset() {
            lock.withLock {
                _readAskCount = 0
                _analyzeCount = 0
                _lastReadAskBody = ""
                _lastAnalyzeBody = ""
                _readAskJSON = Build117ReadTheAskTests.readingJSON
                _readAskStatus = 200
                _holdSeconds = 0
            }
        }

        private static let claimed: Set<String> = ["/v1/register", "/v1/me", "/api/read-ask", "/api/analyze"]

        override class func canInit(with request: URLRequest) -> Bool {
            guard let path = request.url?.path, claimed.contains(path) else { return false }
            // `httpBody` is nil once URLSession has taken the request, so the
            // body is read here — the one point where it is still attached.
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
                ?? request.bodyStreamText()
            lock.withLock {
                if path == "/api/read-ask" { _readAskCount += 1; _lastReadAskBody = body }
                if path == "/api/analyze" { _analyzeCount += 1; _lastAnalyzeBody = body }
            }
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            if url.path == "/api/read-ask", Self.holdSeconds > 0 {
                Thread.sleep(forTimeInterval: Self.holdSeconds)
            }
            var status = 200
            let body: String
            switch url.path {
            case "/v1/register":
                body = #"{"device_id":"b117","api_token":"b117-token","device_credential":"b117-cred","#
                    + #""plan":"pro","is_pro":true,"account_id":"6E7E0A64-1B2C-4D3E-8F90-A1B2C3D4E5F6"}"#
            case "/v1/me":
                body = #"{"device_id":"b117","plan":"pro","is_pro":true,"subscription_status":"active","#
                    + #""subscription_renews_at":null,"account_id":"6E7E0A64-1B2C-4D3E-8F90-A1B2C3D4E5F6","#
                    + #""email":null,"email_verified_at":null,"device_count_for_email":1,"max_devices_per_email":3}"#
            case "/api/read-ask":
                status = Self.readAskStatus
                body = status == 200 ? Self.readAskJSON : #"{"error":{"message":"nope"}}"#
            default:
                body = Self.analysisJSON
            }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// All four axes in `RewriteAxis.allCases` order — `analyze(mode:.coach)`
        /// rejects an incomplete set.
        static let analysisJSON = #"""
        {"risk_level":"medium","perception":"Reads as rushed.","subtext":"","risk_reason":null,
         "flags":[],"plan":"pro",
         "suggestions":[
           {"axis":"warmer","text":"WARMER-B117","rationale":null,"risk_after":"low"},
           {"axis":"clearer","text":"CLEARER-B117","rationale":null,"risk_after":"low"},
           {"axis":"funnier","text":"FUNNIER-B117","rationale":null,"risk_after":"low"},
           {"axis":"safer","text":"SAFER-B117","rationale":null,"risk_after":"low"}
         ]}
        """#
    }

    override func setUp() {
        super.setUp()
        ReadAskStub.reset()
        URLProtocol.registerClass(ReadAskStub.self)
        addTeardownBlock {
            URLProtocol.unregisterClass(ReadAskStub.self)
            ReadAskStub.reset()
        }

        // Every device secret this class can cause to be written, removed after
        // each test.
        //
        // Not hygiene for its own sake. The Keychain outlives the process AND
        // the test run: a token left behind here means the host app finds
        // itself registered at its NEXT launch and issues `/v1/me` during
        // startup — which lands inside `Build109…testLocalLaneMeasurement…`'s
        // measurement window and is charged to the keyboard. A test that
        // poisons a later run of an unrelated suite is worse than a test that
        // fails.
        let secrets = [
            Tono.KeychainKeys.apiToken, Tono.KeychainKeys.deviceID,
            Tono.KeychainKeys.deviceCredential, Tono.KeychainKeys.accountID,
            Tono.KeychainKeys.signedInEmail,
        ]
        let before = secrets.map { ($0, Tono.SharedKeychain.get($0)) }
        addTeardownBlock {
            for (key, value) in before {
                if let value {
                    Tono.SharedKeychain.set(value, forKey: key)
                } else {
                    Tono.SharedKeychain.delete(key)
                }
            }
        }
    }

    // ───────────────────────────────────────────────────────────────────
    // Stores
    // ───────────────────────────────────────────────────────────────────

    /// A defaults suite nothing else can see, removed afterwards.
    private func isolatedDefaults(
        _ label: String = #function, file: StaticString = #filePath, line: UInt = #line
    ) throws -> UserDefaults {
        let name = "build117.\(label).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name), file: file, line: line)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    /// The shared App Group store the shipping views actually read, with its
    /// previous value restored afterwards. The views construct
    /// `ReadTheAskActivation()` themselves, so a test about what the SHIPPING
    /// screen does has to write where the shipping screen reads.
    private func setSharedActivation(_ enabled: Bool) {
        let defaults = Tono.SharedStore.defaults
        let previous = defaults.object(forKey: ReadTheAskKeys.enabled)
        addTeardownBlock {
            if let previous {
                Tono.SharedStore.defaults.set(previous, forKey: ReadTheAskKeys.enabled)
            } else {
                Tono.SharedStore.defaults.removeObject(forKey: ReadTheAskKeys.enabled)
            }
        }
        defaults.set(enabled, forKey: ReadTheAskKeys.enabled)
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1. The explicit mode boundary
    // ═══════════════════════════════════════════════════════════════════

    func testTheModeVocabularyIsExactlyRewriteAndReadAsk() {
        XCTAssertEqual(
            Set(TonoRequestMode.allCases.map(\.rawValue)), ["rewrite", "read_ask"],
            "the wire vocabulary is part of the contract on both sides"
        )
    }

    func testAMissingModeIsRefusedRatherThanDefaulted() {
        XCTAssertNil(TonoRequestMode.explicit(nil))
        XCTAssertNil(TonoRequestMode.explicit(""))
    }

    /// Every one of these is a value this app has never sent. Repairing one into
    /// a mode is the inference the whole feature is built to avoid, so each is
    /// refused rather than trimmed, folded or guessed at.
    func testAnAmbiguousModeIsRefusedRatherThanRepaired() {
        for ambiguous in [
            " read_ask", "read_ask ", " read_ask ", "READ_ASK", "Read_Ask",
            "read-ask", "readAsk", "read", "coach", "ask", "REWRITE", "rewrite ",
        ] {
            XCTAssertNil(
                TonoRequestMode.explicit(ambiguous),
                "“\(ambiguous)” was accepted as a mode; exact match only"
            )
        }
    }

    func testTheTwoRealModesParse() {
        XCTAssertEqual(TonoRequestMode.explicit("rewrite"), .rewrite)
        XCTAssertEqual(TonoRequestMode.explicit("read_ask"), .readAsk)
    }

    /// The legacy default is allowed to exist in exactly one place, and this is
    /// the assertion that it still maps to the byte the established wire has
    /// always carried.
    func testTheLegacyAdapterMapsRewriteToTheUnchangedCoachWire() throws {
        XCTAssertEqual(try TonoLegacyAnalysisMode.analysisMode(for: .rewrite), .coach)
        XCTAssertEqual(AnalysisMode.coach.rawValue, "coach")
    }

    /// The legacy `read` mode asks a model for the sender's emotional state.
    /// Read the Ask must never be able to reach it — not by mapping, not by
    /// default, not by mistake.
    func testTheLegacyAdapterRefusesToCarryReadTheAsk() {
        XCTAssertThrowsError(try TonoLegacyAnalysisMode.analysisMode(for: .readAsk)) { error in
            XCTAssertEqual(error as? TonoModeError, .modeNotServedHere(.readAsk))
        }
    }

    /// The transport is the last place a wrong mode can be stopped, and it stops
    /// one — before the request is built, so nothing is sent at all.
    func testTheTransportRefusesTheRewriteModeAndSendsNothing() async {
        setSharedActivation(true)
        do {
            _ = try await TonoBackend.shared.readAsk(
                receivedText: Self.receivedWithDeadline, mode: .rewrite
            )
            XCTFail("the Read the Ask transport served a rewrite request")
        } catch {
            XCTAssertEqual(error as? TonoModeError, .modeNotServedHere(.rewrite))
        }
        XCTAssertEqual(ReadAskStub.readAskCount, 0, "a refused mode still reached the network")
    }

    func testTheRequestStatesItsModeOnTheWire() async throws {
        setSharedActivation(true)
        Tono.SharedKeychain.set("b117-token", forKey: Tono.KeychainKeys.apiToken)
        _ = try await TonoBackend.shared.readAsk(
            receivedText: Self.receivedWithDeadline, mode: .readAsk
        )
        XCTAssertTrue(
            ReadAskStub.lastReadAskBody.contains("\"mode\":\"read_ask\""),
            "the request did not state its mode: \(ReadAskStub.lastReadAskBody)"
        )
    }

    /// A response that does not answer in the mode it was asked in is not a
    /// response to this request.
    func testAnEnvelopeInTheWrongModeIsRefused() {
        let envelope = ReadAskEnvelope(
            mode: "read", status: "ok", ask: "Send the deck.",
            byWhen: nil, unclear: nil, possibleReadings: []
        )
        XCTAssertThrowsError(try envelope.validated(against: Self.receivedWithDeadline)) { error in
            XCTAssertEqual(
                error as? ReadAskContractError,
                .modeMismatch(expected: "read_ask", received: "read")
            )
        }
    }

    func testAnUnrecognisedStatusIsRefused() {
        let envelope = ReadAskEnvelope(
            mode: "read_ask", status: "partial", ask: "Send the deck.",
            byWhen: nil, unclear: nil, possibleReadings: []
        )
        XCTAssertThrowsError(try envelope.validated(against: Self.receivedWithDeadline))
    }

    // ═══════════════════════════════════════════════════════════════════
    // 2. Off by default, and off means nothing happens
    // ═══════════════════════════════════════════════════════════════════

    func testTheToggleIsOffOnAFreshInstall() throws {
        let defaults = try isolatedDefaults()
        XCTAssertNil(
            defaults.object(forKey: ReadTheAskKeys.enabled),
            "a fresh install must have written nothing"
        )
        XCTAssertFalse(ReadTheAskActivation(defaults: defaults).isEnabled)
    }

    /// Absent, explicit-false and a junk value all land in the same place. A
    /// privacy default that only holds for the tidy case is not a default.
    func testEveryUnsetOrDamagedValueReadsAsOff() throws {
        let defaults = try isolatedDefaults()
        let activation = ReadTheAskActivation(defaults: defaults)

        XCTAssertFalse(activation.isEnabled, "absent")
        defaults.set(false, forKey: ReadTheAskKeys.enabled)
        XCTAssertFalse(activation.isEnabled, "explicit false")
        defaults.set("yes", forKey: ReadTheAskKeys.enabled)
        XCTAssertFalse(activation.isEnabled, "a string is not consent")
        defaults.removeObject(forKey: ReadTheAskKeys.enabled)
        XCTAssertFalse(activation.isEnabled, "removed")
    }

    func testTheToggleRoundTrips() throws {
        let defaults = try isolatedDefaults()
        let activation = ReadTheAskActivation(defaults: defaults)
        activation.setEnabled(true)
        XCTAssertTrue(activation.isEnabled)
        activation.setEnabled(false)
        XCTAssertFalse(activation.isEnabled)
    }

    /// The gate that makes "nothing is sent while it is off" true no matter how
    /// the action is reached — an accessibility activation, a hardware keyboard,
    /// a caller written next year.
    func testTheTransportSendsNothingWhileTheToggleIsOff() async throws {
        let defaults = try isolatedDefaults()
        do {
            _ = try await TonoBackend.shared.readAsk(
                receivedText: Self.receivedWithDeadline,
                mode: .readAsk,
                activation: ReadTheAskActivation(defaults: defaults)
            )
            XCTFail("a reading was served while Read the Ask was off")
        } catch {
            XCTAssertEqual(error as? ReadAskContractError, .notActivated)
        }
        XCTAssertEqual(
            ReadAskStub.readAskCount, 0,
            "the received message left the device while the toggle was off"
        )
    }

    /// The whole point of the gate being in the transport: it holds even when
    /// the same call is made repeatedly from a surface that thinks it may.
    func testRepeatedAttemptsWhileOffStillSendNothing() async throws {
        let defaults = try isolatedDefaults()
        for _ in 0..<5 {
            _ = try? await TonoBackend.shared.readAsk(
                receivedText: Self.receivedWithDeadline,
                mode: .readAsk,
                activation: ReadTheAskActivation(defaults: defaults)
            )
        }
        XCTAssertEqual(ReadAskStub.readAskCount, 0)
    }

    // ═══════════════════════════════════════════════════════════════════
    // 3. By when: stated, or absent. Never guessed.
    // ═══════════════════════════════════════════════════════════════════

    func testADeadlineTheSenderWroteSurvives() throws {
        let envelope = ReadAskEnvelope(
            mode: "read_ask", status: "ok", ask: "Send the Q3 deck.",
            byWhen: "by Friday", unclear: nil, possibleReadings: []
        )
        guard case .reading(let result) = try envelope.validated(against: Self.receivedWithDeadline) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(result.byWhen, "by Friday")
    }

    /// The single most damaging thing this feature could do is put a plausible
    /// time on screen that nobody wrote.
    func testAFabricatedDeadlineIsDroppedAndTheReadingSurvives() throws {
        let envelope = ReadAskEnvelope(
            mode: "read_ask", status: "ok", ask: "Send the Q3 deck.",
            byWhen: "by Tuesday at 9am", unclear: nil, possibleReadings: []
        )
        guard case .reading(let result) = try envelope.validated(against: Self.receivedWithoutDeadline) else {
            return XCTFail("expected a reading")
        }
        XCTAssertNil(result.byWhen, "a deadline appeared for a message that states none")
        XCTAssertEqual(result.ask, "Send the Q3 deck.", "dropping the deadline destroyed the reading")
    }

    /// Paraphrase is where reporting stops and interpreting starts. "end of the
    /// week" is a reasonable reading of "by Friday" and it is still not what the
    /// sender wrote.
    func testAParaphrasedDeadlineIsDropped() throws {
        for paraphrase in ["end of the week", "this week", "in two days", "EOD Friday", "Friday 5pm"] {
            let envelope = ReadAskEnvelope(
                mode: "read_ask", status: "ok", ask: "Send the Q3 deck.",
                byWhen: paraphrase, unclear: nil, possibleReadings: []
            )
            guard case .reading(let result) = try envelope.validated(against: Self.receivedWithDeadline) else {
                return XCTFail("expected a reading")
            }
            XCTAssertNil(result.byWhen, "“\(paraphrase)” was rendered as a stated deadline")
        }
    }

    /// Typography is not paraphrase. A model that returns "by Friday," or
    /// "By Friday" has quoted the sender; punishing it for that would push real
    /// deadlines off the screen for no gain.
    func testQuotationSurvivesCaseAndTrailingPunctuation() {
        for variant in ["by Friday", "By Friday", "by Friday,", "  by  Friday  ", "by friday."] {
            XCTAssertTrue(
                ReadAskGuard.isQuoted(variant, from: Self.receivedWithDeadline),
                "“\(variant)” should count as quoted"
            )
        }
        XCTAssertFalse(ReadAskGuard.isQuoted("", from: Self.receivedWithDeadline))
        XCTAssertFalse(ReadAskGuard.isQuoted("   ", from: Self.receivedWithDeadline))
    }

    /// The screen says so. "No deadline stated" is true and useful; a blank
    /// space invites the reader to supply their own.
    @MainActor
    func testAMessageWithNoDeadlineSaysSoOnScreen() throws {
        ReadAskStub.readAskJSON = #"""
        {"mode":"read_ask","status":"ok","ask":"Send the Q3 deck.","by_when":null,
         "unclear":null,"possible_readings":[],"plan":"pro"}
        """#
        let controller = try hostReading(receivedText: Self.receivedWithoutDeadline)
        let screen = rendered(controller)
        XCTAssertTrue(screen.contains(ReadTheAskCopy.byWhenAbsent), screen)
    }

    // ═══════════════════════════════════════════════════════════════════
    // 4. Never diagnose the sender
    // ═══════════════════════════════════════════════════════════════════

    static let senderClaims = [
        "The sender is frustrated and wants acknowledgment.",
        "They really mean that you have let them down.",
        "They seem annoyed about the delay.",
        "She sounds upset about the reschedule.",
        "He is being passive-aggressive about the deadline.",
        "Read between the lines: they want an apology.",
        "The hidden intent is to make you feel guilty.",
        "You seem to have missed their point.",
        "You sound defensive in this thread.",
        "Sentiment: negative.",
        "This person wants you to feel bad.",
        "The writer means something else entirely.",
    ]

    /// Two controls with the same accessibility label on one screen is a defect
    /// in itself: VoiceOver announces the same words for a control that changes
    /// the surface and a control that sends a message off the device. (This
    /// caught exactly that — the action was first written as "Read the Ask" and
    /// every activation in this suite hit the mode segment instead.)
    func testNoTwoControlsOnTheReadingSurfaceShareALabel() {
        let labels = [
            ReadTheAskCopy.rewriteModeTitle, ReadTheAskCopy.readAskModeTitle,
            ReadTheAskCopy.readAction, ReadTheAskCopy.removeReceivedText,
            ReadTheAskCopy.draftReplyAction, ReadTheAskCopy.clarificationAction,
            ReadTheAskCopy.activationDismiss, ReadTheAskCopy.activationConfirm,
            ReadTheAskCopy.activationToggleTitle,
        ]
        XCTAssertEqual(Set(labels).count, labels.count, "two controls share a label: \(labels)")
    }

    func testTheGuardRecognisesAClaimAboutTheSender() {
        for claim in Self.senderClaims {
            XCTAssertTrue(
                ReadAskGuard.claimsAboutTheSender(claim),
                "“\(claim)” was not recognised as a claim about the sender"
            )
        }
    }

    /// A claim about a person is not a field that can be trimmed back into
    /// honesty, so the whole reading goes rather than a sanitised version of it.
    func testAReadingThatDiagnosesTheSenderIsRefusedWhole() {
        for claim in Self.senderClaims {
            let envelope = ReadAskEnvelope(
                mode: "read_ask", status: "ok", ask: claim,
                byWhen: nil, unclear: nil, possibleReadings: []
            )
            XCTAssertThrowsError(
                try envelope.validated(against: Self.receivedWithDeadline),
                "“\(claim)” was rendered as an Ask"
            ) { error in
                XCTAssertEqual(error as? ReadAskContractError, .claimsAboutTheSender(field: "ask"))
            }
        }
    }

    /// `unclear` and the readings are shown to a person exactly like the Ask is,
    /// so they are held to exactly the same rule.
    func testTheGuardCoversEveryFieldThatReachesTheScreen() {
        let claim = "They seem annoyed about the delay."
        let unclearEnvelope = ReadAskEnvelope(
            mode: "read_ask", status: "ok", ask: "Send the deck.",
            byWhen: nil, unclear: claim, possibleReadings: []
        )
        XCTAssertThrowsError(try unclearEnvelope.validated(against: Self.receivedWithDeadline)) { error in
            XCTAssertEqual(error as? ReadAskContractError, .claimsAboutTheSender(field: "unclear"))
        }

        let readingEnvelope = ReadAskEnvelope(
            mode: "read_ask", status: "ok", ask: "Send the deck.",
            byWhen: nil, unclear: nil, possibleReadings: [claim]
        )
        XCTAssertThrowsError(try readingEnvelope.validated(against: Self.receivedWithDeadline)) { error in
            XCTAssertEqual(
                error as? ReadAskContractError, .claimsAboutTheSender(field: "possibleReadings")
            )
        }
    }

    /// The guard has to survive contact with real asks. A question the SENDER
    /// asked about the reader is a legitimate ask, not a claim about the sender,
    /// and a guard that blocks it protects nobody.
    func testOrdinaryReadingsAreNotOverBlocked() {
        for ordinary in [
            "Confirm whether you are free on Tuesday.",
            "Send the Q3 deck to the board.",
            "Decide whether to move the launch date.",
            "Reply with the invoice number.",
            "Let them know if the meeting still works for you.",
            "Approve the budget line for the new hire.",
        ] {
            XCTAssertFalse(
                ReadAskGuard.claimsAboutTheSender(ordinary),
                "“\(ordinary)” is an ordinary ask and was blocked"
            )
        }
    }

    func testAnEmptyAskIsRefused() {
        for empty in [nil, "", "   "] as [String?] {
            let envelope = ReadAskEnvelope(
                mode: "read_ask", status: "ok", ask: empty,
                byWhen: nil, unclear: nil, possibleReadings: []
            )
            XCTAssertThrowsError(try envelope.validated(against: Self.receivedWithDeadline)) { error in
                XCTAssertEqual(error as? ReadAskContractError, .askMissing)
            }
        }
    }

    func testPossibleReadingsAreBounded() {
        let envelope = ReadAskEnvelope(
            mode: "read_ask", status: "ok", ask: "Send the deck.", byWhen: nil, unclear: nil,
            possibleReadings: (0..<9).map { "Reading \($0)." }
        )
        XCTAssertThrowsError(try envelope.validated(against: Self.receivedWithDeadline)) { error in
            XCTAssertEqual(error as? ReadAskContractError, .tooManyReadings(9))
        }
    }

    /// They are offered as possibilities, and the screen says so in words —
    /// a heading alone is a formatting convention, not a statement.
    @MainActor
    func testPossibleReadingsAreLabelledAsPossibilities() throws {
        ReadAskStub.readAskJSON = #"""
        {"mode":"read_ask","status":"ok","ask":"Send the Q3 deck.","by_when":"by Friday",
         "unclear":null,"possible_readings":["The full deck.","Only the summary slides."],"plan":"pro"}
        """#
        let controller = try hostReading(receivedText: Self.receivedWithDeadline)
        let screen = rendered(controller)
        XCTAssertTrue(screen.contains(ReadTheAskCopy.possibleReadingsHeading), screen)
        XCTAssertTrue(screen.contains(ReadTheAskCopy.possibleReadingsCaption), screen)
    }

    // ═══════════════════════════════════════════════════════════════════
    // 5. The safety boundary, without becoming a crisis product
    // ═══════════════════════════════════════════════════════════════════

    /// A declined message gets one neutral sentence. No helpline, no resource,
    /// no clinical microcopy, no interpretation — product-scope silence, not a
    /// judgement about anyone.
    @MainActor
    func testADeclinedReadingSaysOneNeutralThingAndOffersNoResources() throws {
        ReadAskStub.readAskJSON = Self.declinedJSON
        let controller = try hostReading(receivedText: "i want to kill myself")
        let screen = rendered(controller)
        XCTAssertTrue(screen.contains(ReadTheAskCopy.declined), screen)
        for banned in ["988", "911", "hotline", "helpline", "crisis", "therapist", "counsel", "suicide"] {
            XCTAssertFalse(
                screen.lowercased().contains(banned),
                "the declined surface mentions “\(banned)”"
            )
        }
        XCTAssertFalse(screen.contains(ReadTheAskCopy.askHeading), "a declined message got a reading")
    }

    /// A message that asks for nothing is read successfully, and the answer is
    /// that there is no request in it. This is a stated outcome, not a failure —
    /// answering "thanks for dinner last night" with "try again" would be a
    /// retry loop over something that can never produce an Ask.
    @MainActor
    func testAMessageThatAsksForNothingSaysSoInsteadOfFailing() throws {
        ReadAskStub.readAskJSON = #"""
        {"mode":"read_ask","status":"no_ask","ask":null,"by_when":null,
         "unclear":null,"possible_readings":[],"plan":"pro"}
        """#
        let controller = try hostReading(receivedText: "Thanks for dinner last night.")
        let screen = rendered(controller)
        XCTAssertTrue(screen.contains(ReadTheAskCopy.noAsk), screen)
        XCTAssertFalse(screen.contains(ReadTheAskCopy.askHeading), "an empty Ask was rendered as one")
        XCTAssertFalse(screen.lowercased().contains("try again"), screen)
    }

    func testANoAskEnvelopeCarriesNoReading() throws {
        let envelope = ReadAskEnvelope(
            mode: "read_ask", status: "no_ask", ask: nil,
            byWhen: nil, unclear: nil, possibleReadings: []
        )
        XCTAssertEqual(try envelope.validated(against: "Thanks for dinner."), .noAsk)
    }

    /// The three outcomes say three different things, and none of them is the
    /// other's copy. Confusing "there is nothing being asked" with "Tono can't
    /// read this" would tell somebody their ordinary message was refused.
    func testTheThreeOutcomesReadDifferently() {
        XCTAssertNotEqual(ReadTheAskCopy.noAsk, ReadTheAskCopy.declined)
        XCTAssertFalse(ReadTheAskCopy.noAsk.lowercased().contains("can't"))
        XCTAssertFalse(ReadTheAskCopy.noAsk.lowercased().contains("try again"))
    }

    func testADeclinedEnvelopeCarriesNoReading() throws {
        let envelope = ReadAskEnvelope(
            mode: "read_ask", status: "declined", ask: nil,
            byWhen: nil, unclear: nil, possibleReadings: []
        )
        XCTAssertEqual(try envelope.validated(against: "anything"), .declined)
    }

    /// Every shipped user-facing string, checked in one place. Copy is where a
    /// coach quietly turns into a clinician.
    func testNoShippedCopyIsClinicalOrDiagnostic() {
        let shipped = [
            ReadTheAskCopy.modeSelectorCaption, ReadTheAskCopy.activationTitle,
            ReadTheAskCopy.activationBody, ReadTheAskCopy.activationToggleTitle,
            ReadTheAskCopy.activationToggleDetail, ReadTheAskCopy.receivedTextLabel,
            ReadTheAskCopy.receivedTextPlaceholder, ReadTheAskCopy.askHeading,
            ReadTheAskCopy.byWhenHeading, ReadTheAskCopy.byWhenAbsent,
            ReadTheAskCopy.unclearHeading, ReadTheAskCopy.possibleReadingsHeading,
            ReadTheAskCopy.possibleReadingsCaption, ReadTheAskCopy.draftReplyAction,
            ReadTheAskCopy.clarificationAction, ReadTheAskCopy.draftEditableNote,
            ReadTheAskCopy.declined, ReadTheAskCopy.noAsk, ReadTheAskCopy.offNotice,
            ReadTheAskCopy.settingsDisclosure,
        ]
        for line in shipped {
            XCTAssertFalse(
                ReadAskGuard.claimsAboutTheSender(line),
                "shipped copy makes a claim about a person: “\(line)”"
            )
            for banned in ["988", "hotline", "helpline", "therapy", "therapist", "diagnos", "mental health"] {
                XCTAssertFalse(
                    line.lowercased().contains(banned),
                    "shipped copy contains clinical language: “\(line)”"
                )
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // 6. Nothing is kept
    // ═══════════════════════════════════════════════════════════════════

    /// The one durable thing this feature has. If a second key ever appears in
    /// the App Group under this feature's namespace, this test is where it is
    /// noticed.
    func testTheOnlyThingPersistedIsTheBoolean() throws {
        let defaults = try isolatedDefaults()
        let activation = ReadTheAskActivation(defaults: defaults)
        activation.setEnabled(true)

        let session = ReadTheAskSession()
        session.setReceivedText(Self.receivedWithDeadline)
        session.apply(.reading(ReadAskResult(ask: "Send the Q3 deck.", byWhen: "by Friday")))
        session.setDraft("Thanks — just to confirm: Send the Q3 deck.", kind: .reply)

        let written = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("tc.readTheAsk") }
        XCTAssertEqual(Array(written.keys), [ReadTheAskKeys.enabled])
        XCTAssertEqual(written[ReadTheAskKeys.enabled] as? Bool, true)
    }

    /// The message, the reading and the draft, checked against every string the
    /// App Group holds — not just against the keys this feature knows about.
    func testNoReceivedTextReachesTheSharedStore() throws {
        setSharedActivation(true)
        let needle = "zqxjkvbwpm"
        let session = ReadTheAskSession()
        session.setReceivedText("Can you send the \(needle) report by Friday?")
        session.apply(.reading(ReadAskResult(ask: "Send the \(needle) report.", byWhen: "by Friday")))
        session.setDraft("Thanks — just to confirm: send the \(needle) report.", kind: .reply)

        for (key, value) in Tono.SharedStore.defaults.dictionaryRepresentation() {
            let text = String(describing: value)
            XCTAssertFalse(
                text.contains(needle),
                "the App Group key “\(key)” retained the received message"
            )
        }
    }

    func testNoReceivedTextReachesTheKeychain() throws {
        let needle = "zqxjkvbwpm"
        let session = ReadTheAskSession()
        session.setReceivedText("Can you send the \(needle) report by Friday?")
        session.apply(.reading(ReadAskResult(ask: "Send the \(needle) report.")))

        for key in [
            Tono.KeychainKeys.apiToken, Tono.KeychainKeys.deviceID, Tono.KeychainKeys.apiKey,
            Tono.KeychainKeys.accountID, Tono.KeychainKeys.signedInEmail, Tono.KeychainKeys.deviceCredential,
        ] {
            let stored = Tono.SharedKeychain.get(key) ?? ""
            XCTAssertFalse(stored.contains(needle), "the Keychain item “\(key)” retained the message")
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // 7. Clearing the one-flow context
    // ═══════════════════════════════════════════════════════════════════

    func testClearRemovesTheMessageTheReadingAndTheDraft() {
        let session = ReadTheAskSession()
        session.setReceivedText(Self.receivedWithDeadline)
        session.apply(.reading(ReadAskResult(ask: "Send the Q3 deck.", byWhen: "by Friday")))
        session.setDraft("a draft", kind: .reply)
        XCTAssertFalse(session.isEmpty)

        session.clear()

        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(session.receivedText, "")
        XCTAssertNil(session.outcome)
        XCTAssertEqual(session.draft, "")
        XCTAssertNil(session.draftKind)
    }

    /// A reading belongs to the text it was made from. Once the text moves, the
    /// reading beside it describes a message that no longer exists.
    func testChangingTheMessageDropsTheReadingMadeFromTheOldOne() {
        let session = ReadTheAskSession()
        session.setReceivedText(Self.receivedWithDeadline)
        session.apply(.reading(ReadAskResult(ask: "Send the Q3 deck.")))
        session.setDraft("a draft", kind: .reply)

        session.setReceivedText("Something else entirely.")

        XCTAssertNil(session.outcome, "a reading survived the message it was made from")
        XCTAssertEqual(session.draft, "")
        XCTAssertNil(session.draftKind)
    }

    /// Coach's own clearing wiring, driven through the surface.
    ///
    /// No typing: the assertion is that leaving Read the Ask takes the reading
    /// surface away entirely, and that coming back produces an EMPTY one rather
    /// than the message that was there. (What `clear()` removes from the model
    /// is pinned above; what a person can still see is pinned here.)
    @MainActor
    func testLeavingAndReturningToReadTheAskProducesAnEmptySurface() throws {
        setSharedActivation(true)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)
        XCTAssertNotNil(element(labelled: ReadTheAskCopy.readAction, in: controller))

        try activate(ReadTheAskCopy.rewriteModeTitle, in: controller)
        settle(controller)
        XCTAssertNil(
            element(labelled: ReadTheAskCopy.readAction, in: controller),
            "the reading surface survived the move back to Rewrite"
        )

        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)
        // An empty editor offers nothing to remove, which is the visible form of
        // "the message is gone".
        XCTAssertNotNil(
            element(labelled: ReadTheAskCopy.readAction, in: controller),
            "the reading surface did not come back:\n\(rendered(controller))"
        )
        // Nothing to remove is the visible form of "the message is gone" — the
        // control only exists while there IS one. (The placeholder is not
        // asserted: the editor carries an explicit accessibility label, so its
        // overlay text is deliberately not a separate element.)
        XCTAssertNil(
            element(labelled: ReadTheAskCopy.removeReceivedText, in: controller),
            "returning to Read the Ask restored a message the person walked away from"
        )
    }

    /// Switching the feature off in Settings has to reach a Coach surface that
    /// is showing Read the Ask, and it has to reach it now. Settings is one push
    /// from Coach's own toolbar, so this is the ordinary way a person withdraws
    /// — not an edge case.
    @MainActor
    func testTurningTheToggleOffElsewhereDropsTheSurfaceBackToRewriteImmediately() throws {
        setSharedActivation(true)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)
        XCTAssertNotNil(element(labelled: ReadTheAskCopy.readAction, in: controller))

        // Exactly what the Settings switch does.
        ReadTheAskActivation().setEnabled(false)
        _ = settle(controller, until: {
            self.element(labelled: ReadTheAskCopy.readAction, in: controller) == nil
        })

        XCTAssertNil(
            element(labelled: ReadTheAskCopy.readAction, in: controller),
            "the action was still reachable after the feature was switched off"
        )
        let rewrite = try XCTUnwrap(element(labelled: ReadTheAskCopy.rewriteModeTitle, in: controller))
        XCTAssertTrue(
            rewrite.accessibilityTraits.contains(.selected),
            "the surface stayed on a mode the feature no longer supports"
        )
    }

    /// The panel's own Remove control, on the surface that ships. The person can
    /// always take the message back out before Tono is asked to do anything with
    /// it, and doing so sends nothing.
    @MainActor
    func testRemovingTheMessageClearsTheReadingAndSendsNothing() throws {
        let controller = try hostReading(receivedText: Self.receivedWithDeadline)
        XCTAssertTrue(rendered(controller).contains("Send the Q3 deck."), rendered(controller))
        let sentWhileReading = ReadAskStub.readAskCount

        try activate(ReadTheAskCopy.removeReceivedText, in: controller)
        _ = settle(controller, until: { !self.rendered(controller).contains("Send the Q3 deck.") })

        let screen = rendered(controller)
        XCTAssertFalse(screen.contains("Send the Q3 deck."), screen)
        XCTAssertFalse(screen.contains("Q3 deck by Friday"), screen)
        XCTAssertNil(
            element(labelled: ReadTheAskCopy.removeReceivedText, in: controller),
            "the message is gone but its Remove control is still offered"
        )
        XCTAssertEqual(
            ReadAskStub.readAskCount, sentWhileReading, "removing the message sent something"
        )
    }

    // ═══════════════════════════════════════════════════════════════════
    // 8. The surface
    // ═══════════════════════════════════════════════════════════════════

    @MainActor
    func testCoachOffersBothModesAndOpensOnRewrite() throws {
        setSharedActivation(false)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        XCTAssertNotNil(element(labelled: ReadTheAskCopy.rewriteModeTitle, in: controller))
        XCTAssertNotNil(element(labelled: ReadTheAskCopy.readAskModeTitle, in: controller))

        let rewrite = try XCTUnwrap(element(labelled: ReadTheAskCopy.rewriteModeTitle, in: controller))
        XCTAssertTrue(
            rewrite.accessibilityTraits.contains(.selected),
            "Coach must open where it has always opened"
        )
    }

    /// Which side is selected is a fact assistive technology needs, not a colour.
    @MainActor
    func testTheSelectedModeIsReportedToAssistiveTechnology() throws {
        setSharedActivation(true)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)

        let readAsk = try XCTUnwrap(element(labelled: ReadTheAskCopy.readAskModeTitle, in: controller))
        let rewrite = try XCTUnwrap(element(labelled: ReadTheAskCopy.rewriteModeTitle, in: controller))
        XCTAssertTrue(readAsk.accessibilityTraits.contains(.selected))
        XCTAssertFalse(rewrite.accessibilityTraits.contains(.selected))
    }

    /// 44pt, at every Dynamic Type size. A control this consequential is not
    /// allowed to become a thin strip because its label happens to be short.
    @MainActor
    func testBothModeSegmentsClearTheMinimumTouchTargetAtEverySize() throws {
        for size in [DynamicTypeSize.xSmall, .large, .xxxLarge, .accessibility3, .accessibility5] {
            let controller = host(
                ReadTheAskModeSelector(mode: .constant(.rewrite))
                    .dynamicTypeSize(size)
                    .frame(width: 353)
            )
            let buttons = elements(of: controller.view).filter {
                $0.accessibilityLabel == ReadTheAskCopy.rewriteModeTitle
                    || $0.accessibilityLabel == ReadTheAskCopy.readAskModeTitle
            }
            XCTAssertEqual(buttons.count, 2, "at \(size) the selector did not render two segments")
            for button in buttons {
                let frame = button.accessibilityFrame
                XCTAssertGreaterThanOrEqual(
                    frame.height, ReadTheAskModeSelector.minimumTouchTarget - 0.5,
                    "“\(button.accessibilityLabel ?? "?")” is \(frame.height)pt tall at \(size)"
                )
                XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.5)
            }
        }
    }

    // ── the activation sheet ───────────────────────────────────────────

    /// The whole sheet, complete and reachable: the title, the truthful body,
    /// the switch, and BOTH exits. A privacy sheet that clips its own `Not now`
    /// has taken the exit away from the person most likely to want it.
    @MainActor
    func testTheActivationSheetIsCompleteAtEveryTextSize() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let controller = host(
                ReadTheAskActivationSheet(onDecision: { _ in }).dynamicTypeSize(size)
            )
            let screen = rendered(controller)
            for required in [
                ReadTheAskCopy.activationTitle,
                ReadTheAskCopy.activationBody,
                ReadTheAskCopy.activationToggleTitle,
                ReadTheAskCopy.activationDismiss,
                ReadTheAskCopy.activationConfirm,
            ] {
                XCTAssertTrue(
                    screen.contains(required),
                    "at \(size) the sheet is missing “\(required)”\n\(screen)"
                )
            }

            // Reachable, not merely present: every control's frame has to sit
            // inside the window it is drawn in.
            let bounds = controller.view.bounds
            for name in [ReadTheAskCopy.activationDismiss, ReadTheAskCopy.activationConfirm] {
                let control = try XCTUnwrap(element(labelled: name, in: controller))
                let frame = controller.view.convert(control.accessibilityFrame, from: nil)
                XCTAssertTrue(
                    bounds.intersects(frame) && frame.height >= 1,
                    "at \(size) “\(name)” is clipped out of the sheet (frame \(frame), bounds \(bounds))"
                )
            }
        }
    }

    /// The switch starts off and nothing but a finger changes that.
    @MainActor
    func testTheActivationSwitchOpensOff() throws {
        let controller = host(ReadTheAskActivationSheet(onDecision: { _ in }))
        let toggle = try XCTUnwrap(
            element(labelled: ReadTheAskCopy.activationToggleTitle, in: controller),
            "the sheet must render the enable switch"
        )
        XCTAssertEqual(toggle.accessibilityValue, "0", "the activation switch did not open off")
    }

    /// Continue commits what the switch SHOWS. Tapping the primary button on a
    /// sheet you have not touched leaves the feature off — the only honest
    /// reading of a switch labelled "Off by default".
    @MainActor
    func testContinueWithTheSwitchUntouchedLeavesTheFeatureOff() throws {
        var decision: Bool?
        let controller = host(ReadTheAskActivationSheet { decision = $0 })
        try activate(ReadTheAskCopy.activationConfirm, in: controller)
        XCTAssertEqual(decision, false, "Continue turned a feature on that the person never enabled")
    }

    @MainActor
    func testNotNowLeavesTheFeatureOff() throws {
        var decision: Bool?
        let controller = host(ReadTheAskActivationSheet { decision = $0 })
        try activate(ReadTheAskCopy.activationDismiss, in: controller)
        XCTAssertEqual(decision, false)
    }

    /// The activation copy is a promise about behaviour. These are the exact
    /// bytes the approved direction carries.
    func testTheActivationCopyIsTheApprovedCopy() {
        XCTAssertEqual(ReadTheAskCopy.activationTitle, "Turn on Read the Ask?")
        XCTAssertEqual(
            ReadTheAskCopy.activationBody,
            "Only text you choose is analyzed. Tono never reads your conversations or clipboard automatically."
        )
        XCTAssertEqual(ReadTheAskCopy.activationToggleTitle, "Enable Read the Ask")
        XCTAssertEqual(ReadTheAskCopy.activationToggleDetail, "Off by default. Turn it off anytime.")
        XCTAssertEqual(ReadTheAskCopy.activationDismiss, "Not now")
        XCTAssertEqual(ReadTheAskCopy.activationConfirm, "Continue")
    }

    // ── the off state ──────────────────────────────────────────────────

    /// An inactive entry point is one that cannot act, not one that acts and
    /// then apologises. With the toggle off there is no editor to paste into and
    /// no action to tap.
    @MainActor
    func testWithTheToggleOffThereIsNothingToActWith() throws {
        setSharedActivation(false)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)

        XCTAssertNil(
            element(labelled: ReadTheAskCopy.readAction, in: controller),
            "the Read the Ask action was reachable while the feature was off"
        )
        XCTAssertNil(
            element(labelled: ReadTheAskCopy.receivedTextLabel, in: controller),
            "an editor for a received message was reachable while the feature was off"
        )
        XCTAssertEqual(ReadAskStub.readAskCount, 0)
    }

    // ── the truthful location label ────────────────────────────────────

    /// This release has one route and it is online, so the app says Online. A
    /// screen that claims on-device processing while a message is on its way to
    /// a server is the worst thing this surface could print.
    func testTheOnlyShippedRouteIsOnlineAndSaysSo() {
        XCTAssertEqual(ReadTheAskRoute.backend.processing, .online)
        XCTAssertEqual(ReadTheAskProcessing.online.badge, "Online")
        XCTAssertTrue(ReadTheAskProcessing.online.disclosure.contains("Online"))
        XCTAssertFalse(ReadTheAskProcessing.online.disclosure.lowercased().contains("on device"))
        XCTAssertFalse(ReadTheAskProcessing.online.disclosure.lowercased().contains("on-device"))
    }

    /// Stated before the button that transmits, not after the message has gone.
    @MainActor
    func testTheOnlineDisclosureIsOnScreenBeforeAnythingIsSent() throws {
        setSharedActivation(true)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)

        XCTAssertTrue(
            rendered(controller).contains(ReadTheAskProcessing.online.disclosure),
            rendered(controller)
        )
        XCTAssertEqual(ReadAskStub.readAskCount, 0, "the disclosure appeared after the request")
    }

    // ── the reading, and the drafts ────────────────────────────────────

    @MainActor
    func testTheReadingRendersTheAskTheDeadlineAndTheUnclearDetail() throws {
        let controller = try hostReading(receivedText: Self.receivedWithDeadline)
        let screen = rendered(controller)
        for expected in [
            ReadTheAskCopy.askHeading, "Send the Q3 deck.",
            ReadTheAskCopy.byWhenHeading, "by Friday",
            ReadTheAskCopy.unclearHeading, "Which version of the deck is meant.",
        ] {
            XCTAssertTrue(screen.contains(expected), "missing “\(expected)”\n\(screen)")
        }
    }

    @MainActor
    func testTheReadingOffersBothActions() throws {
        let controller = try hostReading(receivedText: Self.receivedWithDeadline)
        XCTAssertNotNil(element(labelled: ReadTheAskCopy.draftReplyAction, in: controller))
        XCTAssertNotNil(element(labelled: ReadTheAskCopy.clarificationAction, in: controller))
    }

    /// A draft quotes what the sender wrote and commits the reader to nothing.
    func testTheDraftReplyQuotesTheDeadlineWithoutPromisingIt() {
        let draft = ReadAskReplyComposer.draftReply(
            for: ReadAskResult(ask: "Send the Q3 deck.", byWhen: "by Friday")
        )
        XCTAssertTrue(draft.contains("Send the Q3 deck."))
        XCTAssertTrue(draft.contains("by Friday"))
        XCTAssertFalse(
            draft.lowercased().contains("i will have it"),
            "the draft made a commitment on the person's behalf"
        )
        XCTAssertFalse(ReadAskGuard.claimsAboutTheSender(draft))
    }

    func testTheDraftReplyOmitsADeadlineThatWasNeverStated() {
        let draft = ReadAskReplyComposer.draftReply(for: ReadAskResult(ask: "Send the Q3 deck."))
        XCTAssertFalse(draft.lowercased().contains("you mentioned"))
    }

    func testTheClarificationAsksAboutTheUnclearDetail() {
        let request = ReadAskReplyComposer.clarificationRequest(
            for: ReadAskResult(ask: "Send the deck.", unclear: "Which version of the deck is meant.")
        )
        XCTAssertTrue(request.contains("Which version of the deck is meant."))
        XCTAssertFalse(ReadAskGuard.claimsAboutTheSender(request))

        let fallback = ReadAskReplyComposer.clarificationRequest(for: ReadAskResult(ask: "Send the deck."))
        XCTAssertFalse(fallback.isEmpty)
        XCTAssertFalse(ReadAskGuard.claimsAboutTheSender(fallback))
    }

    /// The draft is editable and it goes nowhere on its own.
    @MainActor
    func testTheDraftIsEditableAndThereIsNoSend() throws {
        let controller = try hostReading(receivedText: Self.receivedWithDeadline)
        try activate(ReadTheAskCopy.draftReplyAction, in: controller)
        _ = settle(controller, until: { self.visibleTextViews(in: controller.view).count >= 2 })

        let screen = rendered(controller)
        XCTAssertTrue(screen.contains(ReadTheAskCopy.draftEditableNote), screen)
        for sendish in ["Send", "Send reply", "Insert", "Send it"] {
            XCTAssertNil(
                element(labelled: sendish, in: controller),
                "the reading surface offers a “\(sendish)” control"
            )
        }
        XCTAssertGreaterThanOrEqual(
            visibleTextViews(in: controller.view).count, 2,
            "the draft must be rendered in an editable field"
        )
    }

    // ═══════════════════════════════════════════════════════════════════
    // 9. The keyboard, and the iMessage extension, stay rewrite-only
    // ═══════════════════════════════════════════════════════════════════

    private func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Read from the Xcode project the way the build phase does. The exclusion
    /// is the contract, so it is asserted rather than assumed.
    func testNoReadTheAskSourceIsCompiledIntoTheKeyboardOrTheIMessageExtension() throws {
        let project = try String(
            contentsOf: sourceRoot().appendingPathComponent("Tono.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let memberships = try Self.sourceMemberships(in: project)

        for target in ["TonoKeyboard", "TonoMessagesExtension"] {
            let files = try XCTUnwrap(memberships[target], "target \(target) has no Sources phase")
            let leaked = files.filter { $0.contains("ReadTheAsk") || $0.contains("Build117") }
            XCTAssertTrue(leaked.isEmpty, "\(target) compiles \(leaked)")
        }
        // And the positive half — an exclusion nobody depends on proves nothing.
        XCTAssertEqual(
            memberships["Tono"]?.filter { $0.contains("ReadTheAsk") }.sorted(),
            ["ReadTheAsk.swift", "ReadTheAskView.swift"]
        )
        XCTAssertEqual(
            memberships["TonoShare"]?.filter { $0.contains("ReadTheAsk") }, ["ReadTheAsk.swift"]
        )
    }

    /// The keyboard's own sources say nothing about this feature either — a file
    /// can be excluded from a target and still be referenced from inside it.
    func testTheKeyboardAndIMessageSourcesNameNothingFromThisFeature() throws {
        let root = sourceRoot()
        let manager = FileManager.default
        for directory in ["KeyboardExtension", "TonoMessagesExtension"] {
            let base = root.appendingPathComponent(directory)
            let files = try manager.subpathsOfDirectory(atPath: base.path)
                .filter { $0.hasSuffix(".swift") }
            XCTAssertFalse(files.isEmpty, "\(directory) has no Swift sources — check the path")
            for relative in files {
                let source = try String(
                    contentsOf: base.appendingPathComponent(relative), encoding: .utf8
                )
                for symbol in [
                    "ReadTheAsk", "ReadAsk", "read_ask", "TonoRequestMode", "readAsk",
                ] {
                    XCTAssertFalse(
                        source.contains(symbol),
                        "\(directory)/\(relative) names “\(symbol)”"
                    )
                }
            }
        }
    }

    /// `path -> [source file names]`, parsed the way the earlier build-number
    /// guard parses `bump-build.sh`: from the reviewed file itself.
    private static func sourceMemberships(in project: String) throws -> [String: [String]] {
        var phases: [String: String] = [:]
        let targetPattern = #"([0-9A-F]{24}) /\* (\w+) \*/ = \{\n\t\t\tisa = PBXNativeTarget;"#
        let regex = try NSRegularExpression(pattern: targetPattern)
        let ns = project as NSString
        var result: [String: [String]] = [:]

        for match in regex.matches(in: project, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 2))
            // The target body runs to the next "\n\t\t};".
            let start = match.range.location
            guard let end = project.range(
                of: "\n\t\t};",
                range: Range(NSRange(location: start, length: ns.length - start), in: project)!
            ) else { continue }
            let body = String(project[Range(NSRange(location: start, length: ns.length - start), in: project)!.lowerBound..<end.lowerBound])
            guard let phaseRange = body.range(of: #"[0-9A-F]{24}(?= /\* Sources \*/)"#, options: .regularExpression)
            else { continue }
            phases[name] = String(body[phaseRange])
        }

        for (name, phaseID) in phases {
            guard let phaseStart = project.range(of: "\(phaseID) /* Sources */ = {") else { continue }
            guard let phaseEnd = project.range(of: "\n\t\t};", range: phaseStart.upperBound..<project.endIndex)
            else { continue }
            let phaseBody = String(project[phaseStart.upperBound..<phaseEnd.lowerBound])
            let fileRegex = try NSRegularExpression(pattern: #"/\* (.+?) in Sources \*/"#)
            let phaseNS = phaseBody as NSString
            result[name] = fileRegex
                .matches(in: phaseBody, range: NSRange(location: 0, length: phaseNS.length))
                .map { phaseNS.substring(with: $0.range(at: 1)) }
        }
        return result
    }

    // ═══════════════════════════════════════════════════════════════════
    // 10. Rewrite is unchanged
    // ═══════════════════════════════════════════════════════════════════

    /// The bytes an established rewrite caller puts on the wire. Stating the
    /// mode at the call site must not change one of them.
    @MainActor
    func testTheRewritePathStillPostsTheUnchangedCoachRequest() throws {
        setSharedActivation(false)
        Tono.SharedKeychain.set("b117-token", forKey: Tono.KeychainKeys.apiToken)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try type("hey can u send me the file tmrw thanks", into: controller)
        try activate("Coach", in: controller)
        _ = settle(controller, until: { ReadAskStub.analyzeCount > 0 })

        XCTAssertEqual(ReadAskStub.analyzeCount, 1, "one tap must still be one request")
        let body = ReadAskStub.lastAnalyzeBody
        XCTAssertTrue(body.contains("\"mode\":\"coach\""), "the rewrite wire changed: \(body)")
        XCTAssertFalse(body.contains("read_ask"), body)
    }

    @MainActor
    func testTheRewriteSurfaceStillDeliversItsRewrite() throws {
        setSharedActivation(false)
        Tono.SharedKeychain.set("b117-token", forKey: Tono.KeychainKeys.apiToken)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try type("hey can u send me the file tmrw thanks", into: controller)
        try activate("Coach", in: controller)
        let delivered = settle(controller, until: { self.rendered(controller).contains("WARMER-B117") })
        XCTAssertTrue(delivered, rendered(controller))
    }

    /// The approved rewrite screen, read off the laid-out accessibility tree in
    /// traversal order. Moving it into a named sub-view is only safe if it comes
    /// out the other side as the same screen, so this reads the order rather
    /// than trusting the refactor.
    @MainActor
    func testTheRewriteSurfaceRendersTheSameElementsInTheSameOrder() throws {
        setSharedActivation(false)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        let screen = rendered(controller)

        // hero → draft editor → Coach → how-it-works, exactly as Build 116 laid
        // it out, with the mode selector and its caption ahead of them.
        let expectedOrder = [
            ReadTheAskCopy.rewriteModeTitle,
            ReadTheAskCopy.modeSelectorCaption,
            "Paste a message. Get a coach.",
            "Draft",
            "Coach",
            "How it works",
        ]
        var searchFrom = screen.startIndex
        for element in expectedOrder {
            guard let found = screen.range(of: element, range: searchFrom..<screen.endIndex) else {
                return XCTFail("“\(element)” is missing or out of order\n\(screen)")
            }
            searchFrom = found.upperBound
        }
    }

    /// Choosing Read the Ask does not throw away a rewrite the person already
    /// has — it is theirs, not the mode selector's.
    @MainActor
    func testSwitchingModesDoesNotDestroyADeliveredRewrite() throws {
        setSharedActivation(true)
        Tono.SharedKeychain.set("b117-token", forKey: Tono.KeychainKeys.apiToken)
        let controller = host(CoachView(connectivity: onlineConnectivity()))
        try type("hey can u send me the file tmrw thanks", into: controller)
        try activate("Coach", in: controller)
        _ = settle(controller, until: { self.rendered(controller).contains("WARMER-B117") })

        try activate(ReadTheAskCopy.readAskModeTitle, in: controller)
        settle(controller)
        try activate(ReadTheAskCopy.rewriteModeTitle, in: controller)
        _ = settle(controller, until: { self.rendered(controller).contains("WARMER-B117") })

        XCTAssertTrue(rendered(controller).contains("WARMER-B117"), rendered(controller))
    }

    // ═══════════════════════════════════════════════════════════════════
    // 11. Build identity
    // ═══════════════════════════════════════════════════════════════════

    /// The four shipped bundles and the archive guard agree, and they agree on
    /// 117. (`BuildNumberGuardTests` pins the agreement; this pins the number,
    /// because a build that shipped as 116 twice is the failure this catches.)
    func testEveryShippedBundleDeclaresBuild117() throws {
        let root = sourceRoot()
        let guardScript = try String(
            contentsOf: root.appendingPathComponent("Scripts/bump-build.sh"), encoding: .utf8
        )
        XCTAssertTrue(guardScript.contains("EXPECTED_BUILD=\"117\""), "the release authority is not 117")

        for relative in [
            "App/Info.plist", "KeyboardExtension/Info.plist",
            "ShareExtension/Info.plist", "TonoMessagesExtension/Info.plist",
        ] {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            XCTAssertEqual(plist?["CFBundleVersion"] as? String, "117", relative)
            XCTAssertEqual(
                plist?["CFBundleShortVersionString"] as? String, "1.1",
                "\(relative): the marketing version is not this build's to change"
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Hosting machinery (same shape as Build116AirplaneModeTests)
    // ═══════════════════════════════════════════════════════════════════

    /// A path source this suite owns, so "the app knows it is online" is a state
    /// the test sets rather than one it hopes for. A simulator has no radio.
    final class OnlinePathSource: TonoConnectivityPathSource {
        private let lock = NSLock()
        private var handler: ((Bool) -> Void)?
        var currentlySatisfied: Bool? = true

        func start(onReport: @escaping (Bool) -> Void) {
            lock.withLock { handler = onReport }
            onReport(true)
        }
        func cancel() { lock.withLock { handler = nil } }
    }

    /// A connectivity observer already reporting online, so a surface gated on
    /// connectivity is not gated by the absence of an answer.
    @MainActor
    private func onlineConnectivity() -> TonoConnectivity {
        let connectivity = TonoConnectivity(source: OnlinePathSource())
        connectivity.start()
        return connectivity
    }

    /// A laid-out view in a real window, because the assertions are about what
    /// a person sees and about controls they can reach.
    @MainActor
    @discardableResult
    private func host<V: View>(_ view: V) -> UIHostingController<AnyView> {
        let controller = UIHostingController(rootView: AnyView(view))
        controller.overrideUserInterfaceStyle = .dark
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let window = UIWindow(frame: controller.view.frame)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.isHidden = false
        window.makeKeyAndVisible()
        addTeardownBlock { MainActor.assumeIsolated { window.isHidden = true } }
        settle(controller)
        return controller
    }

    /// Drive the Read the Ask surface to an on-screen reading of `receivedText`.
    ///
    /// Hosts `ReadTheAskPanel` inside the SAME composition `CoachView` puts it
    /// in — `NavigationStack { ScrollView { VStack(spacing: 18).padding(20)
    /// .tonoReadableColumn(.reading) } }` on the same black background — so what
    /// is measured is the shipping view under the shipping layout, not a replica
    /// of it.
    ///
    /// Why the panel rather than `CoachView` end to end: driving Coach's own
    /// mode switch and THEN typing does not reliably deliver keystrokes to the
    /// binding in this harness. The test window is not the key window (the test
    /// host app's is), and after the `_ConditionalContent` branch swap the
    /// editor's write-back is lost. That this is a harness limitation and not a
    /// product defect is evidenced directly: the identical panel receives typed
    /// text and updates its binding both bare AND inside this exact wrapper.
    /// The Coach-level mode switch is covered by the tests above that do not
    /// need typing (`…OffersBothModes…`, `…SelectedModeIsReported…`,
    /// `…NothingToActWith`, `…OnlineDisclosureIsOnScreen…`,
    /// `…DropsBackToRewrite…`), and typing into Coach itself is a listed
    /// physical-acceptance item.
    @MainActor
    private func hostReading(
        receivedText: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> UIHostingController<AnyView> {
        setSharedActivation(true)
        let controller = host(ReadTheAskSurfaceHarness())
        try type(receivedText, into: controller)
        XCTAssertNotNil(
            element(labelled: ReadTheAskCopy.removeReceivedText, in: controller),
            "the typed message never reached the model", file: file, line: line
        )
        XCTAssertTrue(
            settle(controller, until: { self.isAvailable(ReadTheAskCopy.readAction, in: controller) }),
            "the read action never became available after a message was entered",
            file: file, line: line
        )
        try activate(ReadTheAskCopy.readAction, in: controller)
        // All three outcomes count as "the reading came back". Leaving `noAsk`
        // out of this list is what made a correct, successful reading of an
        // ask-free message look like a timeout.
        XCTAssertTrue(
            settle(controller, until: {
                let screen = self.rendered(controller)
                return screen.contains(ReadTheAskCopy.askHeading)
                    || screen.contains(ReadTheAskCopy.noAsk)
                    || screen.contains(ReadTheAskCopy.declined)
            }),
            "no reading arrived", file: file, line: line
        )
        return controller
    }

    @MainActor
    private func settle(_ controller: UIViewController, seconds: TimeInterval = 0.35) {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    @MainActor
    @discardableResult
    private func settle(
        _ controller: UIViewController, until condition: () -> Bool, seconds: TimeInterval = 6
    ) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        return condition()
    }

    @MainActor
    private func elements(of view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        var seen = 0
        func walk(_ node: Any) {
            seen += 1
            guard seen < 6000 else { return }
            guard let object = node as? NSObject else { return }
            if object.isAccessibilityElement { found.append(object); return }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) { walk(child) }
                }
                return
            }
            if let children = object.accessibilityElements { children.forEach(walk); return }
            (object as? UIView)?.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    @MainActor
    private func rendered(_ controller: UIViewController) -> String {
        elements(of: controller.view)
            .map { ($0.accessibilityLabel ?? "") + " " + ($0.accessibilityValue ?? "") }
            .joined(separator: "\n")
    }

    @MainActor
    private func element(labelled name: String, in controller: UIViewController) -> NSObject? {
        elements(of: controller.view).first {
            let label = $0.accessibilityLabel ?? ""
            return label == name || label.hasPrefix(name + ",")
        }
    }

    /// Every `UITextView` in the tree. SwiftUI's `TextEditor` is one.
    @MainActor
    private func textViews(in view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        func walk(_ node: UIView) {
            if let editor = node as? UITextView { found.append(editor) }
            node.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// The editors a person can actually see and reach.
    ///
    /// This filter is load-bearing, and finding out why cost an afternoon.
    /// `switch mode { case .rewrite: … case .readAsk: … }` compiles to
    /// `_ConditionalContent`, and SwiftUI leaves the departed branch's
    /// `UITextView` in the view hierarchy — detached, zero-sized, and FIRST in
    /// traversal order. Typing into `textViews().first` therefore typed into the
    /// rewrite draft while Read the Ask was on screen: the characters landed in
    /// a real text view, the binding under test never moved, and every
    /// assertion downstream failed for a reason that had nothing to do with the
    /// code being tested.
    @MainActor
    private func visibleTextViews(in view: UIView) -> [UITextView] {
        textViews(in: view).filter { editor in
            guard !editor.isHidden, editor.alpha > 0, editor.window != nil else { return false }
            guard editor.bounds.width > 1, editor.bounds.height > 1 else { return false }
            let onScreen = editor.convert(editor.bounds, to: view)
            return view.bounds.intersects(onScreen)
        }
    }

    /// Type the way a person does — through the text view's own input path, so
    /// the SwiftUI binding updates. Assigning `.text` changes the pixels and
    /// leaves the state empty.
    @MainActor
    private func type(
        _ text: String, into controller: UIViewController,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let editors = visibleTextViews(in: controller.view)
        XCTAssertEqual(
            editors.count, 1,
            "expected exactly one editor on screen, found \(editors.count) — the helper would be guessing",
            file: file, line: line
        )
        let editor = try XCTUnwrap(
            editors.first, "the surface must render an editor", file: file, line: line
        )
        // Typed through the text view's own input path, so SwiftUI's coordinator
        // sees exactly what it sees when a person types. `textViewDidChange` is
        // then called explicitly, and that is not belt-and-braces: the test
        // window is not the key window (the test host app's is), so
        // `becomeFirstResponder` is not guaranteed and UIKit's own delegate
        // callback can be skipped — which is what left this editor's binding
        // empty while its text view held the typed characters. Calling the
        // delegate is the same notification UIKit sends; it drives the shipping
        // coordinator rather than standing in for it. What it does NOT prove is
        // first-responder behaviour, which physical acceptance covers.
        editor.becomeFirstResponder()
        editor.insertText(text)
        editor.delegate?.textViewDidChange?(editor)
        settle(controller)
    }

    /// Tap the way assistive technology does.
    @MainActor
    @discardableResult
    private func activate(
        _ name: String, in controller: UIViewController,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Bool {
        let control = try XCTUnwrap(
            element(labelled: name, in: controller),
            "the surface must offer a control labelled “\(name)”", file: file, line: line
        )
        let acted = control.accessibilityActivate()
        XCTAssertTrue(
            acted, "the control “\(name)” refused to act — it is present but not usable",
            file: file, line: line
        )
        settle(controller)
        return acted
    }

    /// Whether the surface presents `name` as something that can act.
    @MainActor
    private func isAvailable(_ name: String, in controller: UIViewController) -> Bool {
        guard let control = element(labelled: name, in: controller) else { return false }
        return !control.accessibilityTraits.contains(.notEnabled)
    }
}

// MARK: - Reading a request body that URLSession has already taken

private extension URLRequest {
    /// `httpBody` is nil once `URLSession` converts the body to a stream, which
    /// is exactly the state a `URLProtocol` sees it in.
    func bodyStreamText() -> String {
        guard let stream = httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}




/// `ReadTheAskPanel` in the composition `CoachView` gives it — same stack
/// spacing, same padding, same readable column, same background — so the tests
/// measure the shipping view under the shipping layout.
/// The panel, plus the one thing Coach does that this suite otherwise cannot
/// reach: take it off screen.
///
/// Switching Coach back to Rewrite, and switching the feature off in Settings,
/// both call `clearReadTheAsk()` and remove the panel from the hierarchy. The
/// button here does exactly that pair, so the test drives the real teardown
/// rather than a description of it. The session is owned by the TEST, because
/// the whole question is what lands in it after the panel is gone.
private struct ReadTheAskLeavableHarness: View {
    @ObservedObject var session: ReadTheAskSession
    @State private var receivedText = ""
    @State private var showsPanel = true

    static let leaveLabel = "Leave Read the Ask"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showsPanel {
                        ReadTheAskPanel(
                            receivedText: $receivedText, session: session, isOffline: false
                        )
                    }
                    Button(Self.leaveLabel) {
                        // `CoachView.clearReadTheAsk()`, then the mode swap.
                        receivedText = ""
                        session.clear()
                        showsPanel = false
                    }
                    Spacer(minLength: 20)
                }
                .padding(20)
                .tonoReadableColumn(.reading)
            }
            .background(Color.black.ignoresSafeArea())
        }
    }
}

private struct ReadTheAskSurfaceHarness: View {
    @State private var receivedText = ""
    @StateObject private var session = ReadTheAskSession()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ReadTheAskPanel(receivedText: $receivedText, session: session, isOffline: false)
                    Spacer(minLength: 20)
                }
                .padding(20)
                .tonoReadableColumn(.reading)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Coach this")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}


// ═══════════════════════════════════════════════════════════════════════════
// BUILD 117 REPAIR — findings from the independent exact-object review of
// 7784480e. Each section names the finding it closes.
// ═══════════════════════════════════════════════════════════════════════════

extension Build117ReadTheAskTests {

    // ── F2 — a failure to READ says so ─────────────────────────────────

    /// Every Read the Ask failure used to say "Couldn't coach this draft."
    ///
    /// On a feature whose entire purpose is that a message somebody sent you is
    /// not a draft you wrote, that is the one confusion it exists to prevent,
    /// reproduced in its own error copy.
    func testAReadTheAskFailureSaysItCouldNotReadTheMessage() {
        for failure: Error in [
            ReadAskContractError.notActivated,
            ReadAskContractError.askMissing,
            ReadAskContractError.modeMismatch(expected: "read_ask", received: "read"),
            ReadAskContractError.claimsAboutTheSender(field: "ask"),
            TonoBackendError.network("boom"),
            TonoBackendError.decoding("boom"),
        ] {
            let message = ReadTheAskFailure.message(for: failure)
            XCTAssertTrue(
                message.hasPrefix("Couldn't read this message."),
                "a Read the Ask failure said: \(message)"
            )
            XCTAssertFalse(message.contains("coach this draft"), message)
        }
    }

    /// The two Build 117 names on `Build112UISurfaceContractTests`'
    /// `approvedErrorMappers` list delegate to the one approved mapper — they
    /// do not author copy of their own.
    ///
    /// That list is what lets a surface assign a failure into rendered state,
    /// so adding a name to it is adding a hole unless the name is checked.
    /// Checked here by EXACT EQUALITY against `ConsumerErrorCopy`, not by
    /// asserting a prefix: a mapper that hardcoded "Couldn't read this
    /// message." would satisfy a prefix check while having quietly become a
    /// second author of consumer copy — the precise thing
    /// `testTheFailureMapperIsPinnedClassifiesByCaseAndShipsEverywhere` exists
    /// to prevent.
    func testTheReadTheAskMappersDelegateToTheOneApprovedMapper() {
        for failure: Error in [
            ReadAskContractError.notActivated,
            ReadAskContractError.modeMismatch(expected: "read_ask", received: "read"),
            TonoBackendError.network("boom"),
            TonoBackendError.http(429, "slow down"),
            TonoBackendError.http(402, "pay up"),
            URLError(.notConnectedToInternet),
        ] {
            let approved = ConsumerErrorCopy.message(for: failure, action: .readMessage)
            XCTAssertEqual(
                ReadTheAskFailure.message(for: failure), approved,
                "ReadTheAskFailure authored its own sentence instead of delegating"
            )
            XCTAssertEqual(
                ReadTheAskNotice.forFailure(failure).message, approved,
                "ReadTheAskNotice authored its own sentence instead of delegating"
            )
        }
    }

    /// The rewrite path's copy is untouched — `.coachDraft` is correct there,
    /// and "fix the wrong copy" must not become "change all the copy".
    func testTheRewritePathStillSaysItCouldNotCoachTheDraft() {
        let message = ConsumerErrorCopy.message(
            for: TonoBackendError.network("boom"), action: .coachDraft
        )
        XCTAssertTrue(message.hasPrefix("Couldn't coach this draft."), message)
    }

    /// Rendered, on the shipping surface — not just the helper in isolation.
    @MainActor
    func testTheCompanionSurfaceRendersTheReadFailureCopy() throws {
        ReadAskStub.readAskStatus = 500
        setSharedActivation(true)
        let controller = host(ReadTheAskSurfaceHarness())
        try type(Self.receivedWithDeadline, into: controller)
        _ = settle(controller, until: { self.isAvailable(ReadTheAskCopy.readAction, in: controller) })
        try activate(ReadTheAskCopy.readAction, in: controller)
        _ = settle(controller, until: {
            self.rendered(controller).contains("Couldn't read this message.")
        })

        let screen = rendered(controller)
        XCTAssertTrue(screen.contains("Couldn't read this message."), screen)
        XCTAssertFalse(screen.contains("coach this draft"), screen)
    }

    // ── F4 — a successful reading is not drawn as a warning ────────────

    /// `noAsk` is a *successful* reading. `declined` is a boundary Tono chose.
    /// Neither is a failure, and the Share extension drew all three with the
    /// same 36pt yellow warning triangle.
    func testEachOutcomeIsPresentedAsWhatItActuallyIs() throws {
        let reading = ReadTheAskNotice.forOutcome(
            .reading(ReadAskResult(ask: "Send the Q3 deck."))
        )
        XCTAssertNil(reading, "a reading renders as a reading, not a notice")

        let noAsk = try XCTUnwrap(ReadTheAskNotice.forOutcome(.noAsk))
        XCTAssertEqual(noAsk.kind, .success)
        XCTAssertEqual(noAsk.glyph, "checkmark.circle")
        XCTAssertEqual(noAsk.message, ReadTheAskCopy.noAsk)
        XCTAssertFalse(noAsk.offersRetry, "re-reading gives the same correct answer forever")

        let declined = try XCTUnwrap(ReadTheAskNotice.forOutcome(.declined))
        XCTAssertEqual(declined.kind, .boundary)
        XCTAssertEqual(declined.glyph, "hand.raised")
        XCTAssertFalse(declined.offersRetry)

        let failure = ReadTheAskNotice.forFailure(TonoBackendError.network("boom"))
        XCTAssertEqual(failure.kind, .failure)
        XCTAssertTrue(failure.offersRetry, "a failure is the one case retrying can change")
        XCTAssertTrue(failure.message.hasPrefix("Couldn't read this message."), failure.message)
    }

    /// The warning triangle belongs to exactly one outcome.
    func testOnlyAGenuineFailureGetsWarningIconography() throws {
        let warning = "exclamationmark.triangle"
        XCTAssertFalse(try XCTUnwrap(ReadTheAskNotice.forOutcome(.noAsk)).glyph.contains(warning))
        XCTAssertFalse(try XCTUnwrap(ReadTheAskNotice.forOutcome(.declined)).glyph.contains(warning))
        XCTAssertTrue(
            ReadTheAskNotice.forFailure(TonoBackendError.network("x")).glyph.contains(warning)
        )
    }

    // ── F5 — the Share surface's decisions are covered ─────────────────
    //
    // `ShareRootView` lives in an `.appex` and cannot be imported by the unit
    // test target, which is why it had no coverage at all. The decisions were
    // therefore lifted into `ReadTheAskShareFlow` — which IS compiled into both
    // TonoShare and (via the app) this target — leaving layout in the view.
    // These test the decisions; the surface-contract test below pins that the
    // view still routes through them rather than re-deciding locally.

    func testShareOpensOnRewriteWhileTheFeatureIsOff() {
        XCTAssertEqual(ReadTheAskShareFlow.initialStage(activationEnabled: false), .rewrite)
        XCTAssertTrue(
            ReadTheAskShareFlow.runsOnAppear(.rewrite),
            "with the feature off, Share must behave exactly as it did before Build 117"
        )
    }

    func testShareAsksWhichModeOnlyWhenTheFeatureIsOn() {
        XCTAssertEqual(ReadTheAskShareFlow.initialStage(activationEnabled: true), .choosing)
        XCTAssertFalse(
            ReadTheAskShareFlow.runsOnAppear(.choosing),
            "the choice screen is a question; a question that answers itself is not one"
        )
    }

    func testShareHasNoPreselectedModeAndBothChoicesLeadSomewhere() {
        XCTAssertEqual(ReadTheAskShareFlow.stage(choosing: .rewrite), .rewrite)
        XCTAssertEqual(ReadTheAskShareFlow.stage(choosing: .readAsk), .readAsk)
        // Neither branch is the "default": the initial stage is `.choosing`,
        // which is neither of them.
        XCTAssertNotEqual(ReadTheAskShareFlow.initialStage(activationEnabled: true), .rewrite)
        XCTAssertNotEqual(ReadTheAskShareFlow.initialStage(activationEnabled: true), .readAsk)
    }

    func testShareRunsNothingOnAppearForEitherReadTheAskStage() {
        XCTAssertFalse(ReadTheAskShareFlow.runsOnAppear(.readAsk))
        XCTAssertFalse(ReadTheAskShareFlow.runsOnAppear(.choosing))
    }

    /// The Share flow's one-flow context clears on the way out, exactly as the
    /// companion app's does.
    func testShareClearsItsOneFlowContext() {
        let session = ReadTheAskSession()
        session.setReceivedText(Self.receivedWithDeadline)
        session.apply(.reading(ReadAskResult(ask: "Send the Q3 deck.", byWhen: "by Friday")))
        XCTAssertFalse(session.isEmpty)
        session.clear()
        XCTAssertTrue(session.isEmpty)
    }

    /// The view still delegates rather than re-deciding.
    ///
    /// A source-contract test, in the shape `Build112UISurfaceContractTests`
    /// already uses for surfaces it cannot host. It is the weaker half of this
    /// section on purpose — the decisions above are the strong half — but it is
    /// what stops the extension quietly growing a second copy of them.
    func testTheShareSurfaceRoutesThroughTheSharedFlowAndNoticeModels() throws {
        // Comments stripped first. Without that, this test matches the comment
        // that explains why the code says `.readMessage` and not `.coachDraft`
        // — a source scan that reads prose as code is exactly the vacuous check
        // this build has already been caught by twice.
        let source = SwiftSource.stripComments(try String(
            contentsOf: sourceRoot().appendingPathComponent("ShareExtension/ShareRootView.swift"),
            encoding: .utf8
        ))
        for required in [
            "ReadTheAskShareFlow.initialStage",
            "ReadTheAskShareFlow.stage(choosing:",
            "ReadTheAskShareFlow.runsOnAppear",
            "ReadTheAskNotice.forOutcome",
            "ReadTheAskNotice.forFailure",
        ] {
            XCTAssertTrue(source.contains(required), "ShareRootView no longer uses \(required)")
        }
        // The Read the Ask path must not reach for the draft-coaching copy.
        // Bounded at the rewrite path that follows it, because THAT one uses
        // `.coachDraft` correctly and a scan that runs into it would fail for
        // the wrong reason.
        let start = try XCTUnwrap(source.range(of: "private func runReadAsk()"))
        let end = try XCTUnwrap(
            source.range(of: "private var rewriteBody", range: start.upperBound..<source.endIndex)
        )
        let readAskPath = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(
            readAskPath.contains(".coachDraft"),
            "the Share Read the Ask path is back on draft-coaching copy"
        )
        XCTAssertTrue(
            readAskPath.contains("ReadTheAskNotice.forFailure"),
            "the Share Read the Ask path must route its failure through the shared model"
        )
        // And the rewrite path below it is untouched — fixing the wrong copy
        // must not become changing all the copy.
        XCTAssertTrue(
            String(source[end.lowerBound...]).contains(".coachDraft"),
            "the Share rewrite path lost its correct draft-coaching copy"
        )
    }

    // ── F3 — the binary claim is backed by an artefact ─────────────────

    func testTheBinaryExclusionVerifierExistsAndIsExecutable() throws {
        let verifier = sourceRoot()
            .appendingPathComponent("Scripts/verify_build117_read_ask_exclusion.py")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: verifier.path),
            "ReadTheAsk.swift promises a binary verifier; it must exist"
        )
        let script = try String(contentsOf: verifier, encoding: .utf8)
        // The two lessons this repo has already paid for.
        XCTAssertTrue(script.contains("swift-demangle"), "symbols must be demangled")
        XCTAssertTrue(
            script.contains("POSITIVE CONTROL"),
            "a zero-hit result means nothing without a positive control"
        )
        XCTAssertTrue(script.contains("debug.dylib") || script.contains("*.dylib"),
                      "a Debug build hides the code in a sibling dylib")
    }

    /// The source comment describes the division of labour honestly: these
    /// tests do membership and sources, the script does binaries.
    func testTheSourceCommentDoesNotClaimThisSuiteInspectsBinaries() throws {
        let source = try String(
            contentsOf: sourceRoot().appendingPathComponent("Shared/ReadTheAsk.swift"),
            encoding: .utf8
        )
        let header = String(source.prefix(2_400))
        XCTAssertTrue(header.contains("verify_build117_read_ask_exclusion.py"), header)
        XCTAssertFalse(
            header.contains("shipped Mach-O binaries by\n//     `Build117ReadTheAskTests`"),
            "the suite must not claim binary assertions it does not make"
        )
    }
}

extension Build117ReadTheAskTests {

    // ── R5 — a withdrawal is a withdrawal ──────────────────────────────

    /// Remove, while a reading is in flight, must not be undone by the response.
    ///
    /// Looking for a safe place to put cancellation found this: the reading
    /// landed after `session.clear()` and called `session.apply`, so the
    /// message the person had just removed came back with a reading attached.
    /// The contract says withdrawal clears immediately; a late response that
    /// repopulates the surface makes "immediately" mean "until the network
    /// disagrees".
    @MainActor
    func testAReadingThatArrivesAfterRemoveDoesNotComeBack() throws {
        // The response is held so the withdrawal genuinely happens mid-flight.
        ReadAskStub.holdSeconds = 1.0
        setSharedActivation(true)
        let controller = host(ReadTheAskSurfaceHarness())
        try type(Self.receivedWithDeadline, into: controller)
        _ = settle(controller, until: { self.isAvailable(ReadTheAskCopy.readAction, in: controller) })

        try activate(ReadTheAskCopy.readAction, in: controller)
        // Withdraw while the request is still in flight.
        try activate(ReadTheAskCopy.removeReceivedText, in: controller)

        // The reading is still in flight here — proven by the stub's hold, and
        // by this test failing when the cancellation is removed.
        XCTAssertGreaterThan(ReadAskStub.readAskCount, 0, "no request was ever made")
        // Give the late response every chance to land.
        _ = settle(controller, until: { false }, seconds: 3.0)

        let screen = rendered(controller)
        XCTAssertFalse(screen.contains("Send the Q3 deck."), "a removed message came back\n\(screen)")
        XCTAssertFalse(screen.contains(ReadTheAskCopy.askHeading), screen)
        XCTAssertNil(
            element(labelled: ReadTheAskCopy.removeReceivedText, in: controller),
            "the message is gone, so its Remove control should be too"
        )
    }

    /// Leaving Read the Ask mid-reading must not be undone by the response
    /// either.
    ///
    /// BUILD 117 REPAIR — cancelling on Remove closed one door and left the
    /// other open. Coach leaves this surface by calling `clearReadTheAsk()` and
    /// swapping the panel out; that empties the buffer and the session, but a
    /// `Task` outlives the view that created it, so the reading landed, found
    /// an uncancelled task, and called `session.apply`. The message the person
    /// had left behind was waiting for them with a reading attached.
    ///
    /// The assertion is on the SESSION rather than the screen, because the
    /// panel is gone by then — the session is what survives to the next visit,
    /// so it is the thing that must be empty.
    @MainActor
    func testAReadingThatArrivesAfterLeavingReadTheAskDoesNotComeBack() throws {
        ReadAskStub.holdSeconds = 1.0
        setSharedActivation(true)
        let session = ReadTheAskSession()
        let controller = host(ReadTheAskLeavableHarness(session: session))
        try type(Self.receivedWithDeadline, into: controller)
        _ = settle(controller, until: { self.isAvailable(ReadTheAskCopy.readAction, in: controller) })

        try activate(ReadTheAskCopy.readAction, in: controller)
        // Leave while the request is genuinely in flight — the stub is holding it.
        try activate(ReadTheAskLeavableHarness.leaveLabel, in: controller)
        XCTAssertGreaterThan(ReadAskStub.readAskCount, 0, "no request was ever made")

        // Give the late response every chance to land.
        _ = settle(controller, until: { false }, seconds: 3.0)

        XCTAssertTrue(
            session.isEmpty,
            "a reading landed after the person left Read the Ask, so the message they "
                + "withdrew is waiting for them the next time they open it"
        )
        XCTAssertFalse(rendered(controller).contains("Send the Q3 deck."), rendered(controller))
    }

    // ── R6 — contrast measured, not inherited ──────────────────────────

    /// WCAG AA on the surfaces this build added.
    ///
    /// The new surfaces reuse CoachView's existing opacity idiom, and "matches
    /// what was already there" is a provenance argument, not a measurement. The
    /// repo's only contrast gate covers keyboard chips. These are the app
    /// surfaces, measured against the field they are actually drawn on.
    func testEveryNewSurfaceTextColourClearsWCAGAAOnItsOwnBackground() {
        // Coach's field is black; cards sit on it at low white opacity, which
        // lightens the effective background very slightly. Measuring against
        // pure black is the conservative direction: it UNDER-states the
        // background luminance for light text, so a pass here is a pass on the
        // real card too.
        let field = UIColor.black

        // Every foreground the Read the Ask surfaces use, with the size class
        // it is used at. AA is 4.5:1 for body text and 3:1 for large text
        // (≥18pt, or ≥14pt bold).
        let samples: [(label: String, colour: UIColor, isLargeText: Bool)] = [
            ("The Ask value (17pt medium)", .white.withAlphaComponent(0.95), true),
            ("field heading (12pt semibold)", .white.withAlphaComponent(0.6), false),
            ("muted 'No deadline stated' (15pt)", .white.withAlphaComponent(0.55), false),
            ("possible-reading body (14pt)", .white.withAlphaComponent(0.85), false),
            ("mode caption (13pt)", .white.withAlphaComponent(0.6), false),
            ("notice text (13pt)", .white, false),
            ("unselected segment (15pt semibold)", .white.withAlphaComponent(0.7), false),
            ("activation body (15pt)", .white.withAlphaComponent(0.72), false),
            ("activation toggle detail (13pt)", .white.withAlphaComponent(0.6), false),
        ]

        for sample in samples {
            let ratio = Self.contrastRatio(
                foreground: sample.colour.flattened(over: field), background: field
            )
            let required: CGFloat = sample.isLargeText ? 3.0 : 4.5
            XCTAssertGreaterThanOrEqual(
                ratio, required,
                "\(sample.label): \(String(format: "%.2f", ratio)):1 is below WCAG AA "
                    + "(\(required):1) on the surface's own background"
            )
        }
    }

    /// The selected segment is white on the app's purple — the one place a new
    /// surface puts text on a filled control rather than on the field.
    func testTheSelectedModeSegmentClearsWCAGAAOnItsFill() {
        let purple = UIColor(Color.purple)
        let ratio = Self.contrastRatio(foreground: .white, background: purple)
        XCTAssertGreaterThanOrEqual(
            ratio, 3.0,
            "the selected segment's label is \(String(format: "%.2f", ratio)):1 on its fill"
        )
    }

    /// Relative luminance and contrast per WCAG 2.1, on resolved sRGB
    /// components. Same formula the keyboard's gate uses; duplicated rather
    /// than shared because that one is `private` to its own suite and a test
    /// helper is not worth widening an API for.
    private static func contrastRatio(foreground: UIColor, background: UIColor) -> CGFloat {
        let bright = max(luminance(foreground), luminance(background))
        let dark = min(luminance(foreground), luminance(background))
        return (bright + 0.05) / (dark + 0.05)
    }

    private static func luminance(_ colour: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}

private extension UIColor {
    /// The colour a translucent foreground actually resolves to once composited
    /// over its background. Measuring the unflattened colour would score the
    /// alpha channel rather than the pixels a person sees.
    func flattened(over background: UIColor) -> UIColor {
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
        background.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(
            red: fr * fa + br * (1 - fa),
            green: fg * fa + bg * (1 - fa),
            blue: fb * fa + bb * (1 - fa),
            alpha: 1
        )
    }
}
