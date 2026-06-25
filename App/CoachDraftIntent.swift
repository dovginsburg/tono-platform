// CoachDraftIntent.swift
// Siri Shortcuts / Apple Shortcuts integration.
//
// Users can say "Coach my draft with Tono" or build a Shortcut that passes
// clipboard text through tone analysis and gets the best rewrite back.
//
// Xcode setup required:
//   No separate extension target needed — AppIntents are hosted inline by iOS.
//   Make sure AppIntents.framework is linked to the main app target (Xcode
//   usually adds it automatically when it detects AppIntent conformances).
//
// The intent runs in the app's background process so it has full Keychain
// access and can make authenticated network calls. openAppWhenRun = false
// keeps this background so the screen stays on whatever the user was doing.

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct CoachDraftIntent: AppIntent {
    static var title: LocalizedStringResource = "Coach a Draft"
    static var description = IntentDescription(
        "Analyze the tone of a message and get the best rewrite.",
        categoryName: "Writing"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Draft Message", description: "The message you want to coach.")
    var draft: String

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard TonoBackend.shared.isRegistered() else {
            return .result(
                value: "",
                dialog: "Open Tono once to create your account, then try again."
            )
        }
        let prefs = TonePreferences()
        let req = AnalysisRequest(
            draft: draft,
            recipientHint: nil,
            preferredVoice: prefs.preferredVoice,
            axes: prefs.axes.isEmpty ? RewriteAxis.allCases : prefs.axes,
            contextHints: UserMemory.topFacts()
        )
        let result = try await ToneEngine.backend().analyze(req)
        let best = StyleMemory.sorted(result.suggestions.map(\.axis)).first
            .flatMap { axis in result.suggestions.first { $0.axis == axis } }
            ?? result.suggestions.first

        if let chosen = best {
            UserMemory.recordSession(flags: result.flags, chosenAxis: chosen.axis.rawValue)
        }

        var lines: [String] = [
            "Risk: \(result.riskLevel.displayName)",
            result.perception,
        ]
        if let s = best {
            lines.append("\(s.axis.displayName) rewrite: \(s.text)")
        }
        let dialog = lines.joined(separator: "\n")
        NotificationManager.shared.recordCoachSession()
        return .result(value: best?.text ?? draft, dialog: IntentDialog(stringLiteral: dialog))
    }
}

@available(iOS 16.0, *)
struct TonoShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CoachDraftIntent(),
            phrases: [
                "Coach my draft with \(.applicationName)",
                "Check my message with \(.applicationName)",
                "Analyze my draft with \(.applicationName)",
            ],
            shortTitle: "Coach Draft",
            systemImageName: "sparkles"
        )
    }
}
