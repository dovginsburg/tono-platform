// KeyboardRootView.swift
// SwiftUI body for the keyboard extension.
//
// Modes:
//  .keyboard             — standard QWERTY-ish layout with Coach + Read + History buttons
//  .loading              — spinner while the backend call is in flight
//  .results              — risk badge + 4 rewrite chips (Coach mode)
//  .reading              — risk badge + interpretation (Read mode, no rewrites)
//  .history              — last 5 coach sessions (tap to re-open any result)
//  .noFullAccess         — prompt to enable Full Access in Settings
//                          (reached only after user attempts Coach without Full Access)
//  .fullAccessOnboarding — first-launch friendly intro shown before any tap,
//                          explains why Tono asks for Full Access
//  .coachPrompt          — confirmation sheet "Coach this draft?" triggered
//                          by long-pressing the return key. Cancel/Coach.
//  .error                — inline error with back button
//
// NEW additions for Tono keyboard rewrite:
//  - SuggestionStripView — three inline word suggestions above the keys,
//                          computed from the current draft prefix + a small
//                          on-device bigram vocabulary. Tap inserts the
//                          predicted word into the host text field.
//  - ReturnKey long-press — long-press the return (newline) key to invoke
//                          Coach on the current draft without leaving the
//                          keyboard or hunting for the Coach button.

import SwiftUI

enum KeyboardMode: Equatable {
    case keyboard
    case loading
    case results(ToneAnalysis)
    case reading(ToneAnalysis)
    case history
    case noFullAccess
    case fullAccessOnboarding
    case coachPrompt
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

/// Keyboard layout + shift state, lifted from the
/// `dovginsburg/Tono-/claude/tono-globalization-rzoqc7` scaffold's
/// `KeyboardRootView.swift` so v28 (which shipped without caps-lock,
/// 123/ABC layer, or auto-cap) matches Tono Android's
/// `TonoInputMethodService` behavior. See kanban t_32ab0bb0.
enum KeyboardLayoutMode { case letters, symbols }
enum ShiftState { case none, shiftOnce, capsLock }

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
    @Published var layoutMode: KeyboardLayoutMode = .letters
    @Published var shiftState: ShiftState = .none

    /// Timestamp of the most recent shift-key tap, used to detect
    /// double-tap-to-caps-lock. Mirrors the scaffold's pattern.
    private var lastShiftTapAt = Date.distantPast

    /// Inline suggestion strip (3 words). Recomputed whenever `draft` changes.
    /// Computed off the main thread by `SuggestionEngine`; this array is
    /// what the SwiftUI strip renders. Empty when there are no useful
    /// completions.
    @Published var suggestions: [String] = []

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
        recomputeSuggestions()
    }

    /// Long-press on the return key: load the draft and pop the Coach prompt.
    /// We deliberately run through `requestCoach()` rather than `runCoach()`
    /// directly so the user always gets a confirmation step — a long-press on
    /// the return key is an exploratory gesture and should not silently burn
    /// a /v1/coach call against their daily quota.
    func requestCoach() {
        loadDraft()
        guard !draft.isEmpty else {
            mode = .error("Type something first.")
            return
        }
        if !hasFullAccess {
            mode = .noFullAccess
            return
        }
        TonoAnalytics.track(.coachRequested(mode: "longpress_return"))
        CrashReporter.addBreadcrumb("Coach long-press requested")
        mode = .coachPrompt
    }

    /// User confirmed the long-press Coach prompt — runs the actual analyze.
    func confirmCoachFromPrompt() {
        mode = .keyboard
        runCoach()
    }

    /// User cancelled the long-press Coach prompt.
    func cancelCoachPrompt() {
        mode = .keyboard
    }

    /// User dismissed the first-launch Full Access onboarding card.
    /// We never auto-block the keyboard based on Full Access — the user can
    /// still type without it. The only gated action is Coach.
    func fullAccessOnboardingDismissed() {
        SharedStore.defaults.set(true, forKey: SharedKeys.fullAccessExplained)
        mode = .keyboard
    }

    /// Recompute the inline suggestion strip from the current draft.
    /// Runs synchronously (the vocab is small and the operation is O(prefix)).
    /// Stays in the model rather than the SwiftUI view so the strip updates
    /// immediately even when the user is in the middle of a Coach flow.
    func recomputeSuggestions() {
        suggestions = SuggestionEngine.suggestions(for: draft, count: 3)
    }

    /// Insert a suggestion chip's text into the host text field.
    /// Only the *tail* (characters not already typed) is appended so the
    /// user's in-progress word is replaced, not doubled.
    func insertSuggestion(_ word: String) {
        guard let proxy = proxyProvider() else { return }
        // Find the in-progress word boundary in the proxy's text-before-input.
        let before = proxy.documentContextBeforeInput ?? ""
        let prefix = before.lastWord()
        let tail: String
        if !prefix.isEmpty,
           word.lowercased().hasPrefix(prefix.lowercased()),
           word.count > prefix.count {
            tail = String(word.dropFirst(prefix.count))
        } else {
            tail = word
        }
        proxy.insertText(tail + " ")
        // Refresh draft from proxy and recompute suggestions.
        loadDraft()
        TonoAnalytics.track(.suggestionTapped)
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
        StyleMemory.rememberRewrite(text: suggestion.text)
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
        // Letter insertion honors shift state: a lowercase key produces an
        // uppercase letter when shift is engaged, and `shiftOnce` collapses
        // back to `.none` after the single character is typed — except in
        // caps-lock mode where it persists. Symbols and whitespace insert
        // verbatim. This mirrors the scaffold's `commitLetter` so users on
        // iOS get the same shift/caps behavior as Tono Android.
        let isLetter = s.count == 1 && s.first?.isLetter == true
        if isLetter, layoutMode == .letters {
            let cased = (shiftState == .none) ? s.lowercased() : s.uppercased()
            proxyProvider()?.insertText(cased)
            if shiftState == .shiftOnce {
                shiftState = .none
            }
            // Keep suggestions in sync with typing. Cheap; runs in <1ms.
            loadDraft()
            return
        }
        proxyProvider()?.insertText(s)
        // Keep suggestions in sync with typing. Cheap; runs in <1ms.
        loadDraft()
    }

    /// Toggle the keyboard between letters and the 123/symbols layer.
    /// Layout-mode flip does NOT touch shift state: returning to letters
    /// from symbols should preserve the user's caps-lock intent, not
    /// silently flip to lowercase.
    func toggleLayoutMode() {
        layoutMode = layoutMode == .letters ? .symbols : .letters
    }

    /// Shift-key tap: a single tap engages one-shot shift; a second tap
    /// within 400ms promotes it to caps-lock; another tap from caps-lock
    /// releases it. Mirrors `TonoInputMethodService.onShiftTapped` so iOS
    /// and Android stay in lockstep.
    func onShiftTapped() {
        let now = Date()
        let isDoubleTap = now.timeIntervalSince(lastShiftTapAt) < 0.4
        lastShiftTapAt = now
        switch shiftState {
        case .shiftOnce where isDoubleTap:
            shiftState = .capsLock
        case .capsLock:
            shiftState = .none
        case .none:
            shiftState = .shiftOnce
        default:
            shiftState = .none
        }
    }

    /// Sentence-start / field-start auto-capitalization: if the cursor
    /// sits at the very beginning of the field, or right after
    /// `. `/`! `/`? ` (or a newline), the next letter should come out
    /// capitalized without reaching for shift. Skipped while the user
    /// has explicitly locked caps.
    func applyAutoCapitalizationIfNeeded() {
        guard shiftState != .capsLock else { return }
        guard let proxy = proxyProvider() else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let lastTwo = String(before.suffix(2))
        let shouldCapitalize = lastTwo.isEmpty
            || lastTwo.hasSuffix("\n")
            || lastTwo.range(of: #"[.!?]\s$"#, options: .regularExpression) != nil
        shiftState = shouldCapitalize ? .shiftOnce : .none
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
            case .fullAccessOnboarding:
                FullAccessOnboardingView(model: model)
            case .coachPrompt:
                CoachPromptView(model: model)
            case .error(let msg):
                ErrorView(model: model, message: msg)
            }
        }
    }
}

// MARK: - Keyboard layout

private struct KeyboardLayout: View {
    @ObservedObject var model: KeyboardModel

    private let letterRows: [[String]] = [
        ["q","w","e","r","t","y","u","i","o","p"],
        ["a","s","d","f","g","h","j","k","l"],
        ["z","x","c","v","b","n","m"],
    ]
    private let symbolRows: [[String]] = [
        ["1","2","3","4","5","6","7","8","9","0"],
        ["-","/",":",";","(",")","$","&","@","\""],
        [".",",","?","!","'"],
    ]

    private var shiftGlyph: String {
        switch model.shiftState {
        case .none:      return "⇧"
        case .shiftOnce: return "⬆"
        case .capsLock:  return "⇪"
        }
    }

    /// Letters-mode labels are uppercase when shift is engaged; symbols-mode
    /// labels ignore shift entirely (they're already display-form).
    private func display(_ key: String) -> String {
        guard model.layoutMode == .letters, key.count == 1, key.first?.isLetter == true else {
            return key
        }
        return model.shiftState == .none ? key : key.uppercased()
    }

    private var rows: [[String]] { model.layoutMode == .letters ? letterRows : symbolRows }
    private var isLettersMode: Bool { model.layoutMode == .letters }

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

            // Inline 3-word suggestion strip — Tono's first keyboard identity
            // surface. Tap a chip to insert (replaces in-progress word).
            SuggestionStripView(model: model)

            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 6) {
                    // Bottom letter row gets a shift key on the left so the
                    // user can flip to uppercase / caps-lock from anywhere
                    // on the keyboard; the symbol layer skips it.
                    if r == rows.count - 1, isLettersMode {
                        ActionKey(label: shiftGlyph, action: model.onShiftTapped)
                            .accessibilityLabel(accessibilityShiftLabel())
                    }
                    ForEach(rows[r], id: \.self) { key in
                        Key(label: display(key)) { model.insertCharacter(key) }
                    }
                    // Pad the right side of the bottom letter row so the
                    // shift key balances the row's visual weight.
                    if r == rows.count - 1, isLettersMode {
                        ActionKey(label: "  ", action: {})
                            .disabled(true)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
                }
            }

            HStack(spacing: 8) {
                // 123/ABC layer toggle — letters ↔ symbols.
                ActionKey(
                    label: isLettersMode ? "123" : "ABC",
                    action: model.toggleLayoutMode
                )
                .accessibilityLabel(isLettersMode ? "Numbers and symbols" : "Letters")
                ActionKey(label: "🌐", action: model.globe)
                    .accessibilityLabel("Switch keyboard")
                ActionKey(label: "⏱", action: model.showHistory)
                    .accessibilityLabel("Recent sessions")
                ActionKey(label: "space", action: { model.insertCharacter(" ") }, wide: true)
                    .accessibilityLabel("Space")
                ActionKey(label: "⌫", action: model.backspace)
                    .accessibilityLabel("Delete")
                // Return key: tap = newline, long-press (≥0.5s) = open Coach prompt.
                ReturnKey(
                    label: "return",
                    insertOnTap: { model.insertCharacter("\n") },
                    longPress: model.requestCoach
                )
                // Coach button remains for users who prefer the explicit affordance.
                ActionKey(label: "Coach", action: model.runCoach, accent: true)
                    .accessibilityLabel("Coach your draft")
                    .accessibilityHint("Analyzes what you typed and suggests rewrites")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func accessibilityShiftLabel() -> String {
        switch model.shiftState {
        case .none:      return "Shift"
        case .shiftOnce: return "Shift on, one capital letter"
        case .capsLock:  return "Caps lock on, tap to release"
        }
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

// MARK: - Inline suggestion engine
//
// A small, offline word-prediction engine. The goal is not to rival Apple's
// QuickType — it's to give Tono's keyboard identity before Apple pulls
// Real-time suggestions out of the sandbox. Order of preference:
//   1. StyleMemory's recent rewrite vocabulary (Pro users, never persisted).
//   2. The user's own DraftHistory stems (last 50 entries, offline-safe).
//   3. A baked-in bigram-frequency table for English text messaging.
//
// All returned words respect the prefix filter (case-insensitive). The
// vocabulary is intentionally conservative — we'd rather show nothing than
// something wrong while the keyboard is a draft surface.

enum SuggestionEngine {
    private static let bakedVocab: [String: [String]] = {
        // Compact message-style bigrams (hand-curated for tone coaching; not
        // trying to be linguistically complete). Values are themselves
        // frequency-ranked arrays so the first match wins for that prefix.
        let raw: [String: [String]] = [
            // greetings / closings
            "h": ["hey", "hi", "hope", "how", "had", "have", "happy", "here"],
            "hey": ["hey!", "hey,", "hey there"],
            "hi": ["hi!", "hiya", "hi there"],
            "th": ["the", "thanks", "that", "this", "they", "them", "there", "think", "thought", "thing"],
            "thanks": ["thanks!", "thanks for", "thanks so much", "thanks again"],
            "thank": ["thank you", "thanks!", "thanks for"],
            "yo": ["you", "your", "yours"],
            "you": ["you're", "you'll", "you've", "you can", "you know"],
            // confirmations
            "ok": ["okay", "ok!", "ok so", "ok cool", "ok great"],
            "okay": ["okay!", "okay so", "okay cool"],
            "ye": ["yes", "yeah", "yep"],
            "yea": ["yeah", "yeah,"],
            "yeah": ["yeah!", "yeah,", "yeah I", "yeah no"],
            "sure": ["sure!", "sure thing", "sure,", "sure—"],
            "sounds": ["sounds good", "sounds great", "sounds like", "sounds fun"],
            // respond / replies
            "lo": ["look", "looks", "long", "lot"],
            "loo": ["look", "looking", "looped"],
            "look": ["look at", "looks like", "looking forward"],
            "i": ["I", "I'm", "I'll", "I think", "I just", "I don't", "I didn't", "I was", "I want"],
            "i ": ["I ", "I'm ", "I'll ", "I think ", "I just ", "I don't ", "I didn't "],
            "i'": ["I'm", "I'll", "I'd", "I've"],
            "i'm": ["I'm so", "I'm not", "I'm going", "I'm here", "I'm good", "I'm happy"],
            "i'l": ["I'll", "I'll be", "I'll let", "I'll try"],
            "i do": ["I don't", "I doubt"],
            "i don": ["I don't", "I don't know", "I don't think"],
            // questions
            "wh": ["what", "when", "where", "why", "which", "who"],
            "what": ["what's up", "what's", "what do you", "what time", "what do"],
            "how": ["how's", "how are", "how about", "how is", "how was", "how would"],
            "are": ["are you", "are we", "are they", "are good"],
            "are y": ["are you", "are you doing", "are you free"],
            "can": ["can you", "can we", "can I"],
            "do": ["do you", "do we", "do I"],
            // prepositions
            "wi": ["with", "will", "would", "wish"],
            "wit": ["with", "with you", "with the", "with a"],
            "fo": ["for", "forward"],
            "for": ["for you", "for the", "for a", "for me", "for sure"],
            // common verbs
            "go": ["going", "got", "gone", "good"],
            "goi": ["going", "going to", "going on"],
            "going": ["going to", "going on", "going to be"],
            "ge": ["get", "getting", "gentle"],
            "get": ["get it", "get back", "get a", "get some"],
            "ma": ["make", "may", "many", "matter"],
            "let": ["let me", "let me know", "let's", "let you"],
            "let's": ["let's do", "let's go", "let's chat"],
            "le": ["let", "left"],
            // time
            "to": ["to", "today", "tomorrow", "tonight", "too"],
            "to ": ["to ", "today ", "tomorrow ", "tonight "],
            "tod": ["today", "today!", "today's"],
            "tom": ["tomorrow", "tomorrow's"],
            "ton": ["tonight", "tonight's"],
            "ne": ["next", "never"],
            "nex": ["next", "next week", "next time"],
            // tone words Tono often rewrites
            "actually": ["actually,", "actually I", "actually we"],
            "sorry": ["sorry!", "sorry about", "sorry I", "sorry to"],
            "perha": ["perhaps", "perhaps I", "perhaps we"],
            "kind": ["kind of", "kindly"],
            // agreements / reactions
            "great": ["great!", "great to", "great,", "great work"],
            "awesome": ["awesome!", "awesome,", "awesome to"],
            "nice": ["nice!", "nice to", "nice work", "nice meeting"],
            "perfect": ["perfect!", "perfect,", "perfect timing"],
            "love": ["love it", "love this", "love that", "love you"],
            "love i": ["love it", "love it!", "love it—"],
            "wow": ["wow!", "wow,"],
            // emotional / human words
            "fee": ["feel", "feeling"],
            "feel": ["feel like", "feel about", "feeling"],
            "happ": ["happy", "happen", "happiness"],
            "happy": ["happy to", "happy birthday", "happy with"],
            "sad": ["sad", "sadly"],
            "an": ["and", "any", "another"],
            "anx": ["anxious", "anxiety"],
            "exci": ["excited", "exciting"],
            "excited": ["excited to", "excited about", "excited!"],
            // punctuation-led closings
            "shi": ["shit", "shift"],
            "haha": ["haha", "haha!", "hahaha"],
            "lol": ["lol", "lol!", "lol,"],
            "btw": ["btw", "btw,", "btw —"],
            "fyi": ["fyi,", "fyi —"],
        ]
        return raw
    }()

    /// Returns up to `count` word suggestions for a given draft string.
    /// Empty result is meaningful: strip just hides when nothing useful exists.
    static func suggestions(for draft: String, count: Int) -> [String] {
        let prefix = draft.lastWord()
        guard !prefix.isEmpty, prefix.count >= 1 else { return [] }

        // 1. StyleMemory (if Pro) — recent rewrite vocabulary.
        var personalized: [String] = []
        if FeatureFlags.isEnabled(.memoryInference) {
            personalized = StyleMemory.recentRewrites(matching: prefix)
        }

        // 2. DraftHistory stems — what the user actually typed recently.
        let historyStems = DraftHistory.stems(matching: prefix, limit: 8)

        // 3. Built-in bigram vocab.
        let lc = prefix.lowercased()
        let canned = bakedVocab[lc] ?? bakedVocab[String(lc.prefix(2))] ?? []

        // Merge, preserving order: personalized → history → canned,
        // dedup, lowercased, prefix-filtered.
        var seen = Set<String>()
        var out: [String] = []
        for list in [personalized, historyStems, canned] {
            for w in list {
                let lower = w.lowercased()
                if seen.contains(lower) { continue }
                if !lower.hasPrefix(lc) { continue }
                if lower == lc { continue }
                seen.insert(lower)
                out.append(lower)
                if out.count >= count { return out }
            }
        }
        // If we have fewer than `count` but the prefix is at least 2 chars,
        // try the 2-char fallback too — feels worse than nothing.
        if out.count < count, lc.count >= 2 {
            let two = String(lc.prefix(2))
            if let more = bakedVocab[two] {
                for w in more where !seen.contains(w.lowercased()) {
                    let lower = w.lowercased()
                    if !lower.hasPrefix(lc) || lower == lc { continue }
                    seen.insert(lower)
                    out.append(lower)
                    if out.count >= count { return out }
                }
            }
        }
        return out
    }
}

// MARK: - String helpers

private extension String {
    /// Last whitespace-delimited token. Empty if string is whitespace/empty.
    /// Used by both the suggestion engine and the suggestion-chip inserter
    /// to figure out what the user is mid-typing.
    func lastWord() -> String {
        if let range = self.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards) {
            let token = String(self[range.upperBound...])
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Inline suggestion strip

private struct SuggestionStripView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        HStack(spacing: 6) {
            if model.suggestions.isEmpty {
                Spacer()
                Text(" ")   // keeps row at a stable height even when empty
                    .font(.system(size: 14, design: .rounded))
                Spacer()
            } else {
                ForEach(model.suggestions, id: \.self) { word in
                    Button {
                        model.insertSuggestion(word)
                    } label: {
                        Text(word)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(Color.white.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Insert \(word)")
                    .accessibilityHint("Replaces your in-progress word with \(word)")
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Return key with long-press → Coach prompt
//
// iOS keyboards don't get a real "return" key for free, so we ship our
// own. Short tap inserts a newline (matches system default); long-press
// (≥0.5s) fires `requestCoach()` which opens the SwiftUI Coach prompt.

private struct ReturnKey: View {
    let label: String
    let insertOnTap: () -> Void
    let longPress: () -> Void
    var accent: Bool = false

    @State private var didLongPress = false

    var body: some View {
        Text(label)
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(accent ? Color.accentColor : Color.white.opacity(0.18))
            .foregroundColor(accent ? .black : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Use plain gestures instead of Button — Button's tap recognizer
            // sometimes wins the race against the long-press and the
            // long-press never fires. Plain onTapGesture + simultaneous
            // LongPressGesture plays nicely together in iOS 16+.
            .onTapGesture {
                if !didLongPress {
                    insertOnTap()
                }
                didLongPress = false
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        didLongPress = true
                        longPress()
                    }
            )
            .accessibilityLabel("Return. Long press to coach your draft.")
            .accessibilityHint("Tap to insert a new line. Long press to have Tono rewrite your draft.")
    }
}

// MARK: - Coach prompt (SwiftUI confirm sheet)

private struct CoachPromptView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.purple)
                Text("Coach this?")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Button {
                    model.cancelCoachPrompt()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
                .accessibilityLabel("Cancel Coach prompt")
            }

            Text(model.draft)
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Button {
                    model.cancelCoachPrompt()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundColor(.white)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Coach")

                Button {
                    model.confirmCoachFromPrompt()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .bold))
                        Text("Coach")
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.black)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Run Coach on this draft")
            }

            Text("Uses one of your \(model.dailyLimit) daily rewrites. Cancel if you weren't sure.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - First-launch Full Access onboarding

private struct FullAccessOnboardingView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.purple)

            Text("Tono needs Full Access")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 10) {
                bullet("Reads only the message you're typing — never anything else.")
                bullet("Sends that text to Tono's coach to suggest rewrites.")
                bullet("Writes back the rewrite you pick. Nothing else.")
            }
            .padding(.horizontal, 6)

            Text("Settings → General → Keyboard → Keyboards → Tono → Allow Full Access")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .multilineTextAlignment(.center)

            Button {
                model.fullAccessOnboardingDismissed()
            } label: {
                Text("Got it")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundColor(.black)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Full Access explanation")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.green)
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
