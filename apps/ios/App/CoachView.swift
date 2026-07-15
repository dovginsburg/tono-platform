// CoachView.swift
// Tono v0 single-screen "Coach this" flow.
// Replaces the keyboard-extension-first onboarding home with the simplest
// possible demo: paste text → tap Coach → see rewrite.
//
// Wire shape (already verified end-to-end against api.tonoit.com):
//   POST /v1/register   → {device_id, api_token, ...}
//   POST /api/analyze   (Bearer <api_token>) → TonoAnalysisResponse
//     → uses suggestions[0].text as the default rewrite.
//
// The host app's TextEditor uses the system keyboard (Apple/Hebrew/etc.),
// not Tono's keyboard extension — the keyboard extension is no longer
// embedded in this build (see Tono.xcodeproj changes) and is not
// installed as a third-party keyboard on the device.

import SwiftUI

struct CoachView: View {
    @State private var prefs = TonePreferences()

    @State private var draft: String = ""
    @State private var loading: Bool = false

    // Analysis results.
    @State private var analysis: TonoAnalysisResponse?
    @State private var errorMessage: String?

    // Usage + connection state (mirrors what SettingsView shows).
    @State private var usage: TonoUsage?

    // Pick which suggestion to feature first. Warmer is the default — it's
    // almost always safe, kind, and the closest match to "what would you
    // actually send". The user can switch to the other axes via chips.
    @State private var selectedAxis: RewriteAxis = .warmer

    // True after we've made at least one Coach call this session.
    @State private var hasCoachedOnce: Bool = false

    // One-time onboarding card flag. When the user lands on Coach for the
    // first time and hasn't registered yet, we show a brief explainer card
    // instead of the bare "unavailable" path. Dismissed once, then stored
    // in defaults — survives reinstalls only via UserDefaults (best-effort).
    @AppStorage("coach.explainerDismissed") private var explainerDismissed: Bool = false
    @State private var showExplainer: Bool = false

    // Whether /v1/register has ever succeeded this install.
    @State private var hasRegistered: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    draftEditor
                    coachButton
                    if let err = errorMessage {
                        errorBanner(err)
                    }
                    if let a = analysis {
                        resultsCard(a)
                    } else if !hasCoachedOnce && !loading {
                        emptyState
                    }
                    Spacer(minLength: 20)
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Coach this")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(prefs: $prefs)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .overlay {
            if showExplainer {
                ZStack {
                    Color.black.opacity(0.75).ignoresSafeArea()
                    explainerOverlay
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showExplainer)
        .task {
            await bootstrap()
            // Onboarding polish: first time the user sees Coach without a
            // registered backend, surface the one-time "How Coach works"
            // card. After registration completes (or the user dismisses)
            // we never show it again.
            await MainActor.run {
                if !hasRegistered && !explainerDismissed {
                    showExplainer = true
                }
            }
        }
    }

    // MARK: - Sub-views

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste a message. Get a coach.")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Tono rewrites your draft warmer, clearer, funnier, or safer — so it lands how you intend.")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Draft")
                .font(.caption).foregroundColor(.white.opacity(0.6))
            TextEditor(text: $draft)
                .frame(minHeight: 120)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
                .tint(.purple)
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("e.g. \"hey can u send me the file tmrw thanks\"")
                            .foregroundColor(.white.opacity(0.35))
                            .font(.system(size: 15, design: .rounded))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var coachButton: some View {
        Button(action: { Task { await runCoach() } }) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().tint(.white)
                }
                Image(systemName: loading ? "hourglass" : "sparkles")
                Text(loading ? "Coaching…" : "Coach")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? Color.purple : Color.purple.opacity(0.35))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canSubmit)
    }

    private var canSubmit: Bool {
        !loading && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                Text("How it works")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.7))
            Text("1. Type or paste a draft above.\n2. Tap Coach.\n3. Read the rewrite, copy it, send it.")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text(message)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.red.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func resultsCard(_ a: TonoAnalysisResponse) -> some View {
        let mapped: [RewriteSuggestion] = a.suggestions.compactMap { s in
            guard let axis = RewriteAxis(rawValue: s.axis) else { return nil }
            return RewriteSuggestion(
                axis: axis,
                text: s.text,
                rationale: s.rationale,
                riskAfter: s.riskAfter.flatMap { RiskLevel(rawValue: $0) }
            )
        }
        let featured = mapped.first(where: { $0.axis == selectedAxis }) ?? mapped.first
        let parsedRisk: RiskLevel = RiskLevel(rawValue: a.riskLevel) ?? .medium

        VStack(alignment: .leading, spacing: 14) {
            // Risk + perception summary
            HStack(alignment: .top, spacing: 10) {
                riskBadge(for: parsedRisk)
                VStack(alignment: .leading, spacing: 4) {
                    Text(parsedRisk.displayName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    if !a.perception.isEmpty {
                        Text(a.perception)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }

            // Axis chips (filter suggestions by axis).
            if !mapped.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RewriteAxis.allCases) { axis in
                            let hasSuggestion = mapped.contains(where: { $0.axis == axis })
                            Button {
                                selectedAxis = axis
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: axis.glyph)
                                    Text(axis.displayName)
                                }
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedAxis == axis ? Color.purple : Color.white.opacity(hasSuggestion ? 0.10 : 0.04))
                                .foregroundColor(hasSuggestion ? .white : .white.opacity(0.35))
                                .clipShape(Capsule())
                            }
                            .disabled(!hasSuggestion)
                        }
                    }
                }
            }

            // Featured rewrite card.
            if let s = featured {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: s.axis.glyph)
                        Text("\(s.axis.displayName) rewrite")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Text(s.text)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let rationale = s.rationale, !rationale.isEmpty {
                        Text(rationale)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = s.text
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.10))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                        }
                        if let after = s.riskAfter {
                            Label(after.displayName, systemImage: after.systemIcon)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if !mapped.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                VStack(alignment: .leading, spacing: 8) {
                    Text("All rewrites")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                    ForEach(mapped) { s in
                        rewriteRow(s)
                    }
                }
            }

            // Footer with usage.
            if let u = usage {
                HStack {
                    Image(systemName: u.isPro ? "checkmark.seal.fill" : "circle.dotted")
                        .foregroundColor(u.isPro ? .green : .white.opacity(0.5))
                    Text(u.isPro ? "Pro · unlimited" : "Subscribe for unlimited rewrites")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func rewriteRow(_ s: RewriteSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: s.axis.glyph)
                    .font(.system(size: 11))
                Text(s.axis.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.white.opacity(0.7))
            Text(s.text)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func riskBadge(for level: RiskLevel) -> some View {
        let tint: Color = {
            switch level {
            case .low: return .green
            case .medium: return .yellow
            case .high: return .orange
            }
        }()
        return Image(systemName: level.systemIcon)
            .font(.system(size: 22))
            .foregroundColor(tint)
    }

    // MARK: - Actions

    private func bootstrap() async {
        // Register + fetch usage in the background so the UI is ready.
        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            )
            await MainActor.run { hasRegistered = true }
            if let me = try? await TonoBackend.shared.me() {
                await MainActor.run {
                    usage = TonoUsage(
                        usedToday: me.usedToday,
                        dailyLimit: me.dailyLimit,
                        plan: me.plan,
                        isPro: me.isPro
                    )
                }
            }
        } catch {
            // Non-fatal — runCoach() will surface registration errors.
            await MainActor.run { hasRegistered = false }
        }
    }

    private func runCoach() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            loading = true
            errorMessage = nil
            analysis = nil
            hasCoachedOnce = true
        }

        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            )

            let response = try await TonoBackend.shared.analyze(
                text: trimmed,
                preferredVoice: prefs.preferredVoice,
                axes: RewriteAxis.allCases,
                recipientHint: nil,
                contextHints: nil,
                threadContext: nil,
                mode: .coach
            )

            // Pick the default featured axis: warmer if available, otherwise first.
            let preferredAxis: RewriteAxis = response.suggestions.contains(where: { $0.axis == "warmer" })
                ? .warmer
                : (RewriteAxis(rawValue: response.suggestions.first?.axis ?? "warmer") ?? .warmer)

            await MainActor.run {
                analysis = response
                selectedAxis = preferredAxis
                loading = false
            }

            // Fire-and-forget: refresh usage + record session.
            Task {
                if let me = try? await TonoBackend.shared.me() {
                    await MainActor.run {
                        usage = TonoUsage(
                            usedToday: me.usedToday,
                            dailyLimit: me.dailyLimit,
                            plan: me.plan,
                            isPro: me.isPro
                        )
                    }
                }
                NotificationManager.shared.recordCoachSession()
            }
        } catch let e as TonoBackendError {
            await MainActor.run {
                errorMessage = prettyError(e)
                loading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                loading = false
            }
        }
    }

    // MARK: - Error formatting (matches SettingsView pattern)

    private func prettyError(_ e: TonoBackendError) -> String {
        switch e {
        case .offline:
            return "No internet connection. Check Wi-Fi or cellular and try again."
        case .network(let m):
            return "Network error: \(m)"
        case .http(let code, let msg):
            let trimmed = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
            if code == 429 {
                return "Active trial or subscription required. Open Settings to continue."
            }
            return trimmed.isEmpty ? "Server error \(code)" : "Server error \(code): \(trimmed)"
        case .notRegistered:
            return "Account not set up yet. Open Settings → Account and tap ‘Set up Tono’."
        case .decoding(let m):
            return "Bad response: \(m)"
        case .tooManyDevices(let current, let max):
            return "This email is already on \(current) devices (max \(max))."
        }
    }

    // MARK: - Onboarding explainer

    /// First-time card. Shown once per install, dismissible, while the user
    /// is still on the "not yet registered" path. Replaces the bare empty
    /// state that looked like the feature was missing.
    private var explainerOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundColor(.purple)
            Text("How Coach works")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 10) {
                explainerLine(number: "1", text: "Type or paste a draft message.")
                explainerLine(number: "2", text: "Tap Coach — Tono rewrites it warmer, clearer, funnier, or safer.")
                explainerLine(number: "3", text: "Pick the rewrite that sounds like you. Copy. Send.")
            }
            .padding(.top, 4)
            Text("Tono needs a one-time setup before it can reach our server (≈2 seconds).")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button {
                    explainerDismissed = true
                    showExplainer = false
                    // Pre-populate a friendly sample so the editor isn't
                    // blank. Users can clear it instantly.
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        draft = "hey, can we push to friday? thx"
                    }
                } label: {
                    Text("Got it")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                Button("Skip for now") {
                    explainerDismissed = true
                    showExplainer = false
                }
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: 340)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }

    private func explainerLine(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.purple)
                .frame(width: 22, height: 22)
                .background(Color.purple.opacity(0.18))
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    CoachView()
        .preferredColorScheme(.dark)
}
