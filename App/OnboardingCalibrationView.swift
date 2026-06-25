// OnboardingCalibrationView.swift
// First-run flow. Seeds UserMemory and teaches the keyboard workflow +
// privacy contract before the user's first Coach session.
// Gated by the `onboarding_calibration` feature flag.

import SwiftUI

struct OnboardingCalibrationView: View {
    let onDone: () -> Void

    @State private var step = 0
    @State private var roleAnswer = ""
    @State private var tendencyAnswer = ""
    @State private var recipientAnswer = ""

    // 5 steps total: 3 input + 2 informational (D3 + D4).
    private let totalSteps = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar

                TabView(selection: $step) {
                    roleStep.tag(0)
                    tendencyStep.tag(1)
                    recipientStep.tag(2)
                    privacyStep.tag(3)
                    howItWorksStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)

                nextButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
            }
            .navigationTitle("Quick setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { finish() }
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.purple : Color.secondary.opacity(0.3))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 32)
    }

    // MARK: - Input steps (1–3)

    private var roleStep: some View {
        StepCard(
            icon: "person.fill",
            question: "What best describes you?",
            placeholder: "e.g. manager, founder, individual contributor",
            answer: $roleAnswer
        )
    }

    private var tendencyStep: some View {
        StepCard(
            icon: "pencil",
            question: "How would others describe your writing?",
            placeholder: "e.g. direct and brief, overly formal, occasionally passive-aggressive",
            answer: $tendencyAnswer
        )
    }

    private var recipientStep: some View {
        StepCard(
            icon: "person.2.fill",
            question: "Who do you message most often?",
            placeholder: "e.g. my manager, teammates, clients",
            answer: $recipientAnswer
        )
    }

    // MARK: - Informational steps (4–5)

    /// D3: Privacy-as-pitch. Surface the trust boundary before the first session.
    private var privacyStep: some View {
        InfoCard(
            icon: "lock.shield",
            headline: "Your memory, your control",
            bullets: [
                "Everything Tono learns stays on your device",
                "You can see and delete every fact in the Memory tab",
                "Tono only gets smarter during sessions you choose",
                "API keys never leave our server — your device never sees them",
            ]
        )
    }

    /// D4: Keyboard workflow. Teach the draft-then-switch pattern and the
    /// trust boundary before the user hits a secure-field block.
    private var howItWorksStep: some View {
        InfoCard(
            icon: "keyboard.badge.arrow.up",
            headline: "How to use Tono",
            bullets: [
                "Draft in any app, then switch to the Tono keyboard when you're ready to send",
                "Tono can't read anything unless you tap Coach or Read",
                "Secure fields (passwords, banking) block all keyboards — that's iOS, not us",
                "Tap Coach to analyze your draft · Tap Read to interpret a message you received",
            ]
        )
    }

    // MARK: - Next / finish

    private var nextButton: some View {
        Button(action: advance) {
            Text(step == totalSteps - 1 ? "Get started" : "Next")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.purple)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func advance() {
        if step < totalSteps - 1 {
            step += 1
        } else {
            finish()
        }
    }

    private func finish() {
        seedMemory()
        SharedStore.defaults.set(true, forKey: SharedKeys.onboardingDone)
        onDone()
    }

    private func seedMemory() {
        let role = roleAnswer.trimmingCharacters(in: .whitespaces)
        if !role.isEmpty {
            UserMemory.addManual(content: role, category: .profile)
        }
        let tendency = tendencyAnswer.trimmingCharacters(in: .whitespaces)
        if !tendency.isEmpty {
            UserMemory.addManual(content: tendency, category: .tendency)
        }
        let recipient = recipientAnswer.trimmingCharacters(in: .whitespaces)
        if !recipient.isEmpty {
            UserMemory.addManual(content: "Often messages \(recipient)", category: .communication)
        }
    }
}

// MARK: - StepCard (input)

private struct StepCard: View {
    let icon: String
    let question: String
    let placeholder: String
    @Binding var answer: String

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.purple)

            Text(question)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)

            TextField(placeholder, text: $answer, axis: .vertical)
                .lineLimit(2...4)
                .padding(14)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .font(.system(size: 16, design: .rounded))
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - InfoCard (D3/D4 informational steps)

private struct InfoCard: View {
    let icon: String
    let headline: String
    let bullets: [String]

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.purple)

            Text(headline)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.purple)
                            .frame(width: 16, height: 16)
                            .padding(.top, 2)
                        Text(bullet)
                            .font(.system(size: 15, design: .rounded))
                            .foregroundColor(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
