// TonoApp.swift
// SwiftUI entry point. Starts the StoreKit 2 transaction listener and
// triggers in-app review prompts at usage milestones.

import SwiftUI
import StoreKit
import WidgetKit

@main
struct TonoApp: App {
    init() {
        // Build 116 — one connectivity observer, started once, for the life of
        // the process. Started here rather than by a view so that no surface's
        // appearance, recreation or teardown can decide whether the app is able
        // to notice a connection coming or going.
        TonoConnectivity.shared.start()
        StoreKitManager.shared.start()
        // Build 123 — RevenueCat canary. A no-op unless REVENUECAT_PUBLIC_SDK_KEY
        // is set (kill switch). The backend stays the sole entitlement authority;
        // this only wires RevenueCat's identity/observation layer with the
        // canonical account UUID. Never creates an anonymous durable identity.
        RevenueCatManager.shared.configureIfEnabled()
        // Google sign-in: configure the SDK once IF it is linked and a real Tono
        // client ID is present in this build. A no-op otherwise (fail closed), so
        // an unconfigured build never touches the SDK and shows no Google button.
        GoogleSignInConfig.configureIfPossible()
        // A1: crash + OOM reporting (no-op until FIREBASE_ENABLED is set in build flags).
        CrashReporter.configure()
        // A2: MetricKit memory diagnostics — receives yesterday's metrics once/day.
        MetricKitReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @State private var prefs = TonePreferences()
    @State private var showOnboarding = false
    @State private var showEntryPointsOnboarding = false
    /// Presented when the "Open Tono Keyboard Setup" App Intent left a one-shot
    /// route. Local-only: the intent reads and sends nothing; this just shows
    /// the existing setup screen (which owns the sanctioned iOS-settings jump).
    @State private var showKeyboardSetup = false
    @Environment(\.requestReview) var requestReview

    var body: some View {
        TabView {
            // Build 112: ONE Coach experience. The separate in-app rehearsal
            // tab was removed — it duplicated this screen's draft editor,
            // action, results and request path with a second one. Coach is the
            // single host-app coaching surface; Settings is also reachable from
            // a gear in CoachView's toolbar.
            CoachView()
                .tabItem { Label("Coach", systemImage: "sparkles") }

            DigestView()
                .tabItem { Label("This Week", systemImage: "chart.line.uptrend.xyaxis") }

            SettingsView(prefs: $prefs)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(.purple)
        .onOpenURL { url in
            // Complete a Google OAuth redirect (reversed-client-ID scheme). A
            // no-op unless Google is linked and configured, so any other deep
            // link falls through untouched.
            GoogleSignInConfig.handle(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Build 116 — the observer keeps running while backgrounded, so
            // this is a re-assertion rather than the primary path. It makes the
            // foreground transition deterministic instead of dependent on
            // whether an update happened to be delivered off screen — which is
            // exactly the trip the person takes to reach Airplane Mode.
            TonoConnectivity.shared.refresh()
            // Re-assert the RevenueCat identity once the canonical account UUID
            // exists (it is minted at registration, possibly after cold launch).
            // No-op when RevenueCat is disabled or no account is present yet.
            RevenueCatManager.shared.identifyFromKeychain()
            promptReviewIfEarned()
            NotificationManager.shared.ensureNudgeScheduled()
            WidgetCenter.shared.reloadAllTimelines()
            consumePendingAppIntentRoute()
        }
        .task {
            // Cold launch via the intent: the didBecomeActive notification can
            // fire before this view subscribes, so also consume once here. The
            // read-and-clear signal makes the double check idempotent.
            consumePendingAppIntentRoute()
            await fetchFeaturesAndOnboard()
        }
        .sheet(isPresented: $showKeyboardSetup) {
            NavigationStack {
                SetupDoctorView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showKeyboardSetup = false }
                        }
                    }
            }
        }
        .fullScreenCover(isPresented: $showEntryPointsOnboarding) {
            OnboardingEntryPointsView {
                // After entry-points tiles, fall through to calibration
                // if user hasn't done that flow yet.
                let calibrationDone = SharedStore.defaults.bool(forKey: SharedKeys.onboardingDone)
                if !calibrationDone && FeatureFlags.isEnabled(.onboardingCalibration) {
                    showOnboarding = true
                }
                showEntryPointsOnboarding = false
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingCalibrationView {
                showOnboarding = false
            }
        }
    }

    /// Present the screen a local-only App Intent asked for, once. The signal is
    /// read-and-cleared, so a route shows its screen a single time rather than on
    /// every foreground.
    private func consumePendingAppIntentRoute() {
        switch AppIntentRouteSignal().consumePending() {
        case .keyboardSetup:
            showKeyboardSetup = true
        case .none:
            break
        }
    }

    private func promptReviewIfEarned() {
        let count = SharedStore.defaults.integer(forKey: SharedKeys.coachUseCount)
        // The OS throttles how often the sheet actually appears (≤3/yr),
        // so calling at natural milestones is safe.
        if count == 3 || count == 10 || count == 25 {
            requestReview()
        }
    }

    private func fetchFeaturesAndOnboard() async {
        guard TonoBackend.shared.isRegistered() else { return }
        if let flags = try? await TonoBackend.shared.fetchFeatures() {
            FeatureFlags.update(from: flags)
            // Schedule or cancel the weekly digest notification based on the flag.
            if flags["weekly_digest"] == true {
                NotificationManager.shared.scheduleWeeklyDigest()
            } else {
                NotificationManager.shared.cancelWeeklyDigest()
            }
        }
        // v1.0 onboarding order: entry-points tiles first (per skill
        // tono-ios-multi-entry-architecture), then calibration if not done.
        // Both are independently gated so a user who skips entry-points
        // still sees the calibration flow if applicable.
        let entryPointsDone = SharedStore.defaults.bool(forKey: SharedKeys.entryPointsOnboardingDone)
        if !entryPointsDone && FeatureFlags.isEnabled(.onboardingCalibration) {
            showEntryPointsOnboarding = true
            return
        }
        let calibrationDone = SharedStore.defaults.bool(forKey: SharedKeys.onboardingDone)
        if !calibrationDone && FeatureFlags.isEnabled(.onboardingCalibration) {
            showOnboarding = true
        }
    }
}
