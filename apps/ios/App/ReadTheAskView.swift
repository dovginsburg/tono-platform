// ReadTheAskView.swift
// Build 117 — the Read the Ask surfaces in the companion app.
//
// Target membership: Tono only. Nothing here is compiled into the keyboard, the
// Share extension or the iMessage extension.
//
// Three pieces, in the order a person meets them:
//
//   1. `ReadTheAskModeSelector` — the `Rewrite | Read the Ask` pair at the top
//      of Coach. This is the whole of the new navigation: no new root tab, no
//      new screen, no new onboarding. The person picks what they want Tono to
//      do with this message, because Tono will not pick for them.
//   2. `ReadTheAskActivationSheet` — the first tap. The switch inside it starts
//      OFF and STAYS off until the person moves it; `Continue` commits whatever
//      the switch actually shows, so a person who reads the sheet and taps the
//      obvious button does not accidentally turn a feature on.
//   3. `ReadTheAskPanel` — the reading itself, and the two drafts made from it.
//
// The founder-approved direction of 2026-07-27 covers the interaction and the
// look; it lives with the product contract, not in this repo, so it is named
// rather than cited by a path nobody here can open. (The earlier citation
// pointed at `assets/tono-read-the-ask`, which does not exist in this
// repository — an unverifiable provenance claim is worse than none.)
// Runtime accessibility is a separate gate and is
// taken seriously here rather than inherited: every control states what it is
// and what it will do, the selector reports which side is selected, both
// segments clear the 44pt minimum at every Dynamic Type size, and the sheet
// scrolls so it cannot clip at the accessibility sizes — which is exactly where
// a fixed-height privacy sheet loses its `Not now` button.

import SwiftUI

// MARK: - The mode selector

/// `Rewrite | Read the Ask`.
///
/// Built from the app's own capsule idiom rather than `Picker(.segmented)` so it
/// renders as the approved purple pill, and given the accessibility a real
/// segmented control would have had: a container that says what the choice is,
/// two buttons that say what they do, and `.isSelected` on the one that is.
struct ReadTheAskModeSelector: View {

    @Binding var mode: TonoRequestMode

    /// The Human Interface Guidelines minimum. A control this important is not
    /// allowed to be a 30pt strip because the text inside it happens to be
    /// short.
    static let minimumTouchTarget: CGFloat = 44

    var body: some View {
        HStack(spacing: 4) {
            segment(.rewrite, title: ReadTheAskCopy.rewriteModeTitle)
            segment(.readAsk, title: ReadTheAskCopy.readAskModeTitle)
        }
        .padding(4)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ReadTheAskCopy.modeSelectorAccessibilityLabel)
    }

    private func segment(_ value: TonoRequestMode, title: String) -> some View {
        Button {
            mode = value
        } label: {
            Text(title)
                .tonoFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                .foregroundColor(mode == value ? .white : .white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(minHeight: Self.minimumTouchTarget)
                .background(mode == value ? Color.purple : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 11))
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(mode == value ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The activation sheet

/// The first tap on Read the Ask.
///
/// Two properties matter more than anything else on this screen:
///
///   * the switch is OFF when the sheet opens and nothing but the person's own
///     finger changes that;
///   * `Continue` commits what the switch SHOWS. Tapping the primary button on
///     a sheet you have not touched leaves the feature off, which is the only
///     honest reading of a switch that says "Off by default".
///
/// It scrolls. A privacy sheet that clips its own `Not now` button at large text
/// sizes has taken the exit away from exactly the person most likely to want it.
struct ReadTheAskActivationSheet: View {

    /// Whether the person turned the switch on before confirming. Starts OFF and
    /// is deliberately local: nothing is persisted until `Continue`.
    @State private var pendingEnabled = false

    /// `true` only when the person confirmed with the switch on.
    let onDecision: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(ReadTheAskCopy.activationTitle)
                        .tonoFont(size: 22, weight: .bold, relativeTo: .title2)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(ReadTheAskCopy.activationBody)
                        .tonoFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $pendingEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ReadTheAskCopy.activationToggleTitle)
                                .tonoFont(size: 16, weight: .semibold, relativeTo: .body)
                                .foregroundColor(.white)
                            Text(ReadTheAskCopy.activationToggleDetail)
                                .tonoFont(size: 13, relativeTo: .footnote)
                                .foregroundColor(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.purple)
                    .padding(16)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityHint(ReadTheAskCopy.settingsDisclosure)

                    // Side by side on a phone; stacked once the labels need the
                    // width, so neither button is ever truncated into a guess.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { dismissButton; confirmButton }
                        VStack(spacing: 10) { confirmButton; dismissButton }
                    }
                }
                .padding(24)
                .tonoReadableColumn(.form)
            }
            .background(Color(white: 0.08).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var dismissButton: some View {
        Button {
            // Nothing is written. "Not now" means nothing happened.
            onDecision(false)
            dismiss()
        } label: {
            Text(ReadTheAskCopy.activationDismiss)
                .tonoFont(size: 16, weight: .semibold, relativeTo: .body)
                .frame(maxWidth: .infinity)
                .frame(minHeight: ReadTheAskModeSelector.minimumTouchTarget)
                .background(Color.white.opacity(0.10))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(ReadTheAskCopy.activationDismiss)
        .accessibilityHint("Leaves Read the Ask off.")
    }

    private var confirmButton: some View {
        Button {
            onDecision(pendingEnabled)
            dismiss()
        } label: {
            Text(ReadTheAskCopy.activationConfirm)
                .tonoFont(size: 16, weight: .semibold, relativeTo: .body)
                .frame(maxWidth: .infinity)
                .frame(minHeight: ReadTheAskModeSelector.minimumTouchTarget)
                .background(Color.purple)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityLabel(ReadTheAskCopy.activationConfirm)
        .accessibilityHint(
            pendingEnabled ? "Turns Read the Ask on." : "Leaves Read the Ask off."
        )
    }
}

// MARK: - The reading

/// The Read the Ask flow: the message, the reading, and the two drafts.
struct ReadTheAskPanel: View {

    /// The editor's buffer, owned by the caller.
    ///
    /// Deliberately NOT read straight out of `session`. `ReadTheAskSession` is
    /// an `ObservableObject`, so binding the editor to it republishes to the
    /// whole Coach surface on every keystroke — which re-identifies the editor
    /// mid-edit and loses the character. (That is not a theory: bound that way,
    /// nine tests in `Build117ReadTheAskTests` failed with the typed message
    /// never reaching the model, while the panel hosted on its own worked.) The
    /// buffer is local; the session is the record of the flow, written when the
    /// reading is asked for and cleared with everything else.
    @Binding var receivedText: String

    @ObservedObject var session: ReadTheAskSession
    let isOffline: Bool
    let route: ReadTheAskRoute

    @State private var loading = false
    @State private var errorMessage: String?

    /// The reading in flight, held so it can be cancelled.
    ///
    /// R5 asked for cancellation "if safely local", and looking for a safe
    /// place to put it found a defect rather than a nicety: a reading that
    /// returned AFTER the person tapped Remove still called `session.apply`,
    /// so the message they had just taken off the screen came back with a
    /// reading attached. Withdrawal has to mean withdrawal, so the request is
    /// cancelled and a late response is dropped.
    ///
    /// No new control: the affordances that cancel are the ones that already
    /// mean "stop" — Remove, and leaving Read the Ask.
    @State private var readingTask: Task<Void, Never>?

    init(
        receivedText: Binding<String>,
        session: ReadTheAskSession,
        isOffline: Bool,
        route: ReadTheAskRoute = .backend
    ) {
        self._receivedText = receivedText
        self.session = session
        self.isOffline = isOffline
        self.route = route
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            receivedTextEditor
            disclosure
            readButton
            if isOffline {
                notice(
                    icon: "wifi.slash",
                    text: "No internet connection. Check Wi-Fi or cellular to read a message."
                )
            } else if let errorMessage {
                notice(icon: "exclamationmark.triangle.fill", text: errorMessage, tinted: true)
            }
            if let outcome = session.outcome {
                switch outcome {
                case .reading(let result):
                    readingCard(result)
                default:
                    // Decided once, in `ReadTheAskNotice`, for this surface and
                    // Share alike.
                    if let shown = ReadTheAskNotice.forOutcome(outcome) {
                        notice(icon: shown.glyph, text: shown.message)
                    }
                }
            }
            if session.draftKind != nil {
                draftCard
            }
        }
        // Leaving Read the Ask stops the reading too.
        //
        // BUILD 117 REPAIR — cancelling on Remove was only half of it. Coach
        // switches back to Rewrite (and the Settings toggle switches the whole
        // feature off) by calling `clearReadTheAsk()`, which empties the buffer
        // and the session and takes this panel off screen — but a `Task` is not
        // cancelled by the view that made it going away. The in-flight reading
        // finished, saw an uncancelled task, and called `session.apply`, so the
        // message the person had just left behind came back with a reading
        // attached the next time they opened the surface.
        //
        // Clearing the buffer could never fix that on its own: `run()` captures
        // the text before it awaits, and the response lands on the SESSION, not
        // the buffer. The task itself has to be cancelled, which is what this
        // does — for every way of leaving, including the ones Coach owns.
        .onDisappear { cancelReading() }
    }

    // MARK: The message

    private var receivedTextEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ReadTheAskCopy.receivedTextLabel)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                // The contract's "removable before analysis", as a control. The
                // person can always take the message back out before Tono is
                // asked to do anything with it.
                if !receivedText.isEmpty {
                    Button(ReadTheAskCopy.removeReceivedText) {
                        cancelReading()
                        receivedText = ""
                        session.clear()
                        errorMessage = nil
                    }
                    .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.purple)
                    .accessibilityHint("Removes the message and its reading from this screen.")
                }
            }
            TextEditor(text: $receivedText)
            .frame(minHeight: 120)
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(.white)
            .tint(.purple)
            .overlay(alignment: .topLeading) {
                if receivedText.isEmpty {
                    Text(ReadTheAskCopy.receivedTextPlaceholder)
                        .foregroundColor(.white.opacity(0.35))
                        .tonoFont(size: 15, relativeTo: .subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(ReadTheAskCopy.receivedTextLabel)
            .accessibilityHint(ReadTheAskCopy.receivedTextPlaceholder)
        }
    }

    /// Stated BEFORE the button that transmits, and derived from the route that
    /// will run rather than written beside it.
    private var disclosure: some View {
        HStack(spacing: 8) {
            Image(systemName: route.processing == .onDevice ? "iphone" : "cloud")
                .tonoGlyphFont(size: 12, relativeTo: .caption2)
            Text(route.processing.disclosure)
                .tonoFont(size: 12, relativeTo: .caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundColor(.white.opacity(0.6))
        .accessibilityElement(children: .combine)
    }

    private var canSubmit: Bool {
        !loading && !isOffline
            && !receivedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var readButton: some View {
        Button {
            readingTask?.cancel()
            readingTask = Task { await run() }
        } label: {
            HStack(spacing: 8) {
                if loading { ProgressView().tint(.white) }
                Image(systemName: loading ? "hourglass" : "text.magnifyingglass")
                Text(loading ? "Reading…" : ReadTheAskCopy.readAction)
                    .tonoFont(size: 17, weight: .semibold, relativeTo: .body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canSubmit ? Color.purple : Color.purple.opacity(0.35))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!canSubmit)
        .accessibilityLabel(
            isOffline
                ? "\(ReadTheAskCopy.readAction), unavailable without a connection"
                : ReadTheAskCopy.readAction
        )
    }

    // MARK: The reading

    @ViewBuilder
    private func readingCard(_ result: ReadAskResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            field(ReadTheAskCopy.askHeading, result.ask, emphasised: true)

            // Absent is a fact worth stating. "No deadline stated" is true and
            // useful; a plausible invented Friday is neither.
            field(
                ReadTheAskCopy.byWhenHeading,
                result.byWhen ?? ReadTheAskCopy.byWhenAbsent,
                muted: result.byWhen == nil
            )

            if let unclear = result.unclear, !unclear.isEmpty {
                field(ReadTheAskCopy.unclearHeading, unclear)
            }

            if !result.possibleReadings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ReadTheAskCopy.possibleReadingsHeading)
                        .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.white.opacity(0.6))
                    ForEach(result.possibleReadings, id: \.self) { reading in
                        Text("• \(reading)")
                            .tonoFont(size: 14, relativeTo: .subheadline)
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(ReadTheAskCopy.possibleReadingsCaption)
                        .tonoFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.white.opacity(0.45))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(ReadTheAskCopy.possibleReadingsHeading)
            }

            Divider().background(Color.white.opacity(0.08))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { replyButton(result); clarifyButton(result) }
                VStack(spacing: 10) { replyButton(result); clarifyButton(result) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func field(
        _ heading: String, _ value: String, emphasised: Bool = false, muted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundColor(.white.opacity(0.6))
            Text(value)
                .tonoFont(
                    size: emphasised ? 17 : 15,
                    weight: emphasised ? .medium : .regular,
                    relativeTo: emphasised ? .body : .subheadline
                )
                .foregroundColor(.white.opacity(muted ? 0.55 : 0.95))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One stop per field, so VoiceOver reads "The Ask, send the Q3 deck"
        // rather than every heading followed by every value.
        .accessibilityElement(children: .combine)
    }

    private func replyButton(_ result: ReadAskResult) -> some View {
        secondaryAction(ReadTheAskCopy.draftReplyAction, glyph: "square.and.pencil") {
            session.setDraft(ReadAskReplyComposer.draftReply(for: result), kind: .reply)
        }
    }

    private func clarifyButton(_ result: ReadAskResult) -> some View {
        secondaryAction(ReadTheAskCopy.clarificationAction, glyph: "questionmark.bubble") {
            session.setDraft(ReadAskReplyComposer.clarificationRequest(for: result), kind: .clarification)
        }
    }

    private func secondaryAction(
        _ title: String, glyph: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                Text(title)
                    .tonoFont(size: 14, weight: .semibold, relativeTo: .subheadline)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: ReadTheAskModeSelector.minimumTouchTarget)
            .background(Color.white.opacity(0.10))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel(title)
        .accessibilityHint(ReadTheAskCopy.draftEditableNote)
    }

    // MARK: The draft

    /// Editable, and going nowhere on its own. There is no Send here and there
    /// never will be: the person copies what they want and sends it themselves,
    /// from their own app, in their own words.
    private var draftCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                session.draftKind == .clarification
                    ? ReadTheAskCopy.clarificationAction
                    : ReadTheAskCopy.draftReplyAction
            )
            .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
            .foregroundColor(.white.opacity(0.6))

            TextEditor(
                text: Binding(
                    get: { session.draft },
                    set: { session.editDraft($0) }
                )
            )
            .frame(minHeight: 100)
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(.white)
            .tint(.purple)
            .accessibilityLabel("Your draft")
            .accessibilityHint(ReadTheAskCopy.draftEditableNote)

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = session.draft
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy")
                    }
                    .tonoFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .padding(.horizontal, 12)
                    .frame(minHeight: ReadTheAskModeSelector.minimumTouchTarget)
                    .background(Color.white.opacity(0.10))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                Text(ReadTheAskCopy.draftEditableNote)
                    .tonoFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Notices

    private func notice(icon: String, text: String, tinted: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(tinted ? .yellow : .white.opacity(0.7))
            Text(text)
                .tonoFont(size: 13, relativeTo: .footnote)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tinted ? Color.red.opacity(0.18) : Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: Action

    /// Stop an in-flight reading and forget it. Safe to call when there is
    /// none.
    private func cancelReading() {
        readingTask?.cancel()
        readingTask = nil
        loading = false
    }

    private func run() async {
        let text = receivedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isOffline else { return }

        await MainActor.run {
            loading = true
            errorMessage = nil
            // The session becomes the record of this flow at the moment the
            // reading is asked for — which is also the moment any reading of a
            // PREVIOUS message stops being about anything on screen.
            session.setReceivedText(text)
        }

        do {
            _ = try await TonoBackend.shared.registerIfNeeded(
                platform: "ios",
                appVersion: Bundle.main.infoDictionaryString("CFBundleShortVersionString")
            )
            // The mode is stated here, at the call site, every time.
            let outcome = try await TonoBackend.shared.readAsk(
                receivedText: text, mode: .readAsk, route: route
            )
            // A response that arrives after the person withdrew is not an
            // answer to anything on screen.
            guard !Task.isCancelled else { return }
            await MainActor.run {
                session.apply(outcome)
                loading = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // `.readMessage`, not `.coachDraft`. See `ReadTheAskFailure`.
                errorMessage = ReadTheAskFailure.message(for: error)
                loading = false
            }
        }
    }
}

private extension Bundle {
    func infoDictionaryString(_ key: String) -> String {
        infoDictionary?[key] as? String ?? "0.0"
    }
}
