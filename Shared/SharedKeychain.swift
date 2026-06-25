// SharedKeychain.swift
// Secure bearer-token storage via the iOS Keychain, shared between the
// host app and the keyboard extension through a Keychain access group.
//
// SETUP — one-time, per developer:
//   1. Find your 10-character Apple Developer Team ID in Xcode → Signing
//      & Capabilities → Team, or at developer.apple.com/account.
//   2. Replace "XXXXXXXXXX" in `teamID` below with that value.
//   Both targets' entitlements already declare the shared access group;
//   this constant must match.

import Foundation
import Security

// ─── Configure this once ───────────────────────────────────────────────
private let teamID = "XXXXXXXXXX"
// ───────────────────────────────────────────────────────────────────────

public enum SharedKeychain {
    // When teamID is still placeholder, skip the access group so the
    // main app can use its own Keychain (keyboard extension won't share
    // until the real Team ID is configured).
    private static let hasTeam: Bool = teamID != "XXXXXXXXXX"
    private static let accessGroup = "\(teamID).group.com.tonocoach.shared"
    private static let service     = "com.tonocoach.app"

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
    /// Direct LLM API key (legacy; only used when bypassing the backend proxy).
    /// Migrated out of UserDefaults on first launch.
    public static let apiKey   = "apiKey"
}
