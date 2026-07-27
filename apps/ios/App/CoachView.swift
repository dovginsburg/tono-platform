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
    // Build 116 — what the app KNOWS about having a connection, observed for
    // the life of the process instead of inferred from the last request's
    // outcome. Before this, a rewrite on screen with no request in flight left
    // the surface with no connectivity input at all: turning on Airplane Mode
    // changed nothing, the Coach control stayed as available as it had looked a
    // second earlier, and finding out cost a doomed request AND the rewrite.
    //
    // Injectable so the lifecycle can be driven exactly in tests — a simulator
    // has no radio to switch off. Production always gets the shared observer.
    @ObservedObject private var connectivity: TonoConnectivity

    init(connectivity: TonoConnectivity = .shared) {
        _connectivity = ObservedObject(wrappedValue: connectivity)
    }

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
                    // Build 116 — the current fact outranks the stale one. An
                    // error sentence describes an attempt made in a network
                    // world that no longer exists; while there is no
                    // connection, the connection is the thing to say.
                    if isOffline {
                        offlineNotice
                    } else if let err = errorMessage {
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
                // Build 115 — iPad. Everything above is one authored column:
                // hero, editor, action, results. Reading and writing are a
                // single focused task, so the column stays one column at every
                // width and simply stops growing past a readable measure. On a
                // phone this is the identity (see AdaptiveLayout.swift), which
                // is why the approved iPhone screen is untouched.
                .tonoReadableColumn(.reading)
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
        // Build 116 — a failure sentence is about one attempt under one set of
        // conditions. When the conditions change, it stops being current, so it
        // goes rather than sitting under a contradicting notice. The rewrite
        // and the draft are untouched: they are the person's, not the network's.
        .onChange(of: connectivity.status) { _, _ in
            errorMessage = nil
        }
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
                .tonoFont(size: 22, weight: .bold, relativeTo: .title2)
                .foregroundColor(.white)
            Text("Tono rewrites your draft warmer, clearer, funnier, or safer — so it lands how you intend.")
                .tonoFont(size: 13, relativeTo: .footnote)
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
                            .tonoFont(size: 15, relativeTo: .subheadline)
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
                    .tonoFont(size: 17, weight: .semibold, relativeTo: .body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? Color.purple : Color.purple.opacity(0.35))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canSubmit)
        // Gated rather than inert: the control reports that it cannot act AND
        // the notice below it says why, in the same breath. VoiceOver gets the
        // reason too, because a dimmed capsule is not a sentence.
        .accessibilityLabel(isOffline ? "Coach, unavailable without a connection" : "Coach")
    }

    /// Build 116 — the app's own connectivity fact. `checking` is not offline:
    /// nothing is claimed and nothing is gated until something is known.
    private var isOffline: Bool { connectivity.isOffline }

    private var canSubmit: Bool {
        !loading
            && !isOffline
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The plain-language statement of the only fact the person needs. Two
    /// forms, because "your rewrite is still here" is true only when there is
    /// one, and a reassurance that is false is worse than none.
    ///
    /// Says nothing about how Tono works, what it talks to, or why a request
    /// would have failed — this is not a failure, it is a condition.
    private var offlineNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash")
                .foregroundColor(.white.opacity(0.7))
            Text(
                analysis == nil
                    ? "No internet connection. Check Wi-Fi or cellular to coach a draft."
                    : "No internet connection. Your rewrite is still here — check Wi-Fi or cellular to coach again."
            )
            .tonoFont(size: 13, relativeTo: .footnote)
            .foregroundColor(.white)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb")
                Text("How it works")
                    .tonoFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            }
            .foregroundColor(.white.opacity(0.7))
            Text("1. Type or paste a draft above.\n2. Tap Coach.\n3. Read the rewrite, copy it, send it.")
                .tonoFont(size: 13, relativeTo: .footnote)
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
                .tonoFont(size: 13, relativeTo: .footnote)
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
                        .tonoFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.white)
                    if !a.perception.isEmpty {
                        Text(a.perception)
                            .tonoFont(size: 13, relativeTo: .footnote)
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
                                .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
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
                            .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    Text(s.text)
                        .tonoFont(size: 17, weight: .medium, relativeTo: .body)
                        .foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let rationale = s.rationale, !rationale.isEmpty {
                        Text(rationale)
                            .tonoFont(size: 12, relativeTo: .caption)
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
                            .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.10))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                        }
                        if let after = s.riskAfter {
                            Label(after.displayName, systemImage: after.systemIcon)
                                .tonoFont(size: 12, relativeTo: .caption)
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
                        .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.white.opacity(0.6))
                    // Build 115 — iPad. These are PARALLEL alternatives, not a
                    // sequence: warmer, clearer, funnier and safer are four
                    // answers to the same draft, and comparing them is the
                    // whole point. Two columns where there is room lets a
                    // person read two side by side instead of scrolling
                    // between them. At every phone PORTRAIT width this resolves
                    // to one column and is frame-for-frame the stack it
                    // replaced; a phone in LANDSCAPE is 844–956pt wide, so it
                    // takes the capped measure and does get two columns, which
                    // is intentional and separately tested.
                    AdaptiveItemGrid(.coachAlternateRewrites) {
                        ForEach(mapped) { s in
                            rewriteRow(s)
                        }
                    }
                }
            }

            // Footer with usage.
            if let u = usage {
                HStack {
                    Image(systemName: u.isPro ? "checkmark.seal.fill" : "circle.dotted")
                        .foregroundColor(u.isPro ? .green : .white.opacity(0.5))
                    Text(u.isPro ? "Pro · unlimited" : "Subscribe for unlimited rewrites")
                        .tonoFont(size: 11, relativeTo: .caption2)
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
                    .tonoGlyphFont(size: 11, relativeTo: .caption2)
                Text(s.axis.displayName)
                    .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
            }
            .foregroundColor(.white.opacity(0.7))
            Text(s.text)
                .tonoFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        // Build 115 — iPad. Two rewrites side by side would otherwise be read
        // axis-name, axis-name, text, text. Each rewrite stays one stop.
        .accessibilityElement(children: .contain)
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
            .tonoGlyphFont(size: 22, relativeTo: .title2)
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
                    usage = TonoUsage(plan: me.plan, isPro: me.isPro)
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
        // Build 116 — Coach is an online-only action, so it is gated on the
        // connectivity the app OBSERVES, before a request is built. The
        // disabled control is the visible half of the gate; this is the half
        // that makes "zero egress" true no matter how the action is reached —
        // an accessibility activation, a hardware keyboard, a future caller.
        guard !connectivity.isOffline else { return }

        await MainActor.run {
            loading = true
            errorMessage = nil
            // Build 116 — the delivered rewrite is deliberately NOT cleared
            // here. Clearing it meant every attempt destroyed the answer the
            // person already had before it knew whether it could produce
            // another one, so the first tap after losing connection cost them
            // the rewrite they were reading. A result is replaced by a better
            // result, never by the hope of one.
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
                        usage = TonoUsage(plan: me.plan, isPro: me.isPro)
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
                errorMessage = "Something went wrong. Try again in a moment."
                loading = false
            }
        }
    }

    // MARK: - Error formatting (matches SettingsView pattern)

    /// Build 112: one short sentence about what the user can do next. The
    /// raw message a failure carries is never rendered — it named transports
    /// and status codes, which is implementation detail, not guidance.
    private func prettyError(_ e: TonoBackendError) -> String {
        switch e {
        case .offline:
            return "No internet connection. Check Wi-Fi or cellular and try again."
        case .network:
            return "Couldn't connect. Check your connection and try again."
        case .http(let code, _):
            // 402 is the server-authoritative entitlement gate; 429 is the
            // per-IP rate limit. Build 113: these two were folded into one
            // branch, so a subscriber who simply went too fast was told to buy
            // a subscription they already have. Untrue copy on the flagship
            // Coach surface, and it contradicts TonoBackend's own invariant.
            switch code {
            case 401: return "Your sign-in expired. Open Settings → Account to sign in again."
            case 402: return "An active trial or subscription is required. Open Settings to continue."
            case 429: return "Too many requests right now. Wait a minute and try again."
            default: return "Something went wrong. Try again in a moment."
            }
        case .notRegistered:
            return "Account not set up yet. Open Settings → Account and tap ‘Set up Tono’."
        case .decoding:
            return "Something went wrong. Try again in a moment."
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
                .tonoGlyphFont(size: 36, relativeTo: .largeTitle)
                .foregroundColor(.purple)
            Text("How Coach works")
                // Declared in `TonoTextStyle.coachExplainerTitle` — the app's
                // own rounded face, pinned so a blanket face change is caught
                // from the rounded direction as well as the standard one.
                .tonoFont(.coachExplainerTitle)
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 10) {
                explainerLine(number: "1", text: "Type or paste a draft message.")
                explainerLine(number: "2", text: "Tap Coach — Tono rewrites it warmer, clearer, funnier, or safer.")
                explainerLine(number: "3", text: "Pick the rewrite that sounds like you. Copy. Send.")
            }
            .padding(.top, 4)
            Text("Tono finishes a one-time setup before your first rewrite (about 2 seconds).")
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
                        .tonoFont(size: 15, weight: .semibold, relativeTo: .subheadline)
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
                .tonoFont(size: 14, relativeTo: .subheadline)
                .foregroundColor(.white.opacity(0.6))
            }
            .padding(.top, 6)
        }
        .padding(28)
        // Build 115 — iPad. A hard 340pt card is right on a phone and is the
        // "tiny island" on an iPad: the same card marooned in a 1,032pt field.
        // The compact branch returns exactly the approved 340 (and, unlike the
        // frame it replaces, still fits a 320pt iPhone SE).
        .tonoDialogWidth()
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }

    /// The numbered step badge.
    ///
    /// Its own view so it can read `dynamicTypeSize`, because a digit inside a
    /// fixed frame with `.clipShape(Circle())` over it is CUT rather than
    /// wrapped when it outgrows the frame — and the first Dynamic Type pass did
    /// exactly that, giving the digit the 2.2× text ceiling (28.6pt at the
    /// accessibility sizes) inside a hard 22pt circle. Both numbers now come
    /// from `TonoStepBadge`, which scales them together against the same text
    /// style and the same decorative ceiling, so the digit's line box stays a
    /// constant fraction of the circle at every size — and at the default size
    /// both are exactly the approved 13pt and 22pt.
    ///
    /// Deliberately not `private`: `Build115AdaptiveLayoutTests` hosts this
    /// exact view and measures its laid-out size, so the assertion is about the
    /// badge that ships rather than about a replica of it.
    struct StepBadge: View {
        let number: String
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            let diameter = TonoStepBadge.diameter(dynamicTypeSize: dynamicTypeSize)
            Text(number)
                .font(Font(TonoStepBadge.font(dynamicTypeSize: dynamicTypeSize)))
                .foregroundColor(.purple)
                .frame(width: diameter, height: diameter)
                .background(Color.purple.opacity(0.18))
                .clipShape(Circle())
        }
    }

    private func explainerLine(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            StepBadge(number: number)
            Text(text)
                .tonoFont(size: 14, relativeTo: .subheadline)
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
