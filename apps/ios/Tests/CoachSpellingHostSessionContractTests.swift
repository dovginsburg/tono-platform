import XCTest
import UIKit

/// Blocker C — a same-content host/session switch must invalidate stale Coach
/// and spelling callbacks.
///
/// On the build-91 base, `CoachRewriteTarget` authorizes a rewrite whenever the
/// live document text concatenates to the captured text, and `SpellingToken`
/// authorizes a candidate whenever the live token *equals* the captured token.
/// Both decisions are text-only: when focus moves to a different host/field
/// whose text happens to be identical, an in-flight Coach response or debounced
/// spelling callback is wrongly accepted and mutates the wrong document.
///
/// The fix is to bind an explicit host/session identity into the authorization
/// (not text equality alone). That identity type does not exist on the base, so
/// the cross-identity behavioral suite is staged behind
/// `TONO_BUILD92_HOSTSESSION` — keeping the base target compile-safe (inactive
/// `#if` branches are not name-resolved) while giving GREEN a ready contract.
/// The running RED on the base is:
///   • two source contracts proving the authorization is text-only, and
///   • an activation guard proving the behavioral suite is not yet wired.
/// The preserve guards below pass on the base and must keep passing after GREEN
/// so the identity change does not regress text-change / cancellation behavior.
final class CoachSpellingHostSessionContractTests: XCTestCase {

    // MARK: - RED: authorization must bind host/session identity (source contract)

    func testCoachRewriteAuthorizationBindsHostSessionIdentity() throws {
        let source = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        XCTAssertTrue(
            Self.referencesHostSessionIdentity(source),
            "CoachRewriteTarget.capture/mutationPlan authorize on document text alone; build 92 requires an explicit host/session identity in the authorization so an in-flight rewrite cannot apply after a same-content host switch"
        )
    }

    func testSpellingAuthorizationBindsHostSessionIdentity() throws {
        let source = try Self.source("KeyboardExtension/SpellingCorrection.swift")
        XCTAssertTrue(
            Self.referencesHostSessionIdentity(source),
            "SpellingToken/SpellingMutationPlan authorize on token text alone; build 92 requires an explicit host/session identity in the token equality/validation so a debounced suggestion cannot apply after a same-content host switch"
        )
    }

    func testHostSessionBehavioralSuiteIsActivatedForBuild92() {
        #if TONO_BUILD92_HOSTSESSION
        // Activated: the cross-identity behavioral suite in this file is compiled.
        #else
        XCTFail("Host/session identity is not wired into CoachRewriteTarget/SpellingToken. Implement the host/session-aware authorization API and define TONO_BUILD92_HOSTSESSION for the TonoTests target to activate the cross-identity behavioral suite below.")
        #endif
    }

    func testProductionIdentityChangesForIdenticalTraitsWhenDocumentChanges() {
        let traits = "0.0.0.0.0.0"
        let first = HostSessionIdentityFactory.make(
            documentIdentifier: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            traitSignature: traits,
            session: 7
        )
        let second = HostSessionIdentityFactory.make(
            documentIdentifier: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            traitSignature: traits,
            session: 7
        )
        XCTAssertNotEqual(first, second, "production identity must distinguish identical-text/same-trait documents")
    }

    @MainActor
    func testProductionControllerInitializationAcceptsUnavailableDocumentIdentifier() {
        let controller = KeyboardViewController()

        XCTAssertNil(
            HostDocumentIdentifier.read(from: controller.textDocumentProxy),
            "a controller that is not connected to a host must expose no document identity"
        )

        // Exercise the real viewDidLoad path, including its initial production
        // spelling refresh. This used to trap while Swift bridged the proxy's
        // nil Objective-C documentIdentifier to UUID.
        controller.loadViewIfNeeded()
        XCTAssertTrue(controller.isViewLoaded)
    }

    func testControllerUsesDocumentIdentifierAndInvalidatesOnTextChangeAndDisappearance() throws {
        let source = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(source.contains("HostDocumentIdentifier.read(from: textDocumentProxy)"))
        XCTAssertTrue(source.contains("public override func textDidChange"))
        XCTAssertTrue(source.contains("if requestAction == .cancel"))
        XCTAssertTrue(source.contains("advanceHostSession()"))
        XCTAssertTrue(source.contains("invalidateCoachWork(restoreKeyboard: true)"))
        XCTAssertTrue(source.contains("coachTask?.cancel()"))
        XCTAssertTrue(source.contains("target.isCurrent("))
    }

    func testCoachClientReturnsARealCancellableTask() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverCompletingCoachURLProtocol.self]
        let session = URLSession(configuration: configuration)
        // Build 96: a bearer token is required to issue a request at all; a
        // token-less client makes zero network requests. Supply one here so
        // this contract still exercises the real, cancellable task.
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/v1/analyze",
            timeout: 15,
            session: session,
            tokenProvider: { "test-token" }
        )
        let task = try XCTUnwrap(client.coach(draft: "same text") { _ in })
        XCTAssertEqual(task.state, .running)
        task.cancel()
        XCTAssertNotEqual(task.state, .running)
        session.invalidateAndCancel()
    }

    // MARK: - PRESERVE: text-change / cancellation behavior must survive GREEN

    func testCoachRewriteStillRejectsAnEditedDraft() throws {
        let target = try XCTUnwrap(CoachRewriteTarget.capture(before: "Please help me", after: " with this"))
        XCTAssertNil(
            target.mutationPlan(liveBefore: "Please help us", liveAfter: " with this", replacement: "Could you help me?"),
            "an edited draft must never authorize a rewrite"
        )
    }

    func testCoachRewriteStillAuthorizesTheUneditedDraftInTheSameSession() throws {
        let target = try XCTUnwrap(CoachRewriteTarget.capture(before: "Please help me", after: " now"))
        XCTAssertNotNil(
            target.mutationPlan(liveBefore: "Please help me", liveAfter: " now", replacement: "Could you help me now?"),
            "the legitimate same-session, unedited case must remain authorized after the identity change"
        )
    }

    func testSpellingCandidateStillRejectsAChangedToken() throws {
        let expected = try XCTUnwrap(SpellingToken.current(before: "Please hl", after: "p now"))
        let live = try XCTUnwrap(SpellingToken.current(before: "Please help", after: " now"))
        XCTAssertNil(
            SpellingMutationPlan.candidate(liveToken: live, expected: expected, replacement: "help"),
            "a changed token must never authorize a candidate replacement"
        )
    }

    func testSpellingCandidateStillAuthorizesTheUnchangedTokenInTheSameSession() throws {
        let token = try XCTUnwrap(SpellingToken.current(in: "Well, teh"))
        XCTAssertNotNil(
            SpellingMutationPlan.candidate(liveToken: token, expected: token, replacement: "the"),
            "the legitimate same-session, unchanged case must remain authorized after the identity change"
        )
    }

    func testSpellingServiceStillInvalidatesStalePendingWorkOnCancellation() {
        let service = SpellingCorrectionService(debounce: 0)
        let stale = service.beginGeneration()
        let current = service.beginGeneration()   // a switch/disappearance bumps the generation
        XCTAssertFalse(service.accepts(generation: stale), "a stale generation must be rejected after cancellation")
        XCTAssertTrue(service.accepts(generation: current))
        service.cancel()
        XCTAssertFalse(service.accepts(generation: current), "cancel() must invalidate the outstanding generation")
    }

    // MARK: - Staged behavioral cross-identity suite (activates in GREEN)

    #if TONO_BUILD92_HOSTSESSION
    func testStaleCoachTargetRejectedAfterHostSwitchWithIdenticalText() throws {
        let hostA = HostSessionIdentity(host: "com.apple.MobileSMS", session: 1)
        let hostB = HostSessionIdentity(host: "com.apple.mobilenotes", session: 2)
        let target = try XCTUnwrap(CoachRewriteTarget.capture(before: "see you at 5", after: "", host: hostA))
        XCTAssertNil(
            target.mutationPlan(liveBefore: "see you at 5", liveAfter: "", replacement: "See you at 5!", host: hostB),
            "a Coach target captured in one host must not apply after a host switch even when the visible text is identical"
        )
        XCTAssertNotNil(
            target.mutationPlan(liveBefore: "see you at 5", liveAfter: "", replacement: "See you at 5!", host: hostA),
            "the same host/session must still authorize the rewrite"
        )
    }

    func testStaleSpellingTokenRejectedAfterHostSwitchWithIdenticalText() throws {
        let hostA = HostSessionIdentity(host: "com.apple.MobileSMS", session: 1)
        let hostB = HostSessionIdentity(host: "com.apple.mobilenotes", session: 2)
        let tokenA = try XCTUnwrap(SpellingToken.current(before: "helo", after: "", host: hostA))
        let tokenBSameText = try XCTUnwrap(SpellingToken.current(before: "helo", after: "", host: hostB))
        XCTAssertNotEqual(tokenA, tokenBSameText, "identical text in different host/sessions must not be equal tokens")
        XCTAssertNil(
            SpellingMutationPlan.candidate(liveToken: tokenBSameText, expected: tokenA, replacement: "hello"),
            "a spelling candidate authorized for one host/session must not apply after switching to another host with identical text"
        )
        XCTAssertNotNil(
            SpellingMutationPlan.candidate(liveToken: tokenA, expected: tokenA, replacement: "hello"),
            "the same host/session must still authorize the candidate"
        )
    }
    #endif

    // MARK: - Helpers

    private static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // <srcroot>/Tests
            .deletingLastPathComponent()   // <srcroot>
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// True when the source names an explicit host/session identity used by the
    /// authorization. On the build-91 base none of these appear, so the
    /// contract fails for the intended missing behavior.
    private static func referencesHostSessionIdentity(_ source: String) -> Bool {
        let needles = ["hostsession", "hostidentity", "sessionidentity", "hosttoken", "sessionid"]
        let folded = source.lowercased()
        return needles.contains { folded.contains($0) }
    }
}

private final class NeverCompletingCoachURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
