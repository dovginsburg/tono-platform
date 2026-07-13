// CrashReporter.swift
// A1: Crash + OOM breadcrumb helper. Works as a no-op stub today;
// activates when Firebase is added and FIREBASE_ENABLED is set.
//
// ─── XCODE SETUP (one-time, when adding Firebase) ────────────────────────
// 1. File → Add Package Dependencies
//    URL: https://github.com/firebase/firebase-ios-sdk
//    Products to add to BOTH targets: FirebaseCrashlytics
//
// 2. Add the Crashlytics run script as the LAST Build Phase in each target:
//      "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"
//    Input files (add both):
//      $(SRCROOT)/<App>.app/$(EXECUTABLE_PATH)
//      $(DWARF_DSYM_FOLDER_PATH)/$(DWARF_DSYM_FILE_NAME)/Contents/Resources/DWARF/$(PRODUCT_NAME)
//
// 3. Build Settings → Debug Information Format: "DWARF with dSYM File"
//    (both targets, both Debug and Release configurations)
//
// 4. Download Google-Services.plist from the Firebase console and add it
//    to each target folder (App/ and KeyboardExtension/).
//
// 5. Add -DFIREBASE_ENABLED to Other Swift Flags in both targets.
//
// ─── EXTENSION MEMORY BUDGET ─────────────────────────────────────────────
// After adding Crashlytics, check the binary-size delta in the extension.
// If it exceeds ~300 KB, keep the full SDK in the host app only and omit
// the -DFIREBASE_ENABLED flag from the extension's build settings.
// MetricKitReporter (MetricKitReporter.swift) captures extension OOM counts
// regardless and is the primary field-signal for extension memory health.
// ─────────────────────────────────────────────────────────────────────────

import Foundation
#if FIREBASE_ENABLED
import FirebaseCore
import FirebaseCrashlytics
#endif

public enum CrashReporter {

    /// Call once from each target's entry point (TonoApp.init, KeyboardViewController.viewDidLoad).
    public static func configure() {
        #if FIREBASE_ENABLED && !targetEnvironment(simulator)
        FirebaseApp.configure()
        if let deviceID = SharedKeychain.get(KeychainKeys.deviceID), !deviceID.isEmpty {
            Crashlytics.crashlytics().setUserID(deviceID)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Crashlytics.crashlytics().setCustomValue(version, forKey: "app_version")
        Crashlytics.crashlytics().setCustomValue(TonePreferences().proUnlocked, forKey: "is_pro")
        #endif
    }

    /// Attach triage context to the next crash report.
    /// Call whenever keyboard mode or network state changes.
    /// Values are enum strings or booleans — no message content.
    public static func setCustomKey(_ value: Any, forKey key: String) {
        #if FIREBASE_ENABLED && !targetEnvironment(simulator)
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
        #endif
    }

    /// Record a step in the coach flow for crash-report timeline reconstruction.
    public static func addBreadcrumb(_ message: String) {
        #if FIREBASE_ENABLED && !targetEnvironment(simulator)
        Crashlytics.crashlytics().log(message)
        #endif
    }
}
