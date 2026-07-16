// TonoMessagesExtension/MessagesViewController.swift
// iMessage extension entry point — enables Tono analysis directly in Messages.
//
// Contract (build 90):
//   compact  → a single "Coach a message" affordance in the Messages drawer
//   expanded → draft field + Coach button
//   draft    → user types/pastes the message they are about to send
//   Coach    → deliberate, authenticated backend round-trip (Bearer token from
//              the shared Keychain; fails closed with a visible, safe message
//              if the account has not been set up yet)
//   select   → user taps one of the four rewrites
//   insert   → the rewrite is inserted as PLAIN TEXT into the Messages input
//              field via MSConversation.insertText(_:), where the user reviews
//              and sends it themselves. We never fabricate an MSMessage bubble,
//              never auto-send, and never touch the pasteboard.
//
// Every failure path (not-registered, network, decode, insert) surfaces a
// short, non-technical line in the UI instead of failing silently.

import UIKit
import Messages
import SwiftUI

class MessagesViewController: MSMessagesAppViewController {
    private var hostingController: UIHostingController<MessagesRootView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        installHostingController()
    }

    private func installHostingController() {
        let host = UIHostingController(rootView: makeRootView())
        hostingController = host
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func makeRootView() -> MessagesRootView {
        MessagesRootView(
            presentationStyle: presentationStyle,
            // Read the auth state fresh each time the UI is (re)built so a
            // sign-in that happened in the host app is reflected immediately.
            isRegistered: TonoBackend.shared.isRegistered(),
            onRequestExpand: { [weak self] in
                self?.requestPresentationStyle(.expanded)
            },
            onInsertMessage: { [weak self] rewrittenText, completion in
                self?.insertRewrite(rewrittenText, completion: completion)
            }
        )
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        updateHostingController()
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        updateHostingController()
    }

    private func updateHostingController() {
        hostingController?.rootView = makeRootView()
    }

    /// Insert the chosen rewrite as plain text into the Messages compose field.
    /// The user keeps full control: they see the text land in the input bar and
    /// tap send themselves. On failure we report a short message back to the UI.
    private func insertRewrite(_ text: String, completion: @escaping (String?) -> Void) {
        guard let conversation = activeConversation else {
            completion("Couldn’t reach the message field. Try reopening Tono.")
            return
        }
        conversation.insertText(text) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    completion("Couldn’t insert the rewrite: \(error.localizedDescription)")
                } else {
                    // Collapse back to compact so the user is looking at their
                    // freshly-inserted draft in the input bar.
                    self?.requestPresentationStyle(.compact)
                    completion(nil)
                }
            }
        }
    }
}

// MARK: - SwiftUI Root View

struct MessagesRootView: View {
    let presentationStyle: MSMessagesAppPresentationStyle
    let isRegistered: Bool
    let onRequestExpand: () -> Void
    /// (rewrite, completion) — completion delivers nil on success or a short,
    /// user-facing error string on failure.
    let onInsertMessage: (String, @escaping (String?) -> Void) -> Void

    @State private var draftText: String = ""
    @State private var analysis: ToneAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didInsert = false

    var body: some View {
        if presentationStyle == .compact {
            compactView
        } else {
            expandedView
        }
    }

    private var compactView: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.title2)
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tono Coach")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(didInsert ? "Rewrite added — review & send" : "Analyze & rewrite your message")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onRequestExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Color.purple)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Coach a message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var expandedView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !isRegistered {
                        notRegisteredBanner
                    }

                    TextField("Type or paste your message...", text: $draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .lineLimit(3...8)

                    Button(action: runAnalysis) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Coach")
                        }
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.purple)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                    }
                    .disabled(!canCoach)

                    if isLoading {
                        ProgressView("Analyzing...")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }

                    if let err = errorMessage {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    if let a = analysis {
                        resultsSection(a)
                    }
                }
                .padding()
            }
            .navigationTitle("Tono")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var notRegisteredBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Set up Tono first", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Open the Tono app once to create your account, then come back to coach messages here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var canCoach: Bool {
        isRegistered
            && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isLoading
    }

    @ViewBuilder
    private func resultsSection(_ a: ToneAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(riskColor(a.riskLevel)).frame(width: 8, height: 8)
                Text(a.riskLevel.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(riskColor(a.riskLevel).opacity(0.15))
            .clipShape(Capsule())

            Text(a.perception)
                .font(.system(size: 15, weight: .medium, design: .rounded))

            Text("Tap a rewrite to drop it into your message.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(a.suggestions) { s in
                Button(action: { insert(s.text) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(s.axis.displayName, systemImage: s.axis.glyph)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                        Text(s.text)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }

    private func runAnalysis() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegistered else {
            errorMessage = "Open the Tono app once to create your account, then try again."
            return
        }
        guard !trimmed.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        analysis = nil
        Task { await performAnalysis() }
    }

    private func insert(_ text: String) {
        errorMessage = nil
        onInsertMessage(text) { failure in
            if let failure {
                errorMessage = failure
            } else {
                didInsert = true
            }
        }
    }

    private func performAnalysis() async {
        do {
            let req = AnalysisRequest(draft: draftText, axes: RewriteAxis.allCases)
            var perception = ""
            var suggestions: [RewriteSuggestion] = []
            var riskLevel: RiskLevel = .medium
            var reason: String?
            var flags: [String] = []
            var subtext = ""

            for await event in ToneEngine.backend().analyzeStream(req) {
                switch event {
                case .perception(let text): perception = text
                case .suggestion(let a, let text, let rationale, let riskAfter):
                    if let axis = RewriteAxis(rawValue: a) {
                        suggestions.append(RewriteSuggestion(
                            axis: axis, text: text, rationale: rationale,
                            riskAfter: riskAfter.flatMap { RiskLevel(rawValue: $0) }
                        ))
                    }
                case .complete(let level, let st, let rr, let f):
                    riskLevel = RiskLevel(rawValue: level) ?? .medium
                    subtext = st; reason = rr; flags = f
                case .error(let msg): throw ToneEngineError.backend(msg)
                }
            }
            suggestions = try suggestions.canonicalCoachChoices()
            await MainActor.run {
                analysis = ToneAnalysis(riskLevel: riskLevel, perception: perception, subtext: subtext, reason: reason, suggestions: suggestions, flags: flags)
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
}
