// GoogleSignInConfig.swift
// The fail-closed gate for Google sign-in — APP TARGET ONLY.
//
// GoogleSignIn-iOS is now linked into the app target via SPM, so
// `canImport(GoogleSignIn)` is true and the "Continue with Google" button
// compiles in. Linking the SDK is NOT the same as being able to sign in: that
// needs Tono's OWN Google OAuth *client ID* (a public value, but Tono's own,
// supplied only at provider-activation time) present in the build, plus its
// reversed-client-ID URL scheme so the OAuth redirect can return to the app.
//
// This type is the single source of truth for "is Google actually usable in
// this build". It reads the client ID from Info.plist (`GIDClientID`, driven by
// the `$(GID_CLIENT_ID)` build variable) and treats empty / placeholder as NOT
// configured — the same kill-switch posture RevenueCatManager uses. Callers gate
// the button on `isConfigured` WITHOUT importing the SDK, so an unconfigured
// build shows no Google affordance at all rather than one that can only fail.
//
// A sibling product's client ID or secret is NEVER embedded here; the contract
// is a build variable Tono fills in with its own value.
//
// Info.plist / URL-scheme contract (see App/Info.plist):
//   • GIDClientID = $(GID_CLIENT_ID)                     — e.g. 12345-abc.apps.googleusercontent.com
//   • CFBundleURLTypes → a URL scheme of $(GID_URL_SCHEME) — the REVERSED client
//     ID, e.g. com.googleusercontent.apps.12345-abc. GoogleSignIn returns to the
//     app on this scheme; RootView routes it back via GoogleSignInConfig.handle.
// Both default empty (fail closed). Set the two build settings to activate.

import Foundation
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

enum GoogleSignInConfig {
    /// The Tono Google OAuth client ID from Info.plist, or nil when unset /
    /// placeholder. A client ID is not a secret, but it is Tono's own and is
    /// present only once an operator has configured this build.
    static var clientID: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty, an unexpanded build variable, or an obvious placeholder all read
        // as "not configured" (fail closed).
        guard !value.isEmpty, !value.hasPrefix("$("), value.uppercased() != "REPLACE_ME"
        else { return nil }
        return value
    }

    /// True only when a real Tono Google client is configured in this build.
    /// This is what the button visibility is gated on.
    static var isConfigured: Bool { clientID != nil }

    /// Configure the SDK once, if it is linked AND a real client is present.
    /// A no-op otherwise, so an unconfigured build never touches the SDK.
    static func configureIfPossible() {
        #if canImport(GoogleSignIn)
        guard let clientID else { return }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        #endif
    }

    /// Complete the Google OAuth redirect. A no-op unless the SDK is linked and
    /// configured, so an unrelated deep link is never claimed by mistake.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        guard isConfigured else { return false }
        return GIDSignIn.sharedInstance.handle(url)
        #else
        _ = url
        return false
        #endif
    }
}
