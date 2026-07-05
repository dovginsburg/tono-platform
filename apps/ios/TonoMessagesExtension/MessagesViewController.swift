// TonoMessagesExtension/MessagesViewController.swift
// iMessage extension entry point — enables Tono analysis directly in Messages.

import UIKit
import Messages
import SwiftUI

class MessagesViewController: MSMessagesAppViewController {
    private var hostingController: UIHostingController<MessagesRootView>?
    private var currentText: String = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    private func setupUI() {
        let rootView = MessagesRootView(
            text: currentText,
            presentationStyle: presentationStyle,
            onRequestExpand: { [weak self] in
                self?.requestPresentationStyle(.expanded)
            },
            onInsertMessage: { [weak self] rewrittenText in
                self?.insertRewrite(rewrittenText)
            }
        )
        let host = UIHostingController(rootView: rootView)
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

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        if let message = conversation.selectedMessage, let url = message.url {
            currentText = url.absoluteString
        }
        updateHostingController()
    }

    override func didResignActive(with conversation: MSConversation) {
        super.didResignActive(with: conversation)
    }

    override func didReceive(_ message: MSMessage, conversation: MSConversation) {
        super.didReceive(message, conversation: conversation)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        updateHostingController()
    }

    private func updateHostingController() {
        hostingController?.rootView = MessagesRootView(
            text: currentText,
            presentationStyle: presentationStyle,
            onRequestExpand: { [weak self] in
                self?.requestPresentationStyle(.expanded)
            },
            onInsertMessage: { [weak self] rewrittenText in
                self?.insertRewrite(rewrittenText)
            }
        )
    }

    private func insertRewrite(_ text: String) {
        guard let conversation = activeConversation else { return }
        let session = MSSession()
        let message = MSMessage(session: session)
        let layout = MSMessageTemplateLayout()
        layout.caption = text
        message.layout = layout
        conversation.insert(message) { error in
            if let error {
                print("[Messages] insert error: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - SwiftUI Root View

struct MessagesRootView: View {
    let text: String
    let presentationStyle: MSMessagesAppPresentationStyle
    let onRequestExpand: () -> Void
    let onInsertMessage: (String) -> Void

    @State private var draftText: String = ""
    @State private var analysis: ToneAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?

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
                Text("Analyze & rewrite your message")
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var expandedView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Type or paste your message...", text: $draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .lineLimit(3...8)

                    HStack(spacing: 8) {
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
                        .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)

                        ForEach(RewriteAxis.allCases) { axis in
                            Button(action: { runAxisRewrite(axis) }) {
                                Text(axis.displayName)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color(.systemGray5))
                                    .clipShape(Capsule())
                            }
                            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                        }
                    }

                    if isLoading {
                        ProgressView("Analyzing...")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding()
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
        .onAppear {
            if !text.isEmpty && draftText.isEmpty {
                draftText = text
            }
        }
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

            ForEach(a.suggestions) { s in
                Button(action: { onInsertMessage(s.text) }) {
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
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task {
            await performAnalysis(axes: RewriteAxis.allCases)
        }
    }

    private func runAxisRewrite(_ axis: RewriteAxis) {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoading = true
        errorMessage = nil
        Task {
            await performAnalysis(axes: [axis])
        }
    }

    private func performAnalysis(axes: [RewriteAxis]) async {
        do {
            let req = AnalysisRequest(draft: draftText, axes: axes)
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
