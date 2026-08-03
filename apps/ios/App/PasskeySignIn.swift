// PasskeySignIn.swift
// Native passkey (WebAuthn) registration + sign-in — APP TARGET ONLY.
//
// This is the client half of the backend's WebAuthn ceremonies
// (apps/backend/passkeys.py). The platform authenticator (Face ID / Touch ID)
// signs a challenge the server minted; we hand back exactly what it signed and
// the backend verifies it. We never see or store biometric data — only a public
// key and a signature, the same trust model as SSH keys.
//
// THREE properties keep this honest, all of which the task and the repo's
// established discipline require:
//
//  1. The BACKEND is the sole authority. `PasskeySignIn.signIn()` returns
//     `.signedIn` ONLY after `/v1/auth/passkey/login/verify` returned 200 and
//     `TonoBackend` converged this device onto the canonical account. A ceremony
//     that the OS completes but the server rejects is a failure, not a sign-in.
//
//  2. No faked success when the provider/AASA is absent. Passkeys need the app's
//     Associated Domains capability (`webcredentials:tonoit.com`, in
//     Tono.entitlements) AND a live Apple App Site Association file hosted at
//     https://tonoit.com/.well-known/apple-app-site-association. Neither is
//     detectable at runtime, so a missing AASA surfaces as a real
//     AuthenticationServices error, mapped to `.failed`/`.unavailable` — never a
//     success. The authoritative rpId is exactly `tonoit.com`.
//
//  3. Fail-closed by default. The button that drives this is gated behind
//     `PasskeyConfig.isEnabled` (Info.plist `TONO_PASSKEYS_ENABLED`), OFF until
//     an operator has provisioned the capability + AASA — so the app never
//     renders a passkey tap target whose only possible result is failure. The
//     ceremony code below always compiles; only the UI entry point is gated.
//
// Operator activation (see also App/README + the auth handoff):
//   • Enable the "Sign in with Apple" *and* "Associated Domains" capabilities on
//     App ID 4938S9TTBM.com.tonoit.app in the Apple Developer portal, then
//     regenerate/download the provisioning profile so a signed build carries
//     `com.apple.developer.associated-domains`.
//   • Host the AASA with a `webcredentials` section listing
//     `4938S9TTBM.com.tonoit.app` at https://tonoit.com/.well-known/apple-app-site-association
//     (served as application/json, no redirect).
//   • Set backend `WEBAUTHN_RP_ID=tonoit.com`, `WEBAUTHN_ORIGIN=https://tonoit.com`
//     (the origin Apple reports for a native ceremony is `https://<rpId>`).
//   • Set the build setting `TONO_PASSKEYS_ENABLED=YES` to reveal the button.

import Foundation
import AuthenticationServices
import UIKit

// MARK: - Configuration (fail-closed kill switch)

enum PasskeyConfig {
    /// The authoritative relying-party identifier. MUST equal the backend's
    /// `WEBAUTHN_RP_ID` and the app's `webcredentials:` associated domain.
    /// Hard-coded to the canonical production value; a non-empty Info.plist
    /// override is honored only for staging.
    static let canonicalRelyingPartyID = "tonoit.com"

    static var relyingPartyID: String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TONO_WEBAUTHN_RP_ID") as? String
        else { return canonicalRelyingPartyID }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, !value.hasPrefix("$(") else { return canonicalRelyingPartyID }
        return value
    }

    /// True only when an operator has flipped the switch after provisioning the
    /// Associated Domains capability + AASA. Empty / placeholder / a negative
    /// value all read as OFF, so the default posture is fail-closed: no button.
    static var isEnabled: Bool {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TONO_PASSKEYS_ENABLED") as? String
        else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["1", "yes", "true", "on", "enabled"].contains(value)
    }
}

// MARK: - Orchestration

/// Drives the two ceremonies end to end and reports a coarse, honest outcome.
/// Never throws to callers — every failure folds to an outcome shape, mirroring
/// how the email lane refuses to let provider text reach a screen.
enum PasskeySignIn {

    enum Outcome: Equatable {
        /// A backend-verified sign-in with an existing passkey.
        case signedIn
        /// A backend-verified registration of a new passkey.
        case registered
        /// The person dismissed the system sheet. Not an error.
        case cancelled
        /// Passkeys are switched off in this build (fail-closed default), or the
        /// device/OS could not start the ceremony at all.
        case unavailable
        /// The ceremony or the backend verification failed — including a missing
        /// AASA / capability. Explicitly NOT a success.
        case failed
    }

    /// Sign in with an existing passkey. `.signedIn` is reachable only after the
    /// backend verified the assertion and bound this device to the account.
    @MainActor
    static func signIn() async -> Outcome {
        guard PasskeyConfig.isEnabled else { return .unavailable }
        do {
            let options = try await TonoBackend.shared.passkeyLoginOptions()
            guard let challenge = Base64URL.decode(options["challenge"] as? String) else {
                return .failed
            }
            let rpID = (options["rpId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? PasskeyConfig.relyingPartyID
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: rpID
            )
            let request = provider.createCredentialAssertionRequest(challenge: challenge)
            let credential = try await PasskeyCeremony().run([request])
            guard let assertion = credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { return .failed }

            let payload: [String: Any] = [
                "id": Base64URL.encode(assertion.credentialID),
                "rawId": Base64URL.encode(assertion.credentialID),
                "type": "public-key",
                "authenticatorAttachment": "platform",
                "response": [
                    "clientDataJSON": Base64URL.encode(assertion.rawClientDataJSON),
                    "authenticatorData": Base64URL.encode(assertion.rawAuthenticatorData),
                    "signature": Base64URL.encode(assertion.signature),
                    "userHandle": Base64URL.encode(assertion.userID),
                ],
            ]
            // Only the server can call this a sign-in. It just did.
            _ = try await TonoBackend.shared.passkeyLoginVerify(credential: payload)
            return .signedIn
        } catch {
            return Self.classify(error)
        }
    }

    /// Register a new passkey on the current account, creating the account on the
    /// backend if this device does not have one yet. `.registered` is reachable
    /// only after the backend verified the attestation.
    @MainActor
    static func register() async -> Outcome {
        guard PasskeyConfig.isEnabled else { return .unavailable }
        do {
            let options = try await TonoBackend.shared.passkeyRegisterOptions()
            guard let challenge = Base64URL.decode(options["challenge"] as? String),
                  let user = options["user"] as? [String: Any],
                  let userID = Base64URL.decode(user["id"] as? String) else { return .failed }
            let userName = (user["name"] as? String) ?? "Tono account"
            let rpID = (options["rp"] as? [String: Any])?["id"] as? String
                ?? PasskeyConfig.relyingPartyID
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
                relyingPartyIdentifier: rpID
            )
            let request = provider.createCredentialRegistrationRequest(
                challenge: challenge, name: userName, userID: userID
            )
            let credential = try await PasskeyCeremony().run([request])
            guard let registration = credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
                  let attestation = registration.rawAttestationObject else { return .failed }

            let payload: [String: Any] = [
                "id": Base64URL.encode(registration.credentialID),
                "rawId": Base64URL.encode(registration.credentialID),
                "type": "public-key",
                "authenticatorAttachment": "platform",
                "response": [
                    "clientDataJSON": Base64URL.encode(registration.rawClientDataJSON),
                    "attestationObject": Base64URL.encode(attestation),
                ],
            ]
            _ = try await TonoBackend.shared.passkeyRegisterVerify(credential: payload)
            return .registered
        } catch {
            return Self.classify(error)
        }
    }

    /// Map a caught failure to an outcome by SHAPE. A user dismissal is not an
    /// error; everything else is a real failure and is never dressed as success.
    private static func classify(_ error: Error) -> Outcome {
        if let asError = error as? ASAuthorizationError {
            switch asError.code {
            case .canceled:
                return .cancelled
            case .notInteractive, .unknown:
                return .unavailable
            default:
                return .failed
            }
        }
        return .failed
    }
}

// MARK: - AuthenticationServices bridge

/// Bridges a one-shot `ASAuthorizationController` run to async/await. Retains
/// itself and the controller for the lifetime of the ceremony — the controller
/// holds its delegate weakly, so without the self-retain the whole thing would
/// deallocate the moment the calling `await` suspends.
@MainActor
private final class PasskeyCeremony: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?
    private var controller: ASAuthorizationController?
    private var strongSelf: PasskeyCeremony?

    func run(_ requests: [ASAuthorizationRequest]) async throws -> ASAuthorizationCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.strongSelf = self
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorizationCredential, Error>) {
        let continuation = self.continuation
        self.continuation = nil
        self.controller = nil
        self.strongSelf = nil
        switch result {
        case .success(let credential): continuation?.resume(returning: credential)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization.credential))
    }

    func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        return window ?? ASPresentationAnchor()
    }
}

// MARK: - base64url

/// WebAuthn uses base64url without padding for every binary field; Foundation
/// only speaks standard base64, so translate at the boundary.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String?) -> Data? {
        guard let string, !string.isEmpty else { return nil }
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}
