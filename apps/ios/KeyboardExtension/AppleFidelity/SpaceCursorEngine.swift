// SpaceCursorEngine.swift
// Apple-fidelity space-key hold/drag cursor mode.
//
// Build 103 was rejected on device: the caret moved "one character at a time
// like backspacing" and could not travel freely in two dimensions. Both were
// real defects in the previous engine, not perception:
//
//   * horizontal travel was quantised at a FIXED 10 points per character, so a
//     long drag moved as slowly as a short one — there was no acceleration, and
//     crossing a sentence meant dragging most of the way across the keyboard;
//   * vertical travel was DISCARDED by contract ("vertical travel is ignored"),
//     so the caret could never change line;
//   * the reachable range was frozen at press time, so a stale bound could
//     stop the caret short.
//
// This engine replaces that contract. It is still a pure value type — no
// timers, no UIKit, no I/O — so every behaviour below is deterministically
// unit-testable with a fixed base `Date` advanced by `addingTimeInterval`.
//
// ── What the public keyboard API actually permits ───────────────────────────
// `UITextDocumentProxy` gives a keyboard extension exactly three relevant
// powers: read `documentContextBeforeInput` / `documentContextAfterInput` /
// `selectedText`, and move the caret with
// `adjustTextPosition(byCharacterOffset:)` — documented as "Adjusts the
// position of the cursor by the number of characters in the given offset."
//
// There is NO public API to read the host's layout: no caret rectangle, no
// line-fragment geometry, no knowledge of where the host visually wraps a long
// line, and no way to set or extend a selection range. Everything here is
// therefore computed from the TEXT the proxy hands us, never from host
// geometry.
//
// ── Build 106: rows, not just logical lines ─────────────────────────────────
// Build 105 defined "line" as a LOGICAL line delimited by "\n" and refused to
// move vertically without one. It was rejected on device for exactly the case
// that definition misses: a composer displaying TWO WRAPPED LINES of a single
// long sentence contains no "\n", so an upward drag did nothing at all.
//
// Build 106 navigates ROWS. A row boundary comes from either
//
//   * an observed "\n"                    — exact, unchanged from Build 105; or
//   * an estimated wrap point             — greedy word wrap at an estimated
//                                           characters-per-row width supplied
//                                           by `SpaceCursorWrapEstimator`.
//
// When no wrap width is available the row list collapses to the logical line
// list and the engine behaves precisely as Build 105 did. Sticky-column
// behaviour, reversal, clamping and the no-mutation guarantee are unchanged.
//
// This is an approximation and is documented as one. It is NOT Apple's line
// breaking and there is no claim of parity with a first-party keyboard's
// wrapped-line caret movement: Apple's own keyboard is inside the layout system
// and can read the caret rect; a third-party extension cannot. The estimate is
// biased to under-shoot so the failure mode is "moved a bit less than a full
// visual line", never "did not move".
//
// The engine deliberately has no delete capability: `Effect` has no delete
// case, so no gesture path can remove text. A quick tap is the ONLY way this
// file can cause an insertion, and it inserts exactly one space.

import Foundation

/// Tunable geometry / timing. Defaults approximate Apple's space-cursor feel.
public struct SpaceCursorConfig: Equatable {

    /// How long the space bar must be held before it becomes a trackpad.
    /// Shorter than this and the release is treated as a plain space tap.
    public var activationDelay: TimeInterval = 0.30

    /// Pre-activation movement (points, either axis) beyond which a release is
    /// no longer a tap. Keeps an aborted swipe from typing a space while still
    /// tolerating the wobble of a genuine tap.
    public var tapCancelSlop: Double = 12.0

    // ── Horizontal acceleration ──────────────────────────────────────────
    // Travel maps to characters on an accelerating curve so that small drags
    // stay precise (one character at a time, for fixing a typo) while long
    // drags cover a sentence or a paragraph without dragging off-screen.

    /// Points per character inside the precision zone — the fine, 1:1 rate.
    public var finePointsPerCharacter: Double = 8.0

    /// How far the finger may travel before acceleration begins. Inside this
    /// zone movement is strictly linear at `finePointsPerCharacter`.
    public var precisionZonePoints: Double = 24.0

    /// Acceleration scale. Past the precision zone each additional point is
    /// worth progressively more: the multiplier grows as `1 + extra / scale`.
    /// SMALLER = more aggressive. Must be > 0.
    public var accelerationScalePoints: Double = 120.0

    /// Hard ceiling on characters travelled in one gesture, per axis-direction.
    /// Guards against an absurd delta if a host reports a pathological context.
    public var maximumCharactersPerGesture: Int = 20_000

    // ── Vertical / multiline ─────────────────────────────────────────────

    /// Vertical travel (points) that must be exceeded before ANY line change.
    /// Keeps a horizontal drag with normal hand-tremor on its own line.
    public var verticalDeadZonePoints: Double = 16.0

    /// Points of further travel per additional line, once past the dead zone.
    public var pointsPerLine: Double = 24.0

    public init() {}
}

/// Estimates how many characters fit on one *visual* row of the host field.
///
/// ── Why an estimate at all ──────────────────────────────────────────────────
/// Build 105 defined a "line" as a LOGICAL line delimited by "\n", and refused
/// vertical movement when the captured context had no newline. On device that
/// produced the Build-105 rejection: a Messages composer showing TWO WRAPPED
/// lines of one long sentence contains no "\n" at all, so `supportsVertical`
/// was false and an upward drag did nothing. The founder saw a keyboard whose
/// caret would not go up.
///
/// `UITextDocumentProxy` still exposes no caret rectangle, no line-fragment
/// geometry, and no host font — that is not going to change, and nothing here
/// pretends otherwise. What it does expose is the TEXT, and the extension knows
/// its own width and the user's dynamic-type body metrics. That is enough for a
/// bounded estimate of where the host must be wrapping, which is strictly
/// better than refusing to move.
///
/// ── Which way to be wrong ───────────────────────────────────────────────────
/// The estimate is deliberately biased LOW. Over-estimating the row width is
/// the dangerous direction: a 50-character wrapped draft measured against a
/// 60-character row collapses to one row and the caret goes inert again — the
/// exact rejected behaviour. Under-estimating merely makes one vertical step
/// travel less than a full visual line: the caret still visibly moves in the
/// direction the finger went, which is what the user is asking for. So the
/// fraction below is conservative and the result is floored, never rounded up.
public enum SpaceCursorWrapEstimator {

    /// Fraction of the keyboard's own width that a host text field is assumed
    /// to give to text. Composer fields (Messages bubbles, Slack, WhatsApp) are
    /// inset from the full width by avatars, send buttons and bubble padding;
    /// 0.82 stays under all of them. Biased low on purpose — see above.
    public static let hostFieldWidthFraction: Double = 0.82

    /// Below this many characters per row the estimate is not credible (a very
    /// narrow field, an enormous accessibility font), and the engine falls back
    /// to logical-newline-only navigation rather than inventing rows.
    public static let minimumCredibleWidth = 12

    /// Ceiling, so a pathological font metric cannot produce a row width larger
    /// than any real composer.
    public static let maximumCredibleWidth = 160

    /// - Parameters:
    ///   - keyboardWidthPoints: the extension's own view width.
    ///   - averageCharacterWidthPoints: measured advance of a representative
    ///     glyph in the user's current body font.
    /// - Returns: estimated characters per visual row, or nil when no credible
    ///   estimate exists.
    public static func charactersPerRow(
        keyboardWidthPoints: Double,
        averageCharacterWidthPoints: Double
    ) -> Int? {
        guard keyboardWidthPoints.isFinite, keyboardWidthPoints > 0,
              averageCharacterWidthPoints.isFinite, averageCharacterWidthPoints > 0
        else { return nil }
        let usable = keyboardWidthPoints * hostFieldWidthFraction
        let raw = Int((usable / averageCharacterWidthPoints).rounded(.down))
        guard raw >= minimumCredibleWidth else { return nil }
        return min(raw, maximumCredibleWidth)
    }
}

/// An immutable snapshot of the text around the caret, captured from the proxy
/// at the moment the trackpad engages.
///
/// All indices are in **grapheme clusters** (Swift `Character`), so an emoji,
/// a flag, a skin-toned emoji, or a combining sequence counts as ONE position —
/// the caret can never be parked inside one. The UTF-16 distance the host needs
/// is derived separately by `utf16Distance(from:to:)`.
public struct SpaceCursorDocument: Equatable {

    /// Caret-adjacent text, before + after concatenated.
    public let characters: [Character]

    /// Grapheme index of the caret within `characters`.
    public let origin: Int

    /// Start index of every logical line in `characters` (delimited by "\n").
    /// Exact — observed, never estimated.
    private let logicalLineStarts: [Int]

    /// Start index of every *navigable row*. Every logical-line start is a row
    /// start; when a wrap width is available, long logical lines additionally
    /// break into estimated rows. With no wrap width this is identical to
    /// `logicalLineStarts`, i.e. exactly the Build-105 behaviour.
    private let rowStarts: [Int]

    /// Characters per estimated visual row, or nil when the document navigates
    /// by explicit newlines only.
    public let wrapWidth: Int?

    public init(before: String, after: String, wrapWidth: Int? = nil) {
        let head = Array(before)
        let tail = Array(after)
        characters = head + tail
        origin = head.count

        var logical = [0]
        for (i, ch) in characters.enumerated() where ch == "\n" {
            logical.append(i + 1)
        }
        logicalLineStarts = logical

        let width = wrapWidth.flatMap { $0 >= 1 ? $0 : nil }
        self.wrapWidth = width
        guard let width else {
            rowStarts = logical
            return
        }
        var rows: [Int] = []
        rows.reserveCapacity(logical.count)
        for (i, lineStart) in logical.enumerated() {
            let lineEnd = i + 1 < logical.count ? logical[i + 1] - 1 : characters.count
            rows.append(contentsOf: Self.wrappedRowStarts(
                in: characters,
                from: lineStart,
                to: lineEnd,
                width: width
            ))
        }
        rowStarts = rows
    }

    /// Greedy word wrap over `characters[start..<end]`, the algorithm every
    /// mainstream text layout engine uses: fill until the row is full, break at
    /// the last space if there is one, otherwise break mid-token. Returns the
    /// start index of each resulting row, beginning with `start`.
    ///
    /// This reproduces the *shape* of host wrapping from the text alone. It is
    /// not, and is not claimed to be, the host's own line breaking: no kerning,
    /// no proportional advances, no hyphenation, no bidi reordering.
    private static func wrappedRowStarts(
        in characters: [Character],
        from start: Int,
        to end: Int,
        width: Int
    ) -> [Int] {
        var rows = [start]
        guard end > start else { return rows }
        var rowStart = start
        var lastBreak: Int?           // index just after the most recent space
        var i = start
        while i < end {
            if characters[i] == " " { lastBreak = i + 1 }
            if i - rowStart >= width {
                let breakAt = (lastBreak.map { $0 > rowStart && $0 < end ? $0 : i }) ?? i
                rows.append(breakAt)
                rowStart = breakAt
                lastBreak = nil
                i = breakAt
                continue
            }
            i += 1
        }
        return rows
    }

    /// Convenience for a proxy that returned nil for either side.
    public init(before: String?, after: String?, wrapWidth: Int? = nil) {
        self.init(before: before ?? "", after: after ?? "", wrapWidth: wrapWidth)
    }

    public var count: Int { characters.count }

    /// True when there is more than one row to move between — either a real
    /// newline (exact) or an estimated wrap (bounded).
    ///
    /// A single-line field, a host that returns no context, or a host that
    /// truncates context to a stretch shorter than one estimated row all still
    /// report `false`, and the engine then confines itself to horizontal
    /// movement rather than inventing geometry it cannot observe.
    public var supportsVerticalNavigation: Bool { rowStarts.count > 1 }

    /// True when at least one row boundary came from the wrap estimate rather
    /// than from an observed "\n". Callers use this to keep their claims
    /// honest; the engine's behaviour is identical either way.
    public var usesEstimatedRows: Bool { rowStarts.count > logicalLineStarts.count }

    /// Number of navigable rows.
    public var lineCount: Int { rowStarts.count }

    /// Number of logical, newline-delimited lines. Always exact.
    public var logicalLineCount: Int { logicalLineStarts.count }

    /// Index of the row containing `index`.
    public func line(of index: Int) -> Int {
        var lo = 0, hi = rowStarts.count - 1, result = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if rowStarts[mid] <= index { result = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return result
    }

    public func start(ofLine line: Int) -> Int {
        rowStarts[min(max(line, 0), rowStarts.count - 1)]
    }

    /// Index one past the last character of `line`, excluding the "\n" or the
    /// wrap space that separates it from the next row — so a caret parked at
    /// the end of a row sits after the last visible character, never on top of
    /// the separator.
    public func end(ofLine line: Int) -> Int {
        let clamped = min(max(line, 0), rowStarts.count - 1)
        guard clamped + 1 < rowStarts.count else { return characters.count }
        let nextStart = rowStarts[clamped + 1]
        var end = nextStart
        while end > rowStarts[clamped],
              end - 1 < characters.count,
              characters[end - 1] == "\n" || characters[end - 1] == " " {
            end -= 1
        }
        return end
    }

    /// Caret column within its logical line, in graphemes.
    public func column(of index: Int) -> Int { index - start(ofLine: line(of: index)) }

    /// Signed UTF-16 distance between two grapheme indices — the unit the host's
    /// NSString-backed text storage counts in. Moving across a non-BMP emoji is
    /// therefore ±2, not ±1, which is what keeps the caret off the middle of a
    /// surrogate pair.
    public func utf16Distance(from: Int, to: Int) -> Int {
        guard from != to else { return 0 }
        let lower = min(from, to), upper = max(from, to)
        let span = characters[lower..<upper].reduce(0) { $0 + $1.utf16.count }
        return to > from ? span : -span
    }

    /// The text this document was built from, for cheap staleness checks.
    public func joined() -> String { String(characters) }
}

/// Pure, timer-free state machine for one space-key touch session.
public struct SpaceCursorEngine: Equatable {

    public enum Phase: Equatable {
        case idle
        /// Finger down, not yet a recognised hold. `movedBeyondSlop` latches
        /// once travel means a release should no longer type a space.
        case pressed(pressedAt: Date, movedBeyondSlop: Bool)
        /// Trackpad live. `caret` is where the engine believes the caret sits
        /// within `document`; `stickyColumn` survives vertical moves so running
        /// up and down a ragged paragraph returns to the same column.
        case cursor(document: SpaceCursorDocument, caret: Int, stickyColumn: Int)
    }

    /// Side effects the host must apply. There is deliberately **no delete
    /// case** — this engine cannot express text removal.
    public enum Effect: Equatable {
        case none
        /// A plain tap: insert exactly one space.
        case insertSpace
        /// The hold was recognised: enter trackpad mode, insert zero spaces.
        case enteredCursorMode
        /// Move the caret. `graphemes` is the user-visible distance (for tests
        /// and assertions); `utf16` is what `adjustTextPosition(byCharacterOffset:)`
        /// should be called with. Both are already clamped to the captured
        /// context and are never zero.
        case moveCaret(graphemes: Int, utf16: Int)
        /// Trackpad finished (release or cancel). The host should resynchronise
        /// context and invalidate caret-dependent async work.
        case endedCursorMode
    }

    public private(set) var phase: Phase = .idle
    public var config: SpaceCursorConfig

    public init(config: SpaceCursorConfig = SpaceCursorConfig()) {
        self.config = config
    }

    // MARK: - Queries

    public var isCursorActive: Bool {
        if case .cursor = phase { return true }
        return false
    }

    public var isTracking: Bool { phase != .idle }

    /// Caret position within the captured document, or nil outside cursor mode.
    public var caretIndex: Int? {
        if case .cursor(_, let caret, _) = phase { return caret }
        return nil
    }

    /// Signed grapheme offset from where the trackpad engaged.
    public var appliedOffset: Int? {
        if case .cursor(let doc, let caret, _) = phase { return caret - doc.origin }
        return nil
    }

    public var document: SpaceCursorDocument? {
        if case .cursor(let doc, _, _) = phase { return doc }
        return nil
    }

    // MARK: - Curves

    /// Characters of horizontal travel for a cumulative translation.
    ///
    /// Linear and fine inside the precision zone, then accelerating, so a
    /// 24pt nudge moves 3 characters while a 300pt sweep moves well over a
    /// hundred. Purely a function of CUMULATIVE translation, so dragging back
    /// retraces exactly — there is no hysteresis and no ratchet.
    public func horizontalCharacters(forTranslation translation: Double) -> Int {
        guard translation != 0, translation.isFinite else { return 0 }
        let magnitude = abs(translation)
        let fine = max(config.finePointsPerCharacter, 0.0001)
        let zone = max(config.precisionZonePoints, 0)

        let characters: Double
        if magnitude <= zone {
            characters = magnitude / fine
        } else {
            let base = zone / fine
            let extra = magnitude - zone
            let scale = max(config.accelerationScalePoints, 0.0001)
            characters = base + (extra / fine) * (1.0 + extra / scale)
        }

        let capped = min(characters, Double(config.maximumCharactersPerGesture))
        let magnitudeSteps = Int(capped.rounded(.towardZero))
        return translation < 0 ? -magnitudeSteps : magnitudeSteps
    }

    /// Logical lines of vertical travel for a cumulative translation. Zero
    /// inside the dead zone; crossing it is a deliberate line change.
    public func verticalLines(forTranslation translation: Double) -> Int {
        guard translation != 0, translation.isFinite else { return 0 }
        let magnitude = abs(translation)
        guard magnitude > config.verticalDeadZonePoints else { return 0 }
        let extra = magnitude - config.verticalDeadZonePoints
        let per = max(config.pointsPerLine, 0.0001)
        let lines = 1 + Int((extra / per).rounded(.towardZero))
        let capped = min(lines, config.maximumCharactersPerGesture)
        return translation < 0 ? -capped : capped
    }

    // MARK: - Transitions

    /// Begin a touch on the space key.
    public mutating func press(at now: Date) {
        phase = .pressed(pressedAt: now, movedBeyondSlop: false)
    }

    /// Drive the activation clock. Returns `.enteredCursorMode` exactly once,
    /// on the first tick at or after `activationDelay` while still pressed.
    /// `document` is the caret context captured at that instant.
    public mutating func tick(at now: Date, document: SpaceCursorDocument) -> Effect {
        guard case .pressed(let pressedAt, _) = phase else { return .none }
        guard now.timeIntervalSince(pressedAt) >= config.activationDelay else { return .none }
        phase = .cursor(
            document: document,
            caret: document.origin,
            stickyColumn: document.column(of: document.origin)
        )
        return .enteredCursorMode
    }

    /// Report cumulative finger translation from the drag origin.
    ///
    /// Before activation this only latches the tap-cancel slop. In trackpad
    /// mode it maps travel to a target caret position, clamped to the captured
    /// context, and returns the delta needed to get there.
    public mutating func drag(translationX: Double, translationY: Double, at now: Date) -> Effect {
        switch phase {
        case .idle:
            return .none

        case .pressed(let pressedAt, let moved):
            let beyond = moved
                || abs(translationX) > config.tapCancelSlop
                || abs(translationY) > config.tapCancelSlop
            if beyond != moved {
                phase = .pressed(pressedAt: pressedAt, movedBeyondSlop: beyond)
            }
            return .none

        case .cursor(let doc, let caret, let sticky):
            let horizontal = horizontalCharacters(forTranslation: translationX)
            let vertical = doc.supportsVerticalNavigation
                ? verticalLines(forTranslation: translationY)
                : 0

            let target: Int
            var nextSticky = sticky

            if vertical == 0 {
                // Pure horizontal: flow freely, crossing line breaks like Apple's
                // does. Always measured from the ORIGIN, so reversal retraces.
                target = clamp(doc.origin + horizontal, in: doc)
                nextSticky = doc.column(of: target)
            } else {
                // Vertical picks the row; horizontal offsets the column within
                // it. The sticky column is preserved so travelling across a
                // short row and back lands where the user started.
                let originLine = doc.line(of: doc.origin)
                let targetLine = min(max(originLine + vertical, 0), doc.lineCount - 1)
                let desiredColumn = max(sticky + horizontal, 0)
                let lineStart = doc.start(ofLine: targetLine)
                let lineEnd = doc.end(ofLine: targetLine)
                target = clamp(lineStart + min(desiredColumn, lineEnd - lineStart), in: doc)
                nextSticky = desiredColumn
            }

            guard target != caret else {
                if nextSticky != sticky {
                    phase = .cursor(document: doc, caret: caret, stickyColumn: nextSticky)
                }
                return .none
            }

            phase = .cursor(document: doc, caret: target, stickyColumn: nextSticky)
            return .moveCaret(
                graphemes: target - caret,
                utf16: doc.utf16Distance(from: caret, to: target)
            )
        }
    }

    /// Adopt an externally observed caret position — used when the host is
    /// confirmed to still hold the captured text but reported a different
    /// caret than we predicted (a host that clamps or partially honours
    /// movement). Keeps subsequent deltas measured from reality instead of
    /// compounding a divergence. Ignored outside cursor mode.
    public mutating func reconcile(observedCaret: Int) {
        guard case .cursor(let doc, let caret, let sticky) = phase else { return }
        let clamped = clamp(observedCaret, in: doc)
        guard clamped != caret else { return }
        phase = .cursor(document: doc, caret: clamped, stickyColumn: sticky)
    }

    /// End the touch. A pre-activation release is a tap (`.insertSpace`) unless
    /// the finger wandered or the hold already crossed the activation delay.
    /// From trackpad mode it is `.endedCursorMode` and NEVER inserts a space.
    public mutating func end(at now: Date) -> Effect {
        let current = phase
        phase = .idle
        switch current {
        case .idle:
            return .none
        case .pressed(let pressedAt, let moved):
            let heldToActivation = now.timeIntervalSince(pressedAt) >= config.activationDelay
            return (moved || heldToActivation) ? .none : .insertSpace
        case .cursor:
            return .endedCursorMode
        }
    }

    /// Abort the touch (system cancellation, touch-outside, lifecycle
    /// teardown). Never inserts a space.
    public mutating func cancel() -> Effect {
        let wasCursor = isCursorActive
        phase = .idle
        return wasCursor ? .endedCursorMode : .none
    }

    private func clamp(_ index: Int, in doc: SpaceCursorDocument) -> Int {
        min(max(index, 0), doc.count)
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Proxy seam
// ───────────────────────────────────────────────────────────────────────────

/// The exact subset of `UITextDocumentProxy` the space cursor touches.
///
/// Declared here, UIKit-free, so the whole insert/move path can be exercised
/// against a recording double in tests — which is how "cursor mode never
/// deletes" is proven rather than asserted. Note there is intentionally no
/// `deleteBackward` requirement: a conforming double cannot even be asked to
/// delete through this seam.
public protocol SpaceCursorTextProxy: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    func adjustTextPosition(byCharacterOffset offset: Int)
}

/// Drives one space-key gesture against a proxy: captures context at takeover,
/// applies caret movement, and self-corrects when the host disagrees.
///
/// The controller keeps ownership of what a TAP means (the double-space "…. "
/// transform, spelling commit, mutation bookkeeping), so this type never
/// inserts anything — it returns `.insertSpace` and lets the controller commit.
public final class SpaceCursorSession {

    public private(set) var engine: SpaceCursorEngine

    /// OWNED, NOT OBSERVED — do not make this `weak`.
    ///
    /// The session is the proxy's only owner. Callers construct the adapter as
    /// a temporary argument (`SpaceCursorSession(proxy: Adapter(owner: self))`),
    /// so a `weak` store here deallocates it before `init` even returns: every
    /// context read yields nil, the engine captures an empty document, `clamp`
    /// collapses to zero and the caret can never move — while the affordance
    /// still engages, because `tick` transitions regardless of content. That is
    /// precisely the Build-104 defect, and it is invisible to any test that
    /// holds the proxy alive in a local `let`.
    ///
    /// This creates no retain cycle: the conforming adapter holds its owning
    /// controller `weak` (see `SpaceCursorProxyAdapter`), so the chain is
    /// controller → session → adapter ⇢(weak) controller. The session must
    /// therefore never outlive the controller that owns it.
    ///
    /// Guarded by `Scripts/verify_space_cursor_lifetime.sh` and by
    /// `testTemporaryProxyOwnershipSurvivesInjectionScope`.
    private let proxy: SpaceCursorTextProxy?

    /// True once this session has actually repositioned the caret, so the
    /// controller knows whether a resynchronise is warranted.
    public private(set) var didMoveCaret = false

    /// Supplies the current estimated characters-per-visual-row, re-read at
    /// every takeover so a rotation or a dynamic-type change is picked up.
    /// Returning nil restricts the session to explicit-newline navigation.
    private let wrapWidthProvider: () -> Int?

    public init(
        engine: SpaceCursorEngine = SpaceCursorEngine(),
        proxy: SpaceCursorTextProxy?,
        wrapWidthProvider: @escaping () -> Int? = { nil }
    ) {
        self.engine = engine
        self.proxy = proxy
        self.wrapWidthProvider = wrapWidthProvider
    }

    public var isCursorActive: Bool { engine.isCursorActive }
    public var isTracking: Bool { engine.isTracking }
    public var config: SpaceCursorConfig {
        get { engine.config }
        set { engine.config = newValue }
    }

    public func press(at now: Date) {
        didMoveCaret = false
        engine.press(at: now)
    }

    /// Capture context from the proxy and attempt takeover.
    public func tick(at now: Date) -> SpaceCursorEngine.Effect {
        let document = SpaceCursorDocument(
            before: proxy?.documentContextBeforeInput,
            after: proxy?.documentContextAfterInput,
            wrapWidth: wrapWidthProvider()
        )
        return engine.tick(at: now, document: document)
    }

    public func drag(translationX: Double, translationY: Double, at now: Date) -> SpaceCursorEngine.Effect {
        let effect = engine.drag(translationX: translationX, translationY: translationY, at: now)
        if case .moveCaret(_, let utf16) = effect {
            proxy?.adjustTextPosition(byCharacterOffset: utf16)
            didMoveCaret = true
            reconcileWithHost()
        }
        return effect
    }

    public func end(at now: Date) -> SpaceCursorEngine.Effect { engine.end(at: now) }

    public func cancel() -> SpaceCursorEngine.Effect {
        let effect = engine.cancel()
        didMoveCaret = false
        return effect
    }

    public func clearMovementFlag() { didMoveCaret = false }

    /// Re-read the caret position, but adopt it ONLY when the surrounding text
    /// is byte-for-byte the text we captured. If the host truncates context,
    /// returns nothing, or the document changed under us, the observation is
    /// not comparable and is discarded rather than corrupting the model.
    private func reconcileWithHost() {
        guard let proxy, let document = engine.document else { return }
        let before = proxy.documentContextBeforeInput ?? ""
        let after = proxy.documentContextAfterInput ?? ""
        guard before + after == document.joined() else { return }
        engine.reconcile(observedCaret: Array(before).count)
    }
}
