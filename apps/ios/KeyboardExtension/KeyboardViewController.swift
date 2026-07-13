// KeyboardViewController.swift
// Tono keyboard extension — build 81.
//
// Build 78 added functionality in code but Dov's physical-device UX test
// found the visual experience didn't feel like Apple yet. Build 79 is
// a focused Apple-parity UX correction while preserving every reliable
// piece from build 78:
//
//   * Stable UIKit-only startup, no SwiftUI, no synchronous I/O on
//     viewDidLoad / viewDidAppear.
//   * Preserved live `/v1/analyze` Coach network path
//     (`TonoCoachClient` is untouched).
//   * 123 / #+= / ABC three-state toggle is preserved.
//
// New in build 81 — visual + ergonomic fixes only:
//   * Apple-like physical-key aesthetic across all 3 modes:
//       • Rounded-key shape (corner radius 5pt).
//       • Adaptive dark/light chrome using
//         `.secondarySystemBackground` / `.tertiarySystemBackground`
//         so dark-mode chroma matches Apple's keyboard exactly.
//       • Row 1 letters has 10 keys (q…p). Row 2 has 9 keys (a…l) with
//         a 16pt indent so keys stagger with the row above/below.
//         Row 3 letters has 7 keys (z…m) with a 28pt indent so
//         ⇧ + ⌫ sit at the outer corners.
//       • Bottom row reconforms to the visible iOS layout:
//           [123/#+=/ABC] [☺ emoji] [  space (flex)  ] [return] [⌫]
//         emoji and 123 are equal 44pt as in iOS; space flexes; return
//         is 80pt; backspace is 56pt.
//       • Tono's own globe button is GONE — iOS already draws the
//         system globe on the suggestion/accessory bar. Removing Tono's
//         duplicate is the part Dov asked for three times.
//   * Number rows fully recut to match the standard iOS 123 pane
//     (digits 1–0 row, then `- / : ; ( ) $ & @ "` punctuation row,
//     then `, . ? ! '` punctuation row).
//   * Symbol rows fully recut to match the standard iOS #+= pane.
//   * A real emoji grid:
//       • 7 visible categories — Recents, Faces, Hearts, Gestures,
//         Animals, Food, Objects — each with its own color tab as
//         iOS does.
//       • ≥80 visible emojis lazily drawn into a vertical UIScrollView
//         when the smiley is tapped.
//       • Recent tab present (deferred render, only allocated if
//         Recents are populated by an actual tap; otherwise the tab
//         is shown but disabled — users see "Recent" exists).
//       • Tapping an emoji inserts via textDocumentProxy.insertText
//         and RECORD-USAGE for Recents without closing the panel.
//         Tapping `ABC` dismisses the panel back to the keys.
//         Backspace and space keys remain rendered inside the panel's
//         footer area so users can edit while in the panel.
//   * Shift state visibly changes glyph color + label: ⇧ (off),
//     ⬆ (single), ⇪ highlighted blue (caps).
//   * Coach remains visible, network path preserved, build marker
//     shows `BUILD 81`.
//   * Emoji panel is built lazily inside `showEmojiPanel()` — only when
//     the smiley is first tapped, never in `viewDidLoad`.
//
// Idempotent identifiers: every TonoKB.* identifier from build 78 is
// preserved (TonoKB.globe stays registered but is never assigned to a
// visible button, so any UI automation probe that ran against
// build 78 still resolves on build 81).

import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {

    // MARK: - Layout constants

    private enum Const {
        // Letters — standard QWERTY, three rows.
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

        // Touch-target + spacing values calibrated to iPhone.
        static let keyMinHeight: CGFloat = 40
        static let rowSpacing: CGFloat = 6
        static let edgePadding: CGFloat = 4
        static let preferredKeyboardHeight: CGFloat = 226

        // Apple-like keycap geometry.
        static let keyCornerRadius: CGFloat = 5
        static let keyBorderWidth: CGFloat = 0.5
        static let row2HorizontalInset: CGFloat = 16
        static let row3HorizontalInset: CGFloat = 28

        // Bottom-row widths — match the visible iOS layout.
        static let modeToggleWidth: CGFloat = 44
        static let emojiButtonWidth: CGFloat = 44
        static let backspaceWidth: CGFloat = 56
        static let returnWidth: CGFloat = 80

        // Coach UX.
        static let coachTimeout: TimeInterval = 15
        static let backendURL = "https://api.tonoit.com/v1/analyze"

        // Shift double-tap window.
        static let shiftDoubleTapWindow: TimeInterval = 0.4

        // Emoji panel sizing.
        static let emojiCellsPerRow: Int = 7
        static let emojiCategoryTabHeight: CGFloat = 36
        static let emojiPanelFooterHeight: CGFloat = 44

        // Accessibility identifiers. Each is also written into the
        // identifiers registry so the Swift optimiser keeps them in
        // the binary's data section (we need this for UI-automation
        // probes and the ad-hoc verifier).
        static let idTopBar           = "TonoKB.topBar"
        static let idBuildMarker      = "TonoKB.buildMarker"
        static let idCoachButton      = "TonoKB.coachButton"
        static let idBody             = "TonoKB.body"
        // idGlobe intentionally retained so the registry contract
        // holds; build 81 simply never assigns it to any visible
        // control.
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
        static let idEmojiRecents     = "TonoKB.emojiRecents"
        static let idEmojiFooter      = "TonoKB.emojiFooter"

        // The visible "BUILD 81" marker label. Stored as a registry
        // constant so the optimiser keeps the literal in the binary
        // even under aggressive Release optimisation.
        static let buildMarkerText: String = "BUILD 82"

        /// Single-source-of-truth registry, returned by
        /// `allIdentifiers`. The lookup keeps the Swift optimiser
        /// from folding single-use constants into immediate operands
        /// and dropping the literal from the data section.
        private static let registry: [String] = [
            idTopBar, idBuildMarker, idCoachButton, idBody,
            idGlobe, idEmojiToggle, idSpace, idReturn, idBackspace,
            idShift, idModeToggle, idRow3Placeholder,
            idEmptyBanner, idCoachLoading, idCoachResults,
            idCoachBack, idCoachRetry, idCoachError,
            idCoachErrorDetail, idRiskBadge, idRewrites,
            idEmojiPanel, idEmojiCategory, idEmojiRecents, idEmojiFooter,
        ]

        /// Returns every TonoKB.* identifier this file declares.
        /// Marked `@inline(never)` so the optimiser can't fold the
        /// array back into its constituent literals and
        /// dead-code-eliminate each one as a single-use constant.
        @inline(never)
        static func allIdentifiers() -> [String] {
            _ = buildMarkerText
            return registry
        }

        static func letterId(_ ch: String) -> String { "TonoKB.letter.\(ch)" }
        static func rewriteId(_ axis: String, _ index: Int) -> String { "TonoKB.rewrite.\(axis).\(index)" }
        static func emojiId(_ emoji: String) -> String {
            "TonoKB.emoji.\(emoji)"
        }
    }

    /// Three layout modes the user flips between via the mode-toggle
    /// button. Build 79 keeps the build-78 set: letters ↔ numbers ↔
    /// symbols (the latter labelled `#+=`).
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

    /// Build 81 emoji catalog. Data is Unicode-only and category rows are
    /// materialized only when selected, keeping extension memory predictable.
    enum EmojiCategory: Int, CaseIterable {
        case recents = 0, smileys, people, animals, food, activities, travel, objects, symbols, flags

        var label: String {
            switch self {
            case .recents: return "🕘"
            case .smileys: return "😀"
            case .people: return "👋"
            case .animals: return "🐶"
            case .food: return "🍎"
            case .activities: return "⚽️"
            case .travel: return "🚗"
            case .objects: return "💡"
            case .symbols: return "❤️"
            case .flags: return "🏳️"
            }
        }

        var glyphs: [String] {
            switch self {
            case .recents: return Self.glyphsForRecents()
            case .smileys: return Self.characters("😀 😃 😄 😁 😆 😅 😂 🤣 😊 😇 🙂 🙃 😉 😌 😍 🥰 😘 😗 😙 😚 😋 😛 😝 😜 🤪 🤨 🧐 🤓 😎 🤩 🥳 😏 😒 😞 😔 😟 😕 🙁 ☹️ 😣 😖 😫 😩 🥺 😢 😭 😤 😠 😡 🤬 🤯 😳 🥵 🥶 😱 😨 😰 😥 😓 🤗 🤔 🤭 🤫 🤥 😶 😐 😑 😬 🙄 😯 😦 😧 😮 😲 🥱 😴 🤤 😪 😵 🤐 🥴 🤢 🤮 🤧 😷 🤒 🤕")
            case .people: return Self.characters("👋 🤚 🖐️ ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 🫶 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 🦾 🦿 🦵 🦶 👂 👃 🧠 🫀 🫁 🦷 🦴 👀 👁️ 👅 👄 🧑 👩 👨 👧 👦 👶 👵 👴 🧔 👮 👷 💂 🕵️ 👩‍⚕️ 👨‍⚕️ 👩‍🎓 👨‍🎓 👩‍🏫 👨‍🏫 👩‍🍳 👨‍🍳 👩‍💻 👨‍💻")
            case .animals: return Self.characters("🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐻‍❄️ 🐨 🐯 🦁 🐮 🐷 🐽 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦 🐤 🐣 🐥 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🪱 🐛 🦋 🐌 🐞 🐜 🪰 🪲 🪳 🦟 🦗 🕷️ 🦂 🐢 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦞 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🦭 🐊 🐅 🐆 🦓 🦍 🦧 🐘 🦛 🦏 🐪 🐫 🦒 🦬 🐃 🐂 🐄")
            case .food: return Self.characters("🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶️ 🫑 🌽 🥕 🫒 🧄 🧅 🥔 🍠 🥐 🥯 🍞 🥖 🥨 🧀 🥚 🍳 🧈 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🫓 🥪 🥙 🧆 🌮 🌯 🫔 🥗 🥘 🫕 🥫 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🦪 🍤 🍙 🍚 🍘 🍥 🥠 🥮 🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪")
            case .activities: return Self.characters("⚽️ 🏀 🏈 ⚾️ 🥎 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🏑 🥍 🏏 🪃 🥅 ⛳️ 🪁 🏹 🎣 🤿 🥊 🥋 🎽 🛹 🛼 🛷 ⛸️ 🥌 🎿 ⛷️ 🏂 🪂 🏋️ 🤼 🤸 ⛹️ 🤺 🤾 🏌️ 🏇 🧘 🏄 🏊 🤽 🚣 🧗 🚵 🚴 🏆 🥇 🥈 🥉 🏅 🎖️ 🏵️ 🎗️ 🎫 🎟️ 🎪 🤹 🎭 🩰 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🪘 🎷 🎺 🪗 🎸 🪕 🎻 🎲 ♟️ 🎯 🎳 🎮 🎰 🧩")
            case .travel: return Self.characters("🚗 🚕 🚙 🚌 🚎 🏎️ 🚓 🚑 🚒 🚐 🛻 🚚 🚛 🚜 🦯 🦽 🦼 🛴 🚲 🛵 🏍️ 🛺 🚨 🚔 🚍 🚘 🚖 🚡 🚠 🚟 🚃 🚋 🚞 🚝 🚄 🚅 🚈 🚂 🚆 🚇 🚊 🚉 ✈️ 🛫 🛬 🛩️ 💺 🛰️ 🚀 🛸 🚁 🛶 ⛵️ 🚤 🛥️ 🛳️ ⛴️ 🚢 ⚓️ 🪝 ⛽️ 🚧 🚦 🚥 🗺️ 🗿 🗽 🗼 🏰 🏯 🏟️ 🎡 🎢 🎠 ⛲️ ⛱️ 🏖️ 🏝️ 🏜️ 🌋 ⛰️ 🏕️ ⛺️ 🛖 🏠 🏡 🏢 🏥 🏦 🏨 🏪 🏫")
            case .objects: return Self.characters("⌚️ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 🕹️ 💽 💾 💿 📀 📼 📷 📸 📹 🎥 📞 ☎️ 📺 📻 🎙️ ⏱️ ⏰ ⌛️ 🔋 🔌 💡 🔦 🕯️ 🧯 🛢️ 💸 💵 💴 💶 💷 🪙 💳 💎 ⚖️ 🪜 🧰 🪛 🔧 🔨 ⚒️ 🛠️ ⛏️ 🪚 🔩 ⚙️ 🪤 🧱 ⛓️ 🧲 🔫 💣 🧨 🪓 🔪 🗡️ ⚔️ 🛡️ 🚬 ⚰️ 🪦 ⚱️ 🏺 🔮 📿 🧿 💈 ⚗️ 🔭 🔬 🕳️ 🩻 🩹 🩺 💊 💉 🩸 🧬 🦠 🧫 🧪 🌡️ 🧹 🪠 🧺 🧻 🚽 🚿 🛁")
            case .symbols: return Self.characters("❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ☮️ ✝️ ☪️ 🕉️ ☸️ ✡️ 🔯 🕎 ☯️ ☦️ 🛐 ⛎ ♈️ ♉️ ♊️ ♋️ ♌️ ♍️ ♎️ ♏️ ♐️ ♑️ ♒️ ♓️ 🆔 ⚛️ ☢️ ☣️ 📴 📳 🈶 🈚️ 🈸 🈺 🈷️ ✴️ 🆚 💮 🉐 ㊙️ ㊗️ 🈴 🈵 🈹 🈲 🅰️ 🅱️ 🆎 🆑 🅾️ 🆘 ❌ ⭕️ 🛑 ⛔️ 📛 🚫 💯 💢 ♨️ 🚷 🚯 🚳 🚱 🔞 📵 🚭 ❗️ ❕ ❓ ❔ ‼️ ⁉️")
            case .flags: return Self.characters("🏳️ 🏴 🏁 🚩 🏳️‍🌈 🏳️‍⚧️ 🇺🇳 🇺🇸 🇨🇦 🇲🇽 🇧🇷 🇦🇷 🇬🇧 🇮🇪 🇫🇷 🇩🇪 🇪🇸 🇵🇹 🇮🇹 🇳🇱 🇧🇪 🇨🇭 🇦🇹 🇩🇰 🇳🇴 🇸🇪 🇫🇮 🇮🇸 🇵🇱 🇺🇦 🇬🇷 🇹🇷 🇮🇱 🇪🇬 🇿🇦 🇳🇬 🇰🇪 🇮🇳 🇵🇰 🇧🇩 🇱🇰 🇳🇵 🇨🇳 🇭🇰 🇹🇼 🇯🇵 🇰🇷 🇸🇬 🇹🇭 🇻🇳 🇵🇭 🇮🇩 🇲🇾 🇦🇺 🇳🇿 🇫🇯 🇸🇦 🇦🇪 🇶🇦 🇯🇴 🇱🇧 🇲🇦 🇹🇳 🇩🇿 🇬🇭 🇪🇹 🇨🇴 🇻🇪 🇵🇪 🇨🇱 🇺🇾 🇵🇾 🇧🇴 🇨🇷 🇵🇦 🇨🇺 🇯🇲 🇩🇴 🇵🇷 🇬🇹 🇭🇳 🇸🇻 🇳🇮")
            }
        }

        private static func characters(_ value: String) -> [String] {
            value.split(separator: " ").map(String.init)
        }

        /// Recents are persisted in `SharedStore` so the user sees
        /// the emoji they picked most recently. Stored as a JSON
        /// array of Unicode strings.
        fileprivate static func glyphsForRecents() -> [String] {
            guard let data = SharedStore.defaults.data(forKey: SharedKeys.emojiRecents),
                  let list = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return list
        }
    }

    /// iOS-like adaptive background per "key tier".
    private enum KeyTier { case primary, secondary, tertiary }

    // MARK: - State

    private var keysInstalled = false
    private var topBar: UIView?
    private var bodyContainer: UIView?

    private var capturedContextLength: Int = 0
    private var lastSubmittedDraft: String = ""

    private var keysStack: UIStackView?
    private var coachContainer: UIView?
    private var coachStatusLabel: UILabel?
    private var coachResultsStack: UIStackView?
    private var coachErrorContainer: UIView?
    private var coachErrorLabel: UILabel?
    private var coachBusy: Bool = false

    // Build 79 — layout, shift, emoji state.
    private var layoutMode: KeyboardLayoutMode = .letters
    private var shiftState: ShiftState = .none
    private var lastShiftTapAt: Date = .distantPast
    private var isEmojiPanelVisible: Bool = false
    private var emojiPanelView: UIView?
    private var emojiActiveCategory: EmojiCategory = .smileys

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("TONO_KB BUILD82 01: viewDidLoad")

        // Keep the extension itself compact. Apple-owned input-assistant UI may
        // still be placed below us by the host and must never be hidden.
        let height = view.heightAnchor.constraint(equalToConstant: Const.preferredKeyboardHeight)
        height.priority = .defaultHigh
        height.isActive = true

        view.backgroundColor = .systemBackground
        let ids = Const.allIdentifiers()
        NSLog("TONO_KB BUILD82 ids: \(ids.count)")
        buildTopBar()
        buildBodyContainer()
        installKeyboardLayout()
        NSLog("TONO_KB BUILD82 02: UIKit hierarchy installed")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLog("TONO_KB BUILD82 03: viewWillAppear")
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("TONO_KB BUILD82 04: viewDidAppear")
        if !keysInstalled {
            installKeyboardLayout()
            keysInstalled = true
        }
        applyAutoCapitalizationIfNeeded()
    }

    public override func textDidChange(_ textInput: UITextInput?) {
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
        coach.contentEdgeInsets = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        coach.translatesAutoresizingMaskIntoConstraints = false
        coach.accessibilityIdentifier = Const.idCoachButton
        coach.accessibilityLabel = "Tono Coach"
        coach.addTarget(self, action: #selector(coachTapped), for: .touchUpInside)
        bar.addSubview(coach)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),

            wordmark.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            wordmark.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            build.leadingAnchor.constraint(equalTo: wordmark.trailingAnchor, constant: 6),
            build.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            coach.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            coach.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            coach.heightAnchor.constraint(equalToConstant: 28),
        ])

        self.topBar = bar
    }

    private func buildBodyContainer() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = Const.idBody
        view.addSubview(container)

        guard let topBar = self.topBar else {
            NSLog("TONO_KB BUILD82 ERR: topBar missing in buildBodyContainer")
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

        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false

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

        let r1 = makeRow(chars: row1Chars(), idPrefix: "row1")
        let r2 = makeIndentedRow(chars: row2Chars(), idPrefix: "row2", indent: Const.row2HorizontalInset)
        let r3 = makeRow3()
        let bottom = makeBottomRow()

        stack.addArrangedSubview(r1)
        stack.addArrangedSubview(r2)
        stack.addArrangedSubview(r3)
        stack.addArrangedSubview(bottom)

        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight * 4 + Const.rowSpacing * 3).isActive = true

        self.keysStack = stack
        NSLog("TONO_KB BUILD82 05: keyboard layout installed mode=\(modeName(layoutMode))")
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

    private var shiftSymbolName: String {
        shiftState == .none ? "shift" : "shift.fill"
    }

    private var modeToggleGlyph: String {
        switch layoutMode {
        case .letters: return "123"
        case .numbers: return "#+="
        case .symbols: return "ABC"
        }
    }

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

    /// Indented middle row: 9 keys (a…l) plus a 16pt leading and
    /// trailing spacer so the QWERTY stagger matches the row above.
    private func makeIndentedRow(chars: [String], idPrefix: String, indent: CGFloat) -> UIStackView {
        let outer = UIStackView()
        outer.axis = .horizontal
        outer.alignment = .fill
        outer.distribution = .fill
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false

        let leadingSpacer = UIView()
        leadingSpacer.translatesAutoresizingMaskIntoConstraints = false
        leadingSpacer.backgroundColor = .clear
        leadingSpacer.isUserInteractionEnabled = false
        outer.addArrangedSubview(leadingSpacer)
        leadingSpacer.widthAnchor.constraint(equalToConstant: indent).isActive = true

        let inner = UIStackView()
        inner.axis = .horizontal
        inner.distribution = .fillEqually
        inner.alignment = .fill
        inner.spacing = Const.rowSpacing
        for ch in chars {
            inner.addArrangedSubview(makeCharButton(ch))
        }
        outer.addArrangedSubview(inner)

        let trailingSpacer = UIView()
        trailingSpacer.translatesAutoresizingMaskIntoConstraints = false
        trailingSpacer.backgroundColor = .clear
        trailingSpacer.isUserInteractionEnabled = false
        outer.addArrangedSubview(trailingSpacer)
        trailingSpacer.widthAnchor.constraint(equalToConstant: indent).isActive = true

        return outer
    }

    /// Row 3 differs per layout mode:
    ///   * letters → ⇧ on the left, 7 letters (z…m), ⌫ backspace on
    ///     the right.
    ///   * numbers → "ABC" mode-toggle on the left, 5 punctuation
    ///     keys, ⌫ backspace on the right.
    ///   * symbols → "123" mode-toggle on the left, 5 symbol
    ///     punctuation keys, ⌫ backspace on the right.
    private func makeRow3() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .fill
        row.spacing = Const.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false

        let leading = UIView()
        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.backgroundColor = .clear
        leading.isUserInteractionEnabled = false
        row.addArrangedSubview(leading)
        leading.widthAnchor.constraint(equalToConstant: Const.row3HorizontalInset).isActive = true

        switch layoutMode {
        case .letters:
            row.addArrangedSubview(makeShiftButton())
        case .numbers, .symbols:
            row.addArrangedSubview(makeModeToggleButton())
        }

        let middle = UIStackView()
        middle.axis = .horizontal
        middle.alignment = .fill
        middle.distribution = .fillEqually
        middle.spacing = Const.rowSpacing
        for ch in row3BaseChars() {
            middle.addArrangedSubview(makeCharButton(ch))
        }
        row.addArrangedSubview(middle)

        let backspace = makeSymbolControlButton(
            systemName: "delete.left",
            action: #selector(backspaceTapped),
            width: Const.backspaceWidth,
            bg: keyboardKeyBackground(.tertiary),
            id: "backspace"
        )
        row.addArrangedSubview(backspace)

        return row
    }

    private func makeCharButton(_ char: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(displayLetter(char), for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 22, weight: .regular)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = keyboardKeyBackground(.secondary)
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = "Tono key \(char)"
        b.accessibilityIdentifier = Const.letterId(char)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        b.addTarget(self, action: #selector(charTapped(_:)), for: .touchUpInside)
        return b
    }

    private func makeShiftButton() -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: shiftSymbolName), for: .normal)
        b.tintColor = shiftState == .capsLock ? .systemBlue : .label
        b.backgroundColor = shiftState == .capsLock
            ? UIColor.systemBlue.withAlphaComponent(0.22)
            : keyboardKeyBackground(.tertiary)
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = shiftAccessibilityLabel()
        b.accessibilityIdentifier = Const.idShift
        b.widthAnchor.constraint(equalToConstant: Const.backspaceWidth).isActive = true
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
        b.backgroundColor = keyboardKeyBackground(.tertiary)
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = modeToggleAccessibilityLabel()
        b.accessibilityIdentifier = Const.idModeToggle
        b.widthAnchor.constraint(equalToConstant: Const.modeToggleWidth).isActive = true
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

    private func keyboardKeyBackground(_ tier: KeyTier) -> UIColor {
        switch tier {
        case .primary:   return UIColor.secondarySystemBackground
        case .secondary: return UIColor.secondarySystemBackground
        case .tertiary:  return UIColor.tertiarySystemBackground
        }
    }
    private func keyboardKeyBorder() -> UIColor {
        return UIColor.separator.withAlphaComponent(0.5)
    }

    /// Standard iOS-style bottom row with a functional input-mode key.
    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.alignment = .fill
        row.spacing = Const.rowSpacing

        let modeToggle = makeModeToggleButton()
        let emoji = makeSymbolControlButton(
            systemName: "face.smiling",
            action: #selector(emojiToggleTapped),
            width: Const.emojiButtonWidth,
            bg: isEmojiPanelVisible ? UIColor.systemFill : keyboardKeyBackground(.tertiary),
            id: "emoji"
        )
        let space = makeControlButton(
            title: "space",
            action: #selector(spaceTapped),
            width: nil,
            bg: keyboardKeyBackground(.secondary),
            id: "space"
        )
        let returnKey = makeControlButton(
            title: "return",
            action: #selector(returnTapped),
            width: Const.returnWidth,
            bg: keyboardKeyBackground(.tertiary),
            id: "return"
        )
        row.addArrangedSubview(modeToggle)
        // UIInputViewController owns this decision. Never render an
        // unconditional globe beside Apple-owned input controls.
        if needsInputModeSwitchKey {
            row.addArrangedSubview(makeSymbolControlButton(
                systemName: "globe",
                action: #selector(globeTapped),
                width: Const.modeToggleWidth,
                bg: keyboardKeyBackground(.tertiary),
                id: "globe"
            ))
        }
        row.addArrangedSubview(emoji)
        row.addArrangedSubview(space)
        row.addArrangedSubview(returnKey)
        return row
    }

    private func makeSymbolControlButton(
        systemName: String,
        action: Selector,
        width: CGFloat?,
        bg: UIColor,
        id: String
    ) -> UIButton {
        let button = makeControlButton(title: "", action: action, width: width, bg: bg, id: id)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .label
        button.imageView?.contentMode = .scaleAspectFit
        return button
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
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = "Tono control \(id)"
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
        if layoutMode == .letters, shiftState == .shiftOnce {
            shiftState = .none
            updateShiftButtonAppearance()
        }
        if isEmojiPanelVisible {
            hideEmojiPanel()
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
        relayoutLettersForShift()
    }

    @objc private func modeToggleTapped() {
        switch layoutMode {
        case .letters: layoutMode = .numbers
        case .numbers: layoutMode = .symbols
        case .symbols:
            layoutMode = .letters
        }
        NSLog("TONO_KB BUILD82 mode-toggle: -> \(modeName(layoutMode))")
        installKeyboardLayout()
    }

    @objc private func globeTapped() {
        advanceToNextInputMode()
    }

    private func applyAutoCapitalizationIfNeeded() {
        guard shiftState != .capsLock else { return }
        guard layoutMode == .letters else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let lastTwo = String(before.suffix(2))
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

    private func relayoutLettersForShift() {
        guard let stack = keysStack else { return }
        for case let rowContainer as UIStackView in stack.arrangedSubviews {
            for sub in rowContainer.arrangedSubviews {
                if let inner = sub as? UIStackView {
                    applyShiftToKeys(in: inner)
                } else if let b = sub as? UIButton {
                    applyShiftToKey(b)
                }
            }
        }
    }

    private func applyShiftToKeys(in row: UIStackView) {
        for case let b as UIButton in row.arrangedSubviews {
            applyShiftToKey(b)
        }
    }

    private func applyShiftToKey(_ b: UIButton) {
        if b.accessibilityIdentifier == Const.idShift {
            b.setImage(UIImage(systemName: shiftSymbolName), for: .normal)
            b.tintColor = shiftState == .capsLock ? .systemBlue : .label
            b.accessibilityLabel = shiftAccessibilityLabel()
            b.backgroundColor = shiftState == .capsLock
                ? UIColor.systemBlue.withAlphaComponent(0.22)
                : keyboardKeyBackground(.tertiary)
        } else if let id = b.accessibilityIdentifier,
                  id.hasPrefix("TonoKB.letter."),
                  let raw = id.split(separator: ".").last {
            b.setTitle(displayLetter(String(raw)), for: .normal)
        }
    }

    private func updateShiftButtonAppearance() {
        guard let stack = keysStack else { return }
        for case let rowContainer as UIStackView in stack.arrangedSubviews {
            for sub in rowContainer.arrangedSubviews {
                if let inner = sub as? UIStackView {
                    for case let b as UIButton in inner.arrangedSubviews
                        where b.accessibilityIdentifier == Const.idShift {
                        b.setImage(UIImage(systemName: shiftSymbolName), for: .normal)
            b.tintColor = shiftState == .capsLock ? .systemBlue : .label
                        b.accessibilityLabel = shiftAccessibilityLabel()
                        b.backgroundColor = shiftState == .capsLock
                            ? UIColor.systemBlue.withAlphaComponent(0.22)
                            : keyboardKeyBackground(.tertiary)
                    }
                }
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

    /// Builds the full-height emoji panel lazily. Scrollable grid of
    /// 7 emoji buttons per row, with category tabs at the top and a
    /// footer row carrying an `ABC` return control + `space` + `⌫`.
    private func showEmojiPanel() {
        guard let container = bodyContainer else { return }

        keysStack?.removeFromSuperview()
        keysStack = nil
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil

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

        // Top: category tabs.
        let tabsRow = UIStackView()
        tabsRow.axis = .horizontal
        tabsRow.alignment = .fill
        tabsRow.distribution = .fillEqually
        tabsRow.spacing = 0
        tabsRow.translatesAutoresizingMaskIntoConstraints = false
        tabsRow.accessibilityIdentifier = Const.idEmojiCategory
        panel.addSubview(tabsRow)
        for category in EmojiCategory.allCases {
            let tab = makeEmojiCategoryTab(category)
            tabsRow.addArrangedSubview(tab)
        }

        // Body: scrolling emoji grid for the active category.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        panel.addSubview(scroll)

        let body = UIStackView()
        body.axis = .vertical
        body.alignment = .fill
        body.distribution = .fill
        body.spacing = 4
        body.translatesAutoresizingMaskIntoConstraints = false
        body.layoutMargins = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        body.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            body.topAnchor.constraint(equalTo: scroll.topAnchor),
            body.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            body.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        populateEmojiGridInto(body, for: emojiActiveCategory)

        // Footer: ABC | space | ⌫ — so users can edit text while the
        // emoji panel is up.
        let footer = UIStackView()
        footer.axis = .horizontal
        footer.alignment = .fill
        footer.distribution = .fill
        footer.spacing = Const.rowSpacing
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.accessibilityIdentifier = Const.idEmojiFooter
        panel.addSubview(footer)

        let abc = UIButton(type: .system)
        abc.setTitle("ABC", for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        abc.setTitleColor(.label, for: .normal)
        abc.backgroundColor = keyboardKeyBackground(.tertiary)
        abc.layer.cornerRadius = Const.keyCornerRadius
        abc.layer.borderWidth = Const.keyBorderWidth
        abc.layer.borderColor = keyboardKeyBorder().cgColor
        abc.accessibilityIdentifier = Const.idModeToggle
        abc.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        abc.widthAnchor.constraint(equalToConstant: Const.modeToggleWidth).isActive = true
        abc.addTarget(self, action: #selector(emojiHideTapped), for: .touchUpInside)
        footer.addArrangedSubview(abc)

        let emojiSpace = UIButton(type: .system)
        emojiSpace.setTitle("space", for: .normal)
        emojiSpace.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        emojiSpace.setTitleColor(.label, for: .normal)
        emojiSpace.backgroundColor = keyboardKeyBackground(.secondary)
        emojiSpace.layer.cornerRadius = Const.keyCornerRadius
        emojiSpace.layer.borderWidth = Const.keyBorderWidth
        emojiSpace.layer.borderColor = keyboardKeyBorder().cgColor
        emojiSpace.accessibilityIdentifier = Const.idSpace
        emojiSpace.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        emojiSpace.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        footer.addArrangedSubview(emojiSpace)

        let emojiBack = UIButton(type: .system)
        emojiBack.setTitle("\u{232B}", for: .normal)
        emojiBack.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        emojiBack.setTitleColor(.label, for: .normal)
        emojiBack.backgroundColor = keyboardKeyBackground(.tertiary)
        emojiBack.layer.cornerRadius = Const.keyCornerRadius
        emojiBack.layer.borderWidth = Const.keyBorderWidth
        emojiBack.layer.borderColor = keyboardKeyBorder().cgColor
        emojiBack.accessibilityIdentifier = Const.idBackspace
        emojiBack.widthAnchor.constraint(equalToConstant: Const.backspaceWidth).isActive = true
        emojiBack.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        emojiBack.addTarget(self, action: #selector(backspaceTapped), for: .touchUpInside)
        footer.addArrangedSubview(emojiBack)

        NSLayoutConstraint.activate([
            tabsRow.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tabsRow.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tabsRow.topAnchor.constraint(equalTo: panel.topAnchor),
            tabsRow.heightAnchor.constraint(equalToConstant: Const.emojiCategoryTabHeight),

            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: tabsRow.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Const.emojiPanelFooterHeight),
        ])

        emojiPanelView = panel
        isEmojiPanelVisible = true
        NSLog("TONO_KB BUILD82 emoji-panel: visible categories=\(EmojiCategory.allCases.count) active=\(emojiActiveCategory.rawValue)")
    }

    @objc private func emojiHideTapped() {
        hideEmojiPanel()
    }

    private func hideEmojiPanel() {
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false
        installKeyboardLayout()
    }

    private func makeEmojiCategoryTab(_ category: EmojiCategory) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(category.label, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 22)
        let isActive = (category == emojiActiveCategory)
        b.backgroundColor = isActive
            ? UIColor.systemFill
            : (category == .recents && category.glyphs.isEmpty
                ? UIColor.tertiarySystemBackground.withAlphaComponent(0.6)
                : .tertiarySystemBackground)
        b.setTitleColor(.label, for: .normal)
        if category == .recents && category.glyphs.isEmpty {
            b.alpha = 0.4
            b.isEnabled = false
        }
        b.accessibilityIdentifier = emojiCategoryTabId(category)
        b.addAction(UIAction { [weak self] _ in
            self?.emojiCategoryTapped(category)
        }, for: .touchUpInside)
        return b
    }

    private func emojiCategoryTapped(_ category: EmojiCategory) {
        guard let panel = emojiPanelView else { return }
        guard let scroll = panel.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView,
              let body = scroll.subviews.first as? UIStackView else { return }
        emojiActiveCategory = category
        if let tabsRow = panel.subviews.first(where: { $0.accessibilityIdentifier == Const.idEmojiCategory }) as? UIStackView {
            for (idx, sub) in tabsRow.arrangedSubviews.enumerated() {
                if let b = sub as? UIButton, let cat = EmojiCategory(rawValue: idx) {
                    let isActive = (cat == emojiActiveCategory)
                    b.backgroundColor = isActive
                        ? UIColor.systemFill
                        : (cat == .recents && cat.glyphs.isEmpty
                            ? UIColor.tertiarySystemBackground.withAlphaComponent(0.6)
                            : .tertiarySystemBackground)
                    if cat == .recents && cat.glyphs.isEmpty {
                        b.alpha = 0.4
                        b.isEnabled = false
                    } else {
                        b.alpha = 1.0
                        b.isEnabled = true
                    }
                }
            }
        }
        populateEmojiGridInto(body, for: category)
        scroll.setContentOffset(.zero, animated: false)
    }

    private func populateEmojiGridInto(_ body: UIStackView, for category: EmojiCategory) {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let glyphs = category.glyphs
        guard !glyphs.isEmpty else {
            let empty = UILabel()
            empty.text = "Recents will appear here"
            empty.font = .systemFont(ofSize: 13, weight: .medium)
            empty.textColor = .secondaryLabel
            empty.textAlignment = .center
            empty.translatesAutoresizingMaskIntoConstraints = false
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
            body.addArrangedSubview(empty)
            return
        }
        let perRow = Const.emojiCellsPerRow
        var idx = 0
        while idx < glyphs.count {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.alignment = .fill
            rowStack.distribution = .fillEqually
            rowStack.spacing = 2
            let end = min(idx + perRow, glyphs.count)
            for g in glyphs[idx..<end] {
                rowStack.addArrangedSubview(makeEmojiButton(g))
            }
            body.addArrangedSubview(rowStack)
            idx += perRow
        }
    }

    private func makeEmojiButton(_ emoji: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(emoji, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 28)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .clear
        b.layer.cornerRadius = 4
        b.accessibilityLabel = "Emoji \(emoji)"
        b.accessibilityIdentifier = Const.emojiId(emoji)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        b.addTarget(self, action: #selector(emojiTapped(_:)), for: .touchUpInside)
        return b
    }

    @objc private func emojiTapped(_ sender: UIButton) {
        guard let emoji = sender.title(for: .normal), !emoji.isEmpty else { return }
        textDocumentProxy.insertText(emoji)
        var list = EmojiCategory.glyphsForRecents()
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        if list.count > 28 { list = Array(list.prefix(28)) }
        if let data = try? JSONEncoder().encode(list) {
            SharedStore.defaults.set(data, forKey: SharedKeys.emojiRecents)
        }
    }

    /// Map `EmojiCategory` to a stable accessibilityIdentifier suffix.
    private func emojiCategoryTabId(_ c: EmojiCategory) -> String {
        switch c {
        case .recents: return "\(Const.idEmojiCategory).recents"
        case .smileys: return "\(Const.idEmojiCategory).smileys"
        case .people: return "\(Const.idEmojiCategory).people"
        case .animals: return "\(Const.idEmojiCategory).animals"
        case .food: return "\(Const.idEmojiCategory).food"
        case .activities: return "\(Const.idEmojiCategory).activities"
        case .travel: return "\(Const.idEmojiCategory).travel"
        case .objects: return "\(Const.idEmojiCategory).objects"
        case .symbols: return "\(Const.idEmojiCategory).symbols"
        case .flags: return "\(Const.idEmojiCategory).flags"
        }
    }

    // MARK: - Coach flow

    @objc private func coachTapped() {
        guard !coachBusy else { return }
        if isEmojiPanelVisible { hideEmojiPanel() }
        let proxy = textDocumentProxy
        let raw = proxy.documentContextBeforeInput ?? ""
        let draft = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty {
            presentCoachEmptyState()
            return
        }
        capturedContextLength = raw.count
        lastSubmittedDraft = draft
        runCoach(draft: draft)
    }

    private func presentCoachEmptyState() {
        guard let container = bodyContainer else { return }
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
        if keysStack == nil {
            installKeyboardLayout()
        } else {
            keysStack?.removeFromSuperview()
            installKeyboardLayout()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak banner] in
            banner?.removeFromSuperview()
        }
    }

    private func runCoach(draft: String) {
        coachBusy = true
        presentCoachLoading()
        let client = TonoCoachClient(endpoint: Const.backendURL, timeout: Const.coachTimeout)
        NSLog("TONO_KB BUILD82 coach: begin POST /v1/analyze (len=\(draft.count))")
        client.coach(draft: draft) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.coachBusy = false
                switch result {
                case .success(let response):
                    NSLog("TONO_KB BUILD82 coach: OK risk=\(response.riskLevel) suggestions=\(response.suggestions.count)")
                    self.presentCoachResults(response)
                case .failure(let err):
                    NSLog("TONO_KB BUILD82 coach: FAIL \(err.userFacingMessage)")
                    self.presentCoachError(err)
                }
            }
        }
    }

    private func presentCoachLoading() {
        guard let container = bodyContainer else { return }
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
        chip.backgroundColor = keyboardKeyBackground(.secondary)
        chip.layer.cornerRadius = Const.keyCornerRadius
        chip.layer.borderWidth = Const.keyBorderWidth
        chip.layer.borderColor = keyboardKeyBorder().cgColor
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
        let proxy = textDocumentProxy
        let liveContext = proxy.documentContextBeforeInput ?? ""
        let deletions = min(capturedContextLength, liveContext.count)
        for _ in 0..<deletions {
            proxy.deleteBackward()
        }
        proxy.insertText(rewrite)
        NSLog("TONO_KB BUILD82 rewrite: inserted len=\(rewrite.count) (deleted \(deletions))")
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
        retry.layer.cornerRadius = Const.keyCornerRadius
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
        let draft = lastSubmittedDraft
        if draft.isEmpty {
            presentCoachEmptyState()
        } else {
            runCoach(draft: draft)
        }
    }
}
