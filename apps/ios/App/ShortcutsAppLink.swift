// ShortcutsAppLink.swift
// The one bounded jump to Apple's Shortcuts app.
//
// Tono's Shortcuts actions — Rewrite Draft (CoachDraftIntent), Open Tono
// Keyboard Setup, and Set Tono Tone Variant — are built into the app through
// `TonoShortcutsProvider`/`AppIntent`. They become discoverable inside Apple's
// Shortcuts app on their own after Tono is installed and opened once: there is
// no import file and nothing is auto-installed. This helper does exactly ONE
// thing — it brings the Shortcuts app to the front so a person can find those
// actions. It passes no workflow, no draft, and no account data; the scheme is
// bare, so it cannot import or run anything.
//
// Why this lives in its own file rather than in the onboarding screen:
//
//   * The host app's consumer-copy contract (Build 112) forbids a scheme
//     literal in any screen's strings, so the scheme cannot sit in
//     `OnboardingEntryPointsView`.
//   * The App Intent contract (`verify_imessage_appintent_contract.py`) forbids
//     ANY URL side effect inside `CoachDraftIntent`, so it cannot sit there
//     either.
//
// This file is neither a SwiftUI surface nor the intent — it is a plain
// launcher the onboarding screen calls, with a seam so the fail-honest path is
// testable without opening anything.

import UIKit

/// The bounded launcher for Apple's Shortcuts app.
enum ShortcutsAppLink {

    /// Apple's public URL scheme for the Shortcuts app.
    static let scheme = "shortcuts"

    /// The destination: the Shortcuts app itself, addressed by a bare scheme
    /// with no `import-workflow` and no query — so it only brings the app
    /// forward and can neither import nor run a workflow. Optional rather than
    /// force-unwrapped so a malformed value fails honestly instead of trapping.
    static var appURL: URL? { URL(string: "\(scheme)://") }

    /// Open the Shortcuts app.
    ///
    /// Fails honestly: the completion receives `false` when the destination
    /// can't be built or the system reports it can't open the app (for
    /// instance, if Shortcuts was removed from the device). It never traps and
    /// has no side effect other than the requested app switch.
    static func open(
        using application: URLOpening = UIApplication.shared,
        completion: @escaping (Bool) -> Void
    ) {
        guard let url = appURL else {
            completion(false)
            return
        }
        application.open(url, options: [:]) { success in
            completion(success)
        }
    }
}

/// The one capability `ShortcutsAppLink` needs from `UIApplication`, expressed
/// as a protocol so a test can drive the success and fail-honest paths without
/// actually switching apps.
protocol URLOpening {
    func open(
        _ url: URL,
        options: [UIApplication.OpenExternalURLOptionsKey: Any],
        completionHandler completion: ((Bool) -> Void)?
    )
}

extension UIApplication: URLOpening {}
