// SettingsView.swift
// Voice + axis toggles, plan management, and consumer-safe account status.
// The paywall uses StoreKit 2 — no Stripe redirect on iOS.

import SwiftUI
import StoreKit
import UIKit

private enum SettingsServiceState: Equatable {
    case checking
    case ready
    case needsSetup
    case offline
    case unavailable

    init(error: TonoBackendError) {
        switch error {
        case .offline, .network: self = .offline
        case .notRegistered: self = .needsSetup
        default: self = .unavailable
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking Tono"
        case .ready: return "Tono is ready"
        case .needsSetup: return "Finish setting up Tono"
        case .offline: return "You're offline"
        case .unavailable: return "Tono is temporarily unavailable"
        }
    }

    var detail: String {
        switch self {
        case .checking: return "Checking whether online coaching is available."
        case .ready: return "Online coaching is available."
        case .needsSetup: return "Set up your account to use online coaching."
        case .offline: return "Connect to Wi-Fi or cellular, then try again."
        case .unavailable: return "This is on our side. Try again in a moment."
        }
    }

    var recoveryAction: String? {
        switch self {
        case .needsSetup: return "Set up Tono"
        case .offline, .unavailable: return "Try again"
        case .checking, .ready: return nil
        }
    }

    var icon: String {
        switch self {
        case .checking: return "clock"
        case .ready: return "checkmark.seal.fill"
        case .needsSetup: return "sparkles"
        case .offline: return "wifi.slash"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .checking: return .secondary
        case .ready: return .green
        case .needsSetup: return .purple
        case .offline, .unavailable: return .orange
        }
    }
}

struct SettingsView: View {
    @Binding var prefs: TonePreferences
    @ObservedObject private var store = StoreKitManager.shared

#if DEBUG
    // Internal-only runtime endpoint override.
    @AppStorage("tc.backendURL") private var customBackendURL: String = ""
#endif

    @State private var voiceField:        String     = ""
    @State private var showPaywall:       Bool       = false
    @State private var usage:             TonoUsage?
    @State private var recipients:        [Recipient] = []
    @State private var contactsAccess:    ContactsAccessSummary = .notDetermined
    @State private var promoCode:         String     = ""
    @State private var promoError:        String?
    @State private var promoSuccess:      String?
    @State private var isRedeemingCode:   Bool       = false
    @State private var featureToggles:    [FeatureFlag: Bool] = [:]
    @State private var liveToneEnabled:   Bool       = true
    @State private var serviceState:      SettingsServiceState = .checking
    @State private var accountNotice:     String?
#if DEBUG
    @State private var diagnosticHealthText: String?
#endif
    @State private var coachVariants = CoachVariantSettings()
    private let coachVariantStore = CoachVariantSettingsStore()
    // build 101 — account deletion
    @State private var showDeleteAccountSheet: Bool = false
    @State private var accountDeleted:         Bool = false
    // build 106 — on-device intelligence self-test result (nil until run)
    @State private var localSelfTestResult: LocalIntelligenceSelfTest.Result?

    // Live Tone v1 control surface (shipping release). A value type over the
    // shared App Group store — writes are visible to the keyboard on its next
    // read, with no networking, timer, or background work. Default ON per the
    // binding Live Tone v1 Acceptance Contract.
    private let liveTonePrefs = LiveTonePreference()
    @State private var isSettingUp:        Bool       = false

    var body: some View {
        NavigationStack {
            Form {
                setupSection
                accountSection
                voiceSection
                memorySection
                featurePreferencesSection
                recipientsSection
                axesSection
                liveToneSection
                localIntelligenceSection
                planSection
                privacySection
                accountManagementSection
#if DEBUG
                developerDiagnosticsSection
#endif
            }
            .navigationTitle("Settings")
            .onAppear {
                voiceField = prefs.preferredVoice ?? ""
                recipients = RecipientMemory.all()
                loadFeatureToggles()
                loadLiveTone()
                coachVariants = coachVariantStore.load()
                Task {
                    await refreshServiceState()
                    await refreshUsage()
                }
            }
            .task {
                try? await TonoBackend.shared.registerIfNeeded(
                    platform: "ios",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                )
                await store.refreshEntitlements()
                await refreshUsage()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(onDismiss: { showPaywall = false })
            }
            .sheet(isPresented: $showDeleteAccountSheet) {
                AccountDeletionView(
                    onSuccess: {
                        showDeleteAccountSheet = false
                        accountDeleted = true
                    },
                    onCancel: {
                        showDeleteAccountSheet = false
                    }
                )
            }
            .alert("Account deleted", isPresented: $accountDeleted) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your account has been permanently deleted. You can create a new account at any time.")
            }
        }
    }

    // MARK: - Sections

    /// Entry point for the Setup Doctor. Kept as a push inside the existing
    /// Settings navigation stack rather than a new tab — setup is a thing you
    /// finish once, not a destination worth permanent chrome.
    @ViewBuilder
    private var setupSection: some View {
        Section("Setup") {
            NavigationLink {
                SetupDoctorView()
            } label: {
                Label("Setup Doctor", systemImage: "stethoscope")
            }
            .accessibilityHint("Checks whether the Tono keyboard is added, has Full Access, and is working.")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: serviceState.icon)
                    .font(.title3)
                    .foregroundColor(serviceState.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(serviceState.title)
                        .font(.subheadline.weight(.semibold))
                    Text(serviceState.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)

            if let action = serviceState.recoveryAction {
                Button {
                    Task { await recoverService() }
                } label: {
                    HStack(spacing: 8) {
                        if isSettingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: serviceState == .needsSetup ? "sparkles" : "arrow.clockwise")
                        }
                        Text(isSettingUp ? "Working…" : action)
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(isSettingUp)
            }

            if let notice = accountNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if usage != nil {
                HStack {
                    Text("Plan")
                    Spacer()
                    Text(store.statusLabel).foregroundColor(.secondary)
                }
            }

            Text("Rewrites run on Tono's service. Your draft is sent only when you tap Coach, and you never need to enter a technical access key.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

#if DEBUG
    @ViewBuilder
    private var developerDiagnosticsSection: some View {
        Section {
            HStack {
                Text("Endpoint")
                Spacer()
                Text(resolvedBackendLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Custom backend URL (leave blank for default)", text: $customBackendURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))
                .onSubmit { Task { await runDiagnosticHealthCheck() } }
            HStack {
                Button("Test Connection") {
                    Task { await runDiagnosticHealthCheck() }
                }
                Spacer()
                if let raw = diagnosticHealthText {
                    Text(raw)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Text("Registered: \(TonoBackend.shared.isRegistered() ? "yes" : "no") · default https://api.tonoit.com")
                .font(.caption2).foregroundColor(.secondary)
        } header: {
            Text("Developer diagnostics (internal build)")
        }
    }

    private var resolvedBackendLabel: String {
        let trimmed = customBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return TonoBackend.shared.baseURL.absoluteString
    }

    private func runDiagnosticHealthCheck() async {
        await MainActor.run { diagnosticHealthText = "checking…" }
        do {
            let ok = try await TonoBackend.shared.health()
            await MainActor.run { diagnosticHealthText = ok ? "healthy" : "non-2xx response" }
        } catch {
            await MainActor.run { diagnosticHealthText = "\(error)" }
        }
        await refreshServiceState()
    }
#endif

    private func refreshServiceState() async {
        await MainActor.run { serviceState = .checking }
        guard TonoBackend.shared.isRegistered() else {
            await MainActor.run { serviceState = .needsSetup }
            return
        }
        do {
            let ok = try await TonoBackend.shared.health()
            await MainActor.run { serviceState = ok ? .ready : .unavailable }
        } catch let e as TonoBackendError {
            await MainActor.run { serviceState = SettingsServiceState(error: e) }
        } catch {
            await MainActor.run { serviceState = .unavailable }
        }
    }

    private func recoverService() async {
        if serviceState == .needsSetup {
            await runSetup()
        } else {
            await refreshServiceState()
            await refreshUsage()
        }
    }

    private func runSetup() async {
        await MainActor.run { isSettingUp = true }
        defer { Task { @MainActor in isSettingUp = false } }
        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            )
            await MainActor.run { accountNotice = nil }
            await refreshUsage()
            await refreshServiceState()
        } catch let e as TonoBackendError {
            await MainActor.run {
                accountNotice = consumerMessage(for: e)
                serviceState = SettingsServiceState(error: e)
            }
        } catch {
            await MainActor.run {
                accountNotice = "Setup didn't finish. Try again in a moment."
                serviceState = .unavailable
            }
        }
    }

    private func consumerMessage(for e: TonoBackendError) -> String {
        switch e {
        case .offline:
            return "You're offline. Check Wi-Fi or cellular and try again."
        case .network:
            return "Tono couldn't reach its service. Check your connection and try again."
        case .notRegistered:
            return "Finish setting up Tono to continue."
        case .decoding:
            return "Tono got an unexpected reply. Try again in a moment."
        case .tooManyDevices(let current, let max):
            return "This email is already on \(current) devices (max \(max)). Contact support@tonoit.com if you need more."
        case .http(let code, _):
            switch code {
            case 401: return "Your sign-in expired. Tap Set up Tono to refresh it."
            case 402: return "An active trial or subscription is required."
            case 429: return "Too many requests right now. Wait a minute and try again."
            default:  return "Tono is temporarily unavailable. This is on our side — try again in a moment."
            }
        }
    }

    private var voiceSection: some View {
        Section("Voice") {
            TextField("Preferred voice (e.g. direct, warm, terse)", text: $voiceField)
                .onChange(of: voiceField) { new in
                    prefs.preferredVoice = new.isEmpty ? nil : new
                    prefs.save()
                }
            Text("Passed to the model so rewrites match how you actually talk.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var memorySection: some View {
        Section("Memory") {
            NavigationLink(destination: MemoryView()) {
                HStack {
                    Label("What Tono knows about you", systemImage: "brain")
                    Spacer()
                    let count = UserMemory.allFacts().count
                    if count > 0 {
                        Text("\(count) fact\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Text("Tono learns from your rewrite choices and lets you add facts manually. These are sent as hints to personalize rewrites over time.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var featurePreferencesSection: some View {
        let controllable = FeatureFlag.allCases.filter(\.isUserControllable)
        if !controllable.isEmpty {
            Section("Preferences") {
                ForEach(controllable, id: \.rawValue) { flag in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(flag.displayName, isOn: featureBinding(flag))
                        if !flag.description.isEmpty {
                            Text(flag.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                NavigationLink(destination: DigestView()) {
                    Label("This week's tone report", systemImage: "chart.bar")
                }
            }
        }
    }

    private var recipientsSection: some View {
        let summary = RecipientsSettingsSummary(
            recipientCount: recipients.count,
            contactsAccess: contactsAccess
        )
        return Section("Recipients") {
            NavigationLink {
                RecipientsManagerView()
            } label: {
                HStack {
                    Label(summary.title, systemImage: "person.2")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(summary.detail).foregroundColor(.secondary)
                        Text(summary.accessDetail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(summary.accessibilityLabel)
                .accessibilityHint("Opens the recipients manager, where you can search, edit, import and delete.")
            }
            Text("Recipient profiles stay in Tono’s local App Group. Only a chosen recipient’s voice hint is sent with a coaching request.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear {
            recipients = RecipientMemory.all()
            contactsAccess = SystemContactsStore().authorizationStatus().summary
        }
    }

    private var axesSection: some View {
        // Build 97 — Safer is mandatory and rendered separately as
        // "Safer — Always on"; the optional toggle list lives below and is
        // bounded to exactly two enabled variants. Tapping a third when
        // two are already enabled shows exactly the spec text "Two
        // tones max" without silently replacing or auto-disabling any
        // selection.
        Group {
            Section {
                Toggle("Safer — Always on", isOn: .constant(true))
                    .disabled(true)
                    .accessibilityHint("Always generated first; cannot be turned off")
            } header: {
                Text("Required")
            } footer: {
                Text("Safer is the mandatory first stage of every Coach request.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Choose up to \(CoachVariantSettings.maximumOptionalCount)")
                    Spacer()
                    Text("\(coachVariants.selectedCount)/\(CoachVariantSettings.maximumOptionalCount)")
                        .foregroundColor(.secondary)
                        .accessibilityLabel("\(coachVariants.selectedCount) of \(CoachVariantSettings.maximumOptionalCount) selected")
                }

                ForEach(CoachOptionalVariant.allCases, id: \.self) { variant in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(variant.displayName, isOn: coachVariantBinding(variant))
                            .disabled(!coachVariants.enabled.contains(variant) && !coachVariants.canEnable(variant))
                            .accessibilityHint(coachVariantAccessibilityHint(variant))
                        if variant == .custom {
                            TextField(
                                "One instruction, up to \(CoachVariantSettings.maximumCustomLength) characters",
                                text: customInstructionBinding,
                                axis: .vertical
                            )
                            .lineLimit(2...4)
                            .textInputAutocapitalization(.sentences)
                            Text("Custom cannot override safety, privacy, entitlement, freshness, or cancellation checks.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("Optional variants")
            } footer: {
                if let hint = fourthToggleHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("build97.fourthToggleHint")
                } else {
                    Text("Clearer and Funnier are on by default. Affectionate, Professional, Concise, and Custom are off.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Spec-exact message shown when the user attempts to enable a third
    /// optional variant while two are already selected. `nil` when no
    /// such attempt is pending; otherwise the literal text "Two tones
    /// max" — the build-97 contract.
    private var fourthToggleHint: String? {
        coachVariants.pendingFourthBlocked ? "Two tones max" : nil
    }

    // MARK: - Live Tone (shipping release — Live Tone v1 contract)

    /// Master toggle (default ON per the contract). The keyboard never
    /// auto-rewrites / never blocks send; the toggle only gates whether
    /// the on-device heuristic executes. The contract-exact disclosure
    /// sits below the toggle.
    @ViewBuilder
    private var liveToneSection: some View {
        Section("Live Tone") {
            Toggle("Live Tone", isOn: liveToneEnabledBinding)
            // Exact contract disclosure — must not be paraphrased.
            Text(LiveTonePreference.settingsCopy)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var liveToneEnabledBinding: Binding<Bool> {
        Binding(
            get: { liveToneEnabled },
            set: { on in
                liveToneEnabled = on
                liveTonePrefs.setMasterEnabled(on)
            }
        )
    }

    private func loadLiveTone() {
        liveToneEnabled = liveTonePrefs.masterEnabled
    }

    private var planSection: some View {
        let isPro = store.isPro
        return Section("Plan") {
            HStack {
                Text(isPro ? "\(store.statusLabel) ✓" : store.statusLabel)
                Spacer()
                if !isPro {
                    Button(store.eligibleFreeTrialProductIDs.isEmpty ? "Subscribe" : "Start free trial") {
                        showPaywall = true
                    }
                        .buttonStyle(.borderedProminent)
                }
            }
            if isPro {
                Button("Manage subscription") {
                    Task { await openManageSubscriptions() }
                }
                .foregroundColor(.accentColor)
            }
            if !isPro {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Promo code", text: $promoCode)
                            .textInputAutocapitalization(.characters)
                            .disableAutocorrection(true)
                        Button(isRedeemingCode ? "…" : "Apply") {
                            Task { await redeemPromoCode() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            promoCode.trimmingCharacters(in: .whitespaces).isEmpty
                            || isRedeemingCode
                        )
                    }
                    if let err = promoError {
                        Text(err).font(.caption).foregroundColor(.red)
                    }
                    if let ok = promoSuccess {
                        Text(ok).font(.caption).foregroundColor(.green)
                    }
                }
            }
            Text("Unlimited rewrites, thread context, style memory, per-recipient coaching, and a weekly digest. Manage or cancel anytime in Apple ID subscriptions.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text("Tono sends your draft securely for coaching only when you ask. Drafts are not stored. Your sign-in information is protected by iOS.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - On-device intelligence (build 106)

    /// Truthful, testable copy about what runs where, plus a self-test that
    /// exercises the REAL shipping resolver, checker and ranker.
    ///
    /// Build 105 shipped no statement of this at all, which is why "offline
    /// mode did not visibly utilize local intelligence" was a fair reading of
    /// the product even where the local lane was working.
    private var localIntelligenceSection: some View {
        Section("On-device intelligence") {
            Text(LocalIntelligenceCopy.offlineCapabilitySummary)
                .font(.caption).foregroundColor(.secondary)
            Text(LocalIntelligenceCopy.onlineRequirementSummary)
                .font(.caption).foregroundColor(.secondary)
            Text(LocalIntelligenceCopy.localModelDisclosure)
                .font(.caption).foregroundColor(.secondary)
                .accessibilityIdentifier("Tono.localModelDisclosure")

            Button("Check on-device intelligence") {
                localSelfTestResult = LocalIntelligenceSelfTest.run(
                    language: Locale.current.identifier,
                    availableLanguages: UITextChecker.availableLanguages,
                    checker: SystemSpellingChecker(),
                    lexicon: .empty
                )
            }
            .accessibilityIdentifier("Tono.runLocalSelfTest")

            if let result = localSelfTestResult {
                Label {
                    Text(result.summary).font(.caption)
                } icon: {
                    Image(systemName: result.isPass ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(result.isPass ? .green : .orange)
                }
                .accessibilityIdentifier("Tono.localSelfTestResult")

                if case .pass(let checks) = result {
                    ForEach(checks, id: \.name) { check in
                        Text("\(check.name): \(check.detail)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                } else if case .fail(let checks) = result {
                    ForEach(checks, id: \.name) { check in
                        Text("\(check.passed ? "OK" : "FAILED") — \(check.name): \(check.detail)")
                            .font(.caption2)
                            .foregroundColor(check.passed ? .secondary : .orange)
                    }
                }
            }
        }
    }

    // MARK: - Account management (build 101)

    @ViewBuilder
    private var accountManagementSection: some View {
        if TonoBackend.shared.isRegistered() {
            Section("Account Management") {
                Button("Delete account", role: .destructive) {
                    showDeleteAccountSheet = true
                }
                Text("Permanently removes your account and all data saved with it. Any active subscription must be cancelled separately in Apple ID settings. This cannot be undone.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func loadFeatureToggles() {
        for flag in FeatureFlag.allCases where flag.isUserControllable {
            featureToggles[flag] = FeatureFlags.isEnabled(flag)
        }
    }

    private func featureBinding(_ flag: FeatureFlag) -> Binding<Bool> {
        Binding(
            get: { featureToggles[flag] ?? FeatureFlags.isEnabled(flag) },
            set: { enabled in
                featureToggles[flag] = enabled
                FeatureFlags.setUserPreference(flag, enabled: enabled)
                if flag == .weeklyDigest {
                    if enabled {
                        NotificationManager.shared.scheduleWeeklyDigest()
                    } else {
                        NotificationManager.shared.cancelWeeklyDigest()
                    }
                }
            }
        )
    }

    private func coachVariantBinding(_ variant: CoachOptionalVariant) -> Binding<Bool> {
        Binding(
            get: { coachVariants.enabled.contains(variant) },
            set: { enabled in
                guard coachVariants.set(variant, enabled: enabled) else { return }
                coachVariantStore.save(coachVariants)
            }
        )
    }

    private var customInstructionBinding: Binding<String> {
        Binding(
            get: { coachVariants.customInstruction },
            set: { text in
                coachVariants.customInstruction = String(text.prefix(CoachVariantSettings.maximumCustomLength))
                coachVariants.pendingFourthBlocked = false
                coachVariants.normalize()
                coachVariantStore.save(coachVariants)
            }
        )
    }

    private func coachVariantAccessibilityHint(_ variant: CoachOptionalVariant) -> String {
        if coachVariants.enabled.contains(variant) { return "Double tap to deselect" }
        // Spec-exact hint when a beyond-cap optional toggle is tapped
        // while two are already selected. Surfaced both in the section
        // footer (as a visible Text) and as the per-row accessibility
        // hint so VoiceOver users hear the same message.
        if coachVariants.selectedCount >= CoachVariantSettings.maximumOptionalCount {
            return "Two tones max"
        }
        if variant == .custom && !coachVariants.isCustomInstructionValid {
            return "Enter a non-empty Custom instruction before enabling"
        }
        return "Double tap to select"
    }

    private func refreshUsage() async {
        do {
            let me = try await TonoBackend.shared.me()
            await MainActor.run {
                store.acceptBackendState(me)
                usage = TonoUsage(plan: me.plan, isPro: me.isPro)
                accountNotice = nil
            }
        } catch let e as TonoBackendError {
            await MainActor.run {
                accountNotice = consumerMessage(for: e)
            }
        } catch {
            await MainActor.run {
                accountNotice = "Tono couldn't refresh your account right now. Try again in a moment."
            }
        }
    }

    private func redeemPromoCode() async {
        let code = promoCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        isRedeemingCode = true
        promoError = nil
        promoSuccess = nil
        do {
            _ = try await TonoBackend.shared.redeemCoupon(code: code)
            promoSuccess = "Pro access activated!"
            promoCode = ""
            await store.refreshEntitlements()
            await refreshUsage()
        } catch let e as TonoBackendError {
            promoError = consumerMessage(for: e)
        } catch {
            promoError = error.localizedDescription
        }
        isRedeemingCode = false
    }

    @MainActor
    private func openManageSubscriptions() async {
        guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
        try? await AppStore.showManageSubscriptions(in: windowScene)
    }
}

// MARK: - PaywallView (StoreKit 2)

struct PaywallView: View {
    let onDismiss: () -> Void
    @ObservedObject private var store = StoreKitManager.shared
    // build 101: sign-in gate. When the user taps buy on an anonymous account,
    // the purchase is deferred until email identity is confirmed. After sign-in
    // the pending product is retried automatically.
    @State private var showSignInForPurchase: Bool = false
    @State private var pendingProduct: Product? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerSection
                    .padding(.top, 40)

                Spacer()

                productList

                Spacer()

                restoreButton

                // App Store Review Guideline 3.1.2 requires renewal disclosure
                // on the same screen as the buy button. Eligible trial terms are
                // rendered per product above from StoreKit's live offer.
                Text(
"""
Payment will be charged to your Apple ID account at confirmation of purchase. The subscription automatically renews unless it is canceled at least 24 hours before the end of the current period. Your account will be charged for renewal within 24 hours before the end of the current period.
"""
                )
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                Text("Manage subscriptions in Settings → Apple ID → Subscriptions.")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Maybe later", action: onDismiss)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .onChange(of: store.isPro) { isPro in
            if isPro { onDismiss() }
        }
        .sheet(isPresented: $showSignInForPurchase) {
            EmailSignInSheet(
                onSuccess: {
                    showSignInForPurchase = false
                    // Retry the purchase now that the account is identified.
                    if let product = pendingProduct {
                        Task { await store.purchase(product) }
                    }
                    pendingProduct = nil
                },
                onCancel: {
                    showSignInForPurchase = false
                    pendingProduct = nil
                }
            )
        }
    }

    // Initiates a purchase or routes to sign-in if the account is anonymous.
    fileprivate func initiatePurchase(_ product: Product) {
        guard store.isIdentifiedAccount else {
            pendingProduct = product
            showSignInForPurchase = true
            return
        }
        Task { await store.purchase(product) }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundColor(.purple)
            Text("Stop second-guessing what you just sent.")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("Tono remembers how you write to each person and gets better every session.")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            VStack(spacing: 6) {
                FeatureLine("Unlimited rewrites")
                FeatureLine("Thread context — paste the prior message")
                FeatureLine("Per-recipient style memory")
                FeatureLine("Weekly tone report — spot your patterns")
                FeatureLine("Memory stays on your device, you control it all")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
    }

    private var productList: some View {
        VStack(spacing: 12) {
            // build 101: anonymous accounts must sign in before purchasing so the
            // appAccountToken is a recoverable canonical UUID, not a device-only one.
            if !store.isIdentifiedAccount {
                VStack(spacing: 8) {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 28))
                        .foregroundColor(.purple)
                    Text("Sign in to subscribe")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    Text("A verified email keeps your subscription recoverable if you reinstall or switch devices.")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    Button {
                        showSignInForPurchase = true
                    } label: {
                        Text("Sign in with email")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                }
                .padding(16)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
            }
            if store.products.isEmpty && !store.isLoading {
                Text("Products unavailable. Make sure you're signed into the App Store.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            ForEach(store.products, id: \.id) { product in
                ProductRow(
                    product: product,
                    isLoading: store.isLoading,
                    isEligibleForFreeTrial: store.isEligibleForFreeTrial(product),
                    isIdentified: store.isIdentifiedAccount
                ) {
                    initiatePurchase(product)
                }
            }
            if let err = store.purchaseError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.horizontal, 24)
    }

    private var restoreButton: some View {
        Button("Restore purchases") {
            Task { await store.restorePurchases() }
        }
        .font(.system(size: 14, design: .rounded))
        .foregroundColor(.white.opacity(0.5))
        .padding(.bottom, 12)
        .disabled(store.isLoading)
    }
}

private struct FeatureLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.purple)
            Text(text)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - AddRecipientView

private struct AddRecipientView: View {
    let onSave: (Recipient) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var voiceHint = ""
    @State private var preferSafer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name or relationship") {
                    TextField("e.g. Mom, Boss, Alex", text: $label)
                }
                Section("Voice hint (optional)") {
                    TextField("e.g. prefers formal tone; no humor", text: $voiceHint)
                    Toggle("Always include safer rewrite", isOn: $preferSafer)
                }
            }
            .navigationTitle("Add Recipient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimLabel = label.trimmingCharacters(in: .whitespaces)
                        guard !trimLabel.isEmpty else { return }
                        let hint = voiceHint.trimmingCharacters(in: .whitespaces)
                        onSave(Recipient(
                            label: trimLabel,
                            voiceHint: hint.isEmpty ? nil : hint,
                            preferSafer: preferSafer
                        ))
                        dismiss()
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct ProductRow: View {
    let product:   Product
    let isLoading: Bool
    let isEligibleForFreeTrial: Bool
    // build 101: when false, the buy button tap routes to sign-in rather than
    // initiating a purchase directly. Displayed as a subtle "sign in first" label.
    let isIdentified: Bool
    let onPurchase: () -> Void

    private var isYearly: Bool { product.id.contains("yearly") }

    var body: some View {
        Button(action: onPurchase) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isYearly ? "Annual" : "Monthly")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    // Show Apple's real intro offer only when StoreKit reports
                    // this account is eligible for it.
                    introOfferLine
                }
                Spacer()
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    // Big price on the right. When intro offer is present,
                    // show the trial "$0.00" up top and the regular price below.
                    // introOffer is only available on iOS 17.2+; older OS
                    // versions just see the regular price.
                    VStack(alignment: .trailing, spacing: 0) {
                        if let intro = product.subscription?.introductoryOffer,
                           intro.paymentMode == .freeTrial,
                           isEligibleForFreeTrial {
                            Text(intro.displayPrice)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("then \(product.displayPrice)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundColor(.white.opacity(0.7))
                        } else {
                            Text(product.displayPrice)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .padding(16)
            .background(isYearly ? Color.purple : Color.white.opacity(0.08))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    /// Renders intro-offer disclosure only for an eligible StoreKit account.
    @ViewBuilder
    private var introOfferLine: some View {
        if let intro = product.subscription?.introductoryOffer,
           intro.paymentMode == .freeTrial,
           isEligibleForFreeTrial {
            // Render the intro period dynamically from the offer (Apple manages
            // the actual duration). The text below is the standard Apple boilerplate
            // per App Store guideline 3.1.2.
            Text("Free for \(intro.period.value) \(intro.period.unit.description), then auto-renews at \(product.displayPrice) unless cancelled")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } else {
            // Either no intro offer configured in ASC yet, or running on
            // iOS < 17.2 where we can't introspect the offer. Show the
            // post-trial price clearly so Apple reviewers don't flag it as
            // bait-and-switch.
            Text("Billed \(isYearly ? "yearly" : "monthly") at \(product.displayPrice), auto-renews unless cancelled")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }
}

// Extension on Product.SubscriptionPeriod.Unit for the human-readable label.
private extension Product.SubscriptionPeriod.Unit {
    var description: String {
        switch self {
        case .day:    return "day"
        case .week:   return "week"
        case .month:  return "month"
        case .year:   return "year"
        @unknown default: return "period"
        }
    }
}

// MARK: - AccountDeletionView (build 101)
//
// Two-step confirmation sheet for permanent account deletion.
//
// Step 1: Warning screen — explains consequences, requires user to type
//         "DELETE" to prove intent, then taps "Permanently delete".
// Step 2: In-progress — calls DELETE /v1/account; shows spinner.
//
// Success: purges all local secrets, resets StoreKit, calls `onSuccess`.
// Failure: shows error message with support email link. Does NOT purge.
// Re-auth: if the backend returns 401 the user is prompted to re-sign-in
//          (unusual, but possible if the session expired mid-flow).
//
// Backend endpoint definition (client contract — not yet deployed on this
// branch; URLProtocol tests in Build101RevenueTests validate the shape):
//   DELETE /v1/account
//   Authorization: Bearer <api_token>
//   → 200 {} — deleted; caller must purge local secrets
//   → 401    — session expired; show re-auth prompt
//   → 404    — already deleted (treat as success)
//   → 500    — server error; do NOT purge; surface support path
struct AccountDeletionView: View {
    let onSuccess: () -> Void
    let onCancel:  () -> Void

    @State private var confirmText:   String = ""
    @State private var isDeleting:    Bool   = false
    @State private var errorMessage:  String?
    @State private var showReAuth:    Bool   = false

    private let confirmKeyword = "DELETE"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                warningHeader
                confirmField
                if let err = errorMessage {
                    errorBanner(err)
                }
                Spacer()
                deleteButton
            }
            .padding(24)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isDeleting)
                }
            }
        }
        .sheet(isPresented: $showReAuth) {
            EmailSignInSheet(
                onSuccess: { showReAuth = false },
                onCancel:  { showReAuth = false }
            )
        }
    }

    private var warningHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("This cannot be undone", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.red)
            Text("Deleting your account permanently removes all data from Tono's servers: your style memory, recipient profiles, and usage history. Your subscription is not automatically cancelled — cancel it separately in Apple ID settings before deleting.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type \(confirmKeyword) to confirm")
                .font(.subheadline.weight(.medium))
            TextField(confirmKeyword, text: $confirmText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundColor(.red)
            if message.contains("session") || message.contains("sign in") {
                Button("Sign in again") { showReAuth = true }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.purple)
            } else {
                Link("Contact support@tonoit.com", destination: URL(string: "mailto:support@tonoit.com")!)
                    .font(.footnote)
                    .foregroundColor(.purple)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var deleteButton: some View {
        Button(action: confirmDeletion) {
            HStack {
                if isDeleting { ProgressView().tint(.white) }
                Text(isDeleting ? "Deleting…" : "Permanently delete my account")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canDelete ? Color.red : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canDelete || isDeleting)
    }

    private var canDelete: Bool {
        confirmText.trimmingCharacters(in: .whitespaces) == confirmKeyword
    }

    private func confirmDeletion() {
        guard canDelete else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            defer { isDeleting = false }
            do {
                try await TonoBackend.shared.deleteAccount()
                // Success: purge all local secrets so the app returns to
                // an unauthenticated state immediately.
                SharedKeychain.purgeAccountSecrets()
                await MainActor.run {
                    StoreKitManager.shared.resetToAnonymous()
                    TonePreferences.recordEntitlement(.notEntitled, isPro: false)
                }
                onSuccess()
            } catch let e as TonoBackendError {
                await MainActor.run {
                    switch e {
                    case .http(401, _):
                        errorMessage = "Your session expired. Sign in again and retry."
                        showReAuth = true
                    case .http(404, _):
                        // Account already deleted — treat as success.
                        SharedKeychain.purgeAccountSecrets()
                        StoreKitManager.shared.resetToAnonymous()
                        TonePreferences.recordEntitlement(.notEntitled, isPro: false)
                        onSuccess()
                    case .offline:
                        errorMessage = "You're offline. Connect to the internet and try again."
                    default:
                        errorMessage = "Account deletion failed (\(e.localizedDescription)). Your account was not deleted. Contact support@tonoit.com if this persists."
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Deletion failed: \(error.localizedDescription). Your account was not deleted."
                }
            }
        }
    }
}
