// KeyboardRootView.swift
// SwiftUI body for the keyboard extension.
//
// Modes:
//  .keyboard     — standard QWERTY-ish layout with Coach + Read + History buttons
//  .loading      — spinner while the backend call is in flight
//  .results      — risk badge + 4 rewrite chips (Coach mode)
//  .reading      — risk badge + interpretation (Read mode, no rewrites)
//  .history      — last 5 coach sessions (tap to re-open any result)
//  .noFullAccess — prompt to enable Full Access in Settings
//  .error        — inline error with back button

import SwiftUI

enum KeyboardMode: Equatable {
    case keyboard
    case loading
    case results(ToneAnalysis)
    case reading(ToneAnalysis)
    case history
    case noFullAccess
    case error(String)
}

private struct ProxyProviderKey: EnvironmentKey {
    static let defaultValue: () -> UITextDocumentProxy? = { nil }
}

extension EnvironmentValues {
    var proxyProvider: () -> UITextDocumentProxy? {
        get { self[ProxyProviderKey.self] }
        set { self[ProxyProviderKey.self] = newValue }
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published var mode: KeyboardMode = .keyboard
    @Published var draft: String = ""
    @Published var usedToday: Int = 0
    @Published var dailyLimit: Int = 10
    @Published var isPro: Bool = false
    @Published var hasFullAccess: Bool = true
    @Published var isOfflineResult: Bool = false
    @Published var isRefinementLoading: Bool = false  // true while LLM refines the mock preview
    @Published var threadContext: String? = nil
    @Published var selectedRecipient: Recipient? = nil

    // C4: edit-after-insert tracking — set when user inserts a rewrite;
    // cleared after detected edit fires the analytics event.
    private var lastInsertedRewrite: String? = nil
    // A3: Coach tap timestamp for latency measurement.
    private var coachTapTime: Date? = nil
    // Collective improvement: context captured when results arrive so we can
    // fire a content-free outcome event on insert or back (no text stored here).
    private struct OutcomeContext {
        let riskLevel: String
        let mode: String
        let msgLenBucket: String
    }
    private var pendingOutcome: OutcomeContext? = nil

    private let proxyProvider: () -> UITextDocumentProxy?
    private let advance: () -> Void
    private let dismiss: () -> Void

    init(
        initialText: String = "",
        proxy: @escaping () -> UITextDocumentProxy?,
        advance: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.draft = initialText
        self.proxyProvider = proxy
        self.advance = advance
        self.dismiss = dismiss
    }

    func loadDraft() {
        var combined = ""
        if let before = proxyProvider()?.documentContextBeforeInput { combined += before }
        if let after = proxyProvider()?.documentContextAfterInput { combined += after }
        let newDraft = combined.trimmingCharacters(in: .whitespacesAndNewlines)

        // C4: Detect if the user edited a rewrite after inserting it.
        if let lastInserted = lastInsertedRewrite, !newDraft.isEmpty, newDraft != lastInserted {
            TonoAnalytics.track(.rewriteEditedAfterInsert)
            lastInsertedRewrite = nil
        }

        draft = newDraft
    }

    func runCoach() {
        guard hasFullAccess else {
            mode = .noFullAccess
            return
        }
        loadDraft()
        guard !draft.isEmpty else {
            mode = .error("Type something first.")
            return
        }

        // A3: record tap time for latency measurement.
        coachTapTime = Date()
        TonoAnalytics.track(.coachRequested(mode: "coach"))
        CrashReporter.addBreadcrumb("Coach tapped")

        Task { @MainActor in
            self.isOfflineResult = false
            self.isRefinementLoading = true
            CrashReporter.setCustomKey("loading", forKey: "keyboard_mode")
            CrashReporter.setCustomKey(true, forKey: "network_in_flight")

            let prefs = TonePreferences()
            let hintsEnabled = FeatureFlags.isEnabled(.memoryContextHints)
            let hints = hintsEnabled ? UserMemory.topFacts() : []
            CrashReporter.setCustomKey(hintsEnabled, forKey: "memory_facts_loaded")
            let enabledAxes = prefs.axes.isEmpty ? RewriteAxis.allCases : prefs.axes
            // Pro users: send axes in StyleMemory-ranked order so the LLM
            // generates in the user's preferred order (mock fallback also respects it).
            let rankedAxes = self.isPro && FeatureFlags.isEnabled(.memoryInference)
                ? StyleMemory.sorted(enabledAxes, recipientId: selectedRecipient?.id)
                : enabledAxes
            let req = AnalysisRequest(
                draft: self.draft,
                recipientHint: self.selectedRecipient?.voiceHint,
                preferredVoice: prefs.preferredVoice,
                axes: rankedAxes,
                contextHints: hints,
                threadContext: FeatureFlags.isEnabled(.threadContext) ? self.threadContext : nil
            )

            // Show mock result immediately (latency masking) — the risk badge
            // appears before the LLM responds. The mock is a placeholder only;
            // it is replaced by the real LLM result or an honest error, never
            // left as a terminal answer (C2).
            if let preview = try? await MockToneAnalyzer().analyze(req) {
                self.mode = .results(preview)
                CrashReporter.setCustomKey("results_mock", forKey: "keyboard_mode")
                // A3: fire analysis_shown with mock latency.
                if let tapTime = self.coachTapTime {
                    let ms = Int(Date().timeIntervalSince(tapTime) * 1000)
                    TonoAnalytics.track(.analysisShown(riskLevel: preview.riskLevel.rawValue, latencyMs: ms, source: "mock"))
                }
                // Capture outcome context (overwritten when real result arrives).
                self.pendingOutcome = OutcomeContext(
                    riskLevel: preview.riskLevel.rawValue,
                    mode: "coach",
                    msgLenBucket: Self.msgLenBucket(self.draft)
                )
            } else {
                self.mode = .loading
            }

            do {
                let me = try await TonoBackend.shared.registerIfNeeded(
                    platform: "ios",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                )
                self.usedToday = me.usedToday
                self.dailyLimit = me.dailyLimit
                self.isPro = me.isPro
                SharedStore.defaults.set(me.usedToday, forKey: SharedKeys.widgetUsedToday)
                SharedStore.defaults.set(max(me.dailyLimit, 0), forKey: SharedKeys.widgetDailyLimit)
            } catch {
                self.isRefinementLoading = false
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .error(error.localizedDescription)
                return
            }

            do {
                let result = try await ToneEngine.backend().analyze(req)
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                if let usage = try? await TonoBackend.shared.me() {
                    self.usedToday = usage.usedToday
                    self.dailyLimit = usage.dailyLimit
                    self.isPro = usage.isPro
                    SharedStore.defaults.set(usage.usedToday, forKey: SharedKeys.widgetUsedToday)
                    SharedStore.defaults.set(usage.dailyLimit, forKey: SharedKeys.widgetDailyLimit)
                    SharedStore.defaults.set(usage.isPro, forKey: SharedKeys.proUnlocked)
                }
                SharedStore.defaults.set(result.perception, forKey: SharedKeys.lastPerception)
                SharedStore.defaults.set(result.riskLevel.rawValue, forKey: SharedKeys.lastRiskLevel)
                DraftHistory.push(draft: self.draft, analysis: result)
                let count = SharedStore.defaults.integer(forKey: SharedKeys.coachUseCount)
                SharedStore.defaults.set(count + 1, forKey: SharedKeys.coachUseCount)
                NotificationManager.shared.recordCoachSession()
                self.isRefinementLoading = false
                self.mode = .results(result)
                CrashReporter.setCustomKey("results_real", forKey: "keyboard_mode")
                // A3: fire analysis_shown with real LLM latency.
                if let tapTime = self.coachTapTime {
                    let ms = Int(Date().timeIntervalSince(tapTime) * 1000)
                    TonoAnalytics.track(.analysisShown(riskLevel: result.riskLevel.rawValue, latencyMs: ms, source: "llm"))
                }
                self.coachTapTime = nil
                // Overwrite mock outcome with real risk level.
                self.pendingOutcome = OutcomeContext(
                    riskLevel: result.riskLevel.rawValue,
                    mode: "coach",
                    msgLenBucket: Self.msgLenBucket(self.draft)
                )
            } catch TonoBackendError.offline {
                // C2: Fail honestly — don't serve the mock as a terminal verdict.
                // A false "Looks okay" on a risky message is worse than no answer.
                self.isRefinementLoading = false
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .error("No connection. Tap Back and try again when you have signal.")
                self.coachTapTime = nil
            } catch let err as TonoBackendError {
                self.isRefinementLoading = false
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                if let usage = try? await TonoBackend.shared.me() {
                    self.usedToday = usage.usedToday
                    self.dailyLimit = usage.dailyLimit
                    self.isPro = usage.isPro
                }
                self.mode = .error(err.localizedDescription)
                self.coachTapTime = nil
            } catch {
                self.isRefinementLoading = false
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .error(error.localizedDescription)
                self.coachTapTime = nil
            }
        }
    }

    func runRead() {
        guard hasFullAccess else {
            mode = .noFullAccess
            return
        }
        loadDraft()
        guard !draft.isEmpty else {
            mode = .error("Paste the message you received first.")
            return
        }
        mode = .loading
        TonoAnalytics.track(.coachRequested(mode: "read"))
        CrashReporter.addBreadcrumb("Read tapped")

        Task { @MainActor in
            self.isOfflineResult = false
            CrashReporter.setCustomKey(true, forKey: "network_in_flight")

            do {
                let me = try await TonoBackend.shared.registerIfNeeded(
                    platform: "ios",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                )
                self.usedToday = me.usedToday
                self.dailyLimit = me.dailyLimit
                self.isPro = me.isPro
            } catch {
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .error(error.localizedDescription)
                return
            }

            let prefs = TonePreferences()
            let hints = FeatureFlags.isEnabled(.memoryContextHints) ? UserMemory.topFacts() : []
            let req = AnalysisRequest(
                draft: self.draft,
                preferredVoice: prefs.preferredVoice,
                axes: [],
                contextHints: hints,
                mode: .read
            )
            do {
                let result = try await ToneEngine.backend().analyze(req)
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .reading(result)
            } catch TonoBackendError.offline {
                // C2: Fail honestly — don't serve a heuristic read as a confident interpretation.
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .error("No connection. Tap Back and try again when you have signal.")
            } catch {
                CrashReporter.setCustomKey(false, forKey: "network_in_flight")
                self.mode = .error(error.localizedDescription)
            }
        }
    }

    func insertRewrite(suggestion: RewriteSuggestion, analysis: ToneAnalysis) {
        guard let proxy = proxyProvider() else { return }
        if let before = proxy.documentContextBeforeInput {
            for _ in 0..<before.count { proxy.deleteBackward() }
        }
        proxy.insertText(suggestion.text)
        SharedStore.defaults.set(suggestion.text, forKey: SharedKeys.lastRewriteVoice)
        StyleMemory.recordTap(axis: suggestion.axis, recipientId: selectedRecipient?.id)
        UserMemory.recordSession(flags: analysis.flags, chosenAxis: suggestion.axis.rawValue)
        TonoBackend.shared.logAxisWin(axis: suggestion.axis.rawValue, riskLevel: analysis.riskLevel.rawValue)

        // C4: track inserted text so loadDraft() can detect subsequent edits.
        lastInsertedRewrite = suggestion.text

        // A3: analytics — what was inserted, what was shown (for axis_rejected derivation).
        let shownAxes = analysis.suggestions.map(\.axis.rawValue)
        TonoAnalytics.track(.rewriteInserted(selectedAxis: suggestion.axis.rawValue, shownAxes: shownAxes))
        // Log rejections for all non-picked axes shown.
        let rejectedShown = analysis.suggestions.filter { $0.axis != suggestion.axis }.map(\.axis.rawValue)
        if !rejectedShown.isEmpty {
            TonoAnalytics.track(.axisRejected(shownAxes: shownAxes, pickedAxis: suggestion.axis.rawValue))
        }
        CrashReporter.addBreadcrumb("Rewrite inserted: \(suggestion.axis.rawValue)")

        // Collective improvement: fire content-free outcome (rewriteUsed=true).
        if let outcome = pendingOutcome {
            TonoAnalytics.track(.improvementOutcome(
                riskLevel: outcome.riskLevel,
                axisSelected: suggestion.axis.rawValue,
                mode: outcome.mode,
                msgLenBucket: outcome.msgLenBucket,
                rewriteUsed: true,
                editAfter: false   // edit detection fires later via rewriteEditedAfterInsert
            ))
            pendingOutcome = nil
        }

        self.mode = .keyboard
    }

    func pasteThreadContext() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        threadContext = text
    }

    func clearThreadContext() {
        threadContext = nil
    }

    func insertCharacter(_ s: String) {
        proxyProvider()?.insertText(s)
    }

    func backspace() {
        proxyProvider()?.deleteBackward()
    }

    func back() {
        // Collective improvement: fire content-free outcome (rewriteUsed=false)
        // when leaving results without inserting.
        if case .results = mode, let outcome = pendingOutcome {
            TonoAnalytics.track(.improvementOutcome(
                riskLevel: outcome.riskLevel,
                axisSelected: nil,
                mode: outcome.mode,
                msgLenBucket: outcome.msgLenBucket,
                rewriteUsed: false,
                editAfter: false
            ))
            pendingOutcome = nil
        }
        mode = .keyboard
    }

    private static func msgLenBucket(_ text: String) -> String {
        switch text.count {
        case ..<50:   return "short"
        case ..<200:  return "medium"
        default:      return "long"
        }
    }
    func showHistory() { mode = .history }
    func globe() { advance() }
    func dismissKeyboard() { dismiss() }
}

// MARK: - Root

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    let proxyProvider: () -> UITextDocumentProxy?

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)
                .ignoresSafeArea()
                .environment(\.proxyProvider, proxyProvider)

            switch model.mode {
            case .keyboard:
                KeyboardLayout(model: model)
            case .loading:
                LoadingView()
            case .results(let analysis):
                ResultsView(model: model, analysis: analysis)
            case .reading(let analysis):
                ReadResultsView(model: model, analysis: analysis)
            case .history:
                HistoryView(model: model)
            case .noFullAccess:
                NoFullAccessView(model: model)
            case .error(let msg):
                ErrorView(model: model, message: msg)
            }
        }
    }
}

// MARK: - Keyboard layout

private struct KeyboardLayout: View {
    @ObservedObject var model: KeyboardModel

    private let rows: [[String]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"],
    ]

    var body: some View {
        VStack(spacing: 8) {
            DraftStrip(model: model)

            // B3: flag gates allocation — RecipientMemory.all() is only called inside
            // RecipientStrip.onAppear, never here, so a disabled flag = zero allocation.
            if model.isPro && FeatureFlags.isEnabled(.recipientMemory) {
                RecipientStrip(model: model)
            }

            if FeatureFlags.isEnabled(.threadContext) {
                ThreadContextStrip(model: model)
            }

            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { key in
                        Key(label: key) { model.insertCharacter(key) }
                    }
                }
            }

            HStack(spacing: 8) {
                ActionKey(label: "🌐", action: model.globe)
                    .accessibilityLabel("Switch keyboard")
                ActionKey(label: "⏱", action: model.showHistory)
                    .accessibilityLabel("Recent sessions")
                ActionKey(label: "space", action: { model.insertCharacter(" ") }, wide: true)
                    .accessibilityLabel("Space")
                ActionKey(label: "⌫", action: model.backspace)
                    .accessibilityLabel("Delete")
                ActionKey(label: "Read", action: model.runRead, accent: false)
                    .accessibilityLabel("Read received message")
                    .accessibilityHint("Interprets the tone of a message you received")
                ActionKey(label: "Coach", action: model.runCoach, accent: true)
                    .accessibilityLabel("Coach your draft")
                    .accessibilityHint("Analyzes what you typed and suggests rewrites")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }
}

private struct DraftStrip: View {
    @ObservedObject var model: KeyboardModel
    var body: some View {
        HStack {
            Text(model.draft.isEmpty ? "Type a message, then tap Coach" : model.draft)
                .lineLimit(1)
                .foregroundColor(model.draft.isEmpty ? .secondary : .primary)
                .font(.system(size: 14, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { model.loadDraft() }
    }
}

private struct ThreadContextStrip: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(model.threadContext == nil ? .secondary : .purple)
            if let ctx = model.threadContext {
                Text(ctx)
                    .lineLimit(1)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
                Spacer()
                Button(action: model.clearThreadContext) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("Paste thread for context")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Paste", action: model.pasteThreadContext)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.purple)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct RecipientStrip: View {
    @ObservedObject var model: KeyboardModel
    @State private var recipients: [Recipient] = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(recipients) { r in
                    let selected = model.selectedRecipient?.id == r.id
                    Button {
                        model.selectedRecipient = selected ? nil : r
                    } label: {
                        Text(r.label)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(selected ? .white : .white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(selected ? Color.purple : Color.white.opacity(0.08))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 28)
        .onAppear { recipients = RecipientMemory.all() }
    }
}

private struct Key: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.white.opacity(0.10))
                .foregroundColor(.primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct ActionKey: View {
    let label: String
    let action: () -> Void
    var wide: Bool = false
    var accent: Bool = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .frame(maxWidth: wide ? .infinity : 52, minHeight: 38)
                .background(accent ? Color.accentColor : Color.white.opacity(0.10))
                .foregroundColor(accent ? .black : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Loading / error views

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Reading your draft…")
                .foregroundColor(.secondary)
                .font(.system(size: 14, design: .rounded))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ErrorView: View {
    @ObservedObject var model: KeyboardModel
    let message: String

    private var isDailyLimit: Bool { message.lowercased().contains("daily free limit") }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.yellow)
            Text(message)
                .font(.system(size: 14, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .foregroundColor(.white)
            if isDailyLimit {
                VStack(spacing: 6) {
                    Text("\(model.usedToday) of \(model.dailyLimit) rewrites used today")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                    Text("Tono can remember how you talk to each person and get better every time. Unlock the full coach.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            }
            Button("Back") { model.back() }
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results view

private struct ResultsView: View {
    @ObservedObject var model: KeyboardModel
    let analysis: ToneAnalysis

    // StyleMemory re-ranking is a Pro feature: free users get default axis order.
    private var sortedSuggestions: [RewriteSuggestion] {
        guard model.isPro, FeatureFlags.isEnabled(.memoryInference) else {
            return analysis.suggestions
        }
        let rid = model.selectedRecipient?.id
        let orderedAxes = StyleMemory.sorted(analysis.suggestions.map(\.axis), recipientId: rid)
        var result = orderedAxes.compactMap { axis in
            analysis.suggestions.first { $0.axis == axis }
        }
        // Honor per-recipient safer preference — always surface it first.
        if model.selectedRecipient?.preferSafer == true,
           let idx = result.firstIndex(where: { $0.axis == .safer }), idx > 0 {
            result.insert(result.remove(at: idx), at: 0)
        }
        return result
    }

    // Non-nil when StyleMemory changed the suggestion order.
    private var styleMemoryHint: String? {
        guard model.isPro, FeatureFlags.isEnabled(.memoryInference) else { return nil }
        let original = analysis.suggestions.map(\.axis)
        let rid      = model.selectedRecipient?.id
        let sorted   = StyleMemory.sorted(original, recipientId: rid)
        guard sorted != original || model.selectedRecipient?.preferSafer == true else { return nil }
        if let recipient = model.selectedRecipient,
           let rid2 = rid, StyleMemory.meetsThreshold(recipientId: rid2) {
            let topAxis = sorted.first?.displayName ?? "this style"
            return "For \(recipient.label) · \(topAxis) first"
        }
        return "Ranked for your style"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    RiskBadge(level: analysis.riskLevel, reason: analysis.reason)
                    if model.isRefinementLoading {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .tint(.secondary)
                            Text("Refining…")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button(action: model.back) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Dismiss results")
                }

                if let reason = analysis.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                }

                Text(analysis.perception)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundColor(.white)

                if !analysis.flags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
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
                }

                Divider().background(Color.white.opacity(0.15))

                if let hint = styleMemoryHint {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text(hint)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.purple.opacity(0.85))
                }

                ForEach(sortedSuggestions) { s in
                    RewriteChip(suggestion: s, currentRisk: analysis.riskLevel) {
                        model.insertRewrite(suggestion: s, analysis: analysis)
                    }
                    .opacity(model.isRefinementLoading ? 0.45 : 1.0)
                    .allowsHitTesting(!model.isRefinementLoading)
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Read results view

private struct ReadResultsView: View {
    @ObservedObject var model: KeyboardModel
    let analysis: ToneAnalysis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Reading", systemImage: "eye")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(action: model.back) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    RiskBadge(level: analysis.riskLevel, reason: analysis.reason)
                    Spacer()
                }

                if let reason = analysis.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.secondary)
                }

                Text(analysis.perception)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundColor(.white)

                if !analysis.subtext.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(analysis.subtext)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }

                if !analysis.flags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
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
                }
            }
            .padding(14)
        }
    }
}

private struct RiskBadge: View {
    let level: RiskLevel
    var reason: String? = nil

    var color: Color {
        switch level {
        case .low:    return .green
        case .medium: return Color(red: 1.0, green: 0.7, blue: 0.0) // amber, more distinct than pure yellow
        case .high:   return .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // A5: icon paired with color so colorblind users get two signals.
            Image(systemName: level.systemIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
            Text(level.displayName)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.20))
        .clipShape(Capsule())
        // A5: VoiceOver announces level name + reason together.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([level.displayName, reason].compactMap { $0 }.joined(separator: ". "))
    }
}

private struct RewriteChip: View {
    let suggestion: RewriteSuggestion
    let currentRisk: RiskLevel
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: suggestion.axis.glyph)
                        .font(.system(size: 12))
                    Text(suggestion.axis.displayName)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                    Spacer()
                    if FeatureFlags.isEnabled(.riskDelta), let after = suggestion.riskAfter,
                       after != currentRisk {
                        RiskDeltaBadge(from: currentRisk, to: after)
                    }
                    Text("Tap to insert")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                }
                Text(suggestion.text)
                    .font(.system(.callout, design: .rounded))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let r = suggestion.rationale {
                    Text(r)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // C3: usage condition — converts chip from synonym-machine to coach.
                Text(suggestion.axis.bestWhen)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // A5: VoiceOver reads axis name + full rewrite text + tap action.
        .accessibilityLabel("\(suggestion.axis.displayName) rewrite. \(suggestion.text)")
        .accessibilityHint("Tap to insert. \(suggestion.axis.bestWhen).")
    }
}

private struct RiskDeltaBadge: View {
    let from: RiskLevel
    let to: RiskLevel

    private func color(_ level: RiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }

    private var improved: Bool {
        let order: [RiskLevel: Int] = [.low: 0, .medium: 1, .high: 2]
        return (order[to] ?? 1) < (order[from] ?? 1)
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color(from)).frame(width: 6, height: 6)
            Image(systemName: improved ? "arrow.down" : "arrow.up")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(improved ? .green : .orange)
            Circle().fill(color(to)).frame(width: 6, height: 6)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - No Full Access view

private struct NoFullAccessView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundColor(.yellow)
            Text("Full Access required")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Text("Settings → General → Keyboard → Keyboards → Tono → Allow Full Access")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button("Back") { model.back() }
                .foregroundColor(.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - History view

private struct HistoryView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        let entries = DraftHistory.all()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Button("Done") { model.back() }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.purple)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if entries.isEmpty {
                Text("No history yet — tap Coach to analyze your first message.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.draft)
                                    .lineLimit(1)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(.white)
                                Text(entry.analysis.perception)
                                    .lineLimit(1)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture {
                                model.mode = .results(entry.analysis)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
