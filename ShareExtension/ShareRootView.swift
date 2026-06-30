// ShareExtension/ShareRootView.swift
// SwiftUI analysis sheet shown inside the Share Extension.

import SwiftUI

struct ShareAnalysisView: View {
    let draft: String
    let onDismiss: () -> Void

    @State private var analysis: ToneAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Analyzing…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let a = analysis {
                    ShareResultsView(analysis: a)
                } else if let err = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.yellow)
                        Text(err)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Try again") { runAnalysis() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Tono")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .onAppear { runAnalysis() }
    }

    private func runAnalysis() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let prefs = TonePreferences()
                let req = AnalysisRequest(
                    draft: draft,
                    preferredVoice: prefs.preferredVoice,
                    axes: prefs.axes.isEmpty ? RewriteAxis.allCases : prefs.axes
                )
                let result: ToneAnalysis = try await {
                    var perception = ""
                    var suggestions: [RewriteSuggestion] = []
                    var riskLevel: RiskLevel = .medium
                    var reason: String?
                    var flags: [String] = []
                    var subtext = ""

                    for await event in ToneEngine.backend().analyzeStream(req) {
                        switch event {
                        case .perception(let text): perception = text
                        case .suggestion(let axis, let text, let rationale, let riskAfter):
                            if let a = RewriteAxis(rawValue: axis) {
                                suggestions.append(RewriteSuggestion(
                                    axis: a, text: text, rationale: rationale,
                                    riskAfter: riskAfter.flatMap { RiskLevel(rawValue: $0) }
                                ))
                            }
                        case .complete(let level, let st, let rr, let f):
                            riskLevel = RiskLevel(rawValue: level) ?? .medium
                            subtext = st; reason = rr; flags = f
                        case .error(let msg): throw ToneEngineError.backend(msg)
                        }
                    }
                    return ToneAnalysis(riskLevel: riskLevel, perception: perception, subtext: subtext, reason: reason, suggestions: suggestions, flags: flags)
                }()
                await MainActor.run {
                    analysis = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

private struct ShareResultsView: View {
    let analysis: ToneAnalysis

    var riskColor: Color {
        switch analysis.riskLevel {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Risk badge
                HStack(spacing: 6) {
                    Circle().fill(riskColor).frame(width: 8, height: 8)
                    Text(analysis.riskLevel.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(riskColor.opacity(0.15))
                .clipShape(Capsule())

                Text(analysis.perception)
                    .font(.system(size: 16, weight: .medium, design: .rounded))

                if !analysis.flags.isEmpty {
                    HStack {
                        ForEach(analysis.flags, id: \.self) { f in
                            Text(f)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.systemGray5))
                                .clipShape(Capsule())
                        }
                    }
                }

                Divider()

                ForEach(analysis.suggestions) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(s.axis.displayName, systemImage: s.axis.glyph)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        Text(s.text)
                            .font(.system(size: 15, design: .rounded))
                        if let r = s.rationale {
                            Text(r)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding()
        }
    }
}
