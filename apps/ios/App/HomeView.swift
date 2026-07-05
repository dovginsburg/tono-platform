// HomeView.swift
// Guided setup screen. Walks the user through three steps — enable the
// keyboard in Settings, grant Full Access, open Tono once so the
// keyboard loads — then transitions to a "you're set" state.
//
// Detection strategy: the keyboard extension writes `keyboardLoaded`
// to the App Group UserDefaults on its first `viewDidLoad`. This view
// polls that flag whenever the scene returns to the foreground.

import SwiftUI

struct HomeView: View {
    @Binding var prefs: TonePreferences
    @Environment(\.scenePhase) private var scenePhase

    @State private var keyboardEnabled = false
    @State private var isRegistered    = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    if keyboardEnabled && isRegistered {
                        readyCard
                    } else {
                        setupCard
                    }
                    footer
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.3), value: keyboardEnabled)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Tono")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear { checkStatus() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { checkStatus() }
        }
    }

    // MARK: - Sub-views

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say what you mean.\nLand how you intend.")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Pre-send rewrites for any text field — warmer, clearer, funnier, or safer — with a risk badge before you hit send.")
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupRow(
                number: 1,
                title: "Enable the keyboard",
                detail: "Settings → General → Keyboard → Keyboards → Add New Keyboard → Tono",
                done: false,
                buttonLabel: "Open Settings",
                onTap: openSettings
            )
            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
            SetupRow(
                number: 2,
                title: "Allow Full Access",
                detail: "Tap Tono in the keyboard list, then toggle Allow Full Access. Required for network calls.",
                done: false
            )
            Divider().background(Color.white.opacity(0.08)).padding(.leading, 52)
            SetupRow(
                number: 3,
                title: "Switch to Tono and type",
                detail: "Long-press 🌐 in any text field, pick Tono, and tap Coach on your draft.",
                done: keyboardEnabled
            )
        }
        .padding(16)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var readyCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("You're all set!")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Switch to the Tono keyboard in any text field and tap Coach on a draft.")
                .font(.system(size: 15, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Enable daily reminders") {
                NotificationManager.shared.requestPermission()
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(.purple)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                Text("Free · 3 coaching sessions/day")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Text("All four rewrite axes on the iOS keyboard. No credit card, no trial — just works.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
            Group {
                Text("Pro · $5.99/mo or $39.99/yr")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.top, 4)
                Text("7-day free trial, then auto-renews unless cancelled. Unlimited rewrites, style memory, per-recipient coaching, weekly digest. Cancel anytime in Settings.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Actions

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func checkStatus() {
        keyboardEnabled = SharedStore.defaults.bool(forKey: SharedKeys.keyboardLoaded)
        isRegistered    = TonoBackend.shared.isRegistered()
    }
}

// MARK: - SetupRow

private struct SetupRow: View {
    let number:      Int
    let title:       String
    let detail:      String
    let done:        Bool
    var buttonLabel: String? = nil
    var onTap:       (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.purple)
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(done ? .green : .white)
                Text(detail)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if let label = buttonLabel, let action = onTap, !done {
                    Button(action: action) {
                        HStack(spacing: 6) {
                            Text(label)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}
