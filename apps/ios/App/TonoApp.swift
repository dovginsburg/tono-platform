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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Build 116 — the observer keeps running while backgrounded, so
            // this is a re-assertion rather than the primary path. It makes the
            // foreground transition deterministic instead of dependent on
            // whether an update happened to be delivered off screen — which is
            // exactly the trip the person takes to reach Airplane Mode.
            TonoConnectivity.shared.refresh()
            promptReviewIfEarned()
            NotificationManager.shared.ensureNudgeScheduled()
            WidgetCenter.shared.reloadAllTimelines()
        }
        .task { await fetchFeaturesAndOnboard() }
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
