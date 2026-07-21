// Build96CoachAuthTests.swift
// Build 96 — Coach API bearer authentication.
//
// The keyboard's Coach client (`TonoCoachClient`) must attach an
// `Authorization: Bearer <token>` header sourced from the app's shared
// Keychain access group, and — when no token is present — recover locally
// with a visible, deterministic missing-token state that makes ZERO
// network requests. It must not weaken backend auth or invent a fallback
// credential.
//
// RED (before build 96):
//   * The client attached no Authorization header and always issued a
//     request even with no token (the zero-request test fails).
//   * There is no visible missing-token state.
// GREEN (build 96): token present → header attached; token absent →
//   `.missingToken` + zero requests.

import XCTest
@testable import Tono

final class Build96CoachAuthTests: XCTestCase {

    // MARK: - RED/GREEN: no token ⇒ zero network requests

    /// A token-less client must make ZERO network requests and return no
    /// task. This compiles against the existing initializer; on the base it
    /// fails because `variant`/`coach` always issued a request.
    func testVariantWithoutTokenMakesZeroNetworkRequests() {
        CoachRequestTrap.reset()
        let session = Self.trapSession()
        defer { session.invalidateAndCancel() }
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: session
        )
        let done = expectation(description: "variant completes without a token")
        let task = client.variant(draft: "please help me", axis: "safer") { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertNil(task, "an absent token must not create a URLSession task")
        XCTAssertFalse(
            CoachRequestTrap.didStartLoading,
            "an absent token must make ZERO network requests"
        )
    }

    func testCoachWithoutTokenMakesZeroNetworkRequests() {
        CoachRequestTrap.reset()
        let session = Self.trapSession()
        defer { session.invalidateAndCancel() }
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/v1/analyze",
            timeout: 15,
            session: session
        )
        let done = expectation(description: "coach completes without a token")
        let task = client.coach(draft: "please help me") { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertNil(task, "an absent token must not create a URLSession task")
        XCTAssertFalse(
            CoachRequestTrap.didStartLoading,
            "an absent token must make ZERO network requests"
        )
    }

    // MARK: - GREEN: bearer attached when a token is present

    func testVariantAttachesBearerTokenWhenTokenPresent() {
        CoachRequestCapture.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestCapture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: session,
            tokenProvider: { "TESTTOKEN123" }
        )
        let done = expectation(description: "variant issues an authenticated request")
        let task = client.variant(draft: "please help me", axis: "safer") { _ in done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertNotNil(task, "a present token must create a URLSession task")
        XCTAssertEqual(
            CoachRequestCapture.lastAuthorization,
            "Bearer TESTTOKEN123",
            "the request must carry Authorization: Bearer <token>"
        )
    }

    func testMissingTokenStateIsDeterministicAndVisible() {
        // The recovery state is a single, stable, user-visible string — never
        // a silent failure and never a fabricated credential.
        XCTAssertEqual(
            TonoCoachClient.CoachError.missingToken.userFacingMessage,
            "Sign in to Tono to use Coach. Open the Tono app to continue."
        )
    }

    func testVariantReportsMissingTokenWithoutNetworkWhenTokenAbsent() {
        CoachRequestCapture.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestCapture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = TonoCoachClient(
            endpoint: "https://tono.invalid/api/analyze/variant",
            timeout: 15,
            session: session,
            tokenProvider: { nil }
        )
        var received: Result<TonoCoachClient.VariantResponse, TonoCoachClient.CoachError>?
        let done = expectation(description: "variant reports missing token")
        let task = client.variant(draft: "please help me", axis: "safer") { result in
            received = result
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertNil(task)
        XCTAssertFalse(CoachRequestCapture.didStartLoading, "missing token must issue zero requests")
        guard case .failure(.missingToken) = received else {
            return XCTFail("expected .missingToken, got \(String(describing: received))")
        }
    }

    // MARK: - RED: source contract for the shipping wiring

    /// The client must attach a bearer token and model a missing-token
    /// state; the keyboard controller must source that token from the
    /// shared Keychain access group.
    func testCoachClientAttachesBearerAndModelsMissingToken() throws {
        let client = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        XCTAssertTrue(
            client.contains("Authorization"),
            "Coach requests must attach an Authorization: Bearer header"
        )
        XCTAssertTrue(
            client.contains("Bearer \\(token)"),
            "the client must attach Bearer <token> for the resolved token"
        )
        XCTAssertTrue(
            client.contains("missingToken"),
            "an absent token must map to a deterministic missing-token state"
        )
    }

    func testKeyboardSourcesBearerFromSharedKeychainAccessGroup() throws {
        let controller = try Self.source("KeyboardExtension/KeyboardViewController.swift")
        XCTAssertTrue(
            controller.contains("SharedKeychain.get(KeychainKeys.apiToken)"),
            "the keyboard must obtain the bearer token from the shared Keychain access group"
        )
    }

    // MARK: - Helpers

    private static func trapSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachRequestTrap.self]
        return URLSession(configuration: configuration)
    }

    static func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // <srcroot>/Tests
            .deletingLastPathComponent()   // <srcroot>
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}

// The production keyboard controller is compiled into TonoTests and, from
// build 96, reads the Coach bearer token from the shared Keychain access
// group. The real `SharedKeychain` / `KeychainKeys` live in Shared/ and are
// intentionally kept out of the unit-test binary — the same policy the
// geometry suite applies to `SharedStore` / `SharedKeys` — so the test module
// supplies a minimal stub. Tests may set `stubbedTokens` to exercise the
// token-present path through the controller; the default (empty) drives the
// deterministic missing-token recovery.
enum KeychainKeys {
    static let apiToken = "apiToken"
}

enum SharedKeychain {
    static var stubbedTokens: [String: String] = [:]
    static func get(_ key: String) -> String? { stubbedTokens[key] }
}

/// Fails the test if any request reaches the network layer. Records the
/// fact a request started and immediately fails it so the client's
/// completion still fires.
final class CoachRequestTrap: URLProtocol {
    static private(set) var didStartLoading = false

    static func reset() { didStartLoading = false }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CoachRequestTrap.didStartLoading = true
        client?.urlProtocol(self, didFailWithError: NSError(domain: "CoachRequestTrap", code: -1))
    }

    override func stopLoading() {}
}

/// Captures the outgoing request's Authorization header (and whether any
/// request started), then fails the request so the completion still fires.
final class CoachRequestCapture: URLProtocol {
    static private(set) var didStartLoading = false
    static private(set) var lastAuthorization: String?

    static func reset() {
        didStartLoading = false
        lastAuthorization = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        CoachRequestCapture.didStartLoading = true
        CoachRequestCapture.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        client?.urlProtocol(self, didFailWithError: NSError(domain: "CoachRequestCapture", code: -1))
    }

    override func stopLoading() {}
}
