// SharedKeychain.swift
// Secure bearer-token storage via the iOS Keychain, shared between the
// host app and the keyboard extension through a Keychain access group.
//
// SETUP — one-time, per developer:
//   1. Find your 10-character Apple Developer Team ID in Xcode → Signing
//      & Capabilities → Team, or at developer.apple.com/account.
//   2. Replace "XXXXXXXXXX" in `teamID` below with that value.
//   3. Both targets' `.entitlements` files declare App Group
//      `group.com.tonoit.shared`; `accessGroup` below MUST match
//      `<TeamID>.group.com.tonoit.shared`.

import Foundation
import Security

// ─── Configure this once ───────────────────────────────────────────────
private let teamID = "4938S9TTBM" // Apple Team ID (DO NOT DELETE — required by keychain access group)
// ───────────────────────────────────────────────────────────────────────

public enum SharedKeychain {
    // When teamID is still placeholder, skip the access group so the
    // main app can use its own Keychain (keyboard extension won't share
    // until the real Team ID is configured).
    private static let hasTeam: Bool = teamID != "XXXXXXXXXX"
    // Must match `com.apple.security.application-groups` in
    // App/Tono.entitlements and KeyboardExtension/TonoKeyboard.entitlements.
    private static let accessGroup = "\(teamID).group.com.tonoit.shared"
    private static let service     = "com.tonoit.app"

    public static func set(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let status = SecItemUpdate(query(key) as CFDictionary,
                                   [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData] = data
            // Readable after first device unlock; survives reboots so the
            // keyboard extension can run in the background.
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData]  = true
        q[kSecMatchLimit]  = kSecMatchLimitOne
        var ref: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    // Migrate a value from the (legacy) App Group UserDefaults into the
    // Keychain, then wipe the defaults entry. Safe to call repeatedly.
    public static func migrateFromDefaults(key: String, defaultsKey: String) {
        guard get(key) == nil,
              let legacy = SharedStore.defaults.string(forKey: defaultsKey),
              !legacy.isEmpty else { return }
        set(legacy, forKey: key)
        SharedStore.defaults.removeObject(forKey: defaultsKey)
    }

    private static func query(_ key: String) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     service,
            kSecAttrAccount:     key,
        ]
        if hasTeam {
            q[kSecAttrAccessGroup] = accessGroup
        }
        return q
    }
}

public enum KeychainKeys {
    public static let apiToken = "apiToken"
    public static let deviceID = "deviceID"
    /// Canonical server-issued account UUID — the only entitlement principal
    /// (build 91). New StoreKit purchases bind this as `appAccountToken`, never
    /// the device id. Stored as its own secure Keychain item in the shared
    /// access group; it is NOT an alias of `deviceID`.
    public static let accountID = "accountID"
    /// High-entropy proof for re-registering an existing public device id.
    public static let deviceCredential = "deviceCredential"
    /// Direct LLM API key (legacy; only used when bypassing the backend proxy).
    /// Migrated out of UserDefaults on first launch.
    public static let apiKey   = "apiKey"
    /// Email the user signed in with (added 2026-07-03). Used to:
    ///   - re-claim the same account on a fresh install
    ///   - power the "use this email to recover" prompt in onboarding
    public static let signedInEmail = "signedInEmail"
}
