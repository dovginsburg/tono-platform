// OnboardingEntryPointsView.swift
// v1.0 onboarding (Dov 2026-07-01, locked in skill tono-ios-multi-entry-architecture):
//
// Three tiles on first launch. User picks any combination; skip allowed.
//
//   1. "Set as keyboard"     — opens iOS Settings (Apple deprecated direct
//                              App-Prefs deep-links, so this is informational;
//                              tells the user exactly which settings page to
//                              open and the toggles to flip). Keyboard is
//                              gated OFF in v1.0 so this tile is shown but
//                              not actionable — it's there for the v1.1
//                              flip if Apple approves the special-request.
//
//   2. "Use from any app"    — instructions for enabling Tono in the iOS
//                              Share Sheet via the share extension. This is
//                              the v1.0 PRIMARY entry point. Directs the
//                              user to the share sheet's "Edit Actions" menu.
//
//   3. "Tono Rewrite"        — explicitly marked Coming soon until a signed,
//                              importable artifact and public install URL are
//                              verified. The Share Sheet extension remains a
//                              separate entry point.
//
// "Skip" closes the sheet. Each tile marks itself complete when its action
// runs; the user can mark done manually if they configured out-of-band.

import SwiftUI
import UIKit

struct OnboardingEntryPointsView: View {
    let onDone: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardDone = false
    @State private var shareExtDone = false
    @AppStorage("tono.onboarding.awaitingSettingsReturn") private var awaitingSettingsReturn = false
    @State private var showSettingsGuidance = false
    @State private var keyboardCheckMessage: String?
    @State private var scrollTarget: Int?
    // Email identity (added 2026-07-03)
    @State private var emailDone = false
    @State private var showEmailSheet = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        tile(
                            number: 1,
                            icon: "keyboard",
                            title: "Set up Tono Keyboard",
                            detail: keyboardDetail,
                            isDone: keyboardDone,
                            buttonLabel: "Open iOS Settings",
                            buttonAction: { showSettingsGuidance = true }
                        )
                        if !keyboardDone {
                            VStack(alignment: .leading, spacing: 8) {
                                if let message = keyboardCheckMessage {
                                    Text(message)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                Button("Verify Setup Manually") {
                                    completeKeyboardStep()
                                }
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(.purple)
                            }
                            .padding(.horizontal, 16)
                        }
                        tile(
                            number: 2,
                            icon: "square.and.arrow.up",
                            title: "Use from any app",
                            detail: shareExtDetail,
                            isDone: shareExtDone,
                            buttonLabel: "Show me how",
                            buttonAction: markShareExtDone
                        )
                        tile(
                            number: 3,
                            icon: "bolt.fill",
                            title: "Tono Rewrite Shortcut — Coming soon",
                            detail: shortcutDetail,
                            isDone: false,
                            buttonLabel: nil,
                            buttonAction: nil
                        )
                        if FeatureFlags.isEnabled(.emailSignIn) {
                            tile(
                                number: 4,
                                icon: "envelope.fill",
                                title: "Sign in with email",
                                detail: emailDetail,
                                isDone: emailDone,
                                buttonLabel: emailDone ? "Signed in ✓" : "Sign in",
                                buttonAction: { showEmailSheet = true }
                            )
                        } else {
                            tile(
                                number: 4,
                                icon: "envelope.fill",
                                title: "Email sign-in — Coming soon",
                                detail: emailComingSoonDetail,
                                isDone: false,
                                buttonLabel: nil,
                                buttonAction: nil
                            )
                        }
                        Spacer(minLength: 8)
                        Text("Set up any available option now, or continue and finish later in Settings.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Button("Continue to Tono", action: finish)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                .onChange(of: scrollTarget) { target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    DispatchQueue.main.async { scrollTarget = nil }
                }
            }
            .navigationTitle("Welcome to Tono")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip for now", action: finish)
                }
            }
            .sheet(isPresented: $showEmailSheet) {
                EmailSignInSheet(
                    onSuccess: {
                        emailDone = true
                        showEmailSheet = false
                    },
                    onCancel: { showEmailSheet = false }
                )
            }
            .alert("Return to Tono after enabling the keyboard", isPresented: $showSettingsGuidance) {
                Button("Not now", role: .cancel) {}
                Button("Open Settings", action: openSettings)
            } message: {
                Text("iOS Settings cannot reopen Tono automatically. Add Tono under Keyboards, choose Full Access if you want online coaching, then return to Tono from the App Switcher. iOS does not let apps verify the Full Access switch.")
            }
        }
        .onAppear { refreshKeyboardStatus(afterSettings: awaitingSettingsReturn) }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshKeyboardStatus(afterSettings: awaitingSettingsReturn) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshKeyboardStatus(afterSettings: awaitingSettingsReturn)
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tono works with your keyboard, not instead of it.")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Set up the keyboard or Share Sheet now. Shortcut and email sign-in are clearly marked until they are available, and you can finish any step later in Settings.")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var keyboardDetail: String {
        // iOS exposes no public API that identifies a specific enabled
        // third-party keyboard or reports its Full Access switch. We can only
        // auto-confirm Tono after the extension writes its App Group marker.
        "1. Enable Keyboard\n2. Allow Full Access for Coach (optional for basic typing)\n3. Try Tono with the globe key\n\nSettings → General → Keyboard → Keyboards → Add New Keyboard → Tono. Return to Tono from the App Switcher when finished."
    }

    private var shareExtDetail: String {
        "In any text field, select text → tap Share → tap More → enable Tono. Then it lives in your Share Sheet forever. Works in iMessage, WhatsApp, Slack, Mail, Notes, Safari."
    }

    private var shortcutDetail: String {
        "Coming soon. There is no verified public Tono Rewrite Shortcut install link yet. The Share Sheet extension above remains available separately."
    }

    private var emailDetail: String {
        // v1.0: email is the durable identity — keeps your plan/subscription
        // across reinstalls, new phones, iPhone + iPad, and (future) web.
        "Use the same account on iPhone, iPad, and any future web. Recovers your subscription if you lose your phone. We email you a 6-digit code — no password to remember."
    }

    private var emailComingSoonDetail: String {
        "Sign in coming soon. Email delivery is not available in this release, so there is no sign-in action yet. You can use Tono without an email account."
    }

    private func tile(
        number: Int,
        icon: String,
        title: String,
        detail: String,
        isDone: Bool,
        buttonLabel: String?,
        buttonAction: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green : Color.purple)
                        .frame(width: 32, height: 32)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !isDone, let buttonLabel, let buttonAction {
                Button(action: buttonAction) {
                    HStack(spacing: 6) {
                        Text(buttonLabel)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .padding(.leading, 44)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .id(number)
    }

    // MARK: - Actions

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        keyboardCheckMessage = "After enabling Tono, return here from the App Switcher."
        UIApplication.shared.open(url) { success in
            DispatchQueue.main.async {
                awaitingSettingsReturn = success
                if !success {
                    keyboardCheckMessage = "Settings didn't open. Open Settings → General → Keyboard → Keyboards, then return here."
                }
            }
        }
    }

    private func refreshKeyboardStatus(afterSettings: Bool) {
        if SharedStore.defaults.bool(forKey: SharedKeys.keyboardLoaded) {
            completeKeyboardStep()
            return
        }
        guard afterSettings else { return }
        awaitingSettingsReturn = false
        // Public UITextInputMode exposes language, but no extension bundle ID.
        // `primaryLanguage == nil` is only a hint that some third-party
        // keyboard is available; it cannot prove that keyboard is Tono.
        let hasThirdPartyKeyboard = UITextInputMode.activeInputModes.contains {
            $0.primaryLanguage == nil
        }
        keyboardCheckMessage = hasThirdPartyKeyboard
            ? "A third-party keyboard is available, but iOS does not identify it or expose Full Access. Switch to Tono with the globe key, then use Verify Setup Manually."
            : "iOS does not let Tono confirm the keyboard or Full Access switch. If Tono is listed in Settings, try it with the globe key, then verify manually."
    }

    private func completeKeyboardStep() {
        guard !keyboardDone else { return }
        keyboardDone = true
        awaitingSettingsReturn = false
        keyboardCheckMessage = nil
        scrollTarget = 2
    }

    private func markShareExtDone() {
        shareExtDone = true
        scrollTarget = 4
    }

    private func finish() {
        SharedStore.defaults.set(true, forKey: SharedKeys.entryPointsOnboardingDone)
        onDone()
    }
}

// MARK: - SharedKeys additions
//
// NOTE: Add the following key to `Shared/SharedKeychain.swift` or
// `Shared/SharedUserDefaults.swift` so this view compiles:
//
//     static let entryPointsOnboardingDone = "entry_points_onboarding_done"
//
// RootView gates the new onboarding behind this flag; the legacy
// OnboardingCalibrationView is gated behind SharedKeys.onboardingDone.
//
// Keeping the new key in this file's README comment so the Shared layer
// owner can add it in the next commit without re-touching this view.
// MARK: - EmailSignInSheet

/// Two-step email sign-in sheet (added 2026-07-03):
///   1. User enters email → app POSTs /v1/auth/request-link
///      (server emails a 6-digit code via Resend)
///   2. User enters the 6-digit code → app POSTs /v1/auth/verify-otp
///      (server links this device to the email, returns a new api_token)
private struct EmailSignInSheet: View {
    @State private var email: String = ""
    @State private var otp: String = ""
    @State private var step: Step = .enterEmail
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    let onSuccess: () -> Void
    let onCancel: () -> Void

    init(onSuccess: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    enum Step {
        case enterEmail
        case enterOTP
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if step == .enterEmail {
                    emailStep
                } else {
                    otpStep
                }
            }
            .padding(24)
            .navigationTitle(step == .enterEmail ? "Sign in with email" : "Enter code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("We'll email you a 6-digit code. No password to remember.")
                .font(.callout)
                .foregroundColor(.secondary)
            TextField("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 4)
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
            Button(action: sendCode) {
                HStack {
                    if isLoading { ProgressView() }
                    Text("Send code")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(email.contains("@") ? Color.purple : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(isLoading || !email.contains("@"))
        }
    }

    private var otpStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Code sent to \(email). Check your inbox.")
                .font(.callout)
                .foregroundColor(.secondary)
            TextField("6-digit code", text: $otp)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .padding(.vertical, 8)
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
            Button(action: verifyCode) {
                HStack {
                    if isLoading { ProgressView() }
                    Text("Verify")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(otp.count == 6 ? Color.purple : Color.gray.opacity(0.3))
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(isLoading || otp.count != 6)
            Button("Use a different email") {
                step = .enterEmail
                otp = ""
                errorMessage = nil
            }
            .font(.footnote)
            .foregroundColor(.purple)
        }
    }

    private func sendCode() {
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                _ = try await TonoBackend.shared.requestEmailLink(email: email.lowercased())
                step = .enterOTP
            } catch let error as TonoBackendError {
                errorMessage = requestErrorMessage(error)
            } catch {
                errorMessage = "Email sign-in couldn't connect. Try again."
            }
        }
    }

    private func verifyCode() {
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                _ = try await TonoBackend.shared.verifyEmailOTP(
                    email: email.lowercased(),
                    otp: otp
                )
                onSuccess()
            } catch let e as TonoBackendError {
                if case .tooManyDevices(let cur, let max) = e {
                    errorMessage = "This email is on \(cur) devices (max \(max)). Contact support if you need more."
                } else {
                    errorMessage = verificationErrorMessage(e)
                }
            } catch {
                errorMessage = "Couldn't verify code. Try again."
            }
        }
    }

    private func requestErrorMessage(_ error: TonoBackendError) -> String {
        switch error {
        case .offline:
            return "You're offline. Connect to the internet and try again."
        case .network:
            return "Can't reach Tono right now. Check your connection and try again."
        case .http(let status, _):
            switch status {
            case 400, 422:
                return "Enter a valid email address."
            case 404:
                return "Email sign-in isn't available in this version yet."
            case 429:
                return "Too many code requests. Wait a few minutes and try again."
            case 503:
                return "Email delivery is temporarily unavailable. Try again later."
            default:
                return "Tono's sign-in service had a problem. Try again later."
            }
        default:
            return "Email sign-in couldn't start. Try again."
        }
    }

    private func verificationErrorMessage(_ error: TonoBackendError) -> String {
        switch error {
        case .offline:
            return "You're offline. Connect to the internet and try again."
        case .network:
            return "Can't reach Tono right now. Check your connection and try again."
        case .http(let status, _):
            switch status {
            case 400, 422:
                return "Invalid or expired code. Request a new code and try again."
            case 404:
                return "Email sign-in isn't available in this version yet."
            case 429:
                return "Too many attempts. Wait a few minutes, then request a new code."
            case 503:
                return "Email sign-in is temporarily unavailable. Try again later."
            default:
                return "Tono's sign-in service had a problem. Try again later."
            }
        default:
            return "Couldn't verify the code. Try again."
        }
    }
}
