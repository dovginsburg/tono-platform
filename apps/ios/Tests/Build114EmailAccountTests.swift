// Build114EmailAccountTests.swift
// Build 114 — the email account lane on iOS: create, confirm, sign in, resend,
// recover, sign out.
//
// Build 113 and earlier shipped a sheet that POSTed to `/v1/auth/request-link`
// and `/v1/auth/verify-otp`. Neither endpoint existed on the server, so every
// tap 404'd, `KeychainKeys.signedInEmail` was never written, and
// `StoreKitManager.isIdentifiedAccount` therefore refused every purchase on
// every device. Build 114 replaces that dead pair with the real registration
// lane. These tests pin the properties that make the replacement safe rather
// than merely present.
//
// They drive the REAL production types — `TonoBackend.EmailAuthOutcome` and
// `EmailSignInSheet`'s own copy mapper — so a mutation to either turns a test
// red instead of passing against a re-implementation. Where the property lives
// in a view body that a unit test cannot instantiate without a host document,
// the assertion is made against the shipped source, which is the same technique
// Build 95/107/112/113 established here.
//
// HONEST LIMIT: nothing below proves a real network round trip, a real inbox,
// or a real provider. It proves the shapes this app maps, the words it can
// render, and the keys it writes. Delivery of an actual confirmation email
// remains a claim only a device run can earn.

import XCTest
@testable import Tono

final class Build114EmailAccountTests: XCTestCase {

    private typealias Outcome = TonoBackend.EmailAuthOutcome
    private typealias Action = EmailSignInSheet.Action

    // ───────────────────────────────────────────────────────────────────
    // Classification — by shape, never by message
    // ───────────────────────────────────────────────────────────────────

    func testEachAnsweredStatusClassBecomesItsOwnOutcome() {
        // The bodies below are deliberately provider-shaped noise. If any of
        // them could influence the outcome, classification would be reading a
        // message — which is the thing this lane must never do.
        let noise = "supabase: project host unreachable (code 40x)"
        XCTAssertEqual(Outcome.from(TonoBackendError.http(400, noise)), .invalidInput)
        XCTAssertEqual(Outcome.from(TonoBackendError.http(401, noise)), .invalidCredentials)
        XCTAssertEqual(Outcome.from(TonoBackendError.http(403, noise)), .verificationRequired)
        XCTAssertEqual(Outcome.from(TonoBackendError.http(429, noise)), .rateLimited)
        XCTAssertEqual(Outcome.from(TonoBackendError.http(500, noise)), .serviceUnavailable)
        XCTAssertEqual(Outcome.from(TonoBackendError.http(503, noise)), .serviceUnavailable)
        // An unmapped status is honest about being unmapped rather than
        // guessing at one of the specific answers.
        XCTAssertEqual(Outcome.from(TonoBackendError.http(418, noise)), .unknownFailure)
    }

    /// Build 113's protected property, carried onto the account path: a rate
    /// limit is not a bad password and it is certainly not a paywall.
    func testARateLimitIsNeitherACredentialFailureNorAPaywall() {
        let outcome = Outcome.from(TonoBackendError.http(429, "rate limited"))
        XCTAssertEqual(outcome, .rateLimited)
        XCTAssertNotEqual(outcome, .invalidCredentials)
        let sentence = EmailSignInSheet.emailOutcomeMessage(outcome, action: .signIn)
        for word in ["subscription", "subscribe", "pro", "upgrade", "trial", "purchase", "pay"] {
            XCTAssertFalse(
                sentence.lowercased().contains(word),
                "a rate limit must never be described as a payment problem (found \"\(word)\")"
            )
        }
    }

    func testOnlyGenuineConnectionFailuresBecomeOffline() {
        XCTAssertEqual(Outcome.from(TonoBackendError.offline), .offline)
        XCTAssertEqual(Outcome.from(TonoBackendError.network("dns")), .offline)
        XCTAssertEqual(
            Outcome.from(URLError(.notConnectedToInternet)), .offline
        )
        XCTAssertEqual(Outcome.from(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(Outcome.from(URLError(.cannotFindHost)), .offline)
        // A request the app itself cancelled is not "you are offline". Telling
        // someone to check a working connection is its own wrong answer.
        XCTAssertEqual(Outcome.from(URLError(.cancelled)), .unknownFailure)
        XCTAssertEqual(Outcome.from(URLError(.badURL)), .unknownFailure)
    }

    func testAnUnrecognisedFailureIsNeverSilentlyAccepted() {
        struct Anything: Error {}
        let outcome = Outcome.from(Anything())
        XCTAssertEqual(outcome, .unknownFailure)
        XCTAssertFalse(
            EmailSignInSheet.isAccepted(outcome),
            "an unclassified failure must never be styled as the accepted answer"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Consumer copy
    // ───────────────────────────────────────────────────────────────────

    private static let everyOutcome: [Outcome] = [
        .checkYourEmail, .verificationRequired, .invalidCredentials, .rateLimited,
        .invalidInput, .offline, .serviceUnavailable, .addressAlreadyLinked,
        .unknownFailure,
    ]

    private static let everyAction: [Action] = [
        .createAccount, .signIn, .resendConfirmation, .resetPassword,
    ]

    /// Every sentence this sheet can produce, across every outcome and every
    /// action. Exhaustive by construction, so a new combination is covered the
    /// moment it exists.
    private static let everySentence: [String] = sentences(for: everyOutcome)

    /// The subset a person can reach WITHOUT having proven the address —
    /// i.e. everything except the post-authentication conflict refusal. This
    /// is the set the anti-enumeration sweep applies to; see
    /// `testTheConflictRefusalIsPostAuthenticationOnlyAndOffersAnExit` for why
    /// the one exclusion is safe rather than convenient.
    private static let unauthenticatedSentences: [String] =
        sentences(for: everyOutcome.filter { $0 != .addressAlreadyLinked })

    private static func sentences(for outcomes: [Outcome]) -> [String] {
        outcomes.flatMap { outcome in
            everyAction.map { EmailSignInSheet.emailOutcomeMessage(outcome, action: $0) }
        }
    }

    func testNoConsumerSentenceNamesImplementationDetail() {
        let forbidden = [
            "backend", "server", "endpoint", "provider", "api key", "apikey",
            "token", "bearer", "transport", "status code", "http", "https",
            "payload", "request", "response", "supabase", "database", "sql",
            "timeout", "socket", "ssl", "401", "403", "429", "500", "503",
            "error code", "exception", "nil", "null",
        ]
        for sentence in Self.everySentence {
            let lowered = sentence.lowercased()
            for word in forbidden {
                XCTAssertFalse(
                    lowered.contains(word),
                    "consumer copy must name no implementation detail — \"\(word)\" in: \(sentence)"
                )
            }
            XCTAssertFalse(sentence.isEmpty, "no outcome may render an empty sentence")
        }
    }

    /// The anti-enumeration property, stated as the sheet's own words.
    ///
    /// Creating an account and asking for a new confirmation link must produce
    /// the IDENTICAL accepted sentence, because the server answers identically
    /// for a registered and an unregistered address. If this sheet phrased the
    /// two differently, a stranger could tell them apart from the outside and
    /// the server-side work would be undone by the one surface they can see.
    func testTheAcceptedAnswerCannotDistinguishAKnownFromAnUnknownAddress() {
        let created = EmailSignInSheet.emailOutcomeMessage(.checkYourEmail, action: .createAccount)
        let resent = EmailSignInSheet.emailOutcomeMessage(
            .checkYourEmail, action: .resendConfirmation
        )
        XCTAssertEqual(
            created, resent,
            "creating an account and resending confirmation must read identically"
        )
        XCTAssertTrue(EmailSignInSheet.isAccepted(.checkYourEmail))
    }

    func testNoSentenceEverStatesWhetherAnAddressIsRegistered() {
        let oracles = [
            "already registered", "already exists", "already has an account",
            "no account", "not registered", "unknown address", "we don't have",
            "isn't registered", "does not exist", "doesn't exist", "new here",
            "already in use",
        ]
        for sentence in Self.unauthenticatedSentences {
            let lowered = sentence.lowercased()
            for phrase in oracles {
                XCTAssertFalse(
                    lowered.contains(phrase),
                    "the sheet must not be an account oracle — \"\(phrase)\" in: \(sentence)"
                )
            }
        }
    }

    /// An operational failure must never be dressed up as delivery. A person
    /// told to check their email when nothing was sent waits for mail that
    /// will never arrive, and the wait is silent.
    func testAnOutageIsNeverAnnouncedAsDelivery() {
        for action in [Action.createAccount, .signIn, .resendConfirmation, .resetPassword] {
            let sentence = EmailSignInSheet
                .emailOutcomeMessage(.serviceUnavailable, action: action)
                .lowercased()
            XCTAssertFalse(sentence.contains("check your email"))
            XCTAssertFalse(sentence.contains("we sent"))
            XCTAssertFalse(sentence.contains("link we sent"))
            XCTAssertTrue(
                sentence.contains("try again"),
                "an outage must still leave the person with a next step"
            )
        }
        XCTAssertFalse(EmailSignInSheet.isAccepted(.serviceUnavailable))
        XCTAssertFalse(EmailSignInSheet.isAccepted(.offline))
        XCTAssertFalse(EmailSignInSheet.isAccepted(.rateLimited))
        XCTAssertFalse(EmailSignInSheet.isAccepted(.verificationRequired))
    }

    /// Confirming an address is not a purchase. Nothing the sheet can say may
    /// imply that proving an email grants Pro.
    func testNoSentencePromisesAccessInReturnForConfirmingAnAddress() {
        for sentence in Self.everySentence {
            let lowered = sentence.lowercased()
            for claim in ["unlock", "you're now pro", "you are now pro", "free access", "activated"] {
                XCTAssertFalse(
                    lowered.contains(claim),
                    "confirming an address grants nothing — \"\(claim)\" in: \(sentence)"
                )
            }
        }
    }

    func testTheVerificationRequiredAnswerNamesTheNextStep() {
        let sentence = EmailSignInSheet
            .emailOutcomeMessage(.verificationRequired, action: .signIn)
            .lowercased()
        XCTAssertTrue(sentence.contains("confirm"))
        XCTAssertTrue(
            sentence.contains("new one") || sentence.contains("link"),
            "a blocked sign-in must point at the link, not just refuse"
        )
    }

    /// The login endpoint answers 409 `account_conflict` when the credentials
    /// were CORRECT but the address is already the verified identity of a
    /// different canonical account. Mapping that to `unknownFailure` produced
    /// "That didn't work. Try again." — advice that can never work, since the
    /// server refuses the same way forever. It is now its own shape.
    ///
    /// Two properties, both required for the exclusion above to be honest:
    ///
    ///   1. It is the ONLY status in this lane that is answered exclusively
    ///      after the auth provider accepted the password, so the person
    ///      reading its sentence has already proven they own the mailbox. A
    ///      stranger is stopped at 401 and never sees it.
    ///   2. It names something to do instead of merely refusing.
    func testTheConflictRefusalIsPostAuthenticationOnlyAndOffersAnExit() {
        XCTAssertEqual(
            Outcome.from(TonoBackendError.http(409, "account_conflict")),
            .addressAlreadyLinked
        )
        XCTAssertNotEqual(
            Outcome.from(TonoBackendError.http(409, "account_conflict")), .unknownFailure,
            "a permanent refusal must not be rendered as a retryable one"
        )
        XCTAssertFalse(EmailSignInSheet.isAccepted(.addressAlreadyLinked))

        let sentence = EmailSignInSheet
            .emailOutcomeMessage(.addressAlreadyLinked, action: .signIn)
            .lowercased()
        // An exit, not just a refusal — and specifically NOT "try again".
        XCTAssertFalse(
            sentence.contains("try again"),
            "retrying a conflict is futile, so the copy must not suggest it"
        )
        XCTAssertTrue(sentence.contains("different address"))
        XCTAssertTrue(sentence.contains("sign in"))

        // The sentence is still bound by the two sweeps that apply to every
        // outcome: no implementation detail, and no promise of access. Only
        // the anti-enumeration sweep is carved out, and only because of
        // property 1 above.
        for word in ["backend", "server", "supabase", "409", "http", "token", "conflict"] {
            XCTAssertFalse(sentence.contains(word), "found \"\(word)\" in: \(sentence)")
        }
        for claim in ["unlock", "free access", "activated", "subscription"] {
            XCTAssertFalse(sentence.contains(claim), "found \"\(claim)\" in: \(sentence)")
        }
    }

    /// The lane's status vocabulary, pinned against the server that emits it.
    /// Every status the email endpoints can answer with must have a mapping
    /// that is not the catch-all — a status the server raises deliberately and
    /// the client collapses into "try again" is a dead end by construction.
    func testEveryStatusTheServerRaisesInThisLaneHasItsOwnShape() throws {
        let server = try Self.repoSource("apps/backend/server.py")
        // The lane starts at its shared rate/failure helpers — where several
        // of the statuses are actually raised — and ends after logout.
        let lane = try XCTUnwrap(
            Self.sliceBetween(
                start: "def _email_auth_rate_gate",
                end: "class RegistrationEventsResponse",
                in: server
            ),
            "the email auth lane must exist in the server"
        )
        let statuses: [(String, Outcome)] = [
            ("HTTP_400_BAD_REQUEST", .invalidInput),
            ("HTTP_401_UNAUTHORIZED", .invalidCredentials),
            ("HTTP_403_FORBIDDEN", .verificationRequired),
            ("HTTP_409_CONFLICT", .addressAlreadyLinked),
            ("HTTP_429_TOO_MANY_REQUESTS", .rateLimited),
            ("HTTP_503_SERVICE_UNAVAILABLE", .serviceUnavailable),
        ]
        for (symbol, _) in statuses {
            XCTAssertTrue(
                lane.contains(symbol),
                "\(symbol) should be raised in this lane — if the server stopped, drop it here too"
            )
        }
        for (symbol, expected) in statuses where lane.contains(symbol) {
            let code = try XCTUnwrap(
                Int(symbol.split(separator: "_")[1]), "status symbol must carry its code"
            )
            XCTAssertEqual(
                Outcome.from(TonoBackendError.http(code, "detail")), expected,
                "the server raises \(symbol) in this lane, so \(code) needs its own shape"
            )
        }
        // And the ones the lane raises that this test does not enumerate must
        // not silently appear — if the server grows a new deliberate status,
        // this list has to grow with it.
        XCTAssertFalse(
            lane.contains("HTTP_402") || lane.contains("HTTP_410") || lane.contains("HTTP_423"),
            "a new deliberate status in this lane needs a mapping and a case here"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Client contract
    // ───────────────────────────────────────────────────────────────────

    func testTheDeadOTPEndpointsAreGoneAndTheRealLaneIsCalled() throws {
        let client = try Self.strippingComments(Self.source("Shared/TonoBackend.swift"))
        for path in [
            "/v1/auth/email/register",
            "/v1/auth/email/login",
            "/v1/auth/email/resend",
            "/v1/auth/email/reset",
            "/v1/auth/email/logout",
        ] {
            XCTAssertTrue(client.contains(path), "the account lane must call \(path)")
        }
        // The endpoints that never existed must be gone from CODE, not merely
        // unreferenced — a stray call site is a 404 a person reads as a broken
        // account.
        XCTAssertFalse(
            client.contains("/v1/auth/request-link"),
            "the endpoint that never existed must not be called"
        )
        XCTAssertFalse(
            client.contains("/v1/auth/verify-otp"),
            "the endpoint that never existed must not be called"
        )
    }

    /// `signedInEmail` is the key `StoreKitManager.isIdentifiedAccount` reads,
    /// so a second writer anywhere would be a way to become purchase-eligible
    /// without the server ever confirming the address.
    func testTheConfirmedAddressIsWrittenInExactlyOnePlaceAndOnlyOnServerProof() throws {
        let raw = try Self.source("Shared/TonoBackend.swift")
        let code = Self.strippingComments(raw)
        let writes = code.components(
            separatedBy: "SharedKeychain.set(address, forKey: KeychainKeys.signedInEmail)"
        ).count - 1
        XCTAssertEqual(writes, 1, "exactly one writer of the confirmed-address key")
        XCTAssertTrue(
            code.contains(#"if let verified = resp["email_verified"] as? Bool, verified,"#),
            "the write must be gated on the server's own verification flag"
        )
        // And no other target may write it either.
        for relative in [
            "App/SettingsView.swift",
            "App/OnboardingEntryPointsView.swift",
            "Shared/StoreKitManager.swift",
        ] {
            let other = Self.strippingComments(try Self.source(relative))
            XCTAssertFalse(
                other.contains("set(") && other.contains("KeychainKeys.signedInEmail")
                    && other.contains("SharedKeychain.set"),
                "\(relative) must read the confirmed address, never write it"
            )
        }
    }

    /// Sign-out has to remove the device's ability to prove itself back into
    /// the same row. Dropping the bearer alone is not a sign-out: the durable
    /// credential would re-register this device into the account it just left,
    /// and on a shared phone the next person lands in someone else's history.
    func testSignOutClearsEveryDeviceSecretAndNotJustTheBearer() throws {
        let code = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        let body = try XCTUnwrap(
            Self.body(ofFunction: "public func signOut() async", in: code),
            "signOut must exist"
        )
        for key in ["apiToken", "signedInEmail", "accountID", "deviceCredential", "deviceID"] {
            XCTAssertTrue(
                body.contains("SharedKeychain.delete(KeychainKeys.\(key))"),
                "sign-out must clear \(key) — leaving it behind is a silent re-entry"
            )
        }
        XCTAssertTrue(
            body.contains("try? await postObject"),
            "the local sign-out must not depend on the network call succeeding"
        )
    }

    /// The registration ledger is only auditable if every event says which
    /// surface and which shipped build it came from.
    func testEveryAccountRequestCarriesTheSurfaceAndTheShippedBuild() throws {
        let code = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        let calls = code.components(separatedBy: #""source_surface": "ios""#).count - 1
        XCTAssertEqual(calls, 4, "register, login, resend and reset all tag their surface")
        XCTAssertEqual(
            code.components(separatedBy: #""app_version": Self.appBuild"#).count - 1, 4,
            "every account request carries the shipped build tag"
        )
        XCTAssertTrue(
            code.contains(#"Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")"#),
            "the build tag must be read from the shipped bundle, never invented"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Surface behaviour
    // ───────────────────────────────────────────────────────────────────

    /// There must be no parameter through which a caught failure could reach
    /// the screen. The mapper takes an outcome and an action; the sheet holds
    /// no state that can carry provider text.
    func testTheSheetCanHoldNoFailureTextAtAll() throws {
        let raw = try Self.source("App/OnboardingEntryPointsView.swift")
        let sheet = try XCTUnwrap(
            Self.sliceBetween(
                start: "struct EmailSignInSheet: View {", end: "\n}\n", in: raw
            ),
            "EmailSignInSheet must exist"
        )
        let code = Self.strippingComments(sheet)
        for leak in [
            "localizedDescription",
            "errorDescription",
            "\\(error",
            "String(describing:",
            "@State private var errorMessage",
        ] {
            XCTAssertFalse(
                code.contains(leak),
                "no failure text may reach the sheet — found \(leak)"
            )
        }
        XCTAssertTrue(
            code.contains("lastOutcome = TonoBackend.EmailAuthOutcome.from(error)"),
            "a caught failure must be reduced to a shape immediately"
        )
        // Busy state is always released, so a thrown failure cannot strand the
        // sheet — the Build 112 property, held here too.
        XCTAssertTrue(code.contains("defer { isWorking = false }"))
    }

    /// A returning subscriber must stop seeing the paywall on the sign-in
    /// itself, not after finding Restore. Settings re-reads the entitlement as
    /// part of the success path.
    func testSigningInRefreshesTheEntitlementAndSigningOutStopsClaimingIt() throws {
        let settings = Self.strippingComments(try Self.source("App/SettingsView.swift"))
        let success = try XCTUnwrap(
            Self.sliceBetween(start: "EmailSignInSheet(", end: "onCancel:", in: settings),
            "Settings must present the account sheet"
        )
        XCTAssertTrue(
            success.contains("store.refreshEntitlements()"),
            "a sign-in must re-read the entitlement the account already owns"
        )
        let signOut = try XCTUnwrap(
            Self.body(ofFunction: "private func signOut() async", in: settings),
            "Settings must offer sign-out"
        )
        XCTAssertTrue(signOut.contains("TonoBackend.shared.signOut()"))
        XCTAssertTrue(
            signOut.contains("store.resetToAnonymous()"),
            "a signed-out device must stop mirroring Pro until it proves itself again"
        )
    }

    /// Confirming an address makes a subscription RECOVERABLE; it does not
    /// grant one. The Settings sentence has to say so, and the purchase gate
    /// has to keep requiring both facts.
    func testConfirmingAnAddressIsAPreconditionForBuyingAndNeverAGrant() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("It does not by itself unlock Pro."),
            "Settings must not imply that signing in is what unlocks Pro"
        )
        let gate = try XCTUnwrap(
            Self.body(ofFunction: "public var isIdentifiedAccount: Bool", in:
                Self.strippingComments(try Self.source("Shared/StoreKitManager.swift"))),
            "the purchase gate must exist"
        )
        XCTAssertTrue(gate.contains("KeychainKeys.signedInEmail"))
        XCTAssertTrue(
            gate.contains("KeychainKeys.accountID"),
            "a purchase binds to the canonical account id, so both facts are required"
        )
    }

    /// One password floor, stated in two places, is a drift risk — so the two
    /// are compared rather than trusted. The server remains the authority; the
    /// client mirrors it only so a person is told the rule while typing.
    func testThePasswordFloorMirrorsTheServersOwn() throws {
        let server = try Self.repoSource("apps/backend/server.py")
        let marker = "if len(raw) < "
        let start = try XCTUnwrap(
            server.range(of: marker), "the server must state a password floor"
        )
        let digits = server[start.upperBound...].prefix { $0.isNumber }
        let serverFloor = try XCTUnwrap(Int(digits), "the floor must be a number")
        XCTAssertEqual(
            EmailSignInSheet.minimumPasswordLength, serverFloor,
            "the sheet must mirror the server's password floor, not invent its own"
        )
        // The floor is stated where a person can act on it BEFORE submitting —
        // in the create-account instruction — rather than in a failure
        // sentence. See the next test for why the failure sentence must not
        // name it.
        let sheet = try Self.source("App/OnboardingEntryPointsView.swift")
        XCTAssertTrue(
            sheet.contains("at least \\(Self.minimumPasswordLength) characters"),
            "the create-account step must state the rule that is enforced"
        )
    }

    /// The server answers TWO different input-shaped refusals with 400: an
    /// address it will not accept, and a password the auth provider considers
    /// too weak on its own strength rules. Both arrive here carrying no
    /// provider text — deliberately — so the client cannot tell them apart.
    ///
    /// A sentence that names only the length floor is therefore a dead end for
    /// the second: someone who typed twenty characters and was refused for
    /// lacking a digit reads "use at least 8 characters", changes nothing, and
    /// is refused again. The one sentence has to be true of either refusal.
    func testTheInputRefusalSentenceIsTrueOfBothRefusalsItCovers() {
        let sentence = EmailSignInSheet
            .emailOutcomeMessage(.invalidInput, action: .createAccount)
            .lowercased()
        XCTAssertFalse(
            sentence.contains("\(EmailSignInSheet.minimumPasswordLength) characters"),
            """
            the refusal sentence must not name the length floor: a provider \
            strength refusal is not a length problem, and pointing at length \
            leaves that person with nothing to change
            """
        )
        XCTAssertTrue(sentence.contains("email address"))
        XCTAssertTrue(sentence.contains("password"))
        // And it still points at something to do about each half.
        XCTAssertTrue(sentence.contains("different address"))
        XCTAssertTrue(sentence.contains("longer") || sentence.contains("less predictable"))
    }

    /// The flow a person actually walks: create → confirm → sign in. The
    /// confirmation step is a real destination, not a toast, because it is
    /// crossed by leaving for an inbox and coming back — possibly after the
    /// app was closed entirely.
    func testConfirmationIsADestinationAndSignInIsTheDefault() throws {
        let code = Self.strippingComments(
            try Self.source("App/OnboardingEntryPointsView.swift")
        )
        XCTAssertTrue(code.contains("case confirmSent"))
        XCTAssertTrue(
            code.contains("@State private var step: Step = .signIn"),
            "an existing person landing on this sheet should be signing in"
        )
        XCTAssertTrue(
            code.contains("step = .confirmSent"),
            "a successful registration must move to the confirmation step"
        )
        // Registration never reports success: only a sign-in can, and only the
        // server can say so.
        let register = try XCTUnwrap(
            Self.body(ofFunction: "private func submitCreateAccount() async", in: code)
        )
        XCTAssertFalse(
            register.contains("onSuccess()"),
            "creating an account must not be reported as being signed in"
        )
        let signIn = try XCTUnwrap(
            Self.body(ofFunction: "private func submitSignIn() async", in: code)
        )
        XCTAssertTrue(signIn.contains("onSuccess()"))
        XCTAssertTrue(
            signIn.contains("password = \"\""),
            "the typed password must be dropped as soon as it is no longer needed"
        )
    }

    // ───────────────────────────────────────────────────────────────────
    // Helpers
    // ───────────────────────────────────────────────────────────────────

    /// `#filePath` is `<srcroot>/Tests/…`; SRCROOT is one directory up.
    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The monorepo root, three levels above SRCROOT (`<root>/apps/ios`). Used
    /// only to compare a client mirror against the server rule it mirrors.
    private static func repoSource(
        _ relative: String, file: StaticString = #filePath
    ) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // <root>
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Drop `//` comments so a doc comment that legitimately NAMES a banned
    /// word (these files explain why the word is banned) cannot mask or fake a
    /// real occurrence. Block comments are not used in the scanned files.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                // Keep the line if the marker is inside a string literal — the
                // only such cases here are URL paths, which we want to keep.
                let prefix = line[..<marker.lowerBound]
                let quotes = prefix.filter { $0 == "\"" }.count
                return quotes % 2 == 1 ? line : prefix
            }
            .joined(separator: "\n")
    }

    /// Extract a function/computed-property body by brace matching from its
    /// declaration, so an assertion can be scoped to one member.
    private static func body(ofFunction declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration) else { return nil }
        var depth = 0
        var started = false
        var out = ""
        for character in code[start.lowerBound...] {
            if character == "{" { depth += 1; started = true }
            if started { out.append(character) }
            if character == "}" {
                depth -= 1
                if started && depth == 0 { return out }
            }
        }
        return nil
    }

    private static func sliceBetween(start: String, end: String, in code: String) -> String? {
        guard let from = code.range(of: start) else { return nil }
        let rest = code[from.upperBound...]
        guard let to = rest.range(of: end) else { return String(rest) }
        return String(rest[..<to.lowerBound])
    }
}
