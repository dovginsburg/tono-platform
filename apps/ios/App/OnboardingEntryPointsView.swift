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
import AuthenticationServices
import CryptoKit
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

struct OnboardingEntryPointsView: View {
    let onDone: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardDone = false
    @State private var shareExtDone = false
    @AppStorage("tono.onboarding.awaitingSettingsReturn") private var awaitingSettingsReturn = false
    @State private var showSettingsGuidance = false
    @State private var showSetupDoctor = false
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
                        // Build 115 — iPad. These four are INDEPENDENT options,
                        // not a sequence: the file's own contract is "user picks
                        // any combination; skip allowed". So unlike the Setup
                        // Doctor's numbered steps, they group two-up where there
                        // is room. Tile 1 and its verification buttons are one
                        // cell, because those buttons belong to that tile.
                        // The spec's `spacing: 20` is the stack spacing they
                        // had, so a phone in PORTRAIT gets the column that
                        // shipped. A phone in LANDSCAPE clears the reading
                        // measure and does group two-up; that is intentional
                        // and separately tested.
                        AdaptiveItemGrid(.onboardingTiles) {
                            VStack(alignment: .leading, spacing: 20) {
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
                                        // Preferred path: the Doctor can actually check
                                        // the keyboard, so it beats self-declaring done.
                                        Button("Open Setup Doctor") {
                                            showSetupDoctor = true
                                        }
                                        .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                        .foregroundColor(.purple)
                                        .accessibilityHint("Walks through adding the keyboard and confirms when it’s working.")
                                        Button("Verify Setup Manually") {
                                            completeKeyboardStep()
                                        }
                                        .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                        .foregroundColor(.purple)
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                            // The whole CELL is one unit: tile 1 and the two
                            // buttons that verify it. Without this the buttons
                            // sit lower than tile 2's card, so geometric
                            // ordering read them after tile 2 — the tile's own
                            // actions, announced under the wrong tile.
                            .accessibilityElement(children: .contain)
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
                        }
                        Spacer(minLength: 8)
                        Text("Set up any available option now, or continue and finish later in Settings.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Button("Continue to Tono", action: finish)
                            .tonoFont(size: 16, weight: .semibold, relativeTo: .callout)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.purple)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            // One capsule spanning a tablet is the exact defect
                            // this repair exists to remove.
                            .tonoReadableColumn(.form)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .tonoReadableColumn(.reading)
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
            .sheet(isPresented: $showSetupDoctor) {
                SetupDoctorSheet {
                    showSetupDoctor = false
                    // The Doctor may have produced the very check-in this tile
                    // is waiting on, so re-read rather than assume.
                    refreshKeyboardStatus(afterSettings: false)
                }
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
                .tonoFont(size: 22, weight: .bold, relativeTo: .title2)
            Text("Set up the keyboard or Share Sheet now. Shortcut and email sign-in are clearly marked until they are available, and you can finish any step later in Settings.")
                .tonoFont(size: 14, relativeTo: .subheadline)
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
        // Email is the durable identity — it keeps your plan and subscription
        // across reinstalls, new phones, iPhone + iPad, and the web.
        //
        // Build 114: this sentence used to promise "a 6-digit code — no
        // password to remember", which described the pre-114 sheet. That sheet
        // posted to two endpoints that never existed on the server, and the
        // flow it named is gone: an account is created with an email and a
        // password, and ownership is proven by opening a link. Copy that
        // promises a code nobody will ever receive is the first thing a person
        // would judge the product by, so it states what actually happens.
        "Use the same account on iPhone, iPad, and the web. Recovers your subscription if you lose your phone. You'll pick a password and confirm your address from a link we email you."
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
                            .tonoGlyphFont(size: 14, weight: .bold, relativeTo: .subheadline)
                            .foregroundColor(.white)
                    } else {
                        Image(systemName: icon)
                            .tonoGlyphFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .tonoFont(size: 17, weight: .semibold, relativeTo: .body)
                    Text(detail)
                        .tonoFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !isDone, let buttonLabel, let buttonAction {
                Button(action: buttonAction) {
                    HStack(spacing: 6) {
                        Text(buttonLabel)
                            .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                        Image(systemName: "arrow.up.right")
                            .tonoGlyphFont(size: 11, relativeTo: .caption2)
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
        // Build 115 — iPad. Two tiles side by side sit on the same visual rows,
        // and UIKit orders accessibility by geometry, so without this VoiceOver
        // read "tile 1 title, tile 2 title, tile 1 detail, tile 2 detail…"
        // straight across the row. Containing each tile keeps a tile's own
        // words together in both layouts. Caught by
        // Build115IPadSurfaceLayoutTests, not by inspection.
        .accessibilityElement(children: .contain)
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

/// The email account sheet — Build 114.
///
/// Build 113 and earlier drove a 6-digit code against `/v1/auth/request-link`
/// and `/v1/auth/verify-otp`. Neither endpoint has ever existed on the server,
/// so every tap in this sheet 404'd, `KeychainKeys.signedInEmail` was never
/// written, and `StoreKitManager.isIdentifiedAccount` therefore refused every
/// purchase on every device. Build 114 drives the registration lane that now
/// exists: create the account, confirm the address from the link that arrives,
/// then sign in with the password.
///
/// Three properties this sheet is responsible for holding:
///
///   * **It is not an account oracle.** Creating an account, asking for a new
///     confirmation link, and starting a password reset all show the SAME
///     confirmation whether or not the address is already registered. The
///     server answers identically for a known and an unknown address; so does
///     this sheet, because otherwise the anti-enumeration work upstream would
///     be undone by the one surface a stranger can actually see.
///   * **No implementation detail reaches the screen.** Every sentence comes
///     from `emailOutcomeMessage`, which switches on a closed set of outcome
///     SHAPES. It takes no `Error`, no status code and no message payload, so
///     there is no parameter through which one could arrive.
///   * **Confirming an address is not a purchase.** Nothing here grants an
///     entitlement. `signedInEmail` — the key the paywall reads — is written
///     by `TonoBackend.signInWithEmail` only after the server confirmed a
///     verified identity, and Pro still comes from a subscription alone.
///
/// Internal (not private) so PaywallView, AccountDeletionView and the Setup
/// Doctor can present it when an identified account is required (build 101).
struct EmailSignInSheet: View {

    /// Where the person is in the flow. `confirmSent` is a real destination
    /// rather than a toast: confirming means leaving for an inbox and coming
    /// back, possibly after closing the app entirely.
    enum Step: Equatable {
        case signIn
        case createAccount
        case confirmSent
    }

    /// What the person was trying to do. Kept separate from the outcome so a
    /// single accepted answer ("check your email") can still say which link is
    /// waiting for them — a confirmation link and a password-reset link lead
    /// to genuinely different next steps.
    enum Action: Equatable {
        case createAccount
        case signIn
        case resendConfirmation
        case resetPassword
    }

    /// The server's own floor, mirrored so the person is told before a round
    /// trip rather than after one.
    static let minimumPasswordLength = 8

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var passwordVisible: Bool = false
    @State private var step: Step = .signIn
    @State private var isWorking: Bool = false
    /// The last thing that happened, as a shape. Never an `Error`.
    @State private var lastOutcome: TonoBackend.EmailAuthOutcome?
    @State private var lastAction: Action = .signIn
    @State private var providerNotice: String?
    @State private var appleNonce: String?

    let onSuccess: () -> Void
    let onCancel: () -> Void

    init(onSuccess: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .signIn:        signInStep
                    case .createAccount: createAccountStep
                    case .confirmSent:   confirmSentStep
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Build 115 — iPad. This is the sheet the brief names: an
                // email field, a password field and one capsule button, all
                // written with `.frame(maxWidth: .infinity)` for a phone. In an
                // iPad form sheet that made a ~656pt capsule, and presented any
                // wider it made a 1,000pt one. The form measure keeps the
                // controls the size of controls. Nothing about what this sheet
                // DOES changes — no endpoint, no outcome mapping, no copy.
                .tonoReadableColumn(.form)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isWorking)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch step {
        case .signIn:        return "Sign in"
        case .createAccount: return "Create your account"
        case .confirmSent:   return "Confirm your email"
        }
    }

    // MARK: - Steps

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sign in so your subscription follows you if you reinstall or switch devices.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            providerButtons
            Divider()
            emailField
            passwordField(isNew: false)
            noticeView
            primaryButton(title: "Sign in", enabled: canSubmitCredentials) {
                Task { await submitSignIn() }
            }
            Button("Send a new confirmation link") {
                Task { await submitResend() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.purple)
            .disabled(isWorking || !looksLikeAddress)
            .accessibilityHint("Sends another link to confirm the address you entered.")
            Button("Forgot your password?") {
                Task { await submitReset() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.purple)
            .disabled(isWorking || !looksLikeAddress)
            .accessibilityHint("Emails you a link to choose a new password.")
            Divider().padding(.vertical, 4)
            Button("Create an account instead") { move(to: .createAccount) }
                .font(.footnote.weight(.semibold))
                .foregroundColor(.purple)
                .disabled(isWorking)
        }
    }

    private var createAccountStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your email keeps your subscription and your style memory recoverable. Pick a password of at least \(Self.minimumPasswordLength) characters.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            emailField
            passwordField(isNew: true)
            noticeView
            primaryButton(title: "Create account", enabled: canSubmitCredentials) {
                Task { await submitCreateAccount() }
            }
            Button("I already have an account") { move(to: .signIn) }
                .font(.footnote.weight(.semibold))
                .foregroundColor(.purple)
                .disabled(isWorking)
        }
    }

    private var confirmSentStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "envelope.badge")
                .tonoGlyphFont(size: 34, relativeTo: .largeTitle)
                .foregroundColor(.purple)
                .accessibilityHidden(true)
            noticeView
            Text("Open the link on this device, then come back and sign in.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            primaryButton(title: "Sign in", enabled: !isWorking) { move(to: .signIn) }
            Button("Send a new link") {
                Task { await submitResend() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundColor(.purple)
            .disabled(isWorking)
        }
    }

    // MARK: - Fields

    private var providerButtons: some View {
        VStack(spacing: 10) {
            SignInWithAppleButton(.continue) { request in
                let nonce = UUID().uuidString + UUID().uuidString
                appleNonce = nonce
                request.requestedScopes = [.email]
                request.nonce = SHA256.hash(data: Data(nonce.utf8))
                    .map { String(format: "%02x", $0) }.joined()
            } onCompletion: { result in
                guard case .success(let authorization) = result,
                      let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let data = credential.identityToken,
                      let token = String(data: data, encoding: .utf8),
                      let nonce = appleNonce else {
                    providerNotice = "Apple sign-in did not finish. Try again or use email."
                    return
                }
                appleNonce = nil
                Task { await submitApple(token: token, nonce: nonce) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityLabel("Continue with Apple")

#if canImport(GoogleSignIn)
            Button("Continue with Google") { Task { await submitGoogle() } }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isWorking)
#endif

            if let providerNotice {
                Text(providerNotice).font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private func submitApple(token: String, nonce: String) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await TonoBackend.shared.signInWithApple(identityToken: token, nonce: nonce)
            onSuccess()
        } catch {
            providerNotice = "That Apple sign-in could not be verified. Try again or use email."
        }
    }

#if canImport(GoogleSignIn)
    private func submitGoogle() async {
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else {
            providerNotice = "Google sign-in is unavailable. Use Apple or email."
            return
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let token = result.user.idToken?.tokenString else { throw URLError(.userAuthenticationRequired) }
            _ = try await TonoBackend.shared.signInWithGoogle(idToken: token)
            onSuccess()
        } catch {
            providerNotice = "Google sign-in did not finish. Try again or use Apple."
        }
    }
#endif

    private var emailField: some View {
        TextField("you@example.com", text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .textFieldStyle(.roundedBorder)
            .disabled(isWorking)
            .accessibilityLabel("Email address")
    }

    private func passwordField(isNew: Bool) -> some View {
        // A password field with an accessible reveal control. SwiftUI's
        // SecureField cannot itself unmask, so we overlay a SecureField and a
        // plain TextField and show one at a time; the eye button flips
        // `passwordVisible`. Both fields bind the SAME `password` state, so the
        // value is never duplicated or lost when toggling. Every password field
        // in the product must let a person verify what they typed.
        HStack(spacing: 8) {
            ZStack {
                SecureField("Password", text: $password)
                    .textContentType(isNew ? .newPassword : .password)
                    .opacity(passwordVisible ? 0 : 1)
                    .accessibilityHidden(passwordVisible)
                TextField("Password", text: $password)
                    .textContentType(isNew ? .newPassword : .password)
                    .opacity(passwordVisible ? 1 : 0)
                    .accessibilityHidden(!passwordVisible)
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .accessibilityLabel("Password")

            Button {
                passwordVisible.toggle()
            } label: {
                // The glyph is a 17pt SF Symbol, but the control a person taps
                // must clear the 44pt guideline — same idiom the plus button in
                // RecipientsManagerView uses. The frame centres the unchanged
                // eye/eye.slash glyph in a 44pt box and `contentShape` makes the
                // whole box the hit region; nothing about the icon changes.
                Image(systemName: passwordVisible ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isWorking)
            .accessibilityLabel(passwordVisible ? "Hide password" : "Show password")
            .accessibilityAddTraits(passwordVisible ? [.isSelected] : [])
        }
        .textFieldStyle(.roundedBorder)
        .disabled(isWorking)
    }

    /// The one rendered failure/notice surface. It reads a mapped sentence, so
    /// there is no path from a transport failure to these pixels.
    @ViewBuilder
    private var noticeView: some View {
        if let outcome = lastOutcome {
            Text(Self.emailOutcomeMessage(outcome, action: lastAction))
                .font(.callout)
                .foregroundColor(Self.isAccepted(outcome) ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private func primaryButton(
        title: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking { ProgressView().controlSize(.small) }
                Text(title).tonoFont(size: 16, weight: .semibold, relativeTo: .callout)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(enabled && !isWorking ? Color.purple : Color.gray.opacity(0.3))
            .foregroundColor(.white)
            .clipShape(Capsule())
        }
        .disabled(!enabled || isWorking)
    }

    // MARK: - Local validity (a courtesy, not the authority)

    /// Cheap shape check so an obvious typo is caught before a round trip. The
    /// server's strict normalization stays the authority; this only decides
    /// whether the button is tappable.
    private var looksLikeAddress: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return !domain.isEmpty && domain.contains(".") && !domain.hasSuffix(".")
            && !domain.contains("@") && !trimmed.contains(" ")
    }

    private var canSubmitCredentials: Bool {
        looksLikeAddress && password.count >= Self.minimumPasswordLength
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func move(to next: Step) {
        step = next
        lastOutcome = nil
    }

    // MARK: - Operations
    //
    // Each one records the SHAPE of what happened and nothing else. The
    // `catch` blocks never touch the failure they caught beyond handing it to
    // `EmailAuthOutcome.from`, which classifies by case and status class.

    private func submitCreateAccount() async {
        await run(.createAccount) {
            _ = try await TonoBackend.shared.registerWithEmail(
                email: normalizedEmail, password: password
            )
            lastOutcome = .checkYourEmail
            step = .confirmSent
        }
    }

    private func submitSignIn() async {
        await run(.signIn) {
            _ = try await TonoBackend.shared.signInWithEmail(
                email: normalizedEmail, password: password
            )
            // Only the server can say this person is signed in, and it just
            // did. Clear the password from memory before leaving.
            password = ""
            onSuccess()
        }
    }

    private func submitResend() async {
        await run(.resendConfirmation) {
            _ = try await TonoBackend.shared.resendVerification(email: normalizedEmail)
            lastOutcome = .checkYourEmail
            step = .confirmSent
        }
    }

    private func submitReset() async {
        await run(.resetPassword) {
            _ = try await TonoBackend.shared.requestPasswordReset(email: normalizedEmail)
            lastOutcome = .checkYourEmail
        }
    }

    /// Run one operation, recording only its outcome shape.
    ///
    /// `isWorking` is cleared in a `defer` so a thrown failure cannot leave the
    /// sheet stuck in its busy state — the state Build 112 fixed elsewhere for
    /// the same reason.
    private func run(_ action: Action, _ operation: () async throws -> Void) async {
        lastAction = action
        lastOutcome = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            lastOutcome = TonoBackend.EmailAuthOutcome.from(error)
        }
    }

    // MARK: - Copy

    /// True when the outcome is the accepted, anti-enumerating answer rather
    /// than a failure. Drives colour only; the sentence is the same either way.
    static func isAccepted(_ outcome: TonoBackend.EmailAuthOutcome) -> Bool {
        outcome == .checkYourEmail
    }

    /// The single place an outcome becomes something a person reads.
    ///
    /// Deliberately takes an outcome and an action — never an `Error`, a
    /// status code, or a message. Exhaustive over both, with no `default`, so
    /// a new outcome is a compile error rather than a silently generic screen.
    static func emailOutcomeMessage(
        _ outcome: TonoBackend.EmailAuthOutcome, action: Action
    ) -> String {
        switch outcome {
        case .checkYourEmail:
            // The one answer that is identical for a registered and an
            // unregistered address. It differs only by which link is waiting.
            switch action {
            case .createAccount, .resendConfirmation:
                return "Check your email. Open the link we sent to confirm your address, then sign in."
            case .resetPassword:
                return "Check your email. Open the link we sent to choose a new password."
            case .signIn:
                return "Check your email for the link we sent you."
            }
        case .verificationRequired:
            return "Confirm your email address first. Open the link we sent you, or ask for a new one."
        case .invalidCredentials:
            return "That email and password don't match. Check them and try again."
        case .rateLimited:
            // A rate limit is never a paywall and never a bad password. Build
            // 113 fixed exactly this confusion on the Coach path; the account
            // path must not reintroduce it.
            return "Too many tries just now. Wait a minute and try again."
        case .invalidInput:
            // Covers BOTH input-shaped refusals the server can answer with:
            // an address it will not accept, and a password the auth provider
            // considers too weak on its own rules. Naming only the length
            // floor was a dead end for the second one — a person who typed
            // twenty characters and was refused for lack of a digit would read
            // "use at least 8 characters", change nothing, and be refused
            // again. The client cannot tell the two apart (both arrive as 400,
            // deliberately carrying no provider text), so the sentence must be
            // true of either.
            return "That email address or password can't be used. Try a different address, or a longer, less predictable password."
        case .offline:
            return "You're offline. Check your connection and try again."
        case .serviceUnavailable:
            // Never "we sent you an email". An operational failure must not be
            // dressed up as delivery, or the person waits for mail that will
            // never arrive.
            return "Email sign-in isn't available right now. Try again in a few minutes."
        case .addressAlreadyLinked:
            // The ONE sentence in this file that says something about whether
            // an address is spoken for, and the only one that may.
            //
            // It is reachable only after the auth provider accepted this
            // password for this address, so the person reading it has already
            // proven they own the mailbox — they learn nothing a stranger
            // could not be refused at the password step. Every other sentence
            // here is reachable unauthenticated and must stay silent.
            //
            // It has to be specific because retrying is futile: the server
            // will refuse the same way forever. Naming the two things that do
            // work is the difference between an exit and a loop.
            return "That address is already in use by a different account. Sign in the way you did the first time, or use a different address."
        case .unknownFailure:
            return "That didn't work. Try again."
        }
    }
}
