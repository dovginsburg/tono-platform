// SettingsView.swift
// Voice + axis toggles, plan management, backend connection status.
// The paywall uses StoreKit 2 — no Stripe redirect on iOS.

import SwiftUI
import StoreKit

struct SettingsView: View {
    @Binding var prefs: TonePreferences
    @ObservedObject private var store = StoreKitManager.shared

    // Runtime backend URL override (read by TonoBackend.baseURL resolution).
    // Default empty → uses TonoBackend.baseURL fallback (https://api.tonoit.com in Release).
    @AppStorage("tc.backendURL") private var customBackendURL: String = ""

    @State private var voiceField:        String     = ""
    @State private var showPaywall:       Bool       = false
    @State private var usage:             TonoUsage?
    @State private var usageError:        String?
    @State private var recipients:        [Recipient] = []
    @State private var showAddRecipient:  Bool       = false
    @State private var promoCode:         String     = ""
    @State private var promoError:        String?
    @State private var promoSuccess:      String?
    @State private var isRedeemingCode:   Bool       = false
    @State private var featureToggles:    [FeatureFlag: Bool] = [:]
    @State private var healthState:       HealthState = .unknown
    @State private var isSettingUp:        Bool       = false
    @State private var showWhySetup:       Bool       = false

    enum HealthState: Equatable {
        case unknown
        case checking
        case ok
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                backendSection
                voiceSection
                memorySection
                featurePreferencesSection
                recipientsSection
                axesSection
                planSection
                privacySection
            }
            .navigationTitle("Settings")
            .onAppear {
                voiceField = prefs.preferredVoice ?? ""
                recipients = RecipientMemory.all()
                loadFeatureToggles()
                Task {
                    await runHealthCheck()
                    await refreshUsage()
                }
            }
            .task {
                try? await TonoBackend.shared.registerIfNeeded(
                    platform: "ios",
                    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
                )
                await refreshUsage()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(onDismiss: { showPaywall = false })
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var backendSection: some View {
        Section("Account") {
            // Status row with health dot.
            HStack(spacing: 8) {
                healthDot
                Text(healthLabel)
                    .foregroundColor(healthLabelColor)
                    .font(.subheadline)
                Spacer()
            }
            // Resolved URL — shows Dov what the app is actually hitting.
            HStack {
                Text("Endpoint")
                Spacer()
                Text(resolvedBackendLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if TonoBackend.shared.isRegistered() {
                HStack {
                    Text("Status")
                    Spacer()
                    Text("Connected").foregroundColor(.secondary)
                }
            } else {
                // CTA: replaces the old dead-end "opens automatically on next
                // Coach tap" hint with a button the user can tap right now.
                Button {
                    Task { await runSetup() }
                } label: {
                    HStack(spacing: 8) {
                        if isSettingUp {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isSettingUp ? "Setting up…" : "Set up Tono in one tap →")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isSettingUp)
                DisclosureGroup(isExpanded: $showWhySetup) {
                    Text("Tono needs to register your device with our server before rewrites work. Takes 2 seconds.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                } label: {
                    Text("Why do I need this?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let u = usage {
                HStack {
                    Text("Plan")
                    Spacer()
                    Text(u.isPro ? "Pro" : "Free").foregroundColor(.secondary)
                }
                if !u.isPro {
                    HStack {
                        Text("Today")
                        Spacer()
                        Text("\(u.usedToday)/\(u.dailyLimit)").foregroundColor(.secondary)
                    }
                }
            } else if let err = usageError {
                Text(err).font(.caption).foregroundColor(.red)
            }
            Text("Rewrites run on the Tono backend — your API key never leaves the server.")
                .font(.caption).foregroundColor(.secondary)
        }
        Section("Backend") {
            TextField("Custom backend URL (leave blank for default)", text: $customBackendURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .font(.system(.body, design: .monospaced))
                .onSubmit { Task { await runHealthCheck() } }
            HStack {
                Button {
                    Task { await runHealthCheck() }
                } label: {
                    HStack(spacing: 6) {
                        if case .checking = healthState {
                            ProgressView().controlSize(.small)
                        }
                        Text(testButtonLabel)
                    }
                }
                .disabled({
                    if case .checking = healthState { return true }
                    return false
                }())
                Spacer()
                if case .failed(let msg) = healthState {
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if case .ok = healthState {
                    Text("Healthy")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            Text("Default: https://api.tonoit.com")
                .font(.caption2).foregroundColor(.secondary)
            Text("Paste a URL here to override (e.g. for staging). Changes take effect immediately on the next request.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Backend helpers

    private var resolvedBackendLabel: String {
        let trimmed = customBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return TonoBackend.shared.baseURL.absoluteString
    }

    private var healthDot: some View {
        Group {
            switch healthState {
            case .unknown:
                Circle().fill(Color.gray).frame(width: 10, height: 10)
            case .checking:
                Circle().fill(Color.gray.opacity(0.5)).frame(width: 10, height: 10)
            case .ok:
                Circle().fill(Color.green).frame(width: 10, height: 10)
            case .failed:
                Circle().fill(Color.red).frame(width: 10, height: 10)
            }
        }
    }

    private var healthLabel: String {
        switch healthState {
        case .unknown:  return "Backend status unknown"
        case .checking: return "Checking…"
        case .ok:       return "Backend reachable"
        case .failed(let m): return "Backend unreachable: \(m)"
        }
    }

    private var healthLabelColor: Color {
        switch healthState {
        case .ok:    return .green
        case .failed: return .red
        default:     return .secondary
        }
    }

    private var testButtonLabel: String {
        switch healthState {
        case .checking: return "Testing…"
        default:        return "Test Connection"
        }
    }

    private func runHealthCheck() async {
        await MainActor.run { healthState = .checking }
        do {
            let ok = try await TonoBackend.shared.health()
            await MainActor.run {
                healthState = ok ? .ok : .failed("non-2xx response")
            }
        } catch let e as TonoBackendError {
            await MainActor.run {
                healthState = .failed(prettyError(e))
            }
        } catch {
            await MainActor.run {
                healthState = .failed(error.localizedDescription)
            }
        }
    }

    /// CTA target: tap "Set up Tono in one tap" → triggers /v1/register
    /// directly. Used in place of the old auto-register-on-Coach dead-end.
    private func runSetup() async {
        isSettingUp = true
        defer { isSettingUp = false }
        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
            )
            await refreshUsage()
            await runHealthCheck()
        } catch let e as TonoBackendError {
            await MainActor.run {
                usageError = prettyError(e)
            }
        } catch {
            await MainActor.run {
                usageError = error.localizedDescription
            }
        }
    }

    private func prettyError(_ e: TonoBackendError) -> String {
        switch e {
        case .offline:
            return "No internet connection"
        case .network(let m):
            return "Network error: \(m)"
        case .http(let code, let msg):
            let trimmed = msg.count > 200 ? String(msg.prefix(200)) + "…" : msg
            return trimmed.isEmpty
                ? "Server error \(code)"
                : "Server error \(code): \(trimmed)"
        case .notRegistered:
            return "Account not set up yet. Tap ‘Set up Tono’ in Settings → Account."
        case .decoding(let m):
            return "Bad response: \(m)"
        case .tooManyDevices(let current, let max):
            return "This email is already on \(current) devices (max \(max))."
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
        Section("Recipients") {
            ForEach(recipients) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    if let hint = r.voiceHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        RecipientMemory.delete(id: r.id)
                        recipients = RecipientMemory.all()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            Button("Add manually") { showAddRecipient = true }
            NavigationLink {
                ContactsAccessView()
            } label: {
                Label("Contacts Access & Import", systemImage: "person.crop.circle.badge.checkmark")
            }
            .accessibilityHint("Review Contacts permission, manage limited access, or import recipients.")
            Text("Recipient profiles stay in Tono’s local App Group. Only a chosen recipient’s voice hint is sent with a coaching request.")
                .font(.caption).foregroundColor(.secondary)
        }
        .sheet(isPresented: $showAddRecipient) {
            AddRecipientView { r in
                RecipientMemory.add(r)
                recipients = RecipientMemory.all()
            }
        }
        .onAppear { recipients = RecipientMemory.all() }
    }

    private var axesSection: some View {
        Section("Rewrite axes") {
            ForEach(RewriteAxis.allCases) { axis in
                Toggle(axis.displayName, isOn: axisBinding(axis))
            }
            Text("Each rewrite differs on exactly one axis. Disable axes you never want.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var planSection: some View {
        let isPro = store.isPro || prefs.proUnlocked || (usage?.isPro ?? false)
        return Section("Plan") {
            HStack {
                Text(isPro ? "Pro ✓" : "Free")
                Spacer()
                if !isPro {
                    // Apple-compliant label: matches the action and names
                    // the auto-renewing nature of the trial.
                    Button("Try Pro free for 7 days") { showPaywall = true }
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
            Text("Free: 3 coaching sessions/day, all four rewrite axes, no card required. Pro (7-day free trial, then auto-renews at $5.99/mo or $39.99/yr unless cancelled): unlimited + thread context + style memory + per-recipient coaching + weekly digest. Cancel anytime in Settings.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Text("Tono sends your draft to our backend, which calls the LLM. Drafts are not stored. Your bearer token is kept in the Keychain, never in plain UserDefaults.")
                .font(.caption).foregroundColor(.secondary)
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

    private func axisBinding(_ axis: RewriteAxis) -> Binding<Bool> {
        Binding(
            get: { prefs.axes.contains(axis) },
            set: { on in
                if on { if !prefs.axes.contains(axis) { prefs.axes.append(axis) } }
                else  { prefs.axes.removeAll { $0 == axis } }
                prefs.save()
            }
        )
    }

    private func refreshUsage() async {
        do {
            let me = try await TonoBackend.shared.me()
            await MainActor.run {
                usage = TonoUsage(usedToday: me.usedToday, dailyLimit: me.dailyLimit,
                                  plan: me.plan, isPro: me.isPro)
                usageError = nil
            }
        } catch let e as TonoBackendError {
            await MainActor.run {
                usageError = prettyError(e)
            }
        } catch {
            await MainActor.run {
                usageError = error.localizedDescription
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
            await refreshUsage()
        } catch let e as TonoBackendError {
            promoError = e.localizedDescription
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerSection
                    .padding(.top, 40)

                Spacer()

                productList

                Spacer()

                restoreButton

                // Apple App Store Review Guideline 3.1.2 (Subscriptions)
                // requires this boilerplate be visible on the same screen as
                // the buy button. Includes trial disclosure if a 7-day free
                // trial introductory offer is configured in App Store Connect.
                Text(
"""
Payment will be charged to your Apple ID account at the confirmation of purchase. Subscription automatically renews unless it is cancelled at least 24 hours before the end of the current period. Your account will be charged for renewal within 24 hours prior to the end of the current period. If you start a free trial, any unused portion of the free trial period will be forfeited when you purchase a subscription.
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
                FeatureLine("Unlimited rewrites (Free is 3/day)")
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
            if store.products.isEmpty && !store.isLoading {
                Text("Products unavailable. Make sure you're signed into the App Store.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            ForEach(store.products, id: \.id) { product in
                ProductRow(product: product, isLoading: store.isLoading) {
                    Task { await store.purchase(product) }
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
    let onPurchase: () -> Void

    private var isYearly: Bool { product.id.contains("yearly") }

    var body: some View {
        Button(action: onPurchase) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isYearly ? "Annual" : "Monthly")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        if isYearly {
                            Text("Save 44%")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.25))
                                .clipShape(Capsule())
                                .foregroundColor(.green)
                        }
                    }
                    // Show Apple's real intro offer if it exists (set up in
                    // App Store Connect → Subscriptions → introductory offer).
                    // Example: "$0.00 / 7 days, then auto-renews at $5.99/mo".
                    // Falls back to a clear fixed text if no offer is configured
                    // yet (e.g., during local development without ASC).
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
                        if let intro = product.subscription?.introductoryOffer {
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

    /// Renders the intro-offer disclosure line in Apple-compliant format.
    /// Example: "7-day free trial, then auto-renews at $5.99/mo unless cancelled".
    @ViewBuilder
    private var introOfferLine: some View {
        if let intro = product.subscription?.introductoryOffer,
           intro.paymentMode == .freeTrial {
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
