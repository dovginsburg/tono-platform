// ReadTheAsk.swift
// Build 117 — Read the Ask.
//
// TARGET MEMBERSHIP IS PART OF THE CONTRACT.
//
//   Tono (host app) ✓    TonoShare ✓    TonoTests ✓
//   TonoKeyboard   ✗    TonoMessagesExtension ✗
//
// This file sits in `Shared/` because the host app and the Share extension are
// two processes that need the same types, and `Shared/` is where two-process
// types live. It is NOT compiled into the keyboard or the iMessage extension,
// and that exclusion is not a convention — it is asserted two ways, and the
// division of labour is stated exactly because an unbacked claim of proof is
// how Build 115's "never match mangled substrings, demangle" lesson gets
// un-learned:
//
//   * `Build117ReadTheAskTests` asserts TARGET MEMBERSHIP, by parsing
//     `project.pbxproj`, and asserts that no keyboard or iMessage SOURCE names
//     this feature. Both are source-level, and neither opens a binary.
//   * `Scripts/verify_build117_read_ask_exclusion.py` asserts the SHIPPED
//     Mach-O binaries — symbols demangled, strings matched case-sensitively as
//     whole sentences, `*.debug.dylib` included, and with mandatory positive
//     controls so a scan that has gone blind fails instead of reporting zero.
//
// The keyboard stays rewrite-only, so not one symbol or string from this
// feature may reach it. (`Shared/` already contains files
// with selective membership — `ToneEngineTests.swift` and
// `OnDeviceAppleRewriteTests.swift` belong to no target at all — so this is the
// established shape, not a new one.)
//
// WHAT THE FEATURE IS
//
// Somebody sends you a message. You share it to Tono, or paste it in, and Tono
// tells you what is being asked of you. That is all. It does not tell you how
// the sender feels, what they "really" meant, or how you come across. Tono is a
// communication coach; it is not a profiler, a therapist or a crisis service,
// and the whole design of this file is a series of refusals to become one.
//
// THE INVARIANT EVERYTHING ELSE HANGS OFF
//
// Tono never works out whether a piece of text is incoming or outgoing. Getting
// that wrong means either coaching somebody's own words back at them as though
// a stranger wrote them, or answering "what are they asking?" about a draft the
// person is holding — and there is no signal in a string that reliably tells
// the two apart. So the mode is STATED, on every request, by the caller.
// `TonoRequestMode` is that statement and `TonoRequestMode.explicit(_:)` is the
// only way to make one from a wire value. It is exact on purpose: a value that
// needs trimming or case-folding before it matches is a value whose intent is
// not certain, and repairing it IS the inference this feature exists to avoid.

import Foundation

// MARK: - The explicit mode boundary

/// What a caller is asking Tono to do with a piece of text.
///
/// There is no `default`. A default here would be exactly the silent assumption
/// the contract forbids, so every Build 117 entry point takes this as a required
/// argument and the compiler enforces that nobody forgets.
public enum TonoRequestMode: String, Codable, CaseIterable, Sendable {

    /// Improve wording the person is about to send. The established behaviour,
    /// unchanged.
    case rewrite = "rewrite"

    /// Read what a message the person RECEIVED is asking of them.
    case readAsk = "read_ask"

    /// Parse a wire value, or refuse.
    ///
    /// Exact match only. `nil`, `""`, `" read_ask "`, `"READ_ASK"` and
    /// `"read-ask"` all return `nil` — none of them is a mode this app has ever
    /// sent, so each one is either a bug or somebody else's traffic, and both
    /// deserve a refusal rather than a best guess.
    public static func explicit(_ wire: String?) -> TonoRequestMode? {
        guard let wire, !wire.isEmpty else { return nil }
        return TonoRequestMode(rawValue: wire)
    }
}

/// Why a request was refused at the mode boundary.
public enum TonoModeError: Error, Equatable, Sendable {
    /// No mode was stated.
    case modeMissing
    /// A mode was stated that this app does not recognise.
    case modeUnrecognized(String)
    /// A recognised mode, on a path that does not serve it.
    case modeNotServedHere(TonoRequestMode)
}

/// The ONE place a legacy default is allowed to live.
///
/// `/api/analyze` has always taken `mode: "coach"` and has always defaulted to
/// it. Build 117 does not move that by a byte — established callers keep the
/// exact wire they had. What it does is make the Build 117 call sites state
/// their mode anyway, and pass it through here, so the default is something the
/// legacy wire has rather than something this app relies on.
public enum TonoLegacyAnalysisMode {

    /// The legacy `AnalysisMode` a Build 117 rewrite request travels as.
    ///
    /// Throws for `.readAsk`: the legacy `read` mode asks a model for "the
    /// sender's likely intent and emotional state" and names "hidden asks,
    /// passive signals". That is the opposite of this feature's contract, so
    /// Read the Ask must never be able to fall back onto it — not through a
    /// mapping table, not through a default, not through a mistake.
    public static func analysisMode(for mode: TonoRequestMode) throws -> AnalysisMode {
        switch mode {
        case .rewrite:
            return .coach
        case .readAsk:
            throw TonoModeError.modeNotServedHere(.readAsk)
        }
    }
}

// MARK: - Where the reading happens

/// Where the text a person chose is processed.
///
/// Derived from the route that will actually run, never asserted next to it.
/// A label that is written by hand beside the code it describes is a label that
/// goes stale the first time the code moves; this one cannot disagree with the
/// transport because the transport is what produces it.
public enum ReadTheAskProcessing: String, Equatable, Sendable {
    case onDevice
    case online

    /// The sentence shown BEFORE anything is transmitted.
    public var disclosure: String {
        switch self {
        case .onDevice:
            return "On device — this text stays on your iPhone."
        case .online:
            return "Online — the text you choose is sent to Tono to be read."
        }
    }

    public var badge: String {
        switch self {
        case .onDevice: return "On Device"
        case .online:   return "Online"
        }
    }
}

/// The routes a reading can take. There is exactly one in this release, and it
/// is online — so the app says Online. There is no on-device Read the Ask model,
/// and claiming otherwise would be the single most damaging thing this surface
/// could print.
public enum ReadTheAskRoute: Equatable, Sendable {
    case backend

    public var processing: ReadTheAskProcessing {
        switch self {
        case .backend: return .online
        }
    }
}

// MARK: - The reading

/// What comes back. Four things, and no fifth.
///
/// There is deliberately no risk level, no perception, no subtext, no sentiment
/// and no flags. A field that does not exist cannot be rendered by accident,
/// and cannot be quietly repurposed later into the profiling this feature is
/// defined against.
public struct ReadAskResult: Codable, Equatable, Sendable {

    /// The concrete request, decision or action the text explicitly supports.
    public let ask: String

    /// A deadline, ONLY where the sender wrote one, in the sender's own words.
    /// `nil` means the message states none — which is a fact worth showing, and
    /// infinitely better than a plausible invention.
    public let byWhen: String?

    /// One material detail the reader would need before they could act.
    public let unclear: String?

    /// Bounded alternative readings, and only where the wording is genuinely
    /// ambiguous. The UI presents these as possibilities; they are never a
    /// verdict about what was meant.
    public let possibleReadings: [String]

    public init(ask: String, byWhen: String? = nil, unclear: String? = nil, possibleReadings: [String] = []) {
        self.ask = ask
        self.byWhen = byWhen
        self.unclear = unclear
        self.possibleReadings = possibleReadings
    }

    enum CodingKeys: String, CodingKey {
        case ask
        case byWhen = "by_when"
        case unclear
        case possibleReadings = "possible_readings"
    }
}

/// The envelope the server returns. `status` is how this codebase already says
/// "nothing happened, on purpose" — see `TonoVariantResult`.
public struct ReadAskEnvelope: Decodable, Equatable, Sendable {
    public let mode: String
    public let status: String
    public let ask: String?
    public let byWhen: String?
    public let unclear: String?
    public let possibleReadings: [String]

    enum CodingKeys: String, CodingKey {
        case mode, status, ask, unclear
        case byWhen = "by_when"
        case possibleReadings = "possible_readings"
    }
}

/// What the client does with an envelope it has checked.
public enum ReadAskOutcome: Equatable, Sendable {
    case reading(ReadAskResult)
    /// Read successfully; the message asks for nothing. A stated outcome, not a
    /// failure — "thanks for dinner last night" is an ordinary message, and the
    /// honest answer is that there is no request in it. Answering a message like
    /// that with "try again" would be a retry loop over something that can never
    /// produce an Ask.
    case noAsk
    /// Outside this feature's authority. Carries no reading and no reason —
    /// no resources, no helpline, no diagnosis, no interpretation. Product-scope
    /// silence, not a judgement about anyone.
    case declined
}

public enum ReadAskContractError: Error, Equatable, Sendable {
    /// The toggle is off. Nothing is read, nothing is sent.
    case notActivated
    /// The envelope did not carry the mode it was asked for.
    case modeMismatch(expected: String, received: String)
    case statusUnrecognized(String)
    case askMissing
    /// A deadline that is not a quotation from the message the person shared.
    case deadlineNotQuoted(String)
    /// A claim about the sender rather than about the text.
    case claimsAboutTheSender(field: String)
    case tooManyReadings(Int)
}

// MARK: - The client-side guards

/// The same two refusals the server makes, made again before anything renders.
///
/// This is not belt-and-braces for its own sake. The server is one deployment
/// behind a URL that a shared default can repoint; the render path is the last
/// place a claim about a person can be stopped, so it stops one. The two
/// implementations are held to the same fixtures on both sides.
public enum ReadAskGuard {

    public static let maximumPossibleReadings = 2

    /// Constructions that describe the SENDER rather than the text.
    ///
    /// The subject is half of each pattern on purpose. "They seem annoyed" is a
    /// diagnosis; "Confirm whether you are free on Tuesday" is an ordinary ask
    /// that happens to quote a question the sender wrote. A guard that cannot
    /// tell those apart either lets the first through or blocks the second, and
    /// blocking real asks protects nobody.
    static let senderClaimPatterns: [String] = [
        #"\b(?:the\s+sender|the\s+writer|the\s+author|this\s+person|they|he|she)(?:\s+(?:really|actually|probably|likely|clearly|obviously|just|being))*\s+(?:is|are|was|were|seems?|sounds?|feels?|appears?|means?|meant|wants?|wanted|needs?|thinks?|implies|implied|intends?)\b"#,
        #"\b(?:really|actually)\s+mean(?:s|t)?\b"#,
        #"\bbetween\s+the\s+lines\b"#,
        #"\bhidden\s+(?:intent|agenda|ask|meaning|message)\b"#,
        #"\bpassive[-\s]?aggressi(?:ve|on)\b"#,
        #"\bsubtext\b"#,
        #"\bsentiment\b"#,
        #"\bpersonality\b"#,
        #"\bdiagnos(?:e|is|ing|ed)\b"#,
        // The two constructions the Live Tone contract bans by name, because
        // they describe a person rather than a text. "are you" is deliberately
        // absent: it is ordinary inside a quoted ask.
        #"\byou\s+seem\b"#,
        #"\byou\s+sound\b"#,
    ]

    public static func claimsAboutTheSender(_ value: String) -> Bool {
        for pattern in senderClaimPatterns {
            if value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    /// True when `candidate` appears in `source` word for word.
    ///
    /// A substring test, not a similarity score. "Explicitly stated" has one
    /// precise meaning — the sender wrote it — and this is that meaning. Case
    /// and runs of whitespace are normalised; nothing else is, because a
    /// deadline that had to be rewritten to match was not quoted.
    public static func isQuoted(_ candidate: String, from source: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return normalized(source).contains(normalized(trimmed))
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

public extension ReadAskEnvelope {

    /// Turn a decoded envelope into something renderable, or refuse.
    ///
    /// `receivedText` is the message the person actually shared — the only thing
    /// a claimed deadline can honestly be checked against.
    func validated(against receivedText: String) throws -> ReadAskOutcome {
        guard mode == TonoRequestMode.readAsk.rawValue else {
            throw ReadAskContractError.modeMismatch(
                expected: TonoRequestMode.readAsk.rawValue, received: mode
            )
        }

        switch status {
        case "declined":
            return .declined
        case "no_ask":
            return .noAsk
        case "ok":
            break
        default:
            throw ReadAskContractError.statusUnrecognized(status)
        }

        let trimmedAsk = (ask ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAsk.isEmpty else { throw ReadAskContractError.askMissing }

        let trimmedUnclear = unclear?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readings = possibleReadings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard readings.count <= ReadAskGuard.maximumPossibleReadings else {
            throw ReadAskContractError.tooManyReadings(readings.count)
        }

        // A claim about a person is not a field that can be trimmed back into
        // honesty, so the whole reading goes.
        if ReadAskGuard.claimsAboutTheSender(trimmedAsk) {
            throw ReadAskContractError.claimsAboutTheSender(field: "ask")
        }
        if let trimmedUnclear, !trimmedUnclear.isEmpty,
           ReadAskGuard.claimsAboutTheSender(trimmedUnclear) {
            throw ReadAskContractError.claimsAboutTheSender(field: "unclear")
        }
        for reading in readings where ReadAskGuard.claimsAboutTheSender(reading) {
            throw ReadAskContractError.claimsAboutTheSender(field: "possibleReadings")
        }

        // A deadline that was not quoted is dropped, and ONLY it. Silence about
        // a deadline is exactly right; throwing away a good Ask over one is not.
        var quotedDeadline = byWhen?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let candidate = quotedDeadline, !candidate.isEmpty {
            if !ReadAskGuard.isQuoted(candidate, from: receivedText) {
                quotedDeadline = nil
            }
        } else {
            quotedDeadline = nil
        }

        return .reading(
            ReadAskResult(
                ask: trimmedAsk,
                byWhen: quotedDeadline,
                unclear: (trimmedUnclear?.isEmpty ?? true) ? nil : trimmedUnclear,
                possibleReadings: readings
            )
        )
    }
}

// MARK: - Activation

public enum ReadTheAskKeys {
    /// The ONE thing this feature persists: whether the person turned it on.
    /// Absent means off.
    public static let enabled = "tc.readTheAsk.enabled"
}

/// The user-facing switch, and the only durable state Read the Ask has.
///
/// Default OFF, and off in the strong sense: absent reads as off, so a fresh
/// install, a restored backup and a corrupted value all land in the same place.
/// (`LiveToneMasterToggle` has to inspect `object(forKey:)` because its contract
/// default is ON; this one's default agrees with `bool(forKey:)`, and the tests
/// pin that agreement so a future refactor cannot flip it by accident.)
public struct ReadTheAskActivation {

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = SharedStore.defaults) {
        self.defaults = defaults
    }

    /// Only a real boolean counts as consent.
    ///
    /// `UserDefaults.bool(forKey:)` PARSES: it reads the string "yes" — and "1",
    /// and "true" — as `true`. This key lives in an App Group that four
    /// processes can write and that a device restore repopulates, so a value
    /// this feature never wrote is not a decision anybody made. Anything that is
    /// not a stored boolean reads as off, which is where every unknown belongs.
    public var isEnabled: Bool {
        guard let stored = defaults.object(forKey: ReadTheAskKeys.enabled) as? NSNumber
        else { return false }
        return stored.boolValue
    }

    /// Records the person's choice. Nothing else is written — not the message,
    /// not the reading, not a timestamp, not a counter.
    ///
    /// Then it says so, out loud, in this process.
    ///
    /// The contract is that turning the switch off clears the unsaved
    /// received-message context IMMEDIATELY. Without this notification it
    /// wouldn't: Settings is pushed from Coach's own toolbar, so a person can
    /// switch the feature off and walk straight back to a Coach surface that is
    /// still holding the message in memory — the surface has no reason to
    /// re-read a value it cached when it appeared. "Immediately" has to mean
    /// before the next frame, not at the next launch, so the write announces
    /// itself rather than waiting to be noticed.
    public func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: ReadTheAskKeys.enabled)
        NotificationCenter.default.post(
            name: .readTheAskActivationChanged, object: nil, userInfo: ["enabled": on]
        )
    }
}

public extension Notification.Name {
    /// Posted by `ReadTheAskActivation.setEnabled` — the ONLY writer of the
    /// preference — so every surface in this process learns about a withdrawal
    /// at the moment it happens.
    static let readTheAskActivationChanged = Notification.Name("tono.readTheAsk.activationChanged")
}

// MARK: - The one-flow context

/// The received message, its reading, and the drafts made from it — held for
/// exactly one flow and then gone.
///
/// Nothing here is ever written to disk. Turning the toggle off, or moving back
/// to Rewrite, calls `clear()` immediately: the contract says unsaved
/// received-message context goes the moment the person withdraws, and "the
/// moment" means before the next frame, not at the next launch.
public final class ReadTheAskSession: ObservableObject {

    @Published public private(set) var receivedText: String = ""
    @Published public private(set) var outcome: ReadAskOutcome?
    @Published public private(set) var draft: String = ""
    @Published public private(set) var draftKind: DraftKind?

    public enum DraftKind: Equatable, Sendable {
        case reply
        case clarification
    }

    public init() {}

    public func setReceivedText(_ text: String) {
        receivedText = text
        // A reading belongs to the text it was made from. Once the text moves,
        // the reading beside it is about a message that no longer exists.
        outcome = nil
        draft = ""
        draftKind = nil
    }

    public func apply(_ outcome: ReadAskOutcome) {
        self.outcome = outcome
        draft = ""
        draftKind = nil
    }

    public func setDraft(_ text: String, kind: DraftKind) {
        draft = text
        draftKind = kind
    }

    /// The person is editing their own words. Nothing else moves.
    public func editDraft(_ text: String) {
        draft = text
    }

    /// Everything about this flow, gone. Called on toggle-off and on mode change.
    public func clear() {
        receivedText = ""
        outcome = nil
        draft = ""
        draftKind = nil
    }

    /// True when this session is holding nothing derived from a received
    /// message. What `clear()` is tested against.
    public var isEmpty: Bool {
        receivedText.isEmpty && outcome == nil && draft.isEmpty && draftKind == nil
    }

    public var reading: ReadAskResult? {
        if case .reading(let result) = outcome { return result }
        return nil
    }
}

// MARK: - Starting points the person can edit

/// `Draft my reply` and `Ask for clarification`.
///
/// Both are composed on device from the reading that is already on screen. That
/// is a deliberate choice for this slice, not a shortcut: it costs no second
/// billed generation (the generation-economy amendment is explicit that one tap
/// is one call and warns against fan-out), it adds no new egress, and it is
/// deterministic enough to be tested line by line. They are starting points in
/// the person's own words, editable, and they are never sent by Tono — the
/// person copies what they want and sends it themselves, from their own app.
public enum ReadAskReplyComposer {

    public static func draftReply(for result: ReadAskResult) -> String {
        var lines: [String] = ["Thanks — just to confirm: \(sentence(result.ask))"]
        if let byWhen = result.byWhen, !byWhen.isEmpty {
            // Quoted, never converted into a promise. What the sender wrote is
            // a fact; what the reader will do about it is theirs to decide.
            lines.append("You mentioned \(byWhen).")
        }
        lines.append("I'll come back to you on this.")
        return lines.joined(separator: " ")
    }

    public static func clarificationRequest(for result: ReadAskResult) -> String {
        guard let unclear = result.unclear, !unclear.isEmpty else {
            return "Before I get to this — could you give me a bit more detail on what you need?"
        }
        return "Before I get to this — one thing I want to check: \(sentence(unclear)) Could you clarify?"
    }

    private static func sentence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard let last = trimmed.last, ".!?".contains(last) else { return trimmed + "." }
        return trimmed
    }
}

// MARK: - Copy

/// Every user-facing string this feature ships, declared once.
///
/// Here rather than inline so the tests read the same bytes the screen does.
/// The activation copy in particular is a promise about behaviour, and a promise
/// that drifts from the code is worse than no promise.
public enum ReadTheAskCopy {

    public static let modeSelectorAccessibilityLabel = "How Tono helps with this message"
    public static let rewriteModeTitle = "Rewrite"
    public static let readAskModeTitle = "Read the Ask"
    public static let modeSelectorCaption = "Choose how Tono helps with this message."

    public static let activationTitle = "Turn on Read the Ask?"
    public static let activationBody =
        "Only text you choose is analyzed. Tono never reads your conversations or clipboard automatically."
    public static let activationToggleTitle = "Enable Read the Ask"
    public static let activationToggleDetail = "Off by default. Turn it off anytime."
    public static let activationDismiss = "Not now"
    public static let activationConfirm = "Continue"

    public static let receivedTextLabel = "Their message"
    public static let receivedTextPlaceholder =
        "Paste or share the message you received."
    public static let removeReceivedText = "Remove"
    /// Deliberately NOT "Read the Ask". The mode segment above already carries
    /// that name, and two controls with the same accessibility label on one
    /// screen is a real defect: VoiceOver announces "Read the Ask" twice and
    /// the two mean entirely different things — one changes the surface, the
    /// other sends a message off the device. This one says what it does to the
    /// message in front of you.
    public static let readAction = "Read this message"

    public static let askHeading = "The Ask"
    public static let byWhenHeading = "By when"
    public static let byWhenAbsent = "No deadline stated."
    public static let unclearHeading = "Unclear"
    public static let possibleReadingsHeading = "Could also mean"
    public static let possibleReadingsCaption = "Possibilities, not conclusions."

    public static let draftReplyAction = "Draft my reply"
    public static let clarificationAction = "Ask for clarification"
    public static let draftEditableNote = "Edit it, copy it, send it yourself. Tono never sends anything."

    /// One neutral sentence for a message this feature has no business reading.
    /// No resources, no helpline, no diagnosis, no interpretation.
    public static let declined = "Tono can't read this one. You can still write your own reply."

    /// The message asks for nothing, and that is the answer rather than an
    /// error. Says what is true about the TEXT and stops there — no guess at
    /// why it was sent, no invitation to read anything into it.
    public static let noAsk = "There's no request in this message — nothing is being asked of you."

    public static let offNotice =
        "Read the Ask is off. Turn it on to read what a message is asking of you."

    /// Shown when the toggle is off and the person taps the mode anyway, and in
    /// Settings. States the boundary as behaviour, not as reassurance.
    public static let settingsDisclosure =
        "Read the Ask reads only text you share or paste. It never reads your conversations, "
        + "the keyboard, or the clipboard on its own, and it never sends a reply for you."
}

// MARK: - What a surface shows, decided once

/// What a Read the Ask notice IS, separate from how it is drawn.
///
/// The Share extension drew all three of "no request in this message",
/// "Tono can't read this one" and "the request failed" with the same 36pt
/// yellow warning triangle. Two of those are not warnings: `noAsk` is a
/// *successful* reading, and `declined` is a deliberate boundary. Telling
/// somebody their ordinary "thanks for dinner" message triggered a warning is
/// the same class of untruth as telling them Tono couldn't coach their draft
/// when they never wrote one.
///
/// Kind is decided here, once, for both surfaces — so the companion app and
/// Share cannot drift apart again.
public enum ReadTheAskNoticeKind: Equatable, Sendable {
    /// It worked. There is simply nothing being asked.
    case success
    /// A boundary Tono chose. Not a failure, and not the person's fault.
    case boundary
    /// Something actually went wrong and trying again may help.
    case failure
}

/// A notice ready to render: what to say, which glyph, whether to offer retry.
public struct ReadTheAskNotice: Equatable, Sendable {

    public let kind: ReadTheAskNoticeKind
    public let glyph: String
    public let message: String

    /// Retry is offered only where retrying could plausibly change the answer.
    /// Re-reading a message that asks for nothing produces the same correct
    /// answer forever, so offering it there is an invitation to a loop.
    public var offersRetry: Bool { kind == .failure }

    public init(kind: ReadTheAskNoticeKind, glyph: String, message: String) {
        self.kind = kind
        self.glyph = glyph
        self.message = message
    }

    /// The notice for a non-reading outcome, or `nil` when there IS a reading
    /// and the surface should render it instead.
    public static func forOutcome(_ outcome: ReadAskOutcome) -> ReadTheAskNotice? {
        switch outcome {
        case .reading:
            return nil
        case .noAsk:
            return ReadTheAskNotice(
                kind: .success, glyph: "checkmark.circle", message: ReadTheAskCopy.noAsk
            )
        case .declined:
            return ReadTheAskNotice(
                kind: .boundary, glyph: "hand.raised", message: ReadTheAskCopy.declined
            )
        }
    }

    /// The notice for a genuine failure. This is the only one that gets the
    /// warning triangle, and the only one that offers a retry.
    public static func forFailure(_ error: Error) -> ReadTheAskNotice {
        ReadTheAskNotice(
            kind: .failure,
            glyph: "exclamationmark.triangle.fill",
            message: ReadTheAskFailure.message(for: error)
        )
    }
}

/// The sentence a Read the Ask failure says.
///
/// One function, called by both surfaces, for one reason: every Read the Ask
/// failure used to report itself as `.coachDraft` — *"Couldn't coach this
/// draft."* — on a feature whose entire purpose is that a message somebody sent
/// you is not a draft you wrote. The one confusion the feature exists to
/// prevent was reproduced in its own error copy.
///
/// `.readMessage` already existed, already said *"Couldn't read this
/// message."*, and the keyboard already used it. Nothing new was needed except
/// picking it — and putting the choice somewhere it can only be made once.
public enum ReadTheAskFailure {
    public static func message(for error: Error) -> String {
        ConsumerErrorCopy.message(for: error, action: .readMessage)
    }
}

// MARK: - Share to Tono, as decisions rather than view state

/// Which screen Share to Tono is on.
public enum ReadTheAskShareStage: Equatable, Sendable {
    /// Asking what the shared text IS. Only reachable with the feature on.
    case choosing
    /// The established rewrite path.
    case rewrite
    /// Reading what a received message asks.
    case readAsk
}

/// The Share extension's flow, as pure decisions.
///
/// Extracted from `ShareRootView` because an `.appex`'s SwiftUI views cannot be
/// imported by the unit-test target, which left the whole Share surface — one
/// of the two the contract names — resting on inspection alone. The decisions
/// are the part worth testing; what remains in the view is layout.
public enum ReadTheAskShareFlow {

    /// Where Share opens.
    ///
    /// With the feature off this is `.rewrite` from the first frame, so the
    /// extension behaves exactly as it did before Build 117 — an entry point
    /// for a feature that is off is not a dimmed entry point, it is no entry
    /// point.
    public static func initialStage(activationEnabled: Bool) -> ReadTheAskShareStage {
        activationEnabled ? .choosing : .rewrite
    }

    /// Where an explicit choice leads. There is no default and no
    /// pre-selection: text somebody shared could equally be a message they
    /// received or a draft they are about to send, and refusing to guess is the
    /// whole point.
    public static func stage(choosing mode: TonoRequestMode) -> ReadTheAskShareStage {
        switch mode {
        case .rewrite: return .rewrite
        case .readAsk: return .readAsk
        }
    }

    /// Whether a stage should start work as soon as it appears.
    ///
    /// `.choosing` must not: it is a question, and a question that answers
    /// itself is not one.
    public static func runsOnAppear(_ stage: ReadTheAskShareStage) -> Bool {
        stage == .rewrite
    }
}

// MARK: - The transport

public extension TonoBackend {

    /// Read what a received message is asking.
    ///
    /// Two gates run before a single byte leaves the device, and they are here —
    /// in the transport — rather than only in the view. A disabled control is
    /// the visible half of a gate; this is the half that makes "nothing is sent
    /// while the toggle is off" true no matter how the action is reached: an
    /// accessibility activation, a hardware keyboard, a future caller.
    ///
    /// - Parameter mode: stated by the caller. There is no default.
    func readAsk(
        receivedText: String,
        mode: TonoRequestMode,
        activation: ReadTheAskActivation = ReadTheAskActivation(),
        route: ReadTheAskRoute = .backend
    ) async throws -> ReadAskOutcome {

        guard mode == .readAsk else {
            throw TonoModeError.modeNotServedHere(mode)
        }
        guard activation.isEnabled else {
            throw ReadAskContractError.notActivated
        }

        let trimmed = receivedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReadAskContractError.askMissing }

        struct Body: Encodable {
            let text: String
            let mode: String
        }

        // Built with the canonical client's own request builder, so this path
        // inherits the bearer, the content type, the timeout and the
        // `notRegistered` gate rather than growing a second copy of them. The
        // route is named so a future on-device path would have to declare
        // itself here before it could claim to be on-device anywhere else.
        let request: URLRequest
        switch route {
        case .backend:
            request = try buildRequest(
                path: "/api/read-ask",
                method: "POST",
                body: Body(text: trimmed, mode: mode.rawValue),
                authorize: true
            )
        }

        // `execute` keeps 401 / 402 / 429 apart, which is the distinction Build
        // 113 had to repair on the streaming path. Reusing it is how it stays
        // repaired here.
        let envelope: ReadAskEnvelope = try await execute(request)
        return try envelope.validated(against: trimmed)
    }
}
