// SetupDoctor.swift
// Setup Doctor — the truthful derivation layer behind the host app's guided
// setup surface. Pure `Foundation`: no UIKit, no networking, no timers, so
// every rule below is exercisable by a standalone verifier as well as XCTest.
//
// WHY THIS EXISTS
// ───────────────
// Getting from "installed" to "one successful Tono keyboard test" involves
// three things iOS deliberately hides from a containing app:
//
//   1. Whether the user enabled the Tono keyboard in Settings.
//   2. Whether they granted it Full Access.
//   3. Whether the keyboard actually loads when they switch to it.
//
// There is no public API that answers any of those from inside the app.
// `UITextInputMode.activeInputModes` exposes languages, never an extension
// bundle id, so at best it hints that *some* third-party keyboard exists —
// it can never prove that keyboard is Tono (this is exactly the limitation
// already documented in `OnboardingEntryPointsView.refreshKeyboardStatus`).
//
// So the app does not guess. The one process that CAN observe all three is
// the keyboard extension itself, and the one channel it shares with the app
// is the App Group. `KeyboardHeartbeat` is that channel, kept as small as a
// truthful answer allows.
//
// THE HEARTBEAT PRIVACY CONTRACT (binding)
// ────────────────────────────────────────
// The heartbeat carries exactly three values and nothing else:
//
//   schema      Int     — contract version, so a future reader can reject
//                         a shape it does not understand.
//   observedAt  Date    — when the extension last appeared.
//   fullAccess  Bool    — `UIInputViewController.hasFullAccess` at that moment.
//
// It deliberately does NOT carry, and must never carry: typed text, the
// document context, recipient identity, message contents, the host app's
// bundle id or name, locale, or any per-keystroke counter. It is a liveness
// probe, not telemetry. `KeyboardHeartbeat.encodedKeys` pins the shape and
// `SetupDoctorTests` fails the build if a field is ever added.
//
// FAIL STALE, NEVER FALSE-GREEN
// ─────────────────────────────
// A heartbeat proves the keyboard ran *at `observedAt`* — nothing about now.
// A user who disables the keyboard leaves the last heartbeat behind, so a
// sticky "enabled ✓" read from old data would be a lie. Every derivation
// here therefore degrades to `.confirmedEarlier` or `.cannotConfirm` once the
// heartbeat ages past `SetupDoctorPolicy.liveWindow`, and only a live
// heartbeat produces a completed state.

import Foundation

// MARK: - App Group keys

public enum SetupDoctorKeys {
    /// JSON-encoded `KeyboardHeartbeat`, written by the keyboard extension.
    /// Lives in the same `group.com.tonoit.shared` suite as `SharedKeys`.
    public static let heartbeat = "tc.setupDoctor.heartbeat"
}

// MARK: - Heartbeat

/// The content-free liveness record the keyboard extension leaves in the App
/// Group so the containing app can tell the truth about setup state.
///
/// Adding a field to this type is a privacy decision, not a refactor: see the
/// contract note at the top of this file and the tests that pin `encodedKeys`.
public struct KeyboardHeartbeat: Equatable {

    /// Current contract version. Bump only alongside `encodedKeys`.
    public static let currentSchema = 1

    /// The complete, exhaustive set of keys a heartbeat may serialize.
    /// Pinned by test so no typed content can be smuggled in later.
    public static let encodedKeys: Set<String> = ["schema", "observedAt", "fullAccess"]

    public let schema: Int
    /// When the keyboard extension last became visible.
    public let observedAt: Date
    /// `UIInputViewController.hasFullAccess` as the extension observed it.
    /// This is the only surface in the product that can read it truthfully.
    public let fullAccess: Bool

    public init(schema: Int = KeyboardHeartbeat.currentSchema, observedAt: Date, fullAccess: Bool) {
        self.schema = schema
        self.observedAt = observedAt
        self.fullAccess = fullAccess
    }

    // Hand-rolled rather than `Codable` so the wire shape is stated once, in
    // one readable place, and a contract test can assert on it directly.

    public func encoded() -> [String: Any] {
        [
            "schema": schema,
            "observedAt": observedAt.timeIntervalSince1970,
            "fullAccess": fullAccess,
        ]
    }

    /// Returns `nil` for anything this reader cannot vouch for: a missing or
    /// malformed payload, or a schema from the future. An unreadable heartbeat
    /// must present as "cannot confirm", never as a default-true success.
    public static func decoded(from raw: Any?) -> KeyboardHeartbeat? {
        guard let dict = raw as? [String: Any],
              let schema = dict["schema"] as? Int,
              schema <= currentSchema,
              let seconds = dict["observedAt"] as? TimeInterval,
              seconds > 0,
              let fullAccess = dict["fullAccess"] as? Bool
        else { return nil }
        return KeyboardHeartbeat(
            schema: schema,
            observedAt: Date(timeIntervalSince1970: seconds),
            fullAccess: fullAccess
        )
    }
}

/// Reads and writes the heartbeat over an injected `UserDefaults` so the app,
/// the extension, and the tests can each point at the right suite.
public struct KeyboardHeartbeatStore {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Convenience initializer pointing at the shared App Group store.
    public init() {
        self.defaults = UserDefaults(suiteName: SharedStore.suiteName) ?? .standard
    }

    public func read() -> KeyboardHeartbeat? {
        KeyboardHeartbeat.decoded(from: defaults.object(forKey: SetupDoctorKeys.heartbeat))
    }

    /// Called by the keyboard extension only. `hasFullAccess` must come from
    /// `UIInputViewController.hasFullAccess` — never from a cached guess.
    public func record(hasFullAccess: Bool, now: Date) {
        let beat = KeyboardHeartbeat(observedAt: now, fullAccess: hasFullAccess)
        defaults.set(beat.encoded(), forKey: SetupDoctorKeys.heartbeat)
    }

    /// Clears the record. Used by the Doctor's "check again" recovery so a
    /// re-check measures a genuinely new appearance rather than re-reading a
    /// record the user has already been shown.
    public func clear() {
        defaults.removeObject(forKey: SetupDoctorKeys.heartbeat)
    }
}

// MARK: - Policy

public enum SetupDoctorPolicy {
    /// How recently the extension must have appeared for the app to speak in
    /// the present tense. Five minutes comfortably covers "open Settings, flip
    /// the switch, come back and test" without letting yesterday's record
    /// masquerade as today's truth.
    public static let liveWindow: TimeInterval = 5 * 60

    /// How long an entitlement verdict stays presentable before the Doctor
    /// asks for a refresh. Entitlement is server-authoritative; this only
    /// governs how the Doctor *describes* the last verdict, never whether Pro
    /// is granted (`TonePreferences.isProAuthoritative` remains the sole gate).
    public static let entitlementWindow: TimeInterval = 24 * 60 * 60
}

// MARK: - Step status

/// The four states a setup step can be in. Deliberately not a Bool: "we do not
/// know" is a first-class outcome here, and collapsing it into "not done" would
/// misdescribe a user whose setup is fine but unverifiable this second.
public enum SetupStepStatus: Equatable {
    /// Verified, right now, by something the app genuinely observed.
    case complete
    /// Verified at `at`, but not recently enough to claim in the present tense.
    case confirmedEarlier(at: Date)
    /// The app has real evidence the user must act (e.g. the extension itself
    /// reported Full Access off, or the server said not entitled).
    case actionNeeded
    /// No trustworthy evidence either way. Never rendered as success.
    case cannotConfirm

    /// Only a live observation counts as green. Used by the summary and by the
    /// tests that pin "stale must not read as success".
    public var isComplete: Bool { self == .complete }
}

public enum SetupStepID: String, CaseIterable {
    case keyboardEnabled
    case fullAccess
    case account
    case testDrive
}

public struct SetupStep: Equatable {
    public let id: SetupStepID
    public let status: SetupStepStatus
    /// One consumer-safe sentence explaining how the app knows. Never contains
    /// URLs, endpoints, environment names, tokens, or diagnostic codes.
    public let detail: String

    public init(id: SetupStepID, status: SetupStepStatus, detail: String) {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

// MARK: - Entitlement input

/// The account/entitlement facts the Doctor is allowed to see. Modelled as a
/// value type so tests can drive every combination without a backend, and so
/// no view can reach past it into a URL or a token.
public struct SetupEntitlementSnapshot: Equatable {
    public let isRegistered: Bool
    public let state: EntitlementState?
    public let checkedAt: Date?

    public init(isRegistered: Bool, state: EntitlementState?, checkedAt: Date?) {
        self.isRegistered = isRegistered
        self.state = state
        self.checkedAt = checkedAt
    }
}

// MARK: - Derivation

public struct SetupDoctorState: Equatable {
    public let steps: [SetupStep]

    public func step(_ id: SetupStepID) -> SetupStep {
        // Every id is always produced by `derive`, so this is total.
        steps.first { $0.id == id }!
    }

    /// True only when every step is live-verified. This is what gates the
    /// "you're set" summary, so it must never soften to include stale states.
    public var isFullySetUp: Bool { steps.allSatisfy { $0.status.isComplete } }

    /// Derives the whole surface from observations alone.
    ///
    /// - Parameters:
    ///   - heartbeat: last record left by the extension, if any.
    ///   - entitlement: account facts the app can verify locally.
    ///   - testStartedAt: when the user focused the Doctor's test field. A
    ///     heartbeat newer than this is the proof that the Tono keyboard
    ///     loaded *during the test* rather than at some earlier point.
    ///   - now: injected for determinism.
    public static func derive(
        heartbeat: KeyboardHeartbeat?,
        entitlement: SetupEntitlementSnapshot,
        testStartedAt: Date?,
        now: Date
    ) -> SetupDoctorState {
        let live = isLive(heartbeat, now: now)
        return SetupDoctorState(steps: [
            keyboardStep(heartbeat, live: live),
            fullAccessStep(heartbeat, live: live),
            accountStep(entitlement, now: now),
            testDriveStep(heartbeat, live: live, testStartedAt: testStartedAt),
        ])
    }

    private static func isLive(_ heartbeat: KeyboardHeartbeat?, now: Date) -> Bool {
        guard let heartbeat else { return false }
        let age = now.timeIntervalSince(heartbeat.observedAt)
        // A record stamped in the future is a clock change, not evidence.
        return age >= 0 && age <= SetupDoctorPolicy.liveWindow
    }

    // Step 1 — the keyboard was enabled in Settings.
    //
    // Proof is indirect but genuine: iOS only loads the extension if the user
    // added it, so a heartbeat is the enable. Absence proves nothing either
    // way, which is why it reads "cannot confirm" and not "not enabled".
    private static func keyboardStep(_ heartbeat: KeyboardHeartbeat?, live: Bool) -> SetupStep {
        guard let heartbeat else {
            return SetupStep(
                id: .keyboardEnabled,
                status: .cannotConfirm,
                detail: "iOS doesn’t let Tono read your keyboard settings. The Tono keyboard hasn’t checked in yet, so add it in Settings and then run the test below."
            )
        }
        if live {
            return SetupStep(
                id: .keyboardEnabled,
                status: .complete,
                detail: "The Tono keyboard checked in just now, so it’s added and loading correctly."
            )
        }
        return SetupStep(
            id: .keyboardEnabled,
            status: .confirmedEarlier(at: heartbeat.observedAt),
            detail: "The Tono keyboard checked in earlier, but not recently. Run the test below to confirm it still loads."
        )
    }

    // Step 2 — Full Access.
    //
    // The containing app cannot read this at all. Only the extension can, via
    // `UIInputViewController.hasFullAccess`, so with no live heartbeat the
    // honest answer is "cannot confirm" — including when an older heartbeat
    // said it was on, because the user may have revoked it since.
    private static func fullAccessStep(_ heartbeat: KeyboardHeartbeat?, live: Bool) -> SetupStep {
        guard let heartbeat, live else {
            return SetupStep(
                id: .fullAccess,
                status: .cannotConfirm,
                detail: "Only the keyboard itself can see whether Full Access is on. Run the test below and it will report back."
            )
        }
        if heartbeat.fullAccess {
            return SetupStep(
                id: .fullAccess,
                status: .complete,
                detail: "The keyboard reported Full Access is on, so Coach can reach Tono when you ask it to."
            )
        }
        return SetupStep(
            id: .fullAccess,
            status: .actionNeeded,
            detail: "The keyboard reported Full Access is off. Typing works, but Coach can’t reach Tono without it."
        )
    }

    // Step 3 — account + entitlement.
    //
    // This is the one step the app verifies directly. `.unknown` and a missing
    // verdict both fail closed, mirroring `TonePreferences.isProAuthoritative`.
    private static func accountStep(_ entitlement: SetupEntitlementSnapshot, now: Date) -> SetupStep {
        guard entitlement.isRegistered else {
            return SetupStep(
                id: .account,
                status: .actionNeeded,
                detail: "You’re not signed in yet. Sign in so Coach knows your subscription is yours."
            )
        }
        guard let state = entitlement.state else {
            return SetupStep(
                id: .account,
                status: .cannotConfirm,
                detail: "Your subscription hasn’t been checked on this device yet. Check again to confirm it."
            )
        }
        let isFresh: Bool = {
            guard let checkedAt = entitlement.checkedAt else { return false }
            let age = now.timeIntervalSince(checkedAt)
            return age >= 0 && age <= SetupDoctorPolicy.entitlementWindow
        }()
        switch state {
        case .entitled:
            guard isFresh else {
                return SetupStep(
                    id: .account,
                    status: .cannotConfirm,
                    detail: "Your subscription was confirmed a while ago. Check again to bring it up to date."
                )
            }
            return SetupStep(
                id: .account,
                status: .complete,
                detail: "You’re signed in and your subscription is active."
            )
        case .notEntitled:
            return SetupStep(
                id: .account,
                status: .actionNeeded,
                detail: "You’re signed in, but there’s no active subscription on this account."
            )
        case .unknown:
            return SetupStep(
                id: .account,
                status: .cannotConfirm,
                detail: "Tono couldn’t confirm your subscription just now. Check again once you’re back online."
            )
        }
    }

    // Step 4 — one successful keyboard test.
    //
    // Passing requires a heartbeat that is BOTH live AND newer than the moment
    // the user began the test. That ordering is what makes it a test rather
    // than a replay of an earlier check-in.
    //
    // Honest limit: this proves the Tono keyboard became active after the test
    // began, not that it was this exact text field. The copy says "just now",
    // never "in this field".
    private static func testDriveStep(
        _ heartbeat: KeyboardHeartbeat?,
        live: Bool,
        testStartedAt: Date?
    ) -> SetupStep {
        guard let testStartedAt else {
            return SetupStep(
                id: .testDrive,
                status: .cannotConfirm,
                detail: "Tap the test field below and switch to the Tono keyboard with the globe key."
            )
        }
        guard let heartbeat, live, heartbeat.observedAt >= testStartedAt else {
            return SetupStep(
                id: .testDrive,
                status: .cannotConfirm,
                detail: "Waiting for the Tono keyboard. Press and hold the globe key, then choose Tono."
            )
        }
        return SetupStep(
            id: .testDrive,
            status: .complete,
            detail: "The Tono keyboard is active — it checked in just now."
        )
    }
}

// MARK: - Navigation capability

/// What iOS actually permits when sending a user to Settings, separated from
/// the view so it can be asserted on.
///
/// Apple removed support for `App-Prefs:` style deep links into specific
/// Settings panes; `UIApplication.openSettingsURLString` is the only sanctioned
/// destination and it lands on *Tono's own* Settings page. Anything further —
/// notably General ▸ Keyboard ▸ Keyboards, where a keyboard is added — must be
/// written instructions. A button that claimed to open that pane would be a
/// fake button, so this type refuses to describe one.
public struct SetupNavigation: Equatable {

    /// Written steps. These are the only guarantee, so they are always present
    /// and always rendered, button or no button.
    public let writtenSteps: [String]

    /// True only when a public API lands the user on the exact pane the written
    /// steps start from. False for the Keyboards pane.
    public let landsOnExactPane: Bool

    /// Whether an "Open Settings" button is offered at all. When true the UI
    /// must use `UIApplication.openSettingsURLString` and nothing else.
    public let opensAppSettingsRoot: Bool

    /// Button caption, or `nil` when no honest button exists.
    public var buttonTitle: String? {
        opensAppSettingsRoot ? "Open Settings" : nil
    }

    /// Sub-caption that keeps the button honest about where it lands.
    public var buttonFootnote: String? {
        guard opensAppSettingsRoot else { return nil }
        return landsOnExactPane
            ? "Opens Tono’s page in Settings."
            : "Opens Tono’s page in Settings — iOS can’t jump straight to the keyboard list, so follow the steps from there."
    }

    /// Adding the keyboard. No public deep link reaches this pane.
    public static let addKeyboard = SetupNavigation(
        writtenSteps: [
            "Open Settings, then General.",
            "Tap Keyboard, then Keyboards.",
            "Tap Add New Keyboard… and choose Tono.",
        ],
        landsOnExactPane: false,
        opensAppSettingsRoot: true
    )

    /// Granting Full Access. Tono's own Settings page carries a Keyboards row
    /// leading to the toggle, so the button does land somewhere genuinely
    /// useful here — but still not on the toggle itself.
    public static let fullAccess = SetupNavigation(
        writtenSteps: [
            "Open Settings, then tap Tono.",
            "Tap Keyboards.",
            "Turn on Allow Full Access.",
        ],
        landsOnExactPane: true,
        opensAppSettingsRoot: true
    )

    /// Switching keyboards happens on the keyboard itself; Settings is not
    /// involved, so offering a Settings button here would be misdirection.
    public static let switchToTono = SetupNavigation(
        writtenSteps: [
            "Tap the test field below.",
            "Press and hold the globe key.",
            "Choose Tono from the list.",
        ],
        landsOnExactPane: false,
        opensAppSettingsRoot: false
    )
}

// MARK: - Full Access explanation

/// Plain-language Full Access copy, kept next to the logic it describes so a
/// reviewer can check every sentence against source in one place.
///
/// Each claim below is traceable:
///   • Coach sends the draft — `TonoCoachClient.coach(draft:)` posts the draft
///     text, the chosen variants, and any custom instruction the user typed.
///   • Only on tap — that method is the sole network call on the Coach path and
///     it has no automatic caller; nothing is sent while merely typing.
///   • No Full Access, no network — iOS blocks extension networking without it,
///     which is why the keyboard degrades to local typing.
///
/// Wording note: this says "what you type stays on your device until you tap
/// Coach" rather than any broader "we don't collect anything" claim, because
/// the Coach round-trip genuinely does transmit the draft.
public enum FullAccessExplainer {

    public static let headline = "Why Coach needs Full Access"

    public static let body = [
        "iOS blocks every keyboard from using the network unless you turn on Full Access. Coach writes your rewrites on Tono’s servers, so without it the Tono keyboard still types normally — Coach just can’t run.",
        "What you type stays on your device until you tap Coach. Tapping it sends that one draft and the tone options you chose, so Tono can write the rewrites back to you.",
        "Tono never sends who you’re messaging, which app you’re typing in, or the words you type when you’re not asking for a rewrite.",
    ]

    /// Rendered under the body as a short, scannable list.
    public static let neverCollected = [
        "Your keystrokes",
        "Who you’re messaging",
        "Which app you’re typing in",
    ]
}
