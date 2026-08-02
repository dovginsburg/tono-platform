// TonoMessagesExtension/MessagesViewController.swift
// iMessage extension entry point — enables Tono analysis directly in Messages.
//
// Contract (build 90):
//   compact  → a single "Coach a message" affordance in the Messages drawer
//   expanded → draft field + Safer and the keyboard's two configured chips
//   draft    → user types/pastes the message they are about to send
//   chip     → one deliberate, authenticated backend round-trip (Bearer token from
//              the shared Keychain; fails closed with a visible, safe message
//              if the account has not been set up yet)
//   result   → one editable rewrite with explicit Insert and Dismiss actions
//   insert   → the edited rewrite is inserted as PLAIN TEXT into the Messages input
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
                    // Build 112: never hand the host's own failure text to the
                    // user — say what happened and what to do.
                    completion(ConsumerErrorCopy.message(for: error, action: .insertRewrite))
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
    @State private var selectedAxis: String?
    @State private var resultText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didInsert = false

    private var toneAxes: [String] {
        let settings = CoachVariantSettingsStore().load()
        return ["safer"] + settings.enabled
            .prefix(CoachVariantSettings.maximumOptionalCount)
            .map(\.rawValue)
    }

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

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose one tone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach(toneAxes, id: \.self) { axis in
                                Button(action: { requestRewrite(axis: axis) }) {
                                    Text(CoachToneChipContract.label(for: axis))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 9)
                                        .foregroundColor(toneColor(axis))
                                        .background(toneColor(axis).opacity(0.18))
                                        .clipShape(Capsule())
                                }
                                .disabled(!canCoach)
                                .accessibilityLabel("\(CoachToneChipContract.label(for: axis)) tone")
                            }
                        }
                    }

                    if isLoading {
                        ProgressView("Rewriting...")
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

                    if selectedAxis != nil, !resultText.isEmpty {
                        resultEditor
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

    private var resultEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit before inserting")
                .font(.caption)
                .foregroundColor(.secondary)
            TextEditor(text: $resultText)
                .font(.system(size: 14, design: .rounded))
                .frame(minHeight: 100)
                .padding(8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Dismiss", action: dismissResult)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Insert") { insert(resultText) }
                    .buttonStyle(.borderedProminent)
                    .disabled(resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func toneColor(_ axis: String) -> Color {
        guard let hex = CoachToneChipContract.accentHex(for: axis),
              let value = UInt64(hex, radix: 16) else {
            return .secondary
        }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    private func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func dismissResult() {
        selectedAxis = nil
        resultText = ""
        errorMessage = nil
    }

    /// Outcomes of a rewrite request that are not failures of anything the
    /// user can see. Kept separate from the transport's error type so they
    /// never inherit its description.
    private enum MessagesRewriteOutcome: Error {
        case noDistinctRewrite
    }

    private func requestRewrite(axis: String) {
        let source = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRegistered else {
            errorMessage = "Open the Tono app once to create your account, then try again."
            return
        }
        guard !source.isEmpty, !isLoading else { return }
        selectedAxis = axis
        resultText = ""
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let customPrompt = axis == "custom"
                    ? CoachVariantSettingsStore().load().customInstruction
                    : nil
                let result = try await TonoBackend.shared.analyzeVariant(
                    text: source,
                    axis: axis,
                    customPrompt: customPrompt
                )
                let rewrite = result.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard result.status == "ok", !rewrite.isEmpty,
                      normalized(rewrite) != normalized(source) else {
                    // Build 112: this was thrown as a decoding failure, so the
                    // sentence reached the user wrapped in that failure's own
                    // description. It is its own outcome — a distinct rewrite
                    // the user can ask for again — and carries no technical
                    // cause, so it keeps its own case and its own copy.
                    throw MessagesRewriteOutcome.noDistinctRewrite
                }
                await MainActor.run {
                    resultText = rewrite
                    isLoading = false
                }
            } catch MessagesRewriteOutcome.noDistinctRewrite {
                await MainActor.run {
                    selectedAxis = nil
                    resultText = ""
                    errorMessage = "No distinct rewrite yet. Tap the tone again to retry."
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    selectedAxis = nil
                    resultText = ""
                    errorMessage = ConsumerErrorCopy.message(for: error, action: .coachDraft)
                    isLoading = false
                }
            }
        }
    }

    private func insert(_ text: String) {
        errorMessage = nil
        // The controller hands back finished consumer copy, never a failure —
        // the binding is named for that so nothing raw can slip in unnoticed.
        onInsertMessage(text) { problem in
            if let problem {
                errorMessage = problem
            } else {
                didInsert = true
            }
        }
    }
}
