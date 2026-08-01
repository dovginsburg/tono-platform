// AppleIntelligenceIntents.swift
// Apple Intelligence readiness — the local-only App Intents actions.
//
// Two actions, and both are LOCAL-ONLY by construction: they read no message
// text, transmit nothing, send no message, and touch no account or entitlement.
// Neither can generate a rewrite — network generation happens ONLY through the
// explicit `CoachDraftIntent` ("Rewrite a Draft"), which keeps its existing
// account/entitlement/provider gates.
//
//   • OpenKeyboardSetupIntent — opens Tono to the keyboard setup screen. The
//     screen itself holds the sanctioned `UIApplication.openSettingsURLString`
//     jump; the intent just asks the app to show it, via the one-shot App Group
//     route signal. Nothing here reads or sends anything.
//   • SetToneVariantEnabledIntent — turns one optional keyboard tone on or off.
//     It edits only the device-local two-optional-tone selection the keyboard
//     already honors (`CoachVariantSettings`), through the pure
//     `ToneVariantConfiguration` policy. No text, no network, no account.

import AppIntents
import Foundation

// MARK: - Open keyboard setup (local-only)

@available(iOS 16.0, *)
struct OpenKeyboardSetupIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Tono Keyboard Setup"
    static var description = IntentDescription(
        "Open Tono to the keyboard setup screen, where you can add the Tono keyboard, allow Full Access, and open iOS keyboard settings.",
        categoryName: "Setup"
    )
    // Opening the setup screen requires the app UI, so this one opens the app.
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        // Leave a one-shot request; the app presents the screen on its next
        // foreground. No text, no network — just a named destination.
        AppIntentRouteSignal().request(.keyboardSetup)
        return .result()
    }
}

// MARK: - Enable / disable a tone variant (local-only)

@available(iOS 16.0, *)
struct SetToneVariantEnabledIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Tono Tone Variant"
    static var description = IntentDescription(
        "Turn one of Tono's optional keyboard tone variants on or off. This changes only your on-device keyboard settings — no message text is read or sent.",
        categoryName: "Setup"
    )
    // Purely a settings edit — never yanks the person out of context.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Tone Variant", description: "The optional keyboard tone to turn on or off.")
    var variant: ToneVariantEntity

    @Parameter(title: "Turn On", description: "On to enable the tone, off to disable it.", default: true)
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$variant) to \(\.$enabled)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = CoachVariantSettingsStore()
        let current = store.load()
        let (updated, outcome) = ToneVariantConfiguration.apply(
            enable: enabled,
            variantAxis: variant.id,
            to: current
        )
        // Persist ONLY when something actually changed — an idempotent request
        // does not rewrite the store, and never claims a change it did not make.
        if outcome.didChange {
            store.save(updated)
        }
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}
