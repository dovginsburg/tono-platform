// SetupDoctorView.swift
// Setup Doctor — the consumer surface over `Shared/SetupDoctor.swift`.
//
// Goal: get a user from "installed" to one successful Tono keyboard test,
// and explain Full Access honestly on the way. It is reachable from Settings
// and from the first onboarding tile; it is NOT a new tab.
//
// This file is deliberately thin. Every truth claim — what counts as verified,
// what degrades to stale, which navigation iOS actually supports — is decided
// in `SetupDoctor.swift` and merely rendered here, so the rules stay testable
// without a simulator.
//
// Consumer-copy rule: nothing on this screen may name a server, endpoint,
// environment, token, or diagnostic code. `SetupDoctorTests` scans this file
// to keep that true.
//
// Accessibility: each step is a single VoiceOver element whose label carries
// its state in words; status is signalled by symbol + text + colour so it
// survives colour-blind and monochrome viewing. Fonts are relative text
// styles (`.system(.subheadline, design: .rounded)`) so they track Dynamic
// Type while keeping the app's rounded face.

import Combine
import SwiftUI
import UIKit

struct SetupDoctorView: View {

    @State private var state: SetupDoctorState = .empty
    @State private var testText: String = ""
    @State private var testStartedAt: Date?
    @State private var showFullAccessDetail = false
    @State private var showSignIn = false
    @State private var isRefreshingAccount = false
    @FocusState private var testFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var store = StoreKitManager.shared

    /// 1 Hz while the screen is up. The heartbeat is written by another
    /// process (the keyboard extension), which cannot call back into the app,
    /// so a light poll is the only way the success state can appear while the
    /// user is still looking at the test field.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stepCard(
                    number: 1,
                    id: .keyboardEnabled,
                    icon: "keyboard",
                    title: "Add the Tono keyboard",
                    navigation: .addKeyboard
                )
                stepCard(
                    number: 2,
                    id: .fullAccess,
                    icon: "lock.open",
                    title: "Allow Full Access",
                    navigation: .fullAccess,
                    accessory: { AnyView(fullAccessDisclosure) }
                )
                stepCard(
                    number: 3,
                    id: .account,
                    icon: "person.crop.circle",
                    title: "Account and subscription",
                    navigation: nil,
                    accessory: { AnyView(accountActions) }
                )
                stepCard(
                    number: 4,
                    id: .testDrive,
                    icon: "checkmark.bubble",
                    title: "Try it once",
                    navigation: .switchToTono,
                    accessory: { AnyView(testField) }
                )
                if state.isFullySetUp { readyBanner }
                recheckButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .navigationTitle("Setup Doctor")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refresh() }
        }
        .sheet(isPresented: $showFullAccessDetail) { fullAccessSheet }
        .sheet(isPresented: $showSignIn) {
            EmailSignInSheet(
                onSuccess: {
                    showSignIn = false
                    refreshAccount()
                },
                onCancel: { showSignIn = false }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Let’s get Tono working")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text("Four steps. Tono only marks one done when it can actually verify it — iOS keeps most keyboard settings private, so the last step is what proves the rest.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Step card

    @ViewBuilder
    private func stepCard(
        number: Int,
        id: SetupStepID,
        icon: String,
        title: String,
        navigation: SetupNavigation?,
        accessory: (() -> AnyView)? = nil
    ) -> some View {
        let step = state.step(id)
        let badge = StatusBadge(status: step.status)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(step.status.isComplete ? Color.green : Color.purple)
                        .frame(width: 32, height: 32)
                    Image(systemName: step.status.isComplete ? "checkmark" : icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                    // Status in words as well as colour, so the state survives
                    // VoiceOver, monochrome, and colour-blind viewing.
                    HStack(spacing: 5) {
                        Image(systemName: badge.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(badge.label)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                    }
                    .foregroundColor(badge.color)
                    Text(step.detail)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(number), \(title). \(badge.label).")
            .accessibilityHint(step.detail)

            if !step.status.isComplete, let navigation {
                navigationBlock(navigation)
            }
            accessory?()
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Written steps always render. A button renders only when a public API
    /// genuinely goes somewhere — never a fake jump to a pane iOS won't open.
    @ViewBuilder
    private func navigationBlock(_ navigation: SetupNavigation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(navigation.writtenSteps.enumerated()), id: \.offset) { index, line in
                    Text("\(index + 1). \(line)")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Steps: " + navigation.writtenSteps.enumerated()
                    .map { "\($0.offset + 1). \($0.element)" }
                    .joined(separator: " ")
            )

            if let title = navigation.buttonTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: openSettings) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(.footnote, design: .rounded).weight(.semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                    .accessibilityHint(navigation.buttonFootnote ?? "")
                    if let footnote = navigation.buttonFootnote {
                        Text(footnote)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.leading, 44)
    }

    // MARK: - Full Access

    private var fullAccessDisclosure: some View {
        Button {
            showFullAccessDetail = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text(FullAccessExplainer.headline)
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundColor(.purple)
        }
        .padding(.leading, 44)
        .accessibilityHint("Explains what Coach sends and what it never sends.")
    }

    private var fullAccessSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(FullAccessExplainer.body.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.system(.subheadline, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tono never sends")
                            .font(.system(.headline, design: .rounded))
                        ForEach(FullAccessExplainer.neverCollected, id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(.system(.subheadline, design: .rounded))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Never sent: \(item)")
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(20)
            }
            .navigationTitle(FullAccessExplainer.headline)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFullAccessDetail = false }
                }
            }
        }
    }

    // MARK: - Account

    @ViewBuilder
    private var accountActions: some View {
        HStack(spacing: 12) {
            if !TonoBackend.shared.isRegistered() {
                Button("Sign in") { showSignIn = true }
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundColor(.purple)
                    .accessibilityHint("Signs you in so your subscription follows your account.")
            }
            Button(isRefreshingAccount ? "Checking…" : "Check again") { refreshAccount() }
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundColor(.purple)
                .disabled(isRefreshingAccount)
                .accessibilityHint("Re-checks your subscription status.")
        }
        .padding(.leading, 44)
    }

    // MARK: - Test drive

    private var testField: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Local scratch field. Text typed here is never read, stored, or
            // sent — it exists only to give the user somewhere safe to bring
            // the Tono keyboard up.
            TextField("Type anything here…", text: $testText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .rounded))
                .lineLimit(1...3)
                .padding(12)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .focused($testFieldFocused)
                .accessibilityLabel("Test field")
                .accessibilityHint("Type here with the Tono keyboard to finish setup. What you type stays on your device.")
                .onChange(of: testFieldFocused) { focused in
                    // Arm the test at focus: only a check-in newer than this
                    // moment proves the keyboard loaded *for this test*.
                    if focused && testStartedAt == nil { testStartedAt = Date() }
                }
            Text("This field is just for testing. What you type here stays on your device.")
                .font(.system(.caption2, design: .rounded))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 44)
    }

    private var readyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("You’re set")
                    .font(.system(.headline, design: .rounded))
                Text("Tono is added, Full Access is on, your subscription is active, and the keyboard just checked in. Switch to Tono in any app and tap Coach on a draft.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// Recovery for a missing, stale, or unreadable check-in: drop the old
    /// record so the next reading measures a genuinely new appearance, re-arm
    /// the test, and put the user in the field where they can produce one.
    private var recheckButton: some View {
        Button {
            KeyboardHeartbeatStore().clear()
            testStartedAt = Date()
            testFieldFocused = true
            refresh()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                Text("Check again")
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundColor(.purple)
        }
        .padding(.top, 4)
        .accessibilityHint("Clears the last check-in and puts the cursor in the test field so you can retry.")
    }

    // MARK: - Refresh

    private func refresh() {
        state = SetupDoctorState.derive(
            heartbeat: KeyboardHeartbeatStore().read(),
            entitlement: SetupEntitlementSnapshot(
                isRegistered: TonoBackend.shared.isRegistered(),
                state: TonePreferences().entitlementState,
                checkedAt: storedEntitlementCheckedAt()
            ),
            testStartedAt: testStartedAt,
            now: Date()
        )
    }

    private func storedEntitlementCheckedAt() -> Date? {
        let raw = SharedStore.defaults.double(forKey: SharedKeys.entitlementCheckedAt)
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    private func refreshAccount() {
        guard !isRefreshingAccount else { return }
        isRefreshingAccount = true
        Task {
            await store.refreshEntitlements()
            await MainActor.run {
                isRefreshingAccount = false
                refresh()
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Status badge

/// Maps a status to its three redundant signals: symbol, word, colour.
private struct StatusBadge {
    let symbol: String
    let label: String
    let color: Color

    init(status: SetupStepStatus) {
        switch status {
        case .complete:
            symbol = "checkmark.circle.fill"
            label = "Done"
            color = .green
        case .confirmedEarlier(let at):
            symbol = "clock.arrow.circlepath"
            label = "Confirmed \(Self.relative(at))"
            color = .orange
        case .actionNeeded:
            symbol = "exclamationmark.triangle.fill"
            label = "Needs you"
            color = .orange
        case .cannotConfirm:
            symbol = "questionmark.circle.fill"
            label = "Not confirmed yet"
            color = .secondary
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private extension SetupDoctorState {
    /// Pre-observation state: everything unconfirmed, nothing green.
    static var empty: SetupDoctorState {
        .derive(
            heartbeat: nil,
            entitlement: SetupEntitlementSnapshot(isRegistered: false, state: nil, checkedAt: nil),
            testStartedAt: nil,
            now: Date()
        )
    }
}

// MARK: - Sheet wrapper

/// Presents the Doctor with its own navigation chrome for callers that show it
/// modally (onboarding). Settings pushes `SetupDoctorView` directly instead.
struct SetupDoctorSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            SetupDoctorView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
    }
}
