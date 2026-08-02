// CoachDraftIntent.swift
// Siri Shortcuts / Apple Shortcuts integration.
//
// Users build a Shortcut that passes a draft message + a chosen Rewrite Style
// through Tono and gets exactly one rewritten String back. The style choices
// mirror the keyboard / iMessage tone-chip strip: the mandatory Safer chip
// plus the six fixed optional tones (Clearer, Funnier, Affectionate,
// Professional, Concise, Custom). Selecting one style makes ONE authenticated
// request to the selected-variant backend endpoint (POST /api/analyze/variant)
// on the correct axis and returns that single variant's text.
//
// Parity + honesty contract (mirrors TonoMessagesExtension.requestRewrite):
//   * Registration pre-check: fail closed when the device has no account token
//     (it cannot make an authenticated call). This is a PRINCIPAL check, not an
//     entitlement grant — being registered does NOT mean being entitled.
//   * Entitlement gate: enforced SERVER-side. There is no free tier, so a
//     registered-but-non-entitled device is refused by the backend with a
//     distinct HTTP 402. That 402 maps to the honest
//     ShortcutRewrite.Failure.entitlementRequired ("active trial or
//     subscription required"), never a rewrite. 429 (per-IP rate limit) and 401
//     (sign-in) map to their own truthful messages via TonoBackendError.
//   * Custom: validated and capped at 120 characters (never silently
//     truncated into a "success").
//   * No-op guard: a blocked envelope, an empty rewrite, or a rewrite that is
//     near-identical to the source draft is an honest FAILURE — the source
//     draft is NEVER returned as a successful rewrite.
//
// No clipboard, no fake shortcut-import URL, no silent success, no auto-send,
// no app-level side effect. The intent runs in the app's background process
// (openAppWhenRun = false) so it has Keychain access for the authenticated
// call without yanking the user out of context.
//
// Xcode setup: no separate extension target — AppIntents are hosted inline by
// iOS. AppIntents.framework links to the main app target automatically when it
// detects AppIntent conformances. The pure label→axis map, the 120-char cap,
// and the no-op guard live in Shared/CoachVariantSettings.swift
// (ShortcutRewriteStyle / ShortcutRewrite) so this file stays a thin wrapper.

import AppIntents
import Foundation

/// The selectable Rewrite Style parameter surfaced in the Shortcuts editor.
/// One case per keyboard tone chip; each maps to a `ShortcutRewriteStyle`
/// (and therefore to one backend variant axis).
@available(iOS 16.0, *)
enum RewriteStyle: String, AppEnum {
    case safer
    case clearer
    case funnier
    case affectionate
    case professional
    case concise
    case custom

    /// The shared, testable style contract this UI case maps onto.
    var style: ShortcutRewriteStyle { ShortcutRewriteStyle(rawValue: rawValue) ?? .safer }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Rewrite Style"

    // Keyboard-source labels. Kept in the mandatory-Safer-first, then
    // optional-tone declaration order the chip strip renders.
    static var caseDisplayRepresentations: [RewriteStyle: DisplayRepresentation] = [
        .safer: "Safer",
        .clearer: "Clearer",
        .funnier: "Funnier",
        .affectionate: "Affectionate",
        .professional: "Professional",
        .concise: "Concise",
        .custom: "Custom",
    ]
}

@available(iOS 16.0, *)
struct CoachDraftIntent: AppIntent {
    static var title: LocalizedStringResource = "Rewrite a Draft"
    static var description = IntentDescription(
        "Rewrite a message in a chosen tone — Safer, Clearer, Funnier, Affectionate, Professional, Concise, or a Custom style.",
        categoryName: "Writing"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Draft Message", description: "The message you want to rewrite.")
    var draft: String

    @Parameter(title: "Rewrite Style", description: "The tone to rewrite in.")
    var style: RewriteStyle

    @Parameter(
        title: "Custom Style",
        description: "Only used when Rewrite Style is Custom. A short directive, 1–120 characters."
    )
    var customStyle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Rewrite \(\.$draft) to be \(\.$style)") {
            \.$customStyle
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let source = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            throw honest(.emptyDraft)
        }
        // Registration pre-check — fail closed when the device has no account
        // token, exactly like the keyboard and iMessage surfaces. This is only
        // a principal check (no token => no authenticated call); it is NOT an
        // entitlement grant. Entitlement is decided server-side below.
        guard TonoBackend.shared.isRegistered() else {
            throw honest(.notRegistered)
        }

        let selected = style.style

        // Custom is validated + capped at 120 before any network request.
        var customPrompt: String? = nil
        if selected.requiresCustomText {
            switch ShortcutRewrite.validatedCustomText(customStyle) {
            case .success(let value): customPrompt = value
            case .failure(let failure): throw honest(failure)
            }
        }

        // Exactly one authenticated request on the selected axis. The
        // server-authoritative entitlement gate refuses a non-entitled device
        // with HTTP 402 (there is no free tier); map that to the honest
        // ShortcutRewrite entitlement failure so the Shortcuts runtime shows
        // "active trial or subscription required" and returns no rewrite.
        // Sign-in (401) and rate-limit (429) failures keep their own truthful
        // TonoBackendError messages.
        let result: TonoVariantResult
        do {
            result = try await TonoBackend.shared.analyzeVariant(
                text: source,
                axis: selected.axis,
                customPrompt: customPrompt
            )
        } catch let error as TonoBackendError {
            if case .http(402, _) = error {
                throw honest(.entitlementRequired)
            }
            throw error
        }

        // Resolve the strict ok|blocked envelope into a distinct rewrite or an
        // honest failure. The source draft is NEVER returned as a success.
        let rewrite: String
        switch ShortcutRewrite.resolve(
            status: result.status,
            text: result.text,
            reason: result.reason,
            source: source
        ) {
        case .success(let value): rewrite = value
        case .failure(let failure): throw honest(failure)
        }

        NotificationManager.shared.recordCoachSession()
        let dialog = "\(selected.label) rewrite:\n\(rewrite)"
        return .result(value: rewrite, dialog: IntentDialog(stringLiteral: dialog))
    }

    private func honest(_ failure: ShortcutRewrite.Failure) -> ShortcutRewriteIntentError {
        ShortcutRewriteIntentError(failure)
    }
}

/// Bridges the pure `ShortcutRewrite.Failure` into a `LocalizedError` so the
/// Shortcuts runtime surfaces the truthful message to the user.
@available(iOS 16.0, *)
struct ShortcutRewriteIntentError: LocalizedError {
    let failure: ShortcutRewrite.Failure
    init(_ failure: ShortcutRewrite.Failure) { self.failure = failure }
    var errorDescription: String? { failure.message }
}

@available(iOS 16.0, *)
struct TonoShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // The explicit "Coach this text" action — the ONLY intent that performs
        // network generation, and it keeps its account/entitlement/provider
        // gates (see CoachDraftIntent.perform). Preserved verbatim.
        AppShortcut(
            intent: CoachDraftIntent(),
            phrases: [
                "Rewrite my draft with \(.applicationName)",
                "Rewrite my message with \(.applicationName)",
                "Coach my draft with \(.applicationName)",
            ],
            shortTitle: "Rewrite Draft",
            systemImageName: "sparkles"
        )
        // Local-only setup action. Opens the app to keyboard setup; reads and
        // sends nothing. Discoverable as a spoken shortcut and in Spotlight.
        AppShortcut(
            intent: OpenKeyboardSetupIntent(),
            phrases: [
                "Set up \(.applicationName)",
                "Open \(.applicationName) keyboard setup",
                "Fix my \(.applicationName) keyboard",
            ],
            shortTitle: "Keyboard Setup",
            systemImageName: "keyboard"
        )
    }
}
