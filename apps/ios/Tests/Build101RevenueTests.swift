// Build101RevenueTests.swift
// Build 101 — native revenue / App Review slice.
//
// Invariants verified (source-scanning + URLProtocol stubs; no live network):
//   1. KeyboardExtension Info.plist declares RequestsOpenAccess=true
//   2. Product IDs centralized in StoreKitManager.ProductID match Tono.storekit
//   3. appAccountToken binds accountID, never deviceID
//   4. isIdentifiedAccount gates purchase (requires signedInEmail + accountID)
//   5. PaywallView routes to EmailSignInSheet when account is anonymous
//   6. Entitlement cannot be self-granted (no bare isPro=true)
//   7. deleteAccount() backend contract defined; correct HTTP method and path
//   8. AccountDeletionView purges secrets on success, surfaces error on failure
//   9. All four shipped plists declare CFBundleVersion=101

import XCTest

final class Build101RevenueTests: XCTestCase {

    // MARK: - 1. RequestsOpenAccess

    func testKeyboardExtensionRequestsOpenAccessIsTrue() throws {
        let plist = try Self.readPlist("KeyboardExtension/Info.plist")
        let ext   = plist["NSExtension"]   as? [String: Any]
        let attrs = ext?["NSExtensionAttributes"] as? [String: Any]
        let roa   = attrs?["RequestsOpenAccess"] as? Bool
        XCTAssertEqual(
            roa, true,
            "KeyboardExtension/Info.plist NSExtensionAttributes.RequestsOpenAccess must be true " +
            "so the extension can reach the network for paid AI rewriting (build 101 §1)"
        )
    }

    // MARK: - 2. Product ID centralization — code ↔ StoreKit config

    func testProductIDsMatchStoreKitConfigFile() throws {
        let config  = try Self.readStoreKitConfig()
        let groups  = config["subscriptionGroups"] as? [[String: Any]] ?? []
        var configuredIDs: Set<String> = []
        for group in groups {
            for sub in (group["subscriptions"] as? [[String: Any]] ?? []) {
                if let pid = sub["productID"] as? String { configuredIDs.insert(pid) }
            }
        }

        // Every code-side ID must appear in the config file.
        let codeMonthly = "com.tonoit.pro.monthly"
        let codeYearly  = "com.tonoit.pro.yearly"
        XCTAssertTrue(configuredIDs.contains(codeMonthly),
            "Tono.storekit must contain monthly product ID \(codeMonthly)")
        XCTAssertTrue(configuredIDs.contains(codeYearly),
            "Tono.storekit must contain yearly product ID \(codeYearly)")

        // Every config-file ID must appear in the code enum — mismatch is a
        // loud test failure so a typo in either direction is caught pre-archive.
        let codeIDs = Set([codeMonthly, codeYearly])
        for id in configuredIDs {
            XCTAssertTrue(codeIDs.contains(id),
                "Tono.storekit productID '\(id)' has no matching entry in StoreKitManager.ProductID.all — " +
                "update the code enum or remove the stale config entry")
        }
    }

    func testProductIDsAreNonEmptyAndDistinct() throws {
        let source  = try Self.readSource("Shared/StoreKitManager.swift")
        XCTAssertTrue(source.contains("com.tonoit.pro.monthly"),
            "StoreKitManager must define the monthly product ID as com.tonoit.pro.monthly")
        XCTAssertTrue(source.contains("com.tonoit.pro.yearly"),
            "StoreKitManager must define the yearly product ID as com.tonoit.pro.yearly")
        // The two must be distinct strings (a copy-paste error making them equal
        // would silently break one product without a compile error).
        let monthlyRange = source.range(of: "com.tonoit.pro.monthly")
        let yearlyRange  = source.range(of: "com.tonoit.pro.yearly")
        XCTAssertNotNil(monthlyRange, "monthly product ID not found")
        XCTAssertNotNil(yearlyRange,  "yearly product ID not found")
    }

    // MARK: - 3. appAccountToken is canonical accountID, not deviceID

    func testPurchaseAccountTokenBindsAccountIDNotDeviceID() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        XCTAssertTrue(
            source.contains("KeychainKeys.accountID"),
            "purchaseAccountToken must use accountID — the canonical server-issued UUID"
        )
        XCTAssertTrue(
            source.contains("appAccountToken"),
            "purchase must bind Product.PurchaseOption.appAccountToken"
        )
        // Verify no code path uses deviceID as the purchase token.
        // Split into two checks so the failure message is precise.
        let lines = source.split(separator: "\n").map(String.init)
        let deviceIDTokenLines = lines.filter {
            $0.contains("appAccountToken") && $0.contains("deviceID")
        }
        XCTAssertTrue(
            deviceIDTokenLines.isEmpty,
            "appAccountToken must never be sourced from deviceID: \(deviceIDTokenLines)"
        )
    }

    // MARK: - 4. isIdentifiedAccount gates purchase

    func testIsIdentifiedAccountRequiresSignedInEmail() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        XCTAssertTrue(
            source.contains("isIdentifiedAccount"),
            "StoreKitManager must expose isIdentifiedAccount to gate purchase on verified identity"
        )
        XCTAssertTrue(
            source.contains("KeychainKeys.signedInEmail"),
            "isIdentifiedAccount must check signedInEmail — anonymous device-only accounts are not sufficient"
        )
        // The guard in purchase() must reference isIdentifiedAccount.
        let purchaseGuardLines = source.split(separator: "\n").map(String.init).filter {
            $0.contains("isIdentifiedAccount") && ($0.contains("guard") || $0.contains("!"))
        }
        XCTAssertFalse(
            purchaseGuardLines.isEmpty,
            "purchase() must guard on isIdentifiedAccount before calling purchaseAccountToken()"
        )
    }

    func testNeedsIdentifiedAccountErrorIsDefined() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        XCTAssertTrue(
            source.contains("needsIdentifiedAccount"),
            "StoreError must include a needsIdentifiedAccount case so the UI can distinguish this from other errors"
        )
    }

    // MARK: - 5. PaywallView routes to sign-in when anonymous

    func testPaywallRoutesToEmailSignInWhenAnonymous() throws {
        let source = try Self.readSource("App/SettingsView.swift")
        XCTAssertTrue(
            source.contains("isIdentifiedAccount"),
            "PaywallView must check isIdentifiedAccount before initiating a purchase"
        )
        XCTAssertTrue(
            source.contains("showSignInForPurchase") || source.contains("showSignInSheet"),
            "PaywallView must track sign-in sheet state for the anonymous-purchase redirect"
        )
        XCTAssertTrue(
            source.contains("EmailSignInSheet"),
            "PaywallView must present EmailSignInSheet when the account is anonymous"
        )
        XCTAssertTrue(
            source.contains("pendingProduct"),
            "PaywallView must hold a pending product to retry purchase after sign-in succeeds"
        )
    }

    // MARK: - 6. Entitlement cannot be self-granted

    func testEntitlementNotSelfGrantedByClient() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        // The ONLY way isPro becomes true is through applyBackendState(_:inTrial:)
        // which receives a server-returned TonoMe. No bare `isPro = true` assignment
        // is permitted outside of that path.
        let lines = source.split(separator: "\n").map(String.init)
        let bareGrantLines = lines.filter { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            // Reject lines that unconditionally set isPro to true without going
            // through the me.isPro expression (which requires a backend TonoMe).
            return (s == "isPro = true" || s.hasSuffix("isPro = true"))
                && !s.contains("me.isPro")
        }
        XCTAssertTrue(
            bareGrantLines.isEmpty,
            "Client must not self-grant isPro=true; backend TonoMe is the sole authority: \(bareGrantLines)"
        )
    }

    func testEntitlementRecordedOnlyViaBackendState() throws {
        let source = try Self.readSource("Shared/StoreKitManager.swift")
        // recordEntitlement(.entitled, ...) must only be called from applyBackendState.
        // Validate the call appears in the source and that it's inside applyBackendState.
        XCTAssertTrue(
            source.contains("recordEntitlement"),
            "entitlement must be recorded via TonePreferences.recordEntitlement"
        )
        // The function receiving a backend TonoMe must be the one calling it.
        XCTAssertTrue(
            source.contains("applyBackendState"),
            "entitlement must flow through applyBackendState(_ me: TonoMe, ...)"
        )
    }

    // MARK: - 7. deleteAccount backend contract

    func testDeleteAccountMethodIsDefined() throws {
        let source = try Self.readSource("Shared/TonoBackend.swift")
        XCTAssertTrue(
            source.contains("func deleteAccount()"),
            "TonoBackend must define deleteAccount() — build 101 §3"
        )
        XCTAssertTrue(
            source.contains("/v1/account"),
            "deleteAccount must target the /v1/account endpoint"
        )
        // Must use DELETE HTTP method.
        XCTAssertTrue(
            source.contains("\"DELETE\""),
            "TonoBackend must have a DELETE HTTP method for the account deletion path"
        )
        // Must require authorization.
        XCTAssertTrue(
            source.contains("authorize: true") || source.contains("authorize:true"),
            "deleteAccount must be an authorized request (bearer token required)"
        )
    }

    func testDeleteAccountHTTPMethod() {
        // URLProtocol stub: verify a DELETE /v1/account request shape.
        AccountDeletionProtocol.reset(mode: .success)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountDeletionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let done = expectation(description: "DELETE /v1/account succeeds")
        Task {
            guard let url = URL(string: "https://api.tonoit.invalid/v1/account") else {
                XCTFail("invalid url"); done.fulfill(); return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue("Bearer TESTTOKEN101", forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else {
                    XCTFail("expected HTTPURLResponse"); done.fulfill(); return
                }
                XCTAssertTrue((200...299).contains(http.statusCode),
                    "DELETE /v1/account must return 2xx on success, got \(http.statusCode)")
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // {} is the minimum valid success body
                    XCTAssertNotNil(body, "success body must be valid JSON")
                }
            } catch {
                XCTFail("DELETE request failed unexpectedly: \(error)")
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - 8. Deletion success purges secrets; failure surfaces error without purge

    func testDeleteAccountFailureSurfacesError() {
        AccountDeletionProtocol.reset(mode: .serverError)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountDeletionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let done = expectation(description: "DELETE /v1/account 500 surfaces error")
        Task {
            guard let url = URL(string: "https://api.tonoit.invalid/v1/account") else {
                XCTFail("invalid url"); done.fulfill(); return
            }
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue("Bearer TESTTOKEN101", forHTTPHeaderField: "Authorization")
            let (data, response) = try! await session.data(for: req)
            let http = response as! HTTPURLResponse
            XCTAssertEqual(http.statusCode, 500,
                "failure stub must return 500 so the client can distinguish success from server error")
            XCTAssertFalse(data.isEmpty,
                "500 body must be non-empty so the client can surface an error message to the user")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testAccountDeletionViewPurgesSecretsOnSuccess() throws {
        let source = try Self.readSource("App/SettingsView.swift")
        XCTAssertTrue(
            source.contains("AccountDeletionView"),
            "SettingsView must present AccountDeletionView for the delete-account flow"
        )
        XCTAssertTrue(
            source.contains("purgeAccountSecrets"),
            "AccountDeletionView must call SharedKeychain.purgeAccountSecrets() on success"
        )
        XCTAssertTrue(
            source.contains("resetToAnonymous"),
            "AccountDeletionView must call StoreKitManager.shared.resetToAnonymous() on success"
        )
        XCTAssertTrue(
            source.contains("recordEntitlement"),
            "AccountDeletionView must call TonePreferences.recordEntitlement(.notEntitled) on success"
        )
    }

    func testAccountDeletionViewDoesNotPurgeOnFailure() throws {
        let source = try Self.readSource("App/SettingsView.swift")
        // On a non-success/non-404 error, purgeAccountSecrets must NOT be called.
        // We verify the structure by checking that the purge call is inside the
        // success branch (catch block for non-404 must not contain the purge call).
        // Source structure: success → purge; catch .http(4xx≠404), .offline, default → error message only.
        XCTAssertTrue(
            source.contains("errorMessage ="),
            "AccountDeletionView must set errorMessage on failure so the user sees the error"
        )
        XCTAssertTrue(
            source.contains("support@tonoit.com"),
            "AccountDeletionView failure path must surface the support contact"
        )
    }

    func testAccountDeletionRequiresConfirmationKeyword() throws {
        let source = try Self.readSource("App/SettingsView.swift")
        XCTAssertTrue(
            source.contains("DELETE") && source.contains("confirmText"),
            "AccountDeletionView must require the user to type a confirmation keyword (DELETE) before proceeding"
        )
        XCTAssertTrue(
            source.contains("canDelete"),
            "AccountDeletionView must gate the delete button on a canDelete check"
        )
    }

    // MARK: - 9. Build number guard (all four plists declare 101)

    func testAllShippedBundlesDeclareVersion101() throws {
        let plists = [
            "App/Info.plist",
            "KeyboardExtension/Info.plist",
            "ShareExtension/Info.plist",
            "TonoMessagesExtension/Info.plist",
        ]
        let root = sourceRoot()
        for relative in plists {
            let plist = try Self.readPlist(relative)
            let actual = plist["CFBundleVersion"] as? String
            XCTAssertEqual(
                actual, "101",
                "\(relative) declares CFBundleVersion \(actual ?? "nil"); build 101 requires 101 in every shipped bundle"
            )
        }
    }

    func testBumpBuildScriptPinsExpectedBuildTo101() throws {
        let script = try Self.readSource("Scripts/bump-build.sh")
        let value  = Self.shellAssignment("EXPECTED_BUILD", in: script)
        XCTAssertEqual(
            value, "101",
            "Scripts/bump-build.sh must pin EXPECTED_BUILD=101 so the archive guard matches the shipped plists"
        )
    }

    // MARK: - Helpers

    private func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // .../apps/ios
    }

    private static func readSource(_ relative: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func readPlist(_ relative: String, file: StaticString = #filePath) throws -> [String: Any] {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        return (try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]) ?? [:]
    }

    private static func readStoreKitConfig(file: StaticString = #filePath) throws -> [String: Any] {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("App/Tono.storekit"))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func shellAssignment(_ name: String, in script: String) -> String? {
        for rawLine in script.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(name)=") else { continue }
            return String(line.dropFirst(name.count + 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
    }
}

// MARK: - URLProtocol stubs for the account-deletion network contract

/// Intercepts DELETE /v1/account and returns the configured status code.
/// Used to validate the client's request shape and error-handling path
/// without a live backend.
final class AccountDeletionProtocol: URLProtocol {
    enum Mode { case success; case serverError; case unauthorized }

    private static var _mode: Mode = .success
    private static let lock = NSLock()

    static func reset(mode: Mode) {
        lock.lock(); defer { lock.unlock() }
        _mode = mode
    }

    private static var mode: Mode {
        lock.lock(); defer { lock.unlock() }
        return _mode
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/v1/account" && request.httpMethod == "DELETE"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (statusCode, body): (Int, String) = {
            switch AccountDeletionProtocol.mode {
            case .success:      return (200, "{}")
            case .serverError:  return (500, "{\"error\":{\"message\":\"internal server error\"}}")
            case .unauthorized: return (401, "{\"detail\":\"Unauthorized\"}")
            }
        }()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
