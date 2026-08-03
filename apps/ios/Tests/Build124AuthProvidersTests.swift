// Build124AuthProvidersTests.swift
// Build 124 — the production auth-provider repair.
//
// The installed app showed an Apple button that did not work, no Google, no
// passkeys, and a resend that told people to check mail no email had been sent.
// This build fixes each: Apple gets its entitlement (the actual defect), Google
// is linked but fail-closed until a real Tono client is configured, passkeys are
// implemented against the backend ceremonies at rpId tonoit.com, and the email
// lane stops claiming delivery it cannot guarantee. Every provider converges on
// the ONE canonical account, and paid access stays fail-closed.
//
// These guards drive the REAL shipped types and scan the REAL shipped source and
// project, so a regression turns a test red instead of passing against a
// re-implementation — the technique Build 95/107/112/113/114 established here.
//
// HONEST LIMIT: nothing below proves a real device ceremony, a live AASA, a real
// Google OAuth round trip, or a signed provisioning profile. It proves the
// entitlement is present, the package is linked, the rpId is canonical, the
// config gates are fail-closed, the copy is honest, and the convergence writes
// land in one place. Device/provider success remains a claim only a signed run
// can earn — see the auth handoff's "Remaining provider blockers".

import XCTest
@testable import Tono

final class Build124AuthProvidersTests: XCTestCase {

    private typealias Outcome = TonoBackend.EmailAuthOutcome
    private typealias Action = EmailSignInSheet.Action

    // ───────────────────────────────────────────────────────────────────────
    // A. Sign in with Apple — the entitlement is the fix
    // ───────────────────────────────────────────────────────────────────────

    /// The production defect: the Apple button shipped, but the host app's
    /// entitlements never requested Sign in with Apple, so the system refused
    /// every authorization. This guard fails if the visible button is ever
    /// shipped again without the signed entitlement beside it.
    func testAppleButtonRequiresTheSignInWithAppleEntitlement() throws {
        let view = try Self.source("App/OnboardingEntryPointsView.swift")
        XCTAssertTrue(
            view.contains("SignInWithAppleButton"),
            "the Apple button is the surface this entitlement exists for"
        )
        let entitlements = try Self.source("App/Tono.entitlements")
        XCTAssertTrue(
            entitlements.contains("com.apple.developer.applesignin"),
            "a shipped Apple button REQUIRES the Sign in with Apple entitlement"
        )
    }

    /// The nonce contract, pinned on both sides: the client sends the RAW nonce
    /// and sets the SHA256 of it on the authorization request; the backend
    /// re-hashes the raw nonce and compares. Break either half and a real device
    /// sign-in 401s, so both are asserted together. The client sends no audience
    /// — the backend's is env-driven (APPLE_CLIENT_ID = the bundle id).
    func testAppleNonceAndAudienceFlowIsPreserved() throws {
        let view = Self.strippingComments(try Self.source("App/OnboardingEntryPointsView.swift"))
        XCTAssertTrue(
            view.contains("request.nonce = SHA256.hash"),
            "the request nonce must be the SHA256 of the one-time nonce"
        )
        XCTAssertTrue(
            view.contains("signInWithApple(identityToken: token, nonce: nonce)"),
            "the RAW nonce must be handed to the backend, not the hash"
        )
        let server = try Self.repoSource("apps/backend/server.py")
        XCTAssertTrue(
            server.contains("hashlib.sha256(body.nonce.encode(\"utf-8\")).hexdigest()"),
            "the backend must re-hash the raw nonce to compare against the token claim"
        )
        XCTAssertFalse(view.contains("audience"), "the client must not invent an audience")
    }

    // ───────────────────────────────────────────────────────────────────────
    // B. Google — linked, but honest and fail-closed
    // ───────────────────────────────────────────────────────────────────────

    /// Part B requires the SDK linked into the app target. The repo's prior
    /// guard asserted the OPPOSITE (not linked) on purpose, deferring the config
    /// review this build performs; that guard is retired in favor of this one.
    func testGoogleSignInPackageIsLinkedIntoTheAppTarget() throws {
        let project = try Self.repoSource("apps/ios/Tono.xcodeproj/project.pbxproj")
        XCTAssertTrue(
            project.contains("google/GoogleSignIn-iOS") || project.contains("GoogleSignIn-iOS.git"),
            "GoogleSignIn-iOS must be linked as an SPM package"
        )
        XCTAssertTrue(
            project.contains("productName = GoogleSignIn"),
            "the GoogleSignIn product must be a package product dependency of the app"
        )
    }

    /// Even linked, the button appears only when a real Tono Google client is
    /// configured — otherwise the app shows no Google affordance rather than one
    /// that can only fail. Both gates are required: compile-time linkage AND the
    /// runtime config check, in that nesting order.
    func testGoogleButtonIsGatedOnBothLinkageAndRealConfig() throws {
        let source = Self.strippingComments(try Self.source("App/OnboardingEntryPointsView.swift"))
        let button = try XCTUnwrap(source.range(of: "Button(\"Continue with Google\")"))
        let canImport = try XCTUnwrap(
            source.range(of: "#if canImport(GoogleSignIn)", options: .backwards,
                         range: source.startIndex..<button.lowerBound)
        )
        let configGate = try XCTUnwrap(
            source.range(of: "if GoogleSignInConfig.isConfigured", options: .backwards,
                         range: source.startIndex..<button.lowerBound)
        )
        XCTAssertLessThan(canImport.lowerBound, configGate.lowerBound)
        XCTAssertLessThan(configGate.lowerBound, button.lowerBound)
    }

    /// The config gate is fail-closed at runtime: this build carries no real
    /// client id (the Info.plist value is the unexpanded build variable), so
    /// `isConfigured` is false and `clientID` is nil. Provider activation flips
    /// this by setting GID_CLIENT_ID.
    func testGoogleConfigIsFailClosedInThisBuild() {
        XCTAssertNil(GoogleSignInConfig.clientID, "no real client id is embedded in this build")
        XCTAssertFalse(
            GoogleSignInConfig.isConfigured,
            "Google must be fail-closed until an operator configures it"
        )
    }

    /// No sibling identifier or secret is embedded. The Info.plist carries only
    /// build variables, and no Google client-id literal appears in app code
    /// (documentation comments that explain the format are stripped first).
    func testNoSiblingGoogleIdentifierOrSecretIsEmbedded() throws {
        let plist = try Self.source("App/Info.plist")
        XCTAssertTrue(plist.contains("$(GID_CLIENT_ID)"), "client id must be a build variable")
        XCTAssertTrue(plist.contains("$(GID_URL_SCHEME)"), "redirect scheme must be a build variable")
        XCTAssertFalse(
            plist.contains("apps.googleusercontent.com"),
            "Info.plist must not embed a Google client identifier"
        )
        for relative in [
            "App/GoogleSignInConfig.swift", "App/OnboardingEntryPointsView.swift", "App/TonoApp.swift",
        ] {
            let code = Self.strippingComments(try Self.source(relative))
            XCTAssertFalse(
                code.contains("googleusercontent"),
                "\(relative) must not embed a Google client identifier"
            )
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // C. Passkeys — implemented, canonical rpId, fail-closed, honest
    // ───────────────────────────────────────────────────────────────────────

    /// The authoritative rpId is exactly `tonoit.com`, and the associated-domains
    /// entitlement must name the same host — a mismatch makes every ceremony fail
    /// on device.
    func testPasskeyRelyingPartyIsCanonicalAndMatchesTheEntitlement() throws {
        XCTAssertEqual(PasskeyConfig.canonicalRelyingPartyID, "tonoit.com")
        XCTAssertEqual(
            PasskeyConfig.relyingPartyID, "tonoit.com",
            "with no staging override, the runtime rpId is the canonical value"
        )
        let entitlements = try Self.source("App/Tono.entitlements")
        XCTAssertTrue(
            entitlements.contains("webcredentials:tonoit.com"),
            "the associated-domains entitlement must match the rpId exactly"
        )
    }

    /// Fail-closed by default: no button until an operator provisions the
    /// capability + AASA and flips TONO_PASSKEYS_ENABLED.
    func testPasskeyIsFailClosedByDefault() {
        XCTAssertFalse(
            PasskeyConfig.isEnabled,
            "passkeys must be OFF until an operator provisions the capability + AASA"
        )
    }

    /// The client drives the backend ceremonies and reports success only from a
    /// verified response. Scanned on shipped source so a refactor that returns
    /// `.signedIn` before the verify call turns this red — the "never fake
    /// success" property.
    func testPasskeyClientVerifiesWithTheBackendBeforeClaimingSuccess() throws {
        let backend = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        for path in [
            "/v1/auth/passkey/register/options", "/v1/auth/passkey/register/verify",
            "/v1/auth/passkey/login/options", "/v1/auth/passkey/login/verify",
        ] {
            XCTAssertTrue(backend.contains(path), "the passkey client must call \(path)")
        }
        let client = Self.strippingComments(try Self.source("App/PasskeySignIn.swift"))
        let verify = try XCTUnwrap(
            client.range(of: "passkeyLoginVerify(credential: payload)"),
            "sign-in must call the backend verify"
        )
        let signedIn = try XCTUnwrap(
            client.range(of: "return .signedIn"), "sign-in must have a success return"
        )
        XCTAssertLessThan(
            verify.lowerBound, signedIn.lowerBound,
            "sign-in must be reported ONLY after the backend verified the assertion"
        )
        // The client never writes an entitlement or the confirmed-address key —
        // those stay with the backend transport / gate.
        for forbidden in ["signedInEmail", "hasRecoveryIdentity", "recordEntitlement"] {
            XCTAssertFalse(client.contains(forbidden), "the ceremony must not write \(forbidden)")
        }
    }

    /// Passkeys converge exactly like Apple/Google: both verify methods funnel
    /// through the same convergence helper.
    func testPasskeyConvergesOnTheCanonicalAccountLikeAppleAndGoogle() throws {
        let backend = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        for fn in ["passkeyRegisterVerify", "passkeyLoginVerify"] {
            let body = try XCTUnwrap(
                Self.body(ofFunction: "func \(fn)", in: backend), "\(fn) must exist"
            )
            XCTAssertTrue(
                body.contains("persistProviderConvergence(response)"),
                "\(fn) must converge on the canonical account"
            )
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // D. Email UX — honest, still anti-enumerating
    // ───────────────────────────────────────────────────────────────────────

    /// The accepted resend/create answer must not claim a link WAS sent (the
    /// server returns 202 and sends nothing for an already-confirmed address),
    /// and must name the exit an already-confirmed person needs.
    func testAcceptedConfirmationCopyNeverClaimsDeliveryAndOffersTheExit() {
        for action in [Action.createAccount, .resendConfirmation] {
            let lowered = EmailSignInSheet.emailOutcomeMessage(.checkYourEmail, action: action).lowercased()
            for claim in [
                "we sent", "we've sent", "we have sent", "link we sent",
                "we emailed you", "sent you a link", "check your email",
            ] {
                XCTAssertFalse(
                    lowered.contains(claim),
                    "accepted \(action) copy must not claim delivery — found \"\(claim)\""
                )
            }
            XCTAssertTrue(lowered.contains("if"), "the delivery claim must be conditional")
            XCTAssertTrue(lowered.contains("sign in"), "an already-confirmed person is told to sign in")
            XCTAssertTrue(lowered.contains("forgot password"), "and to reset a forgotten password")
        }
        // Still anti-enumerating: create and resend read identically.
        XCTAssertEqual(
            EmailSignInSheet.emailOutcomeMessage(.checkYourEmail, action: .createAccount),
            EmailSignInSheet.emailOutcomeMessage(.checkYourEmail, action: .resendConfirmation)
        )
    }

    /// Reset is its own, separately truthful message: conditional, about a
    /// password, and never dressed as guaranteed delivery.
    func testPasswordResetCopyIsSeparateAndTruthful() {
        let reset = EmailSignInSheet.emailOutcomeMessage(.checkYourEmail, action: .resetPassword)
        let lowered = reset.lowercased()
        XCTAssertNotEqual(
            reset, EmailSignInSheet.emailOutcomeMessage(.checkYourEmail, action: .createAccount),
            "reset is a different link and a different next step"
        )
        XCTAssertTrue(lowered.contains("password"))
        XCTAssertTrue(lowered.contains("if"), "reset delivery must be conditional")
        for claim in ["we sent", "link we sent", "check your email"] {
            XCTAssertFalse(lowered.contains(claim), "reset must not claim delivery — found \"\(claim)\"")
        }
    }

    // ───────────────────────────────────────────────────────────────────────
    // E. One canonical account, fail-closed paid access
    // ───────────────────────────────────────────────────────────────────────

    /// The confirmed-address key gates purchases, so it must have exactly ONE
    /// writer. Before this build there were two (a latent regression from when
    /// the native-provider path was added); the fix funnels every writer —
    /// email, Apple/Google, passkey — through a single helper.
    func testTheConfirmedAddressHasExactlyOneWriter() throws {
        let backend = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        let writes = backend.components(
            separatedBy: "SharedKeychain.set(address, forKey: KeychainKeys.signedInEmail)"
        ).count - 1
        XCTAssertEqual(writes, 1, "exactly one writer of the purchase-gating address key")
    }

    /// Convergence binds the canonical account id and sets the explicit
    /// purchase-gate flag, recording the address through the single writer.
    func testProviderConvergenceSetsTheAccountAndTheRecoveryFlag() throws {
        let backend = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        let body = try XCTUnwrap(
            Self.body(ofFunction: "func persistProviderConvergence", in: backend),
            "the convergence helper must exist"
        )
        XCTAssertTrue(
            body.contains("persistAccountID(response[\"account_id\"] as? String)"),
            "convergence binds the canonical account id"
        )
        XCTAssertTrue(
            body.contains("KeychainKeys.hasRecoveryIdentity"),
            "convergence sets the explicit purchase-gate flag"
        )
        XCTAssertTrue(
            body.contains("setSignedInEmail(response[\"email\"] as? String)"),
            "convergence records the address via the single writer"
        )
    }

    /// Both native provider sign-ins route through the shared convergence, so
    /// Apple, Google and passkey all land on the same account the email lane and
    /// the web resolve.
    func testAppleAndGoogleAlsoConvergeThroughTheSharedHelper() throws {
        let backend = Self.strippingComments(try Self.source("Shared/TonoBackend.swift"))
        let native = try XCTUnwrap(
            Self.body(ofFunction: "func signInWithNativeProvider", in: backend),
            "the native-provider sign-in must exist"
        )
        XCTAssertTrue(
            native.contains("persistProviderConvergence(response)"),
            "Apple/Google must converge through the same helper as passkeys"
        )
    }

    /// Paid access stays fail-closed: the purchase gate requires the canonical
    /// account id and returns false without it, regardless of provider.
    func testPaidAccessIsFailClosedWithoutTheCanonicalAccount() throws {
        let gate = try XCTUnwrap(
            Self.body(
                ofFunction: "public var isIdentifiedAccount: Bool",
                in: Self.strippingComments(try Self.source("Shared/StoreKitManager.swift"))
            ),
            "the purchase gate must exist"
        )
        XCTAssertTrue(gate.contains("KeychainKeys.accountID"))
        XCTAssertTrue(
            gate.contains("else { return false }"),
            "a missing canonical account must remain fail closed"
        )
    }

    // ───────────────────────────────────────────────────────────────────────
    // Helpers (mirrors of the Build114 source-scanning helpers)
    // ───────────────────────────────────────────────────────────────────────

    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func repoSource(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // apps
            .deletingLastPathComponent()   // <root>
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                let prefix = line[..<marker.lowerBound]
                let quotes = prefix.filter { $0 == "\"" }.count
                return quotes % 2 == 1 ? line : prefix
            }
            .joined(separator: "\n")
    }

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
}
