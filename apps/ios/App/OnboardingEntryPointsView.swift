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
//   3. "Quick setup"         — bundles the TonoRewrite.shortcut file inside
//                              the app and presents the system Share Sheet
//                              (UIActivityViewController). User picks
//                              "Add to Shortcuts" / AirDrop / Save to Files
//                              and the shortcut is installed into their
//                              Shortcuts library. Works offline, no URL,
//                              no publish step.
//
// "Skip" closes the sheet. Each tile marks itself complete when its action
// runs; the user can mark done manually if they configured out-of-band.

import SwiftUI
import UIKit

// TODO: move to .xcconfig
private let kTonoRewriteShortcutURL = "https://bndbgpqbpzukrbhukrbhquztj.supabase.co/storage/v1/object/public/shortcuts/TonoRewrite.shortcut"

struct OnboardingEntryPointsView: View {
    let onDone: () -> Void

    @State private var keyboardDone = false
    @State private var shareExtDone = false
    @State private var shortcutDone = false
    @State private var showShortcutShareSheet = false
    // Email identity (added 2026-07-03)
    @State private var emailDone = false
    @State private var showEmailSheet = false
    @State private var otpForSignIn = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    tile(
                        number: 1,
                        icon: "keyboard",
                        title: "Set as keyboard",
                        detail: keyboardDetail,
                        isDone: keyboardDone,
                        buttonLabel: "Open iOS Settings",
                        buttonAction: openSettings
                    )
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
                        title: "Quick setup",
                        detail: shortcutDetail,
                        isDone: shortcutDone,
                        buttonLabel: shortcutDone ? "Installed ✓" : "Install Shortcut",
                        buttonAction: installShortcut
                    )
                    tile(
                        number: 4,
                        icon: "envelope.fill",
                        title: "Sign in with email",
                        detail: emailDetail,
                        isDone: emailDone,
                        buttonLabel: emailDone ? "Signed in ✓" : "Sign in",
                        buttonAction: { showEmailSheet = true }
                    )
                    Spacer(minLength: 8)
                    Text("Tap any combination. Skip the rest with the button below.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            .navigationTitle("Welcome to Tono")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip", action: finish)
                }
            }
            .sheet(isPresented: $showShortcutShareSheet) {
                if let url = Bundle.main.url(forResource: "TonoRewrite", withExtension: "shortcut") {
                    ActivityViewController(items: [url])
                        .ignoresSafeArea()
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
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tono works with your keyboard, not instead of it.")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("Pick how you want to use Tono. You can do all three, just one, or skip and configure later in Settings.")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var keyboardDetail: String {
        // v1.0: keyboard is enabled. Apple has no special-approval gate; the
        // only step the user needs to do is flip "Allow Full Access" on in
        // Settings → General → Keyboard → Tono (so Tono can reach its
        // backend for tone analysis).
        "Settings → General → Keyboard → Keyboards → Add New Keyboard → Tono. Then tap Tono in the keyboard list → enable \"Allow Full Access\" (so Tono can reach its backend for tone analysis)."
    }

    private var shareExtDetail: String {
        "In any text field, select text → tap Share → tap More → enable Tono. Then it lives in your Share Sheet forever. Works in iMessage, WhatsApp, Slack, Mail, Notes, Safari."
    }

    private var shortcutDetail: String {
        "One-tap install. The Tono Shortcut shows up in the top row of your Share Sheet. Tap any text → Share → Tono Rewrite → rewrite is on your clipboard."
    }

    private var emailDetail: String {
        // v1.0: email is the durable identity — keeps your plan/subscription
        // across reinstalls, new phones, iPhone + iPad, and (future) web.
        "Use the same account on iPhone, iPad, and any future web. Recovers your subscription if you lose your phone. We email you a 6-digit code — no password to remember."
    }

    private func tile(
        number: Int,
        icon: String,
        title: String,
        detail: String,
        isDone: Bool,
        buttonLabel: String,
        buttonAction: @escaping () -> Void
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
            if !isDone {
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
    }

    // MARK: - Actions

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        // We can't detect when the user returns. Let them mark done manually
        // by tapping the tile header — for v1.0 informational tile, this is
        // fine. v1.1 will flip on App Group polling like HomeView does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            keyboardDone = true
        }
    }

    private func markShareExtDone() {
        shareExtDone = true
    }

    private func installShortcut() {
        let encodedURL = kTonoRewriteShortcutURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? kTonoRewriteShortcutURL
        guard let shortcutURL = URL(string: "shortcuts://import-workflow?url=\(encodedURL)&name=Tono%20Rewrite") else {
            showShortcutShareSheet = true
            return
        }
        if UIApplication.shared.canOpenURL(shortcutURL) {
            UIApplication.shared.open(shortcutURL) { success in
                if success {
                    DispatchQueue.main.async { self.shortcutDone = true }
                }
            }
        } else {
            showShortcutShareSheet = true
        }
    }

    private func finish() {
        SharedStore.defaults.set(true, forKey: SharedKeys.entryPointsOnboardingDone)
        onDone()
    }
}

// MARK: - Share Sheet wrapper

private struct ActivityViewController: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
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
            } catch {
                errorMessage = "Couldn't send code. Try again."
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
                    errorMessage = "Invalid or expired code. Try again."
                }
            } catch {
                errorMessage = "Couldn't verify code. Try again."
            }
        }
    }
}
