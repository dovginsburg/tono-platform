// AppIntentRouting.swift
// Apple Intelligence readiness — the one-shot navigation signal an App Intent
// leaves for the host app.
//
// An App Intent runs in a system process, not the app's UI. When a local-only
// intent (e.g. "Open Tono Keyboard Setup") needs the app to show a particular
// screen, it cannot present a view itself — it writes a pending route to the
// shared App Group and returns; the app reads it on its next foreground and
// presents the screen once.
//
// Pure Foundation. It carries a route ENUM and nothing else — never any message
// text, never a draft, never account data. The route names a screen, not a
// payload.

import Foundation

/// A screen an App Intent can ask the host app to show. Closed set on purpose:
/// an intent may only request a known destination, never an arbitrary deep link.
public enum AppIntentRoute: String, Codable, Sendable, Equatable, CaseIterable {
    /// The keyboard setup screen (add keyboard, Full Access, the sanctioned
    /// `UIApplication.openSettingsURLString` jump). Entirely local.
    case keyboardSetup
}

/// App Group persistence for a single pending route.
///
/// One-shot by contract: `consumePending()` reads AND clears, so a route
/// presents the screen once rather than re-presenting it on every foreground.
public struct AppIntentRouteSignal {
    public static let key = "tc.appIntentPendingRoute.v1"

    /// The shared App Group suite, spelled out rather than taken from
    /// `SharedStore` — a `public` default argument may not reference another
    /// file's `public` computed property across every target this type compiles
    /// into (host app + test target), the same reason `LocalRewritePreferenceStore`
    /// spells its suite out. See that type's note.
    public static let appGroupSuite = "group.com.tonoit.shared"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appGroupSuite)
            ?? .standard
    }

    /// Record a pending route. The intent calls this, then returns.
    public func request(_ route: AppIntentRoute) {
        defaults.set(route.rawValue, forKey: Self.key)
    }

    /// Read the pending route WITHOUT clearing it. For tests and diagnostics.
    public func peekPending() -> AppIntentRoute? {
        guard let raw = defaults.string(forKey: Self.key) else { return nil }
        return AppIntentRoute(rawValue: raw)
    }

    /// Read AND clear the pending route. The app calls this once per foreground;
    /// a nil result means there is nothing to present.
    @discardableResult
    public func consumePending() -> AppIntentRoute? {
        guard let raw = defaults.string(forKey: Self.key) else { return nil }
        defaults.removeObject(forKey: Self.key)
        return AppIntentRoute(rawValue: raw)
    }

    /// Drop any pending route without acting on it.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
