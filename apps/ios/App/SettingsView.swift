// SettingsView.swift
// Voice + axis toggles, plan management, and consumer-safe account status.
// The paywall uses StoreKit 2 — no Stripe redirect on iOS.

import SwiftUI
import StoreKit
import UIKit

/// Build 112 — what Settings may say about the account.
///
/// The rejected Build 111 surface polled a service health endpoint and
/// rendered its verdict ("temporarily unavailable", "this is on our side"),
/// which is infrastructure state wearing consumer clothes. This state is
/// derived from one local, truthful fact — whether this device has finished
/// account setup — and it offers the one action a user can actually take.
private enum SettingsAccountState: Equatable {
    case ready
    case needsSetup

    var title: String {
        switch self {
        case .ready: return "Your account is set up"
        case .needsSetup: return "Finish setting up Tono"
        }
    }

    var detail: String {
        switch self {
        case .ready: return "Coach is ready whenever you are."
        case .needsSetup: return "Set up your account to start coaching drafts."
        }
    }

    var setupAction: String? {
        switch self {
        case .needsSetup: return "Set up Tono"
        case .ready: return nil
        }
    }

    var icon: String {
        switch self {
        case .ready: return "checkmark.seal.fill"
        case .needsSetup: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .needsSetup: return .purple
        }
    }
}

struct SettingsView: View {
    @Binding var prefs: TonePreferences
    @ObservedObject private var store = StoreKitManager.shared

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
    // build 115 — on-device rewriting. `localRewriteAvailability` is what the
    // model reported on this appearance, never a stored guess.
    @State private var localRewriteEnabled: Bool = false
    @State private var localRewriteAvailability: LocalRewriteAvailability = .modelNotReady
    @State private var accountState:      SettingsAccountState = .needsSetup
    @State private var accountNotice:     String?
    @State private var coachVariants = CoachVariantSettings()
    private let coachVariantStore = CoachVariantSettingsStore()
    // build 101 — account deletion
    @State private var showDeleteAccountSheet: Bool = false
    @State private var accountDeleted:         Bool = false
    // build 114 — email account. `signedInEmail` mirrors the one Keychain key
    // that means "this person proved an address"; it is read, never written,
    // here. Only `TonoBackend.signInWithEmail` writes it, and only after the
    // server confirmed the address — so Settings cannot manufacture an identity.
    @State private var signedInEmail:          String?
    @State private var showSignInSheet:        Bool = false
    @State private var isSigningOut:           Bool = false
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
                onDeviceRewritingSection
                liveToneSection
                localIntelligenceSection
                planSection
                privacySection
                accountManagementSection
            }
            // Build 115 — iPad. LAYOUT ONLY. Measured before this line, the
            // Settings form ran 992pt of a 1,032pt window: every toggle label
            // and every row of account copy stretched the width of the tablet.
            // The form keeps its own full-bleed grouped background and its rows
            // take a readable measure. No section, row, order, binding, action
            // or piece of copy is touched, and nothing about cross-device
            // identity, entitlement, purchase, restore or deletion changes.
            .tonoReadableColumn(.reading)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .onAppear {
                voiceField = prefs.preferredVoice ?? ""
                recipients = RecipientMemory.all()
                loadFeatureToggles()
                loadLiveTone()
                loadLocalRewriteState()
                coachVariants = coachVariantStore.load()
                refreshAccountState()
                refreshEmailIdentity()
                Task { await refreshUsage() }
            }
            .task {
                try? await TonoBackend.shared.registerIfNeeded(
                    platform: "ios",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                )
                await store.refreshEntitlements()
                await MainActor.run {
                    refreshAccountState()
                    refreshEmailIdentity()
                }
                await refreshUsage()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(onDismiss: { showPaywall = false })
            }
            .sheet(isPresented: $showSignInSheet) {
                EmailSignInSheet(
                    onSuccess: {
                        showSignInSheet = false
                        // A sign-in converges this device on the canonical
                        // account, so the entitlement it already owns has to be
                        // re-read here: a returning subscriber must not have to
                        // tap Restore to stop seeing the paywall.
                        Task {
                            await store.refreshEntitlements()
                            await MainActor.run {
                                refreshEmailIdentity()
                                refreshAccountState()
                            }
                            await refreshUsage()
                        }
                    },
                    onCancel: { showSignInSheet = false }
                )
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
                Image(systemName: accountState.icon)
                    .font(.title3)
                    .foregroundColor(accountState.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountState.title)
                        .font(.subheadline.weight(.semibold))
                    Text(accountState.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)

            if let action = accountState.setupAction {
                Button {
                    Task { await runSetup() }
                } label: {
                    HStack(spacing: 8) {
                        if isSettingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
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

            emailIdentityRows

            Text("Your draft is only used for coaching, and only when you tap Coach. There is nothing technical to set up.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// Build 114 — the email account, from the one place a person looks for it.
    ///
    /// Signed in, this shows WHICH address they used, because that is the fact
    /// they need when a subscription does not appear on a new device. Signed
    /// out, it explains what signing in buys them without implying that signing
    /// in is what grants Pro — a confirmed address makes a subscription
    /// recoverable; only a subscription grants access.
    ///
    /// Signing out is deliberately here and not buried in Account Management
    /// next to deletion: they are opposite actions, and a person looking to
    /// leave a shared device should never have to read a delete-everything
    /// screen to find the harmless one.
    @ViewBuilder
    private var emailIdentityRows: some View {
        if let address = signedInEmail {
            HStack {
                Text("Email")
                Spacer()
                Text(address)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)

            Button {
                Task { await signOut() }
            } label: {
                HStack(spacing: 8) {
                    if isSigningOut {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    Text(isSigningOut ? "Signing out…" : "Sign out")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(isSigningOut)
            .accessibilityHint("Signs this device out. Your account, your subscription and your saved style stay as they are.")
        } else {
            Button {
                showSignInSheet = true
            } label: {
                Label("Sign in with email", systemImage: "envelope.badge.shield.half.filled")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityHint("Creates or signs in to your account so your subscription follows you.")

            Text("Confirming an email keeps your subscription and your saved style recoverable if you reinstall or switch devices. It does not by itself unlock Pro.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Signs this device out, then re-reads the shared state the extensions
    /// also read, so the keyboard, Share sheet and Messages app stop presenting
    /// a signed-in person on the same pass rather than at their next launch.
    ///
    /// `TonoBackend.signOut()` clears the local credential whether or not the
    /// call it makes first succeeds — signing out of a shared device must not
    /// depend on a good connection — so there is no failure branch to render
    /// and nothing here can leave the device half-signed-in.
    private func signOut() async {
        await MainActor.run { isSigningOut = true }
        await TonoBackend.shared.signOut()
        await MainActor.run {
            isSigningOut = false
            accountNotice = nil
            // Signing out is not an entitlement change, but this device no
            // longer holds a credential to prove one, so the shared mirror must
            // stop claiming Pro until it registers and re-reads.
            store.resetToAnonymous()
            refreshEmailIdentity()
            refreshAccountState()
        }
    }

    private func refreshEmailIdentity() {
        let stored = SharedKeychain.get(KeychainKeys.signedInEmail)
        signedInEmail = (stored?.isEmpty ?? true) ? nil : stored
    }

    /// Local, synchronous, and truthful: has this device finished account
    /// setup? Build 112 removed the periodic service probe this used to run —
    /// a user cannot act on a health verdict, and rendering one put
    /// implementation state on a consumer screen.
    private func refreshAccountState() {
        accountState = TonoBackend.shared.isRegistered() ? .ready : .needsSetup
    }

    private func runSetup() async {
        await MainActor.run { isSettingUp = true }
        defer { Task { @MainActor in isSettingUp = false } }
        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            )
            await MainActor.run {
                accountNotice = nil
                refreshAccountState()
            }
            await refreshUsage()
        } catch let e as TonoBackendError {
            await MainActor.run {
                accountNotice = consumerMessage(for: e)
                refreshAccountState()
            }
        } catch {
            await MainActor.run {
                accountNotice = "Setup didn't finish. Try again in a moment."
                refreshAccountState()
            }
        }
    }

    /// Every failure the user can meet becomes one short sentence about what
    /// they can do next. No transport, status code, or implementation detail
    /// reaches this screen — those belong in logs.
    private func consumerMessage(for e: TonoBackendError) -> String {
        switch e {
        case .offline:
            return "You're offline. Check Wi-Fi or cellular and try again."
        case .network:
            return "Couldn't connect. Check your connection and try again."
        case .notRegistered:
            return "Finish setting up Tono to continue."
        case .decoding:
            return "Something went wrong. Try again in a moment."
        case .tooManyDevices(let current, let max):
            return "This email is already on \(current) devices (max \(max)). Contact support@tonoit.com if you need more."
        case .http(let code, _):
            switch code {
            case 401: return "Your sign-in expired. Tap Set up Tono to sign in again."
            case 402: return "An active trial or subscription is required."
            case 429: return "Too many tries right now. Wait a minute and try again."
            default:  return "Something went wrong. Try again in a moment."
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
            Text("Rewrites follow this so they sound like how you actually talk.")
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
            Text("Tono learns from your rewrite choices and lets you add facts manually. They personalize your rewrites over time.")
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
            Text("Recipient profiles stay on this device. Only a chosen recipient’s voice hint is used when you coach a draft.")
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

    // MARK: - Build 115 · on-device rewriting
    //
    // Its own section rather than a row in `featurePreferencesSection`, because
    // it is not a `FeatureFlag`. The generic section writes through
    // `FeatureFlags.setUserPreference`, whose value lives in the same cached
    // dictionary that `FeatureFlags.update(from:)` replaces wholesale on every
    // `/v1/features` fetch — so a preference stored there lasts until the next
    // feature refresh. This one is a privacy choice and has to outlive that, so
    // it is persisted on its own key by `LocalRewritePreferenceStore`.
    //
    // The row states what is TRUE of this device, not what would be true of a
    // supported one: on hardware that cannot run Apple Intelligence the toggle
    // is disabled and the caption says which condition is unmet.
    @ViewBuilder
    private var onDeviceRewritingSection: some View {
        Section("On-device rewriting") {
            Toggle("Rewrite on this iPhone", isOn: localRewriteBinding)
                .disabled(!localRewriteAvailability.isAvailable)
            Text(localRewriteCaption)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var localRewriteCaption: String {
        guard localRewriteAvailability.isAvailable else {
            return LocalCoachCopy.sentence(
                for: LocalCoachUnavailableReason(availability: localRewriteAvailability)
            )
        }
        return localRewriteEnabled
            ? "Coach writes your rewrites here, with no connection and nothing sent anywhere. Turn this off to have Tono do it instead."
            : "Coach asks Tono for your rewrites. Turn this on to have them written here instead, with no connection needed."
    }

    private var localRewriteBinding: Binding<Bool> {
        Binding(
            get: { localRewriteEnabled },
            set: { on in
                localRewriteEnabled = on
                LocalRewritePreferenceStore().setEnabled(on)
            }
        )
    }

    /// Ask the model itself, once per appearance. The switch must reflect the
    /// device as it is now — somebody who just enabled Apple Intelligence in
    /// iOS Settings should find this row live when they come back.
    private func loadLocalRewriteState() {
        let preference = LocalRewritePreferenceStore().load()
        Task {
            let availability = await AppleRewriteBridge.shared.availability(locale: Locale.current)
            await MainActor.run {
                localRewriteAvailability = availability
                localRewriteEnabled = preference.resolved(availability: availability)
            }
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
                accountNotice = "Couldn't refresh your account right now. Try again in a moment."
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
            promoError = "That code couldn't be applied. Check it and try again."
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
            // Build 115 — iPad. LAYOUT ONLY. Measured at 984pt of a 1,032pt
            // window before this line. A paywall is a decision surface, not a
            // reading surface — a headline, five feature lines and two product
            // rows — so it takes the narrower FORM measure and the product rows
            // stop being 1,000pt bars. The black field stays full-bleed behind
            // it. `initiatePurchase`, the sign-in gate, the eligibility check,
            // `store.products`, restore and every renewal-disclosure sentence
            // are untouched.
            .tonoReadableColumn(.form)
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
                .tonoGlyphFont(size: 44, relativeTo: .largeTitle)
                .foregroundColor(.purple)
            Text("Stop second-guessing what you just sent.")
                .tonoFont(size: 26, weight: .bold, relativeTo: .title)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("Tono remembers how you write to each person and gets better every session.")
                .tonoFont(size: 14, relativeTo: .subheadline)
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
                        .tonoGlyphFont(size: 28, relativeTo: .title)
                        .foregroundColor(.purple)
                    Text("Sign in to subscribe")
                        .tonoFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.white)
                    Text("A verified email keeps your subscription recoverable if you reinstall or switch devices.")
                        .tonoFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    Button {
                        showSignInForPurchase = true
                    } label: {
                        Text("Sign in with email")
                            .tonoFont(size: 14, weight: .semibold, relativeTo: .subheadline)
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
        .tonoFont(size: 14, relativeTo: .subheadline)
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
                .tonoGlyphFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundColor(.purple)
            Text(text)
                .tonoFont(size: 14, relativeTo: .subheadline)
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
            .tonoReadableColumn(.form)
            .background(Color(.systemGroupedBackground))
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
                            .tonoFont(size: 16, weight: .semibold, relativeTo: .callout)
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
                                .tonoFont(size: 16, weight: .bold, relativeTo: .callout)
                                .foregroundColor(.white)
                            Text("then \(product.displayPrice)")
                                .tonoFont(size: 10, relativeTo: .caption2)
                                .foregroundColor(.white.opacity(0.7))
                        } else {
                            Text(product.displayPrice)
                                .tonoFont(size: 16, weight: .bold, relativeTo: .callout)
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
                .tonoFont(size: 11, relativeTo: .caption2)
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } else {
            // Either no intro offer configured in ASC yet, or running on
            // iOS < 17.2 where we can't introspect the offer. Show the
            // post-trial price clearly so Apple reviewers don't flag it as
            // bait-and-switch.
            Text("Billed \(isYearly ? "yearly" : "monthly") at \(product.displayPrice), auto-renews unless cancelled")
                .tonoFont(size: 11, relativeTo: .caption2)
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
            // Build 115 — iPad. LAYOUT ONLY. The confirmation field and the
            // destructive button were phone-width controls with no cap, so on a
            // tablet "Permanently delete my account" became a 1,000pt red bar —
            // the single worst control in the app to render as an easy-to-hit
            // slab. The form measure keeps it the size of a button.
            // `confirmDeletion`, the DELETE call, the typed-keyword gate, the
            // 401/404/offline handling and the purge are untouched.
            .tonoReadableColumn(.form)
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
                // Declared in `TonoTextStyle.accountDeletionWarning`, which
                // carries `face: .standard` because this label shipped
                // `.font(.system(size: 17, weight: .semibold))` with no
                // `design:` argument, i.e. SF Pro — and the account-deletion
                // phase of Build 115 is LAYOUT ONLY, so a typeface change here
                // would be outside its own declared scope. Only the Dynamic
                // Type scaling is new.
                .tonoFont(.accountDeletionWarning)
                .foregroundColor(.red)
            Text("Deleting your account permanently deletes your account and everything saved with it: your style memory, recipient profiles, and usage history. Your subscription is not automatically cancelled — cancel it separately in Apple ID settings before deleting.")
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
                    .tonoFont(size: 16, weight: .semibold, relativeTo: .callout)
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
                        errorMessage = "Account deletion didn't finish. Your account was not deleted. Contact support@tonoit.com if this persists."
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Account deletion didn't finish. Your account was not deleted."
                }
            }
        }
    }
}
