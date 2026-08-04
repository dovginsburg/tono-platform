// ShareExtension/ShareRootView.swift
// SwiftUI analysis sheet shown inside the Share Extension.
//
// Build 117 — Share to Tono now asks what the shared text IS before doing
// anything with it. `ShareModeChoiceView` is that question, and it only appears
// when Read the Ask is switched on; with the toggle off this extension does
// exactly what it did before, with the same first frame and the same request.
// An entry point for a feature that is off is not a dimmed entry point — it is
// no entry point.

import SwiftUI

/// Build 117 — the explicit choice. Two buttons, no default, no pre-selection
/// and no timer: text somebody shared could equally be a message they received
/// or a draft they are about to send, and the whole point of this screen is that
/// Tono does not guess which.
struct ShareModeChoiceView: View {
    let onChoice: (TonoRequestMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What is this text?")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(ReadTheAskCopy.modeSelectorCaption)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            choice(
                title: "Read what they're asking",
                detail: "A message you received.",
                glyph: "text.magnifyingglass",
                mode: .readAsk
            )
            choice(
                title: "Rewrite this text",
                detail: "Something you're about to send.",
                glyph: "sparkles",
                mode: .rewrite
            )
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice(
        title: String, detail: String, glyph: String, mode: TonoRequestMode
    ) -> some View {
        Button {
            onChoice(mode)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .font(.system(size: 18))
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(14)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

// Build 117 repair — the stage type now lives in `ReadTheAskShareFlow`
// (`Shared/ReadTheAsk.swift`) together with the decisions that produce it, so
// the unit-test target can reach both. A local copy here would be a second
// vocabulary for one idea, and the decisions would drift back into the view.

struct ShareAnalysisView: View {
    let draft: String
    let onDismiss: () -> Void

    /// Build 117 — with Read the Ask off this is `.rewrite` from the first
    /// frame, so the extension opens on exactly the screen it always opened on.
    @State private var stage: ReadTheAskShareStage

    @State private var analysis: ToneAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?

    // The received message and its reading, for one flow. Never written down.
    @StateObject private var readAskSession = ReadTheAskSession()
    @State private var readAskLoading = false
    /// Read the Ask's own failure notice. Kept apart from `errorMessage`, which
    /// belongs to the rewrite path and correctly says "Couldn't coach this
    /// draft."
    @State private var readAskFailure: ReadTheAskNotice?

    init(
        draft: String,
        activation: ReadTheAskActivation = ReadTheAskActivation(),
        onDismiss: @escaping () -> Void
    ) {
        self.draft = draft
        self.onDismiss = onDismiss
        _stage = State(initialValue: ReadTheAskShareFlow.initialStage(
            activationEnabled: activation.isEnabled
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choosing:
                    ShareModeChoiceView { mode in
                        stage = ReadTheAskShareFlow.stage(choosing: mode)
                        switch mode {
                        case .rewrite:
                            runAnalysis()
                        case .readAsk:
                            readAskSession.setReceivedText(draft)
                            runReadAsk()
                        }
                    }
                case .readAsk:
                    readAskBody
                case .rewrite:
                    rewriteBody
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
        .onAppear {
            // Only the established path runs on appear. The choice screen waits
            // for the person, because it is a question.
            if ReadTheAskShareFlow.runsOnAppear(stage) { runAnalysis() }
        }
        .onDisappear {
            // One flow, then gone.
            readAskSession.clear()
        }
    }

    // MARK: - Read the Ask

    @ViewBuilder
    private var readAskBody: some View {
        if readAskLoading {
            ProgressView("Reading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let outcome = readAskSession.outcome {
            // Build 117 repair — what a notice IS is decided once, in
            // `ReadTheAskNotice`, for both surfaces. A successful "nothing is
            // being asked of you" is no longer drawn as a warning.
            if let notice = ReadTheAskNotice.forOutcome(outcome) {
                ShareNoticeView(notice: notice)
            } else if case .reading(let result) = outcome {
                ShareReadAskResultView(result: result)
            }
        } else if let readAskFailure {
            ShareNoticeView(notice: readAskFailure, retry: { runReadAsk() })
        } else {
            Color.clear
        }
    }

    private func runReadAsk() {
        readAskLoading = true
        errorMessage = nil
        Task {
            do {
                // The mode is stated. Every time, at the call site.
                let outcome = try await TonoBackend.shared.readAsk(
                    receivedText: draft, mode: .readAsk
                )
                await MainActor.run {
                    readAskSession.apply(outcome)
                    readAskLoading = false
                }
            } catch {
                await MainActor.run {
                    // `.readMessage`, not `.coachDraft`: this failed to read a
                    // message somebody sent, not to coach a draft nobody wrote.
                    readAskFailure = ReadTheAskNotice.forFailure(error)
                    readAskLoading = false
                }
            }
        }
    }

    // MARK: - Rewrite (unchanged)

    @ViewBuilder
    private var rewriteBody: some View {
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
    }

    private func runAnalysis() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let prefs = TonePreferences()
                // Build 117 — this established caller used to let the mode
                // default. It now states it, through the one legacy adapter, so
                // the bytes on the wire are identical and the intent is no
                // longer implied by an omission.
                let req = AnalysisRequest(
                    draft: draft,
                    preferredVoice: prefs.preferredVoice,
                    axes: RewriteAxis.allCases,
                    mode: try TonoLegacyAnalysisMode.analysisMode(for: .rewrite)
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
                        case .offline: throw TonoBackendError.offline
                        case .error(let msg): throw ToneEngineError.backend(msg)
                        // Build 113: the status reaches the mapper intact, so
                        // Share keeps 401 / 402 / 429 apart instead of
                        // answering all three with "Try again."
                        case .failure(let status): throw StreamedFailure.http(status: status)
                        }
                    }
                    return ToneAnalysis(riskLevel: riskLevel, perception: perception, subtext: subtext, reason: reason, suggestions: try suggestions.canonicalCoachChoices(), flags: flags)
                }()
                await MainActor.run {
                    analysis = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    // Build 112: the streamed failure's text is a status line,
                    // not guidance. Show the action instead.
                    errorMessage = ConsumerErrorCopy.message(for: error, action: .coachDraft)
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Build 117 — the reading, inside Share

/// The Ask, the deadline the sender actually wrote, and one unclear detail.
///
/// Read-only and copyable. There is no Send here, and there is no draft editor:
/// the Share extension is a place a person passes through, and the composing
/// surface is the companion app.
private struct ShareReadAskResultView: View {
    let result: ReadAskResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                field(ReadTheAskCopy.askHeading, result.ask, emphasised: true)
                field(
                    ReadTheAskCopy.byWhenHeading,
                    result.byWhen ?? ReadTheAskCopy.byWhenAbsent,
                    muted: result.byWhen == nil
                )
                if let unclear = result.unclear, !unclear.isEmpty {
                    field(ReadTheAskCopy.unclearHeading, unclear)
                }
                if !result.possibleReadings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ReadTheAskCopy.possibleReadingsHeading)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        ForEach(result.possibleReadings, id: \.self) { reading in
                            Text("• \(reading)")
                                .font(.system(size: 14, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(ReadTheAskCopy.possibleReadingsCaption)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(ReadTheAskCopy.possibleReadingsHeading)
                }
                Text(ReadTheAskCopy.draftEditableNote)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
    }

    private func field(
        _ heading: String, _ value: String, emphasised: Bool = false, muted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: emphasised ? 17 : 15, design: .rounded))
                .foregroundColor(muted ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One neutral sentence, drawn as what it actually is.
///
/// The glyph and its tint come from `ReadTheAskNotice.kind`, so a successful
/// reading with no request in it is no longer presented with the iconography of
/// a failure. Retry appears only where retrying could change the answer.
private struct ShareNoticeView: View {
    let notice: ReadTheAskNotice
    var retry: (() -> Void)?

    private var tint: Color {
        switch notice.kind {
        case .success:  return .green
        case .boundary: return .secondary
        case .failure:  return .yellow
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: notice.glyph)
                .font(.system(size: 36))
                .foregroundColor(tint)
            Text(notice.message)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if notice.offersRetry, let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
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
