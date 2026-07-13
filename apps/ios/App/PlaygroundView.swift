// PlaygroundView.swift
// In-app playground so the user can rehearse the Coach flow without
// enabling the keyboard first. Useful for QA and for onboarding demos.

import SwiftUI

struct PlaygroundView: View {
    @State private var draft: String = "Thanks for the update but I think we should reconsider as per my last message."
    @State private var recipientHint: String = "Senior PM, hasn't replied in 3 days"
    @State private var analysis: ToneAnalysis?
    @State private var loading = false
    @State private var error: String?
    @State private var prefs = TonePreferences()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Draft")
                        .font(.caption).foregroundColor(.secondary)
                    TextEditor(text: $draft)
                        .frame(minHeight: 80)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.white)

                    Text("Recipient context (optional)")
                        .font(.caption).foregroundColor(.secondary)
                    TextField("e.g. manager I rarely talk to", text: $recipientHint)
                        .padding(8)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.white)

                    Button(action: run) {
                        HStack {
                            if loading { ProgressView().tint(.white) }
                            Text(loading ? "Analyzing…" : "Coach it")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(loading || draft.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let err = error {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    if let a = analysis {
                        PlaygroundResults(analysis: a)
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Playground")
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 0) }
        }
    }

    private func run() {
        loading = true
        error = nil
        analysis = nil
        Task {
            // Backend handles registration on first call.
            do {
                _ = try await TonoBackend.shared.registerIfNeeded(
                    platform: "ios",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                )
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.loading = false
                }
                return
            }
            let prefs = TonePreferences()
            let req = AnalysisRequest(
                draft: draft,
                recipientHint: recipientHint.isEmpty ? nil : recipientHint,
                preferredVoice: prefs.preferredVoice,
                axes: prefs.axes.isEmpty ? RewriteAxis.allCases : prefs.axes
            )
            do {
                var perception = ""
                var suggestions: [RewriteSuggestion] = []
                var riskLevel: RiskLevel = .medium
                var reason: String?
                var flags: [String] = []
                var subtext = ""

                for await event in ToneEngine.backend().analyzeStream(req) {
                    switch event {
                    case .perception(let text):
                        perception = text
                    case .suggestion(let axis, let text, let rationale, let riskAfter):
                        if let a = RewriteAxis(rawValue: axis) {
                            suggestions.append(RewriteSuggestion(
                                axis: a, text: text, rationale: rationale,
                                riskAfter: riskAfter.flatMap { RiskLevel(rawValue: $0) }
                            ))
                        }
                    case .complete(let level, let st, let rr, let f):
                        riskLevel = RiskLevel(rawValue: level) ?? .medium
                        subtext = st
                        reason = rr
                        flags = f
                    case .error(let msg):
                        throw ToneEngineError.backend(msg)
                    }
                }

                let result = ToneAnalysis(
                    riskLevel: riskLevel,
                    perception: perception,
                    subtext: subtext,
                    reason: reason,
                    suggestions: suggestions,
                    flags: flags
                )
                await MainActor.run {
                    self.analysis = result
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }
}

private struct PlaygroundResults: View {
    let analysis: ToneAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(riskColor).frame(width: 10, height: 10)
                Text(analysis.riskLevel.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
            }

            if let reason = analysis.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.secondary)
            }

            Text(analysis.perception)
                .font(.system(size: 16, weight: .medium, design: .rounded))

            if !analysis.flags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(analysis.flags, id: \.self) { f in
                        Text(f)
                            .font(.system(size: 11, design: .rounded))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Capsule())
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }

            Divider().background(Color.white.opacity(0.15))

            ForEach(analysis.suggestions) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: s.axis.glyph)
                        Text(s.axis.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    Text(s.text)
                        .font(.system(size: 15, design: .rounded))
                    if let r = s.rationale {
                        Text(r)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.top, 6)
    }

    private var riskColor: Color {
        switch analysis.riskLevel {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}
