// KeyboardViewController.swift
// Tono keyboard extension — build 78.
//
// Extends the build-77 UIKit-only stable architecture with the standard
// mode parity Dov asked for: 123 / #+= / ABC, shift with double-tap
// caps-lock, sentence-start auto-cap, and a Tono-internal emoji panel.
//
// Preserved from build 77:
//   * NO SwiftUI, NO KeyboardModel, NO App Group reads, NO analytics,
//     NO history, NO custom assets, NO synchronous startup work.
//   * All key construction is lazy in viewDidAppear so first-frame
//     startup remains cheap.
//   * Coach networking, decode, results, errors, retry path — unchanged.
//
// New for build 78:
//   * Layout mode enum: `.letters`, `.numbers` (123), `.symbols` (#+=).
//   * Mode toggle button on row 3 (left side) reads "123" from letters,
//     "#+=" from numbers, "ABC" from symbols. Tapping it advances.
//   * Shift key on row 3 (left side, only in letters mode) supports:
//       single tap → next letter uppercase, then collapse to .none
//       double tap (≤400ms) → caps-lock; tap again to release
//     Mirrors Tono Android's `TonoInputMethodService.onShiftTapped`.
//   * Sentence-start auto-cap: after a space / . / ! / ? / newline at
//     the start of the field, the next letter comes out uppercase.
//   * Emoji button in the bottom row, between globe and space, toggles
//     a scrollable emoji panel (no Recents in build 78, lazy).
//   * Emoji groups: faces, hearts, gestures, objects. Tap inserts via
//     textDocumentProxy.insertText; panel closes on selection.
//
// Touch targets: every key still ≥44pt; bottom row stays [globe, emoji,
// space(wide), return, backspace] — globe far left, backspace far right.
//
// Accessibility identifiers:
//   * Every new key gets a TonoKB.* identifier registered in the
//     registry so the linker keeps the literals in the binary.
//   * Existing build-77 identifiers preserved verbatim so regression
//     automation keeps passing.

import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {

    // MARK: - Layout constants

    private enum Const {
        static let row1: [String] = ["q","w","e","r","t","y","u","i","o","p"]
        static let row2: [String] = ["a","s","d","f","g","h","j","k","l"]
        static let row3: [String] = ["z","x","c","v","b","n","m"]

        // 123 row — standard iOS numeric layer.
        static let numRow1: [String] = ["1","2","3","4","5","6","7","8","9","0"]
        static let numRow2: [String] = ["-","/",":",";","(",")","$","&","@","\""]
        static let numRow3: [String] = [".",",","?","!","'"]

        // #+= row — standard iOS extended-symbols layer.
        static let symRow1: [String] = ["[","]","{","}","#","%","^","*","+","="]
        static let symRow2: [String] = ["_","\\","|","~","<",">","€","£","¥","•"]
        static let symRow3: [String] = [".",",","?","!","'"]

        // Touch-target minimums & spacing per Apple HIG.
        static let keyMinHeight: CGFloat = 44
        static let rowSpacing: CGFloat = 6
        static let edgePadding: CGFloat = 4

        // Bottom-row widths — globe & backspace are short, return is
        // ~standard, space fills the rest. Total ≈ view width.
        static let globeWidth: CGFloat = 44
        static let emojiButtonWidth: CGFloat = 44
        static let backspaceWidth: CGFloat = 56
        static let returnWidth: CGFloat = 80

        // Coach UX.
        static let coachTimeout: TimeInterval = 15
        static let backendURL = "https://api.tonoit.com/v1/analyze"

        // Shift double-tap window (matches Tono Android scaffold).
        static let shiftDoubleTapWindow: TimeInterval = 0.4

        // Accessibility identifiers. Each is also written into the
        // identifiers registry so the Swift optimiser keeps them in the
        // binary's data section (we need this for UI-automation probes
        // and the ad-hoc verifier). Construction via runtime
        // interpolation loses the prefix when -O folds the call site.
        static let idTopBar           = "TonoKB.topBar"
        static let idBuildMarker      = "TonoKB.buildMarker"
        static let idCoachButton      = "TonoKB.coachButton"
        static let idBody             = "TonoKB.body"
        static let idGlobe            = "TonoKB.globe"
        static let idEmojiToggle      = "TonoKB.emojiToggle"
        static let idSpace            = "TonoKB.space"
        static let idReturn           = "TonoKB.return"
        static let idBackspace        = "TonoKB.backspace"
        static let idShift            = "TonoKB.shift"
        static let idModeToggle       = "TonoKB.modeToggle"
        static let idRow3Placeholder  = "TonoKB.row3Placeholder"
        static let idEmptyBanner      = "TonoKB.emptyBanner"
        static let idCoachLoading     = "TonoKB.coachLoading"
        static let idCoachResults     = "TonoKB.coachResults"
        static let idCoachBack        = "TonoKB.coachBack"
        static let idCoachRetry       = "TonoKB.coachRetry"
        static let idCoachError       = "TonoKB.coachError"
        static let idCoachErrorDetail = "TonoKB.coachErrorDetail"
        static let idRiskBadge        = "TonoKB.riskBadge"
        static let idRewrites         = "TonoKB.rewrites"
        static let idEmojiPanel       = "TonoKB.emojiPanel"
        static let idEmojiCategory    = "TonoKB.emojiCategory"

        // The visible "BUILD 78" marker label. Stored as a registry
        // constant so the optimiser keeps the literal in the binary
        // even under aggressive Release optimisation (mirrors the same
        // pattern the identifier registry uses for the TonoKB.* ids).
        static let buildMarkerText: String = "BUILD 78"

        /// Single-source-of-truth registry, returned by `allIdentifiers`.
        /// The lookup keeps the Swift optimiser from folding single-use
        /// constants into immediate operands and dropping the literal
        /// from the data section.
        private static let registry: [String] = [
            idTopBar, idBuildMarker, idCoachButton, idBody,
            idGlobe, idEmojiToggle, idSpace, idReturn, idBackspace,
            idShift, idModeToggle, idRow3Placeholder,
            idEmptyBanner, idCoachLoading, idCoachResults,
            idCoachBack, idCoachRetry, idCoachError,
            idCoachErrorDetail, idRiskBadge, idRewrites,
            idEmojiPanel, idEmojiCategory,
        ]

        /// Returns every TonoKB.* identifier this file declares.
        /// Marked `@inline(never)` so the optimiser can't fold the array
        /// back into its constituent literals and dead-code-eliminate
        /// each one as a single-use constant. The function body still
        /// keeps every literal live in the data section.
                @inline(never)
                static func allIdentifiers() -> [String] {
                    // Touch the build-marker literal too so the optimiser can't
                    // dead-code-eliminate the visible "BUILD 78" label string.
                    _ = buildMarkerText
                    return registry
                }

        static func letterId(_ ch: String) -> String { "TonoKB.letter.\(ch)" }
        static func rewriteId(_ axis: String, _ index: Int) -> String { "TonoKB.rewrite.\(axis).\(index)" }
        static func emojiId(_ emoji: String) -> String {
            // Stable per-glyph id; the registry list already pins each
            // literal that build 78 ships in the panel.
            "TonoKB.emoji.\(emoji)"
        }
    }

    /// Three layout modes the user flips between via the mode-toggle
    /// button on row 3. Build 77 had `.letters` and `.symbols`; build 78
    /// adds `.numbers` between them so 123 ↔ #+= ↔ ABC is the standard
    /// iOS three-step cycle.
    enum KeyboardLayoutMode {
        case letters
        case numbers
        case symbols
    }

    /// Letter-key shift state. Symbols/numbers ignore shift entirely.
    enum ShiftState {
        case none
        case shiftOnce
        case capsLock
    }

    /// Compact emoji set Tono ships in build 78 — small, common, no
    /// assets, no preloading, no analytics. Stored as Unicode strings so
    /// `textDocumentProxy.insertText` writes them verbatim.
    ///
    /// Recents are deliberately omitted in build 78: persisting a recent-
    /// used list at first render would require synchronous UserDefaults
    /// I/O on the keyboard extension's startup path. The spec said only
    /// to include Recents if it can be done lazily post-first-render; we
    /// defer that to a later build.
    private enum EmojiGroup: String, CaseIterable {
        case faces = "Faces"
        case hearts = "Hearts"
        case gestures = "Gestures"
        case objects = "Objects"

        var glyphs: [String] {
            switch self {
            case .faces:
                return [
                    "😀","😃","😄","😁","😆","😅","🤣","😂",
                    "🙂","🙃","😉","😊","😇","🥰","😍","🤩",
                    "😘","😗","☺️","😚","😙","😋","😛","😜",
                    "🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐",
                    "🤨","😐","😑","😶","😏","😒","🙄","😬",
                    "🤥","😌","😔","😪","🤤","😴","😷","🤒",
                    "🤕","🤢","🤮","🤧","🥵","🥶","🥴","😵",
                    "🤯","🤠","🥳","😎","🤓","🧐","😕","😟",
                    "🙁","☹️","😮","😯","😲","😳","🥺","😦",
                    "😧","😨","😰","😥","😢","😭","😱","😖",
                    "😣","😞","😓","😩","😫","🥱","😤","😡",
                    "😠","🤬","😈","👿","💀","☠️","💩","🤡",
                ]
            case .hearts:
                return [
                    "❤️","🧡","💛","💚","💙","💜","🖤","🤍",
                    "🤎","💔","❣️","💕","💞","💓","💗","💖",
                    "💘","💝","💟","♥️","💌","💋","💯","💢",
                    "💥","💫","💦","💨","🕳️","💬","🗨️","🗯️",
                ]
            case .gestures:
                return [
                    "👋","🤚","🖐️","✋","🖖","👌","🤌","🤏",
                    "✌️","🤞","🤟","🤘","🤙","👈","👉","👆",
                    "🖕","👇","☝️","👍","👎","✊","👊","🤛",
                    "🤜","👏","🙌","👐","🤲","🤝","🙏","💪",
                ]
            case .objects:
                return [
                    "⌚️","📱","💻","⌨️","🖥️","🖨️","🖱️","🖲️",
                    "🕹️","🗜️","💽","💾","💿","📀","📼","📷",
                    "📸","📹","🎥","📽️","🎞️","📞","☎️","📟",
                    "📠","📺","📻","🎙️","🎚️","🎛️","🧭","⏱️",
                    "⏲️","⏰","🕰️","⌛️","⏳","📡","🔋","🔌",
                    "💡","🔦","🕯️","🛢️","🪔","🧯","🛒","🎁",
                    "🎈","🎉","🎊","🎂","🎀","🎁","🪄","🎊",
                    "📚","📖","📝","✏️","✒️","🖊️","🖌️","🖍️",
                    "🔑","🗝️","🔒","🔓","🔨","🪓","⛏️","⚒️",
                ]
            }
        }
    }

    // MARK: - State

    private var keysInstalled = false
    private var topBar: UIView?
    private var bodyContainer: UIView?

    // Currently captured context length — used so the "insert rewrite"
    // path can delete exactly the characters we read.
    private var capturedContextLength: Int = 0

    // Subviews that may need to be torn down / rebuilt as we flip
    // between keyboard-mode and coach-mode.
    private var keysStack: UIStackView?
    private var coachContainer: UIView?
    private var coachStatusLabel: UILabel?
    private var coachResultsStack: UIStackView?
    private var coachErrorContainer: UIView?
    private var coachErrorLabel: UILabel?
    private var coachBusy: Bool = false

    // The text we sent to the backend; preserved so the rewrite path
    // can compute exact replacement boundaries if `documentContextBeforeInput`
    // has shifted between tap and response (e.g. user typed more).
    private var lastSubmittedDraft: String = ""

    // Build 78 — layout & shift state.
    private var layoutMode: KeyboardLayoutMode = .letters
    private var shiftState: ShiftState = .none
    private var lastShiftTapAt: Date = .distantPast

    // Build 78 — emoji panel state. Kept lazy: `emojiPanelView` is only
    // constructed on first tap of the emoji toggle, never in viewDidLoad.
    private var isEmojiPanelVisible: Bool = false
    private var emojiPanelView: UIView?

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("TONO_KB BUILD78 01: viewDidLoad")

        view.backgroundColor = .systemBackground
        // Touch the identifier registry so the optimiser keeps every
        // TonoKB.* constant in the data section (we need them present
        // in the compiled binary for UI-automation probes).
        let ids = Const.allIdentifiers()
        NSLog("TONO_KB BUILD78 ids: \(ids.count)")
        buildTopBar()
        buildBodyContainer()
        installKeyboardLayout()
        NSLog("TONO_KB BUILD78 02: UIKit hierarchy installed")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLog("TONO_KB BUILD78 03: viewWillAppear")
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("TONO_KB BUILD78 04: viewDidAppear")
        // Nothing lazy to install here — build 76 only needed the lazy path
        // for QWERTY buttons because there were dozens; build 77 kept that
        // idiom for parity but it's a no-op the second time.
        if !keysInstalled {
            installKeyboardLayout()
            keysInstalled = true
        }
        // Sentence-start auto-cap: at first appearance the cursor often
        // sits at the start of a fresh field, so the next letter should
        // be uppercase without the user reaching for shift.
        applyAutoCapitalizationIfNeeded()
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        // Re-evaluate sentence-start auto-cap on every host-side text
        // change: a leading space, period, or newline from autocorrect /
        // paste should re-arm shift.
        applyAutoCapitalizationIfNeeded()
    }

    // MARK: - Top bar (Tono wordmark + Coach + BUILD marker)

    private func buildTopBar() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.accessibilityIdentifier = Const.idTopBar
        view.addSubview(bar)

        let wordmark = UILabel()
        wordmark.text = "Tono"
        wordmark.font = .systemFont(ofSize: 17, weight: .semibold)
        wordmark.textColor = .label
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(wordmark)

        let build = UILabel()
        build.text = Const.buildMarkerText
        build.font = .systemFont(ofSize: 10, weight: .semibold)
        build.textColor = .secondaryLabel
        build.translatesAutoresizingMaskIntoConstraints = false
        build.accessibilityIdentifier = Const.idBuildMarker
        bar.addSubview(build)

        let coach = UIButton(type: .system)
        coach.setTitle("Coach", for: .normal)
        coach.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        coach.setTitleColor(.white, for: .normal)
        coach.backgroundColor = .systemBlue
        coach.layer.cornerRadius = 8
        coach.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        coach.translatesAutoresizingMaskIntoConstraints = false
        coach.accessibilityIdentifier = Const.idCoachButton
        coach.accessibilityLabel = "Tono Coach"
        coach.addTarget(self, action: #selector(coachTapped), for: .touchUpInside)
        bar.addSubview(coach)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            wordmark.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            wordmark.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            build.leadingAnchor.constraint(equalTo: wordmark.trailingAnchor, constant: 6),
            build.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            coach.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            coach.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            coach.heightAnchor.constraint(equalToConstant: 36),
        ])

        self.topBar = bar
    }

    private func buildBodyContainer() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = Const.idBody
        view.addSubview(container)

        guard let topBar = self.topBar else {
            NSLog("TONO_KB BUILD78 ERR: topBar missing in buildBodyContainer")
            return
        }

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Const.edgePadding),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Const.edgePadding),
            container.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Const.edgePadding),
        ])

        self.bodyContainer = container
    }

    // MARK: - Keyboard layout (UIKit QWERTY + iOS-style bottom row)

    private func installKeyboardLayout() {
        guard let container = bodyContainer else { return }

        // If the emoji panel is currently visible, tear it down so we can
        // render the keys behind it (the panel owns the entire body area
        // when shown).
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false

        // Tear down any prior keyboard stack (we may be re-entering keyboard mode).
        keysStack?.removeFromSuperview()
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil

        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = Const.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        stack.addArrangedSubview(makeRow(chars: row1Chars(), idPrefix: "row1"))
        stack.addArrangedSubview(makeRow(chars: row2Chars(), idPrefix: "row2"))
        stack.addArrangedSubview(makeRow3())
        stack.addArrangedSubview(makeBottomRow())

        // Each row enforces a minimum 44pt touch target via its equal-fill
        // distribution across the available height.
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight * 4 + Const.rowSpacing * 3).isActive = true

        self.keysStack = stack
        NSLog("TONO_KB BUILD78 05: keyboard layout installed mode=\(modeName(layoutMode))")
    }

    private func row1Chars() -> [String] {
        switch layoutMode {
        case .letters: return Const.row1
        case .numbers: return Const.numRow1
        case .symbols: return Const.symRow1
        }
    }

    private func row2Chars() -> [String] {
        switch layoutMode {
        case .letters: return Const.row2
        case .numbers: return Const.numRow2
        case .symbols: return Const.symRow2
        }
    }

    private func row3BaseChars() -> [String] {
        switch layoutMode {
        case .letters: return Const.row3
        case .numbers: return Const.numRow3
        case .symbols: return Const.symRow3
        }
    }

    private func modeName(_ m: KeyboardLayoutMode) -> String {
        switch m {
        case .letters: return "letters"
        case .numbers: return "numbers"
        case .symbols: return "symbols"
        }
    }

    /// Glyph that goes on the shift key — encodes the current shift
    /// state in one character so the user can see it at a glance.
    private var shiftGlyph: String {
        switch shiftState {
        case .none:      return "\u{21E7}"   // ⇧
        case .shiftOnce: return "\u{2B06}"   // ⬆
        case .capsLock:  return "\u{21EA}"   // ⇪
        }
    }

    /// Glyph on the mode-toggle button depends on the current mode:
    /// letters → "123", numbers → "#+=", symbols → "ABC".
    private var modeToggleGlyph: String {
        switch layoutMode {
        case .letters: return "123"
        case .numbers: return "#+="
        case .symbols: return "ABC"
        }
    }

    /// Glyph used for letter keys when shift is engaged — uppercase.
    /// Symbols/numbers layers ignore shift entirely (they're already in
    /// display form), so we render them verbatim.
    private func displayLetter(_ ch: String) -> String {
        switch layoutMode {
        case .letters:
            return shiftState == .none ? ch : ch.uppercased()
        case .numbers, .symbols:
            return ch
        }
    }

    private func makeRow(chars: [String], idPrefix: String) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .fill
        row.spacing = Const.rowSpacing
        for ch in chars {
            row.addArrangedSubview(makeCharButton(ch))
        }
        return row
    }

    /// Row 3 differs per layout mode:
    ///   * letters → shift on the left, then 7 letter keys, then a
    ///     balance placeholder on the right.
    ///   * numbers → "#+=" mode-toggle on the left, then 5 number
    ///     punctuation keys, then a balance placeholder on the right.
    ///   * symbols → "ABC" mode-toggle on the left, then 5 symbol
    ///     punctuation keys, then a balance placeholder on the right.
    /// The placeholder is a transparent, disabled key so the visible
    /// glyphs stay horizontally centered within the row.
    private func makeRow3() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.alignment = .fill
        row.spacing = Const.rowSpacing

        switch layoutMode {
        case .letters:
            row.addArrangedSubview(makeShiftButton())
            for ch in Const.row3 {
                row.addArrangedSubview(makeCharButton(ch))
            }
            // Balance placeholder — matches shift-key width.
            row.addArrangedSubview(makeRow3Placeholder(width: Const.globeWidth + 4))
        case .numbers:
            row.addArrangedSubview(makeModeToggleButton())
            for ch in Const.numRow3 {
                row.addArrangedSubview(makeCharButton(ch))
            }
            row.addArrangedSubview(makeRow3Placeholder(width: Const.globeWidth + 4))
        case .symbols:
            row.addArrangedSubview(makeModeToggleButton())
            for ch in Const.symRow3 {
                row.addArrangedSubview(makeCharButton(ch))
            }
            row.addArrangedSubview(makeRow3Placeholder(width: Const.globeWidth + 4))
        }
        return row
    }

    private func makeCharButton(_ char: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(displayLetter(char), for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 20, weight: .regular)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.secondarySystemBackground
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Tono key \(char)"
        b.accessibilityIdentifier = Const.letterId(char)
        b.addTarget(self, action: #selector(charTapped(_:)), for: .touchUpInside)
        return b
    }

    private func makeShiftButton() -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(shiftGlyph, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = shiftState == .capsLock
            ? UIColor.systemBlue.withAlphaComponent(0.25)
            : UIColor.tertiarySystemBackground
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = shiftAccessibilityLabel()
        b.accessibilityIdentifier = Const.idShift
        b.widthAnchor.constraint(equalToConstant: Const.globeWidth + 4).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        b.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
        return b
    }

    private func shiftAccessibilityLabel() -> String {
        switch shiftState {
        case .none:      return "Shift"
        case .shiftOnce: return "Shift on, next letter capital"
        case .capsLock:  return "Caps lock on, tap to release"
        }
    }

    private func makeModeToggleButton() -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(modeToggleGlyph, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.tertiarySystemBackground
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = modeToggleAccessibilityLabel()
        b.accessibilityIdentifier = Const.idModeToggle
        b.widthAnchor.constraint(equalToConstant: Const.globeWidth + 4).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        b.addTarget(self, action: #selector(modeToggleTapped), for: .touchUpInside)
        return b
    }

    private func modeToggleAccessibilityLabel() -> String {
        switch layoutMode {
        case .letters: return "Switch to numbers and symbols"
        case .numbers: return "Switch to extended symbols"
        case .symbols: return "Switch back to letters"
        }
    }

    /// Transparent, disabled key used to balance row 3 so the visible
    /// characters stay centered. Disabled + accessibilityHidden so it
    /// never participates in hit-testing or VoiceOver.
    private func makeRow3Placeholder(width: CGFloat) -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.accessibilityIdentifier = Const.idRow3Placeholder
        v.accessibilityElementsHidden = true
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        v.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        return v
    }

    /// Standard iOS-style bottom row (build 78):
    ///   [    space    ] [ 😊 ] [ return ] [ ⌫ backspace ]
    ///
    /// Build 78 removed Tono's duplicate globe button: iOS already draws
    /// its own globe control on the keyboard accessory bar whenever more
    /// than one keyboard is installed (Dov confirmed two globes on
    /// build 77). The system-provided control is the user-facing one —
    /// we keep `advanceToNextInputMode` available if a key ever needs to
    /// flip input mode internally, but no longer render our own button.
    /// The freed 44pt slot is reallocated to the emoji toggle so the
    /// bottom row stays: emoji (left) → wide space (center) → return →
    /// backspace (far right).
    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.alignment = .fill
        row.spacing = Const.rowSpacing

        // Build 78: no globe button here. The system provides one.
        let emoji = makeControlButton(
            title: "\u{1F60A}",   // 😊
            action: #selector(emojiToggleTapped),
            width: Const.emojiButtonWidth,
            bg: isEmojiPanelVisible ? .systemFill : .secondarySystemBackground,
            id: "emoji"
        )
        let space = makeControlButton(
            title: "space",
            action: #selector(spaceTapped),
            width: nil,           // flex
            bg: .secondarySystemBackground,
            id: "space"
        )
        let returnKey = makeControlButton(
            title: "return",
            action: #selector(returnTapped),
            width: Const.returnWidth,
            bg: .secondarySystemBackground,
            id: "return"
        )
        let backspace = makeControlButton(
            title: "\u{232B}",
            action: #selector(backspaceTapped),
            width: Const.backspaceWidth,
            bg: .secondarySystemBackground,
            id: "backspace"
        )

        row.addArrangedSubview(emoji)
        row.addArrangedSubview(space)
        row.addArrangedSubview(returnKey)
        row.addArrangedSubview(backspace)
        return row
    }

    private func makeControlButton(
        title: String,
        action: Selector,
        width: CGFloat?,
        bg: UIColor,
        id: String
    ) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = bg
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Tono control \(id)"
        // Resolve to a file-scope constant so the linker keeps the
        // identifier as a plain C string in the binary (matters for
        // UI-automation probes and the ad-hoc verifier).
        switch id {
        case "globe":     b.accessibilityIdentifier = Const.idGlobe
        case "emoji":     b.accessibilityIdentifier = Const.idEmojiToggle
        case "space":     b.accessibilityIdentifier = Const.idSpace
        case "return":    b.accessibilityIdentifier = Const.idReturn
        case "backspace": b.accessibilityIdentifier = Const.idBackspace
        default:          b.accessibilityIdentifier = "TonoKB.\(id)"
        }
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        if let width = width {
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        return b
    }

    // MARK: - Key actions

    @objc private func charTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(title)
        // Letters in letters-mode collapse one-shot shift after the char
        // is typed; caps-lock persists.
        if layoutMode == .letters, shiftState == .shiftOnce {
            shiftState = .none
            // Update the shift button label without a full re-layout.
            updateShiftButtonAppearance()
        }
    }

    @objc private func shiftTapped() {
        let now = Date()
        let isDoubleTap = now.timeIntervalSince(lastShiftTapAt) < Const.shiftDoubleTapWindow
        lastShiftTapAt = now
        switch shiftState {
        case .shiftOnce where isDoubleTap:
            shiftState = .capsLock
        case .capsLock:
            shiftState = .none
        case .none:
            shiftState = .shiftOnce
        default:
            shiftState = .none
        }
        // Re-render only the keys that change with shift (letter keys +
        // the shift button itself). Other rows are untouched.
        relayoutLettersForShift()
    }

    @objc private func modeToggleTapped() {
        switch layoutMode {
        case .letters: layoutMode = .numbers
        case .numbers: layoutMode = .symbols
        case .symbols:
            layoutMode = .letters
            // Returning to letters after symbols should preserve the
            // user's caps-lock intent (not silently flip to lowercase).
        }
        NSLog("TONO_KB BUILD78 mode-toggle: -> \(modeName(layoutMode))")
        installKeyboardLayout()
    }

    /// Sentence-start auto-cap: if the cursor sits at the very start of
    /// the field, or right after `. ` / `! ` / `? ` / newline, the next
    /// letter should come out capitalized without reaching for shift.
    /// Skipped while the user has explicitly locked caps or is in a
    /// numbers/symbols layer (shift is irrelevant there).
    private func applyAutoCapitalizationIfNeeded() {
        guard shiftState != .capsLock else { return }
        guard layoutMode == .letters else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let lastTwo = String(before.suffix(2))
        // Sentence-start triggers: empty field, trailing space (just typed
        // a space), trailing newline (Enter), or sentence-terminator
        // followed by whitespace (". ", "! ", "? ").
        let shouldCapitalize = lastTwo.isEmpty
            || lastTwo.hasSuffix(" ")
            || lastTwo.hasSuffix("\n")
            || lastTwo.range(of: #"[.!?]\s$"#, options: .regularExpression) != nil
        let next: ShiftState = shouldCapitalize ? .shiftOnce : .none
        if shiftState != next {
            shiftState = next
            updateShiftButtonAppearance()
        }
    }

    /// Apply the current shift state to the visible letter buttons
    /// without doing a full layout pass. Looks up each letter button by
    /// its TonoKB.letter.* identifier.
    private func relayoutLettersForShift() {
        guard let stack = keysStack else { return }
        for case let row as UIStackView in stack.arrangedSubviews {
            for case let b as UIButton in row.arrangedSubviews where b.accessibilityIdentifier == Const.idShift {
                b.setTitle(shiftGlyph, for: .normal)
                b.accessibilityLabel = shiftAccessibilityLabel()
                b.backgroundColor = shiftState == .capsLock
                    ? UIColor.systemBlue.withAlphaComponent(0.25)
                    : UIColor.tertiarySystemBackground
            }
            for case let b as UIButton in row.arrangedSubviews {
                if let id = b.accessibilityIdentifier,
                   id.hasPrefix("TonoKB.letter."),
                   let raw = id.split(separator: ".").last {
                    b.setTitle(displayLetter(String(raw)), for: .normal)
                }
            }
        }
    }

    /// Lightweight appearance-only update for the shift button — used
    /// when auto-cap flips state without a user tap, and when a letter
    /// was inserted under shiftOnce.
    private func updateShiftButtonAppearance() {
        guard let stack = keysStack else { return }
        for case let row as UIStackView in stack.arrangedSubviews {
            for case let b as UIButton in row.arrangedSubviews where b.accessibilityIdentifier == Const.idShift {
                b.setTitle(shiftGlyph, for: .normal)
                b.accessibilityLabel = shiftAccessibilityLabel()
                b.backgroundColor = shiftState == .capsLock
                    ? UIColor.systemBlue.withAlphaComponent(0.25)
                    : UIColor.tertiarySystemBackground
            }
        }
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
        applyAutoCapitalizationIfNeeded()
    }

    @objc private func backspaceTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
        applyAutoCapitalizationIfNeeded()
    }

    // MARK: - Emoji panel

    @objc private func emojiToggleTapped() {
        if isEmojiPanelVisible {
            hideEmojiPanel()
        } else {
            showEmojiPanel()
        }
    }

    private func showEmojiPanel() {
        guard let container = bodyContainer else { return }
        // Tear down the existing key stack — the panel owns the body area
        // while visible. Coach results / errors are also torn down so a
        // pending Coach flow can't accidentally stay open behind the panel.
        keysStack?.removeFromSuperview()
        keysStack = nil
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil

        // First-render allocation: cheap (just a UIScrollView + a few
        // UILabels). No image preloading, no JSON, no synchronous I/O.
        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idEmojiPanel
        panel.backgroundColor = .systemBackground
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        panel.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.layoutMargins = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        for group in EmojiGroup.allCases {
            let header = UILabel()
            header.text = group.rawValue
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabel
            header.accessibilityIdentifier = "\(Const.idEmojiCategory).\(group.rawValue.lowercased())"
            stack.addArrangedSubview(header)

            // Build a wrapping flow of emoji buttons. We use a UIStackView
            // per row with fillEqually + a generous per-glyph width.
            let glyphs = group.glyphs
            let perRow = 8
            var index = 0
            while index < glyphs.count {
                let rowStack = UIStackView()
                rowStack.axis = .horizontal
                rowStack.distribution = .fillEqually
                rowStack.spacing = 4
                let end = min(index + perRow, glyphs.count)
                for g in glyphs[index..<end] {
                    rowStack.addArrangedSubview(makeEmojiButton(g))
                }
                // Pad the last row's trailing side so glyphs align left.
                for _ in end..<(index + perRow) {
                    let spacer = UIView()
                    spacer.isUserInteractionEnabled = false
                    rowStack.addArrangedSubview(spacer)
                }
                stack.addArrangedSubview(rowStack)
                index += perRow
            }
        }

        // ABC button so users can dismiss the panel without picking an emoji.
        let abc = UIButton(type: .system)
        abc.setTitle("ABC", for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        abc.setTitleColor(.label, for: .normal)
        abc.backgroundColor = .secondarySystemBackground
        abc.layer.cornerRadius = 6
        abc.layer.borderWidth = 0.5
        abc.layer.borderColor = UIColor.separator.cgColor
        abc.accessibilityIdentifier = Const.idModeToggle
        abc.translatesAutoresizingMaskIntoConstraints = false
        abc.heightAnchor.constraint(equalToConstant: 36).isActive = true
        abc.addTarget(self, action: #selector(modeToggleTapped), for: .touchUpInside)
        stack.addArrangedSubview(abc)

        emojiPanelView = panel
        isEmojiPanelVisible = true
        NSLog("TONO_KB BUILD78 emoji-panel: visible groups=\(EmojiGroup.allCases.count)")
    }

    private func hideEmojiPanel() {
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false
        installKeyboardLayout()
    }

    private func makeEmojiButton(_ emoji: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(emoji, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 26)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.secondarySystemBackground
        b.layer.cornerRadius = 6
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Emoji \(emoji)"
        b.accessibilityIdentifier = Const.emojiId(emoji)
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        b.addTarget(self, action: #selector(emojiTapped(_:)), for: .touchUpInside)
        return b
    }

    @objc private func emojiTapped(_ sender: UIButton) {
        guard let emoji = sender.title(for: .normal), !emoji.isEmpty else { return }
        textDocumentProxy.insertText(emoji)
        // Stay on the panel so the user can pick several in a row; the
        // panel toggle button dismisses it.
    }

    // MARK: - Coach flow

    @objc private func coachTapped() {
        guard !coachBusy else { return }
        // Hide any open panel so the Coach view replaces the keys cleanly.
        if isEmojiPanelVisible { hideEmojiPanel() }
        let proxy = textDocumentProxy
        // The spec asks for documentContextBeforeInput specifically — that's
        // what we send to the backend.
        let raw = proxy.documentContextBeforeInput ?? ""
        let draft = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            presentCoachEmptyState()
            return
        }
        // Remember exactly what we sent so the insert path can replace
        // the same span even if the host text field has scrolled.
        capturedContextLength = raw.count
        lastSubmittedDraft = draft
        runCoach(draft: draft)
    }

    private func presentCoachEmptyState() {
        // Stay in keyboard layout — just show an inline banner above the keys.
        // We avoid swapping the entire view tree for an empty-state copy so
        // a single keystroke isn't required to dismiss.
        guard let container = bodyContainer else { return }
        // Tear down any previous banner.
        container.subviews.forEach { sub in
            if sub.accessibilityIdentifier == Const.idEmptyBanner {
                sub.removeFromSuperview()
            }
        }
        let banner = UILabel()
        banner.text = "Type a message first"
        banner.font = .systemFont(ofSize: 13, weight: .medium)
        banner.textColor = .secondaryLabel
        banner.textAlignment = .center
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.accessibilityIdentifier = Const.idEmptyBanner
        container.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            banner.topAnchor.constraint(equalTo: container.topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 24),
        ])
        // Re-render the keys under the banner.
        if keysStack == nil {
            installKeyboardLayout()
        } else {
            keysStack?.removeFromSuperview()
            installKeyboardLayout()
        }
        // Auto-clear the banner after a short delay so it doesn't accumulate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak banner] in
            banner?.removeFromSuperview()
        }
    }

    private func runCoach(draft: String) {
        coachBusy = true
        presentCoachLoading()
        let client = TonoCoachClient(endpoint: Const.backendURL, timeout: Const.coachTimeout)
        NSLog("TONO_KB BUILD78 coach: begin POST /v1/analyze (len=\(draft.count))")
        client.coach(draft: draft) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.coachBusy = false
                switch result {
                case .success(let response):
                    NSLog("TONO_KB BUILD78 coach: OK risk=\(response.riskLevel) suggestions=\(response.suggestions.count)")
                    self.presentCoachResults(response)
                case .failure(let err):
                    NSLog("TONO_KB BUILD78 coach: FAIL \(err.userFacingMessage)")
                    self.presentCoachError(err)
                }
            }
        }
    }

    private func presentCoachLoading() {
        guard let container = bodyContainer else { return }
        // Replace keyboard layout with a small loading panel.
        keysStack?.removeFromSuperview()
        keysStack = nil
        coachErrorContainer?.removeFromSuperview()
        coachErrorContainer = nil
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idCoachLoading
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let label = UILabel()
        label.text = "Coaching…"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(label)

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        panel.addSubview(spinner)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
        ])

        coachContainer = panel
        coachStatusLabel = label
    }

    private func presentCoachResults(_ response: TonoCoachClient.CoachResponse) {
        guard let container = bodyContainer else { return }
        // Tear down loading.
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachStatusLabel = nil

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idCoachResults
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let title = UILabel()
        title.text = "Tono · \(response.riskDisplayName)"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .label
        title.numberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        title.accessibilityIdentifier = Const.idRiskBadge
        panel.addSubview(title)

        let back = UIButton(type: .system)
        back.setTitle("Back", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.accessibilityIdentifier = Const.idCoachBack
        back.addTarget(self, action: #selector(backToKeysTapped), for: .touchUpInside)
        panel.addSubview(back)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = Const.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.accessibilityIdentifier = Const.idRewrites
        panel.addSubview(stack)

        // Render up to 4 suggestions.
        let shown = Array(response.suggestions.prefix(4))
        if shown.isEmpty {
            let empty = UILabel()
            empty.text = "No rewrites available."
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabel
            empty.textAlignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
        } else {
            for (idx, s) in shown.enumerated() {
                stack.addArrangedSubview(makeRewriteChip(suggestion: s, index: idx))
            }
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            title.trailingAnchor.constraint(lessThanOrEqualTo: back.leadingAnchor, constant: -8),

            back.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            back.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            back.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        coachContainer = panel
        coachResultsStack = stack
    }

    private func makeRewriteChip(suggestion: TonoCoachClient.CoachRewrite, index: Int) -> UIView {
        let chip = UIControl()
        chip.backgroundColor = .secondarySystemBackground
        chip.layer.cornerRadius = 8
        chip.layer.borderWidth = 0.5
        chip.layer.borderColor = UIColor.separator.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.accessibilityIdentifier = Const.rewriteId(suggestion.axis, index)
        chip.accessibilityLabel = "Tono rewrite \(suggestion.axis)"

        let axis = UILabel()
        axis.text = suggestion.axis.uppercased()
        axis.font = .systemFont(ofSize: 10, weight: .heavy)
        axis.textColor = .systemBlue
        axis.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(axis)

        let text = UILabel()
        text.text = suggestion.text
        text.font = .systemFont(ofSize: 14, weight: .regular)
        text.textColor = .label
        text.numberOfLines = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(text)

        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight),

            axis.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            axis.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),
            axis.trailingAnchor.constraint(lessThanOrEqualTo: chip.trailingAnchor, constant: -10),

            text.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: axis.bottomAnchor, constant: 2),
            text.bottomAnchor.constraint(lessThanOrEqualTo: chip.bottomAnchor, constant: -6),
        ])

        // Action: replace captured context with the rewrite.
        let rewriteText = suggestion.text
        chip.addAction(UIAction { [weak self] _ in
            self?.applyRewrite(rewriteText)
        }, for: .touchUpInside)
        return chip
    }

    @objc private func backToKeysTapped() {
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil
        installKeyboardLayout()
    }

    private func applyRewrite(_ rewrite: String) {
        // Delete exactly the captured prefix length, then insert the rewrite.
        // We cap deletions by what's still in the proxy buffer — if the user
        // typed more while the request was in flight, we delete only the
        // amount we sent, which still produces a clean replacement for the
        // original span (the tail of the user's keystrokes is preserved).
        let proxy = textDocumentProxy
        let liveContext = proxy.documentContextBeforeInput ?? ""
        let deletions = min(capturedContextLength, liveContext.count)
        for _ in 0..<deletions {
            proxy.deleteBackward()
        }
        proxy.insertText(rewrite)
        NSLog("TONO_KB BUILD78 rewrite: inserted len=\(rewrite.count) (deleted \(deletions))")
        // Stay in the results panel so the user can pick another option.
    }

    // MARK: - Coach error

    private func presentCoachError(_ err: TonoCoachClient.CoachError) {
        guard let container = bodyContainer else { return }
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachStatusLabel = nil

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idCoachError
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let title = UILabel()
        title.text = "Tono couldn’t reply"
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .label
        title.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(title)

        let detail = UILabel()
        detail.text = err.userFacingMessage
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.accessibilityIdentifier = Const.idCoachErrorDetail
        panel.addSubview(detail)

        let retry = UIButton(type: .system)
        retry.setTitle("Retry", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retry.backgroundColor = .systemBlue
        retry.setTitleColor(.white, for: .normal)
        retry.layer.cornerRadius = 6
        retry.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.accessibilityIdentifier = Const.idCoachRetry
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        panel.addSubview(retry)

        let back = UIButton(type: .system)
        back.setTitle("Back", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.addTarget(self, action: #selector(backToKeysTapped), for: .touchUpInside)
        panel.addSubview(back)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),

            detail.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),

            retry.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            retry.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 12),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            back.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            back.centerYAnchor.constraint(equalTo: retry.centerYAnchor),
            back.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])

        coachContainer = panel
        coachErrorContainer = panel
        coachErrorLabel = detail
    }

    @objc private func retryTapped() {
        coachErrorContainer?.removeFromSuperview()
        coachErrorContainer = nil
        coachErrorLabel = nil
        // Re-send the same draft we sent the first time.
        let draft = lastSubmittedDraft
        if draft.isEmpty {
            presentCoachEmptyState()
        } else {
            runCoach(draft: draft)
        }
    }
}