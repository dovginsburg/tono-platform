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

// MARK: - Ink and fields

/// Every surface these views draw text ON, and what it composites down to.
///
/// BUILD 117 REPAIR (N-B) — why this exists.
///
/// The contrast gate used to carry a hand-transcribed table of nine colours.
/// Three foregrounds the surfaces actually use were not in it —
/// `possibleReadingsCaption`, `draftEditableNote` and `receivedTextPlaceholder`
/// — and measured against the field they are really drawn on, two of them
/// failed WCAG AA outright and the third cleared it by 0.4%. The test was named
/// `testEveryNewSurfaceTextColour…` and the handoff said "every foreground the
/// new surfaces use is measured against the field it is drawn on". Neither was
/// true, and neither could be: a table transcribed by hand drifts from the view
/// in both directions and nothing notices.
///
/// So the view and the gate now read the SAME values. A foreground that is not
/// in `ReadTheAskInk` cannot be drawn (there is a test for that), and every case
/// that is in it is measured on `field`, composited down to an opaque colour
/// rather than scored on its alpha channel.
enum ReadTheAskField: String, CaseIterable {
    case appBackground, sheetBackground
    case selectorTrack, editorWell, card, secondaryFill
    case draftCard, draftEditorWell, draftSecondaryFill
    case notice, warningNotice
    case purpleFill, dimPurpleFill
    case toggleRow, sheetSecondaryFill

    /// The translucent layer this field puts on top of `base`, exactly as the
    /// view applies it. `nil` for the two opaque roots.
    var layer: (tint: Color, opacity: Double)? {
        switch self {
        case .appBackground, .sheetBackground: return nil
        case .selectorTrack:      return (.white, 0.08)
        case .editorWell:         return (.white, 0.07)
        case .card:               return (.white, 0.05)
        case .secondaryFill:      return (.white, 0.10)
        case .draftCard:          return (.purple, 0.15)
        case .draftEditorWell:    return (.white, 0.07)
        case .draftSecondaryFill: return (.white, 0.10)
        case .notice:             return (.white, 0.08)
        case .warningNotice:      return (.red, 0.18)
        case .purpleFill:         return (.purple, 1.0)
        case .dimPurpleFill:      return (.purple, 0.35)
        case .toggleRow:          return (.white, 0.07)
        case .sheetSecondaryFill: return (.white, 0.10)
        }
    }

    /// The field this one is drawn on. `nil` for the two opaque roots.
    var base: ReadTheAskField? {
        switch self {
        case .appBackground, .sheetBackground:
            return nil
        case .toggleRow, .sheetSecondaryFill:
            return .sheetBackground
        case .secondaryFill:
            return .card
        case .draftEditorWell, .draftSecondaryFill:
            return .draftCard
        default:
            return .appBackground
        }
    }

    /// What a view passes to `.background(…)`.
    ///
    /// Coach's field is `Color.black`; the activation sheet's is `Color(white:
    /// 0.08)`. Everything else is one translucent layer over one of those, which
    /// is why the composite below is exact rather than an approximation.
    var fill: Color {
        guard let layer else {
            return self == .sheetBackground ? Color(white: 0.08) : .black
        }
        return layer.tint.opacity(layer.opacity)
    }
}

/// Every text colour the Read the Ask surfaces draw, with the field it is drawn
/// on and the type size it is drawn at.
///
/// The type size is here because WCAG's threshold depends on it: 3:1 for large
/// text (≥18pt, or ≥14pt bold), 4.5:1 for everything else.
enum ReadTheAskInk: String, CaseIterable {
    // the reading
    case askValue, mutedValue, fieldHeading
    case possibleReadingsHeading, possibleReading, possibleReadingsCaption
    // the message
    case receivedTextLabel, receivedTextPlaceholder, editorText, removeControl
    case disclosure, readActionLabel, readActionLabelDisabled
    case secondaryActionLabel
    // the draft
    case draftHeading, draftEditorText, copyLabel, draftEditableNote
    // notices
    case noticeText, noticeGlyph, warningText, warningGlyph
    // the selector and the sheet
    case selectedSegment, unselectedSegment
    case activationTitle, activationBody
    case activationToggleTitle, activationToggleDetail
    case activationConfirmLabel, activationDismissLabel

    var tint: Color {
        switch self {
        case .removeControl: return .purple
        case .warningGlyph: return .yellow
        default: return .white
        }
    }

    var opacity: Double {
        switch self {
        case .askValue: return 0.95
        case .mutedValue: return 0.55
        case .possibleReading: return 0.85
        case .fieldHeading, .possibleReadingsHeading, .receivedTextLabel,
             .disclosure, .draftHeading, .activationToggleDetail:
            return 0.6
        // BUILD 117 REPAIR — these three were 0.45, 0.45 and 0.35, and on the
        // field they are actually drawn on they measured 4.52:1, 4.48:1 and
        // 3.21:1 against a 4.5:1 requirement. 0.55 is the same value the muted
        // "No deadline stated" already uses and clears AA with ≥1.36× margin on
        // every one of the three fields.
        case .possibleReadingsCaption, .draftEditableNote, .receivedTextPlaceholder:
            return 0.55
        case .noticeGlyph: return 0.7
        case .unselectedSegment: return 0.7
        case .activationBody: return 0.72
        default: return 1.0
        }
    }

    var field: ReadTheAskField {
        switch self {
        case .askValue, .mutedValue, .fieldHeading, .possibleReadingsHeading,
             .possibleReading, .possibleReadingsCaption:
            return .card
        case .receivedTextLabel, .removeControl, .disclosure:
            return .appBackground
        case .receivedTextPlaceholder, .editorText:
            return .editorWell
        case .readActionLabel:
            return .purpleFill
        case .readActionLabelDisabled:
            return .dimPurpleFill
        case .secondaryActionLabel:
            return .secondaryFill
        case .draftHeading, .draftEditableNote:
            return .draftCard
        case .draftEditorText:
            return .draftEditorWell
        case .copyLabel:
            return .draftSecondaryFill
        case .noticeText, .noticeGlyph:
            return .notice
        case .warningText, .warningGlyph:
            return .warningNotice
        case .selectedSegment:
            return .purpleFill
        case .unselectedSegment:
            return .selectorTrack
        case .activationTitle, .activationBody:
            return .sheetBackground
        case .activationToggleTitle, .activationToggleDetail:
            return .toggleRow
        case .activationConfirmLabel:
            return .purpleFill
        case .activationDismissLabel:
            return .sheetSecondaryFill
        }
    }

    /// The type this ink is drawn at, for WCAG's large-text threshold.
    var pointSize: CGFloat {
        switch self {
        case .activationTitle: return 22
        case .askValue, .readActionLabel, .readActionLabelDisabled: return 17
        case .activationToggleTitle, .activationConfirmLabel, .activationDismissLabel: return 16
        case .mutedValue, .receivedTextPlaceholder, .editorText, .draftEditorText,
             .selectedSegment, .unselectedSegment, .activationBody:
            return 15
        case .possibleReading, .secondaryActionLabel: return 14
        case .removeControl, .copyLabel, .noticeText, .noticeGlyph,
             .warningText, .warningGlyph, .activationToggleDetail:
            return 13
        case .fieldHeading, .possibleReadingsHeading, .receivedTextLabel,
             .disclosure, .draftHeading:
            return 12
        case .possibleReadingsCaption, .draftEditableNote: return 11
        }
    }

    /// Whether this ink is drawn heavier than regular — which is `.semibold`
    /// everywhere here except `activationTitle`, the one `.bold` case.
    ///
    /// Read this before reading the gate that uses it. WCAG 2.1 SC 1.4.3 gives
    /// large text (≥18pt, or ≥14pt **bold**) the lower 3:1 threshold, and
    /// "bold" is commonly read as weight 700; `.semibold` is 600. So every ink
    /// under 18pt that clears only because this returns `true` is clearing a
    /// threshold a stricter reading would not grant it. Which inks those are,
    /// and what each of them actually measures, is recorded at
    /// `Build117ReadTheAskTests.inksClearingOnlyAsSemiboldLargeText` rather
    /// than left implicit here.
    var isBold: Bool {
        switch self {
        case .activationTitle, .askValue, .readActionLabel, .readActionLabelDisabled,
             .activationToggleTitle, .activationConfirmLabel, .activationDismissLabel,
             .selectedSegment, .unselectedSegment, .secondaryActionLabel,
             .removeControl, .copyLabel, .fieldHeading, .possibleReadingsHeading,
             .draftHeading:
            return true
        default:
            return false
        }
    }

    /// What a view passes to `.foregroundColor(…)`. The ONE place these values
    /// live.
    var color: Color { tint.opacity(opacity) }
}

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
        .background(ReadTheAskField.selectorTrack.fill)
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
                .foregroundColor(mode == value ? ReadTheAskInk.selectedSegment.color : ReadTheAskInk.unselectedSegment.color)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Self.minimumTouchTarget)
                .background(mode == value ? ReadTheAskField.purpleFill.fill : Color.clear)
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
                        .foregroundColor(ReadTheAskInk.activationTitle.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(ReadTheAskCopy.activationBody)
                        .tonoFont(size: 15, relativeTo: .subheadline)
                        .foregroundColor(ReadTheAskInk.activationBody.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(isOn: $pendingEnabled) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ReadTheAskCopy.activationToggleTitle)
                                .tonoFont(size: 16, weight: .semibold, relativeTo: .body)
                                .foregroundColor(ReadTheAskInk.activationToggleTitle.color)
                            Text(ReadTheAskCopy.activationToggleDetail)
                                .tonoFont(size: 13, relativeTo: .footnote)
                                .foregroundColor(ReadTheAskInk.activationToggleDetail.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.purple)
                    .padding(16)
                    .background(ReadTheAskField.toggleRow.fill)
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
            .background(ReadTheAskField.sheetBackground.fill.ignoresSafeArea())
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
                .background(ReadTheAskField.sheetSecondaryFill.fill)
                .foregroundColor(ReadTheAskInk.activationDismissLabel.color)
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
                .background(ReadTheAskField.purpleFill.fill)
                .foregroundColor(ReadTheAskInk.activationConfirmLabel.color)
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
        //
        // "EVERY WAY OF LEAVING" INCLUDES PUSHING SETTINGS — stated, because it
        // is a real user-visible consequence and nothing said so (N-D).
        //
        // `onDisappear` fires on any removal of this panel, and a
        // `NavigationStack` push from Coach's toolbar removes it. Measured, not
        // reasoned: with the request genuinely in flight and the push genuinely
        // performed, the reading does not arrive. So starting a reading,
        // checking Settings and coming back leaves the surface with no reading
        // and a Read button that works.
        //
        // That is the right answer, and it is the same one Remove and the mode
        // switch get. The alternative is a response landing on a surface the
        // person is not looking at — the exact defect this repair exists to
        // close — and it does not become acceptable because the screen on top
        // happens to be Tono's own. It fails CLOSED: the message they pasted is
        // untouched, so the cost is one tap, not their work.
        // `testAReadingIsCancelledWhenTheSurfaceIsPushedAsideForSettings` holds
        // both halves.
        .onDisappear { cancelReading() }
    }

    // MARK: The message

    private var receivedTextEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ReadTheAskCopy.receivedTextLabel)
                    .font(.caption)
                    .foregroundColor(ReadTheAskInk.receivedTextLabel.color)
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
                    .foregroundColor(ReadTheAskInk.removeControl.color)
                    .accessibilityHint("Removes the message and its reading from this screen.")
                }
            }
            TextEditor(text: $receivedText)
            .frame(minHeight: 120)
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(ReadTheAskField.editorWell.fill)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(ReadTheAskInk.editorText.color)
            .tint(.purple)
            .overlay(alignment: .topLeading) {
                if receivedText.isEmpty {
                    Text(ReadTheAskCopy.receivedTextPlaceholder)
                        .foregroundColor(ReadTheAskInk.receivedTextPlaceholder.color)
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
        .foregroundColor(ReadTheAskInk.disclosure.color)
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
            .background(canSubmit ? ReadTheAskField.purpleFill.fill : ReadTheAskField.dimPurpleFill.fill)
            .foregroundColor(canSubmit ? ReadTheAskInk.readActionLabel.color : ReadTheAskInk.readActionLabelDisabled.color)
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
                        .foregroundColor(ReadTheAskInk.possibleReadingsHeading.color)
                    ForEach(result.possibleReadings, id: \.self) { reading in
                        Text("• \(reading)")
                            .tonoFont(size: 14, relativeTo: .subheadline)
                            .foregroundColor(ReadTheAskInk.possibleReading.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(ReadTheAskCopy.possibleReadingsCaption)
                        .tonoFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(ReadTheAskInk.possibleReadingsCaption.color)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(ReadTheAskCopy.possibleReadingsHeading)
            }

            Divider().background(ReadTheAskField.selectorTrack.fill)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { replyButton(result); clarifyButton(result) }
                VStack(spacing: 10) { replyButton(result); clarifyButton(result) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReadTheAskField.card.fill)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func field(
        _ heading: String, _ value: String, emphasised: Bool = false, muted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .tonoFont(size: 12, weight: .semibold, relativeTo: .caption)
                .foregroundColor(ReadTheAskInk.fieldHeading.color)
            Text(value)
                .tonoFont(
                    size: emphasised ? 17 : 15,
                    weight: emphasised ? .medium : .regular,
                    relativeTo: emphasised ? .body : .subheadline
                )
                .foregroundColor(muted ? ReadTheAskInk.mutedValue.color : ReadTheAskInk.askValue.color)
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
            .background(ReadTheAskField.secondaryFill.fill)
            .foregroundColor(ReadTheAskInk.secondaryActionLabel.color)
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
            .foregroundColor(ReadTheAskInk.draftHeading.color)

            TextEditor(
                text: Binding(
                    get: { session.draft },
                    set: { session.editDraft($0) }
                )
            )
            .frame(minHeight: 100)
            .padding(10)
            .scrollContentBackground(.hidden)
            .background(ReadTheAskField.draftEditorWell.fill)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundColor(ReadTheAskInk.draftEditorText.color)
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
                    .background(ReadTheAskField.draftSecondaryFill.fill)
                    .foregroundColor(ReadTheAskInk.copyLabel.color)
                    .clipShape(Capsule())
                }
                Text(ReadTheAskCopy.draftEditableNote)
                    .tonoFont(size: 11, relativeTo: .caption2)
                    .foregroundColor(ReadTheAskInk.draftEditableNote.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReadTheAskField.draftCard.fill)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Notices

    private func notice(icon: String, text: String, tinted: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(tinted ? ReadTheAskInk.warningGlyph.color : ReadTheAskInk.noticeGlyph.color)
            Text(text)
                .tonoFont(size: 13, relativeTo: .footnote)
                .foregroundColor(tinted ? ReadTheAskInk.warningText.color : ReadTheAskInk.noticeText.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tinted ? ReadTheAskField.warningNotice.fill : ReadTheAskField.notice.fill)
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
