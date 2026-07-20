// KeyboardViewController.swift
// Tono keyboard extension — build 86.
//
// Build 86 preserves build-85 typing/spelling behavior while hardening
// caret-range candidate replacement and the four-axis Coach result contract.
//
//   * Explicit navigation matrix: letters bottom `123`; numbers/symbols
//     bottom `ABC`; numbers row-3 `#+=`; symbols row-3 `123`.
//   * Responsive 10/9/7 Apple-parity geometry with full 44pt typing targets,
//     an accessible semantic-violet Coach action, and no build-number label.
//   * One delete in row 3; conventional mode/emoji/space/return bottom row;
//     the globe is created only when `needsInputModeSwitchKey` requires it.
//   * Lazy adaptive-column UICollectionView emoji grid with reusable cells, compact
//     spacing, substantial category datasets, repeated insertion, and recents.
//   * Monochrome SF Symbols category strip for Recents, Smileys, People,
//     Animals, Food, Activities, Travel, Objects, Symbols, and Flags.
//
// Stable TonoKB.* accessibility identifiers remain available for automation.

import UIKit

/// Reads the optional Objective-C document identity without invoking Swift's
/// `UUID._unconditionallyBridgeFromObjectiveC` thunk. UIKit can legitimately
/// return nil until the keyboard has connected to its host application.
enum HostDocumentIdentifier {
    private static let selector = NSSelectorFromString("documentIdentifier")

    static func read(from proxy: UITextDocumentProxy) -> UUID? {
        let object = proxy as AnyObject
        guard object.responds(to: selector) else { return nil }
        return object.value(forKey: "documentIdentifier") as? UUID
    }
}

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIInputViewAudioFeedback {

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

        // Keyboard geometry has one measured source of truth. Width-dependent
        // content height is applied by `currentVisualMetrics`; these baseline
        // values cover key construction before the first layout pass.
        static let baselineMetrics = TonoKeyboardMetrics.portrait(availableWidth: 402)
        static let keyMinHeight = baselineMetrics.keyMinHeight
        static let rowSpacing = baselineMetrics.rowSpacing
        static let edgePadding = baselineMetrics.edgePadding

        // Apple-like keycap geometry.
        static let keyCornerRadius = baselineMetrics.keyCornerRadius
        static let keyBorderWidth: CGFloat = 0.5
        static let referencePortraitWidth: CGFloat = 367.5

        static func letterKeyWidth(availableWidth: CGFloat) -> CGFloat {
            let usable = max(availableWidth - edgePadding * 2, 320)
            return (usable - rowSpacing * 9) / 10
        }

        static func row2HorizontalInset(availableWidth: CGFloat) -> CGFloat {
            (letterKeyWidth(availableWidth: availableWidth) + rowSpacing) / 2
        }

        static func row3InnerGap(availableWidth: CGFloat) -> CGFloat {
            max(8, letterKeyWidth(availableWidth: availableWidth) * 0.34)
        }

        // Bottom-row widths — match the visible iOS layout.
        static let modeToggleWidth: CGFloat = 46
        static let emojiButtonWidth: CGFloat = TonoKeyboardMetrics.ControlGeometry.emojiToggleWidth
        static let backspaceWidth: CGFloat = 54
        static let returnWidth: CGFloat = 72

        // Coach UX.
        static let coachTimeout: TimeInterval = 15
        static let backendURL = "https://api.tonoit.com/v1/analyze"

        // Delete fires once immediately, then repeats with a bounded ramp.
        static let deleteRepeatInitialDelay: TimeInterval = 0.5
        static let deleteRepeatInterval: TimeInterval = 0.105
        static let deleteRepeatMinimumInterval: TimeInterval = 0.055

        // Emoji panel sizing.
        static let emojiCategoryTabHeight: CGFloat = TonoKeyboardMetrics.ControlGeometry.emojiCategoryTabHeight
        static let emojiPanelFooterHeight: CGFloat = TonoKeyboardMetrics.ControlGeometry.emojiPanelFooterHeight
        static let emojiCellReuseIdentifier = "TonoEmojiCell"

        // Accessibility identifiers. Each is also written into the
        // identifiers registry so the Swift optimiser keeps them in
        // the binary's data section (we need this for UI-automation
        // probes and the ad-hoc verifier).
        static let idTopBar           = "TonoKB.topBar"

        static let idCoachButton      = "TonoKB.coachButton"
        static let idCandidates       = "TonoKB.candidates"
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


        /// Single-source-of-truth registry, returned by
        /// `allIdentifiers`. The lookup keeps the Swift optimiser
        /// from folding single-use constants into immediate operands
        /// and dropping the literal from the data section.
        private static let registry: [String] = [
            idTopBar, idCoachButton, idCandidates, idBody,
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
    typealias ShiftState = TonoShiftStateMachine.State

    private struct HostConfiguration: Equatable {
        let keyboardType: Int
        let returnKeyType: Int
        let keyboardAppearance: Int
        let resolvedInterfaceStyle: Int
        let autocapitalizationType: Int
        let autocorrectionType: Int
        let spellCheckingType: Int
        let needsGlobe: Bool
    }

    /// Build 81 emoji catalog. Data is Unicode-only and category rows are
    /// materialized only when selected, keeping extension memory predictable.
    enum EmojiCategory: Int, CaseIterable {
        case recents = 0, smileys, people, animals, food, activities, travel, objects, symbols, flags

        var symbolName: String {
            switch self {
            case .recents: return "clock"
            case .smileys: return "face.smiling"
            case .people: return "person.2.fill"
            case .animals: return "pawprint.fill"
            case .food: return "fork.knife"
            case .activities: return "sportscourt.fill"
            case .travel: return "car.fill"
            case .objects: return "lightbulb.fill"
            case .symbols: return "heart.fill"
            case .flags: return "flag.fill"
            }
        }

        var accessibilityName: String {
            switch self {
            case .recents: return "Recents"
            case .smileys: return "Smileys"
            case .people: return "People"
            case .animals: return "Animals"
            case .food: return "Food"
            case .activities: return "Activities"
            case .travel: return "Travel"
            case .objects: return "Objects"
            case .symbols: return "Symbols"
            case .flags: return "Flags"
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
    private var preferredHeightConstraint: NSLayoutConstraint?

    private var coachRewriteTarget: CoachRewriteTarget?
    private var coachRequestID: UUID?
    private var coachTask: URLSessionDataTask?

    /// Monotonic host/editing-session serial. It advances at every lifecycle
    /// boundary where the editing context may have changed (appear, disappear,
    /// host-configuration change) so an authorization captured in one session
    /// is not honored after a switch even when the visible text is identical.
    private var hostSessionSerial = 0

    /// Current host/editing-session identity: a privacy-safe host-configuration
    /// signature (no bundle id, no message text) plus the session serial.
    private var currentHostSession: HostSessionIdentity {
        let signature: String
        if let c = hostConfiguration {
            signature = "\(c.keyboardType).\(c.returnKeyType).\(c.keyboardAppearance).\(c.autocapitalizationType).\(c.autocorrectionType).\(c.spellCheckingType)"
        } else {
            signature = ""
        }
        return HostSessionIdentityFactory.make(
            documentIdentifier: HostDocumentIdentifier.read(from: textDocumentProxy),
            traitSignature: signature,
            session: hostSessionSerial
        )
    }

    private func advanceHostSession() {
        hostSessionSerial &+= 1
    }

    private var keysStack: UIStackView?
    private var coachContainer: UIView?
    private var coachStatusLabel: UILabel?
    private var coachResultsStack: UIStackView?
    private var coachErrorContainer: UIView?
    private var coachErrorLabel: UILabel?
    private var coachBusy: Bool = false

    // Build 93 — explicit Shift state plus monotonic document-mutation tracking.
    private var layoutMode: KeyboardLayoutMode = .letters
    private var shiftMachine = TonoShiftStateMachine()
    private var shiftState: ShiftState { shiftMachine.state }
    private var documentMutationGeneration: UInt64 = 0
    private var pendingDocumentMutation: TonoPendingDocumentMutation?
    private weak var shiftButton: UIButton?
    private weak var returnButton: UIButton?
    private var hostConfiguration: HostConfiguration?
    private var isRebuildingLayout = false
    private var lastLayoutWidth: CGFloat?
    private var deleteRepeatWorkItem: DispatchWorkItem?
    private var deleteRepeatGeneration = 0
    private var deleteRepeatCount = 0
    private weak var previewOwner: UIButton?
    private var keyPreview: UIView?
    private var isEmojiPanelVisible: Bool = false
    private var emojiPanelView: UIView?
    private var emojiActiveCategory: EmojiCategory = .smileys
    private var emojiCollectionView: UICollectionView?
    private weak var emojiCategoryStack: UIStackView?
    private var emojiVisibleGlyphs: [String] = []
    private let spellingService = SpellingCorrectionService()
    private var spellingDecision: SpellingDecision?
    private var spellingToken: SpellingToken?
    private var autocorrectionRecord: AutoCorrectionRecord?
    private weak var candidateStack: UIStackView?
    private weak var coachButton: TonoCoachButton?
    private var candidateValues: [String] = []

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("TONO_KB BUILD86 01: viewDidLoad")

        // Preserve Apple's typing-row scale. Apple-owned input-assistant UI may
        // still be placed below us by the host and must never be hidden.
        let height = view.heightAnchor.constraint(equalToConstant: currentVisualMetrics.preferredContentHeight)
        height.priority = .defaultHigh
        height.isActive = true
        preferredHeightConstraint = height

        view.backgroundColor = .systemBackground
        let ids = Const.allIdentifiers()
        NSLog("TONO_KB BUILD86 ids: \(ids.count)")
        buildTopBar()
        buildBodyContainer()
        updateHostConfiguration(rebuildIfNeeded: false)
        installKeyboardLayout()
        keysInstalled = true
        #if !TONO_BUILD92_HOSTSESSION
        requestSupplementaryLexicon { [weak self] lexicon in
            let words = Set(lexicon.entries.lazy.flatMap { [$0.userInput, $0.documentText] })
            self?.spellingService.updateSupplementaryWords(words)
            self?.refreshSpellingSuggestions()
        }
        #endif
        refreshSpellingSuggestions()
        NSLog("TONO_KB BUILD86 02: UIKit hierarchy installed")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLog("TONO_KB BUILD86 03: viewWillAppear")
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("TONO_KB BUILD86 04: viewDidAppear")
        advanceHostSession()
        refreshHostConfigurationIfNeeded()
        applyAutoCapitalizationIfNeeded()
        refreshSpellingSuggestions()
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        // A proxy notification is also the only lifecycle signal iOS guarantees
        // for a same-trait field/document focus switch. Advance even when the
        // visible text is identical, then invalidate previous authorization.
        advanceHostSession()
        invalidateCoachWork(restoreKeyboard: true)
        spellingService.cancel()
        refreshHostConfigurationIfNeeded()
        let liveContext = textDocumentProxy.documentContextBeforeInput ?? ""
        let pending = pendingDocumentMutation
        let isExpectedLocalNotification = pending?.canExplain(
            notificationContext: liveContext
        ) == true
        if !isExpectedLocalNotification {
            documentMutationGeneration &+= 1
            pendingDocumentMutation = nil
        }
        let generation = documentMutationGeneration
        let effectiveContext: String
        if isExpectedLocalNotification, let pending, pending.generation == generation {
            effectiveContext = pending.contextAfter
        } else {
            effectiveContext = liveContext
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentMutationGeneration == generation else { return }
            self.refreshHostConfigurationIfNeeded()
            self.applyAutoCapitalizationIfNeeded(
                context: effectiveContext,
                callbackGeneration: generation
            )
            self.validateAutocorrectionRecord()
            self.refreshSpellingSuggestions()
            if self.pendingDocumentMutation?.generation == generation {
                self.pendingDocumentMutation = nil
            }
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = bodyContainer?.bounds.width ?? 0
        guard width > 0 else { return }
        let changed = lastLayoutWidth.map { abs($0 - width) > 0.5 } ?? true
        lastLayoutWidth = width
        preferredHeightConstraint?.constant = currentVisualMetrics.preferredContentHeight
        guard changed, keysInstalled, !isRebuildingLayout, coachContainer == nil else { return }
        if isEmojiPanelVisible { showEmojiPanel() } else { installKeyboardLayout() }
    }

    public override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        cancelTransientInteractions()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self = self else { return }
            self.lastLayoutWidth = nil
            self.view.setNeedsLayout()
        }
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
                || previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        cancelTransientInteractions()
        refreshHostConfigurationIfNeeded()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        advanceHostSession()
        invalidateCoachWork(restoreKeyboard: false)
        spellingService.cancel()
        cancelTransientInteractions()
        super.viewWillDisappear(animated)
    }

    public override func viewDidDisappear(_ animated: Bool) {
        invalidateCoachWork(restoreKeyboard: false)
        spellingService.cancel()
        cancelTransientInteractions()
        super.viewDidDisappear(animated)
    }

    deinit {
        coachTask?.cancel()
        spellingService.cancel()
        cancelDeleteRepeat()
        dismissKeyPreview()
    }

    public var enableInputClicksWhenVisible: Bool { true }

    private func playInputClick() {
        UIDevice.current.playInputClick()
    }

    private func cancelTransientInteractions() {
        cancelDeleteRepeat()
        dismissKeyPreview()
    }

    private func invalidateCoachWork(restoreKeyboard: Bool, clearTarget: Bool = true) {
        coachTask?.cancel()
        coachTask = nil
        coachRequestID = nil
        if clearTarget { coachRewriteTarget = nil }
        coachBusy = false
        coachButton?.isEnabled = true
        guard restoreKeyboard, coachContainer != nil, keysInstalled, !isRebuildingLayout else { return }
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil
        installKeyboardLayout()
    }

    // MARK: - Minimal Coach bar

    private func buildTopBar() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.accessibilityIdentifier = Const.idTopBar
        view.addSubview(bar)

        let coach = TonoCoachButton(type: .custom)
        coach.setTitle("Coach", for: .normal)
        coach.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        coach.layer.cornerRadius = Const.keyCornerRadius
        coach.layer.masksToBounds = true
        coach.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        coach.translatesAutoresizingMaskIntoConstraints = false
        coach.accessibilityIdentifier = Const.idCoachButton
        coach.accessibilityLabel = "Tono Coach"
        coach.addTarget(self, action: #selector(coachTapped), for: .touchUpInside)
        bar.addSubview(coach)

        let candidates = UIStackView()
        candidates.axis = .horizontal
        candidates.alignment = .fill
        candidates.distribution = .fillEqually
        candidates.spacing = 1
        candidates.translatesAutoresizingMaskIntoConstraints = false
        candidates.accessibilityIdentifier = Const.idCandidates
        bar.addSubview(candidates)
        for index in 0..<3 {
            let button = TonoMinimumHitTargetButton(type: .system)
            button.tag = index
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: 13, weight: .regular)
            )
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(.label, for: .normal)
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 5
            button.isHidden = true
            button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
            candidates.addArrangedSubview(button)
        }
        bar.accessibilityElements = candidates.arrangedSubviews + [coach]
        let approvedCoachWidth = ceil(coach.intrinsicContentSize.width)
        coach.setContentHuggingPriority(.required, for: .horizontal)
        coach.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Const.baselineMetrics.topBarHeight),

            coach.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            coach.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            coach.heightAnchor.constraint(equalToConstant: Const.baselineMetrics.coachControlHeight),
            coach.widthAnchor.constraint(equalToConstant: approvedCoachWidth),

            candidates.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 3),
            candidates.trailingAnchor.constraint(equalTo: coach.leadingAnchor, constant: -5),
            candidates.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            candidates.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
        ])

        self.topBar = bar
        self.candidateStack = candidates
        self.coachButton = coach
    }

    private func buildBodyContainer() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityIdentifier = Const.idBody
        view.addSubview(container)

        guard let topBar = self.topBar else {
            NSLog("TONO_KB BUILD86 ERR: topBar missing in buildBodyContainer")
            return
        }

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Const.edgePadding),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Const.edgePadding),
            container.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 2),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Const.edgePadding),
        ])

        self.bodyContainer = container
    }

    // MARK: - Host-field traits

    private var hostKeyboardType: UIKeyboardType {
        textDocumentProxy.keyboardType ?? .default
    }

    private var hostReturnKeyType: UIReturnKeyType {
        textDocumentProxy.returnKeyType ?? .default
    }

    private var hostKeyboardAppearance: UIKeyboardAppearance {
        textDocumentProxy.keyboardAppearance ?? .default
    }

    private var hostAutocapitalizationType: UITextAutocapitalizationType {
        textDocumentProxy.autocapitalizationType ?? .sentences
    }

    private var hostAutocorrectionType: UITextAutocorrectionType {
        textDocumentProxy.autocorrectionType ?? .default
    }

    private var hostSpellCheckingType: UITextSpellCheckingType {
        textDocumentProxy.spellCheckingType ?? .default
    }

    private var currentHostConfiguration: HostConfiguration {
        HostConfiguration(
            keyboardType: hostKeyboardType.rawValue,
            returnKeyType: hostReturnKeyType.rawValue,
            keyboardAppearance: hostKeyboardAppearance.rawValue,
            resolvedInterfaceStyle: resolvedKeyboardInterfaceStyle.rawValue,
            autocapitalizationType: hostAutocapitalizationType.rawValue,
            autocorrectionType: hostAutocorrectionType.rawValue,
            spellCheckingType: hostSpellCheckingType.rawValue,
            needsGlobe: needsInputModeSwitchKey
        )
    }

    private func refreshHostConfigurationIfNeeded() {
        updateHostConfiguration(rebuildIfNeeded: true)
    }

    private func updateHostConfiguration(rebuildIfNeeded: Bool) {
        let previous = hostConfiguration
        let next = currentHostConfiguration
        guard previous != next else { return }
        hostConfiguration = next
        advanceHostSession()
        if previous != nil {
            invalidateCoachWork(restoreKeyboard: true)
            spellingService.cancel()
        }
        applyKeyboardAppearance(hostKeyboardAppearance)

        if previous?.keyboardType != next.keyboardType {
            layoutMode = initialMode(for: hostKeyboardType)
        }
        guard rebuildIfNeeded, keysInstalled, !isRebuildingLayout,
              coachContainer == nil else { return }
        if isEmojiPanelVisible {
            showEmojiPanel()
        } else {
            installKeyboardLayout()
        }
    }

    private func initialMode(for keyboardType: UIKeyboardType) -> KeyboardLayoutMode {
        switch keyboardType {
        case .numbersAndPunctuation, .numberPad, .decimalPad, .asciiCapableNumberPad:
            return .numbers
        case .default, .asciiCapable, .URL, .emailAddress, .twitter, .webSearch,
             .phonePad, .namePhonePad:
            return .letters
        @unknown default:
            return .letters
        }
    }

    private var resolvedKeyboardInterfaceStyle: UIUserInterfaceStyle {
        TonoKeyboardAppearanceResolver.resolve(
            hostAppearance: hostKeyboardAppearance,
            extensionStyle: traitCollection.userInterfaceStyle,
            systemStyle: UIScreen.main.traitCollection.userInterfaceStyle
        )
    }

    private func applyKeyboardAppearance(_ appearance: UIKeyboardAppearance) {
        overrideUserInterfaceStyle = TonoKeyboardAppearanceResolver.resolve(
            hostAppearance: appearance,
            extensionStyle: traitCollection.userInterfaceStyle,
            systemStyle: UIScreen.main.traitCollection.userInterfaceStyle
        )
    }

    private var quickCharactersForKeyboardType: [String] {
        switch hostKeyboardType {
        case .URL: return ["/", "."]
        case .emailAddress: return ["@", "."]
        case .twitter: return ["@", "#"]
        case .webSearch: return ["."]
        case .default, .asciiCapable, .numbersAndPunctuation, .numberPad,
             .phonePad, .namePhonePad, .decimalPad, .asciiCapableNumberPad:
            return []
        @unknown default:
            return []
        }
    }

    // MARK: - Keyboard layout (UIKit QWERTY + iOS-style bottom row)

    private func installKeyboardLayout() {
        guard let container = bodyContainer else { return }
        guard !isRebuildingLayout else { return }
        isRebuildingLayout = true
        defer { isRebuildingLayout = false }
        cancelTransientInteractions()
        preferredHeightConstraint?.constant = currentVisualMetrics.preferredContentHeight

        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false

        keysStack?.removeFromSuperview()
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil
        shiftButton = nil
        returnButton = nil

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
        let width = currentKeyboardWidth
        let r2 = makeIndentedRow(
            chars: row2Chars(),
            idPrefix: "row2",
            indent: layoutMode == .letters ? Const.row2HorizontalInset(availableWidth: width) : 0
        )
        let r3 = makeRow3()
        let bottom = makeBottomRow()

        stack.addArrangedSubview(r1)
        stack.addArrangedSubview(r2)
        stack.addArrangedSubview(r3)
        stack.addArrangedSubview(bottom)

        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight * 4 + Const.rowSpacing * 3).isActive = true

        self.keysStack = stack
        NSLog("TONO_KB BUILD86 05: keyboard layout installed mode=\(modeName(layoutMode))")
    }

    private var currentKeyboardWidth: CGFloat {
        let measured = bodyContainer?.bounds.width ?? 0
        return measured > 0 ? measured : Const.referencePortraitWidth
    }

    private var currentVisualMetrics: TonoKeyboardMetrics {
        TonoKeyboardMetrics.portrait(availableWidth: currentKeyboardWidth)
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
        shiftState == .lowercase ? "shift" : "shift.fill"
    }

    /// Build 85 retains the build-84 mode-state matrix.
    /// the row-3 modifier is the sole numbers ↔ symbols transition.
    private var bottomModeSpec: (label: String, target: KeyboardLayoutMode) {
        switch layoutMode {
        case .letters: return ("123", .numbers)
        case .numbers: return ("ABC", .letters)
        case .symbols: return ("ABC", .letters)
        }
    }

    private var thirdRowModeSpec: (label: String, target: KeyboardLayoutMode)? {
        switch layoutMode {
        case .letters: return nil
        case .numbers: return ("#+=", .symbols)
        case .symbols: return ("123", .numbers)
        }
    }

    private func displayLetter(_ ch: String) -> String {
        switch layoutMode {
        case .letters:
            return shiftMachine.display(ch)
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

        switch layoutMode {
        case .letters:
            row.addArrangedSubview(makeShiftButton())
        case .numbers, .symbols:
            if let spec = thirdRowModeSpec {
                row.addArrangedSubview(makeModeToggleButton(
                    label: spec.label,
                    action: #selector(thirdRowModeTapped),
                    identifierSuffix: "thirdRow"
                ))
            }
        }

        if layoutMode == .letters {
            let innerGap = UIView()
            innerGap.translatesAutoresizingMaskIntoConstraints = false
            innerGap.widthAnchor.constraint(
                equalToConstant: Const.row3InnerGap(availableWidth: currentKeyboardWidth)
            ).isActive = true
            row.addArrangedSubview(innerGap)
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

        if layoutMode == .letters {
            let trailingInnerGap = UIView()
            trailingInnerGap.translatesAutoresizingMaskIntoConstraints = false
            trailingInnerGap.widthAnchor.constraint(
                equalToConstant: Const.row3InnerGap(availableWidth: currentKeyboardWidth)
            ).isActive = true
            row.addArrangedSubview(trailingInnerGap)
        }

        let backspace = makeSymbolControlButton(
            systemName: "delete.left",
            action: nil,
            width: Const.backspaceWidth,
            bg: keyboardKeyBackground(.tertiary),
            id: "backspace"
        )
        backspace.addTarget(self, action: #selector(backspaceTouchDown), for: .touchDown)
        backspace.addTarget(
            self,
            action: #selector(backspaceTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
        row.addArrangedSubview(backspace)

        return row
    }

    private func makeCharButton(_ char: String) -> UIButton {
        let b = KeyboardButton(frame: .zero)
        b.setTitle(displayLetter(char), for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: Const.baselineMetrics.keyFontSize, weight: .regular)
        b.setTitleColor(.label, for: .normal)
        b.normalBackgroundColor = keyboardKeyBackground(.secondary)
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = char.uppercased()
        b.accessibilityIdentifier = Const.letterId(char)
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        b.addTarget(self, action: #selector(characterTouchDown(_:)), for: .touchDown)
        b.addTarget(self, action: #selector(charTapped(_:)), for: .touchUpInside)
        b.addTarget(
            self,
            action: #selector(characterTouchEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
        return b
    }

    private func makeShiftButton() -> UIButton {
        let b = KeyboardButton(frame: .zero)
        b.setImage(UIImage(systemName: shiftSymbolName), for: .normal)
        b.tintColor = shiftState == .capsLock ? .systemBlue : .label
        b.normalBackgroundColor = shiftState == .capsLock
            ? UIColor.systemBlue.withAlphaComponent(0.22)
            : keyboardKeyBackground(.tertiary)
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = shiftAccessibilityLabel()
        b.accessibilityIdentifier = Const.idShift
        b.widthAnchor.constraint(equalToConstant: Const.backspaceWidth).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(shiftSingleTapped))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(shiftDoubleTapped))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        b.addGestureRecognizer(singleTap)
        b.addGestureRecognizer(doubleTap)
        b.accessibilityActivationHandler = { [weak self] in
            self?.shiftSingleTapped()
            return self != nil
        }
        shiftButton = b
        applyShiftToKey(b)
        return b
    }

    private func shiftAccessibilityLabel() -> String {
        switch shiftState {
        case .lowercase:        return "Shift, Off"
        case .oneShotUppercase: return "Shift, On"
        case .capsLock:  return "Caps lock on, tap to release"
        }
    }

    private func makeModeToggleButton(label: String, action: Selector, identifierSuffix: String) -> UIButton {
        let b = KeyboardButton(frame: .zero)
        b.setTitle(label, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.setTitleColor(.label, for: .normal)
        b.normalBackgroundColor = keyboardKeyBackground(.tertiary)
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = "Switch keyboard mode to \(label)"
        b.accessibilityIdentifier = "\(Const.idModeToggle).\(identifierSuffix)"
        b.widthAnchor.constraint(equalToConstant: Const.modeToggleWidth).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
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

        let bottomSpec = bottomModeSpec
        let modeToggle = makeModeToggleButton(
            label: bottomSpec.label,
            action: #selector(bottomModeTapped),
            identifierSuffix: "bottom"
        )
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
        let returnKey = makeReturnButton()
        row.addArrangedSubview(modeToggle)
        // UIInputViewController owns this decision. Never render an
        // unconditional globe beside Apple-owned input controls.
        if needsInputModeSwitchKey {
            row.addArrangedSubview(makeGlobeButton(systemName: "globe"))
        }
        row.addArrangedSubview(emoji)
        for character in quickCharactersForKeyboardType {
            row.addArrangedSubview(makeQuickCharacterButton(character))
        }
        row.addArrangedSubview(space)
        row.addArrangedSubview(returnKey)
        return row
    }

    private func makeGlobeButton(systemName: String) -> UIButton {
        let button = makeSymbolControlButton(
            systemName: systemName,
            action: nil,
            width: Const.modeToggleWidth,
            bg: keyboardKeyBackground(.tertiary),
            id: "globe"
        )
        button.addTarget(self, action: #selector(globeEvent(_:with:)), for: .allTouchEvents)
        return button
    }

    private func makeQuickCharacterButton(_ character: String) -> UIButton {
        let button = makeControlButton(
            title: character,
            action: #selector(quickCharacterTapped(_:)),
            width: TonoKeyboardMetrics.ControlGeometry.quickCharacterWidth,
            bg: keyboardKeyBackground(.secondary),
            id: "quick.\(character)"
        )
        button.accessibilityLabel = character
        return button
    }

    private func makeSymbolControlButton(
        systemName: String,
        action: Selector?,
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
        action: Selector?,
        width: CGFloat?,
        bg: UIColor,
        id: String
    ) -> UIButton {
        let b = KeyboardButton(frame: .zero)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.setTitleColor(.label, for: .normal)
        b.normalBackgroundColor = bg
        b.layer.cornerRadius = Const.keyCornerRadius
        b.layer.borderWidth = Const.keyBorderWidth
        b.layer.borderColor = keyboardKeyBorder().cgColor
        b.accessibilityLabel = controlAccessibilityLabel(for: id, title: title)
        switch id {
        case "globe":     b.accessibilityIdentifier = Const.idGlobe
        case "emoji":     b.accessibilityIdentifier = Const.idEmojiToggle
        case "space":     b.accessibilityIdentifier = Const.idSpace
        case "return":    b.accessibilityIdentifier = Const.idReturn
        case "backspace": b.accessibilityIdentifier = Const.idBackspace
        default:          b.accessibilityIdentifier = "TonoKB.\(id)"
        }
        if let action = action {
            b.addTarget(self, action: action, for: .touchUpInside)
        }
        b.translatesAutoresizingMaskIntoConstraints = false
        if let width = width {
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        return b
    }

    private func controlAccessibilityLabel(for id: String, title: String) -> String {
        switch id {
        case "globe": return "Next keyboard"
        case "emoji": return "Emoji"
        case "space": return "Space"
        case "return": return returnKeySpec.accessibilityLabel
        case "backspace": return "Delete"
        default: return title.isEmpty ? id : title
        }
    }

    private var returnKeySpec: (title: String, accessibilityLabel: String) {
        switch hostReturnKeyType {
        case .default: return ("return", "Return")
        case .go: return ("go", "Go")
        case .google: return ("Google", "Google")
        case .join: return ("join", "Join")
        case .next: return ("next", "Next")
        case .route: return ("route", "Route")
        case .search: return ("search", "Search")
        case .send: return ("send", "Send")
        case .yahoo: return ("Yahoo", "Yahoo")
        case .done: return ("done", "Done")
        case .emergencyCall: return ("emergency call", "Emergency call")
        case .continue: return ("continue", "Continue")
        @unknown default: return ("return", "Return")
        }
    }

    private var returnKeyIsEmphasized: Bool {
        switch hostReturnKeyType {
        case .go, .search, .send, .done, .continue, .emergencyCall:
            return true
        case .default, .google, .join, .next, .route, .yahoo:
            return false
        @unknown default:
            return false
        }
    }

    private func makeReturnButton() -> UIButton {
        let spec = returnKeySpec
        let button = makeControlButton(
            title: spec.title,
            action: #selector(returnTapped),
            width: Const.returnWidth,
            bg: returnKeyIsEmphasized ? .systemBlue : keyboardKeyBackground(.tertiary),
            id: "return"
        )
        button.accessibilityLabel = spec.accessibilityLabel
        if returnKeyIsEmphasized { button.setTitleColor(.white, for: .normal) }
        if hostReturnKeyType == .emergencyCall {
            button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center
        }
        returnButton = button
        return button
    }

    // MARK: - Key actions

    @objc private func charTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        let beforeMutation = effectiveDocumentContextBeforeInput
        let afterMutation: String
        if isSpellingBoundary(title) {
            afterMutation = commitBoundary(title, contextBeforeInput: beforeMutation)
        } else {
            autocorrectionRecord = nil
            textDocumentProxy.insertText(title)
            afterMutation = beforeMutation + title
        }
        playInputClick()
        recordDocumentMutation(
            from: beforeMutation,
            to: afterMutation,
            consumingEligibleCapital: layoutMode == .letters ? title : nil
        )
    }

    @objc private func characterTouchDown(_ sender: UIButton) {
        showKeyPreview(for: sender)
    }

    @objc private func characterTouchEnded(_ sender: UIButton) {
        if previewOwner === sender { dismissKeyPreview() }
    }

    @objc private func shiftSingleTapped() {
        shiftMachine.tapShift()
        relayoutLettersForShift()
        playInputClick()
    }

    @objc private func shiftDoubleTapped() {
        shiftMachine.doubleTapShift()
        relayoutLettersForShift()
        playInputClick()
    }

    @objc private func bottomModeTapped() {
        cancelTransientInteractions()
        layoutMode = bottomModeSpec.target
        NSLog("TONO_KB BUILD86 bottom-mode: -> \(modeName(layoutMode))")
        installKeyboardLayout()
    }

    @objc private func thirdRowModeTapped() {
        cancelTransientInteractions()
        guard let target = thirdRowModeSpec?.target else { return }
        layoutMode = target
        NSLog("TONO_KB BUILD86 third-row-mode: -> \(modeName(layoutMode))")
        installKeyboardLayout()
    }

    @objc private func globeEvent(_ sender: UIButton, with event: UIEvent) {
        cancelTransientInteractions()
        handleInputModeList(from: sender, with: event)
    }

    private var effectiveDocumentContextBeforeInput: String {
        if let pending = pendingDocumentMutation,
           pending.generation == documentMutationGeneration {
            return pending.contextAfter
        }
        return textDocumentProxy.documentContextBeforeInput ?? ""
    }

    private func recordDocumentMutation(
        from contextBefore: String,
        to contextAfter: String,
        consumingEligibleCapital text: String? = nil
    ) {
        documentMutationGeneration &+= 1
        let generation = documentMutationGeneration
        pendingDocumentMutation = TonoPendingDocumentMutation(
            generation: generation,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )

        if let text { shiftMachine.consumeEligibleCapital(text) }
        applyAutoCapitalizationIfNeeded(
            context: contextAfter,
            callbackGeneration: generation
        )
        relayoutLettersForShift()

        // UIKit may publish textDidChange before UITextDocumentProxy catches up.
        // A pending mutation is accepted only while the live proxy is either its
        // known before- or after-context. Any third context is an external host
        // mutation and advances the generation, invalidating stale callbacks.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.documentMutationGeneration == generation else { return }
            self.refreshSpellingSuggestions()
            if self.pendingDocumentMutation?.generation == generation {
                self.pendingDocumentMutation = nil
            }
        }
    }

    private func applyAutoCapitalizationIfNeeded(
        context: String? = nil,
        callbackGeneration: UInt64? = nil
    ) {
        guard layoutMode == .letters else { return }
        let generation = callbackGeneration ?? documentMutationGeneration
        let before = context ?? effectiveDocumentContextBeforeInput
        let shouldCapitalize = automaticCapitalizationRecommended(
            policy: hostAutocapitalizationType,
            context: before
        )
        if shiftMachine.applyAutomaticCapitalization(
            recommended: shouldCapitalize,
            callbackGeneration: generation,
            documentGeneration: documentMutationGeneration
        ) {
            relayoutLettersForShift()
        }
    }

    private func automaticCapitalizationRecommended(
        policy: UITextAutocapitalizationType,
        context: String
    ) -> Bool {
        switch policy {
        case .none:
            return false
        case .allCharacters:
            return true
        case .words:
            return context.isEmpty || context.last?.isWhitespace == true
        case .sentences:
            if context.isEmpty || context.hasSuffix("\n") { return true }
            let trimmed = context.replacingOccurrences(
                of: #"\s+$"#,
                with: "",
                options: .regularExpression
            )
            guard trimmed.count < context.count else { return false }
            if trimmed.isEmpty { return true }
            guard let last = trimmed.last else { return false }
            return ".!?".contains(last)
        @unknown default:
            return false
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
            b.accessibilityValue = shiftState == .capsLock ? "Caps Lock" : (shiftState == .lowercase ? "Off" : "On")
            b.accessibilityTraits = shiftState == .lowercase ? [.button] : [.button, .selected]
            (b as? KeyboardButton)?.normalBackgroundColor = shiftState == .capsLock
                ? UIColor.systemBlue.withAlphaComponent(0.22)
                : keyboardKeyBackground(.tertiary)
        } else if let id = b.accessibilityIdentifier,
                  id.hasPrefix("TonoKB.letter."),
                  let raw = id.split(separator: ".").last {
            b.setTitle(displayLetter(String(raw)), for: .normal)
        }
    }

    private func updateShiftButtonAppearance() {
        guard let button = shiftButton else { return }
        applyShiftToKey(button)
    }

    // MARK: - On-device spelling

    private var spellingHostPolicy: SpellingHostPolicy {
        let fieldKind: SpellingFieldKind
        switch hostKeyboardType {
        case .emailAddress:
            fieldKind = .email
        case .URL:
            fieldKind = .url
        case .numberPad, .decimalPad, .asciiCapableNumberPad, .phonePad:
            fieldKind = .numeric
        case .default, .asciiCapable, .numbersAndPunctuation, .namePhonePad,
             .twitter, .webSearch:
            fieldKind = .ordinary
        @unknown default:
            fieldKind = .secureLike
        }
        let language = primaryLanguage
            ?? textInputMode?.primaryLanguage
            ?? Locale.current.identifier
        return SpellingHostPolicy(
            language: language,
            fieldKind: fieldKind,
            allowsAutocorrection: hostAutocorrectionType != .no,
            allowsSpellChecking: hostSpellCheckingType != .no
        )
    }

    private func refreshSpellingSuggestions() {
        guard coachContainer == nil, !isEmojiPanelVisible else {
            spellingService.cancel()
            return
        }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        guard let token = SpellingToken.current(before: before, after: after, host: currentHostSession) else {
            spellingService.cancel()
            spellingDecision = nil
            spellingToken = nil
            if autocorrectionRecord == nil { updateCandidateStrip(values: []) }
            return
        }
        let request = SpellingRequest(token: token, host: spellingHostPolicy)
        guard request.host.allowsSuggestions else {
            spellingService.cancel()
            spellingDecision = nil
            spellingToken = nil
            updateCandidateStrip(values: [])
            return
        }
        spellingDecision = nil
        spellingToken = token
        updateCandidateStrip(values: [token.text])
        spellingService.schedule(request) { [weak self] _, decision in
            guard let self = self else { return }
            let live = SpellingToken.current(
                before: self.textDocumentProxy.documentContextBeforeInput ?? "",
                after: self.textDocumentProxy.documentContextAfterInput ?? "",
                host: self.currentHostSession
            )
            guard live == token else { return }
            self.spellingDecision = decision
            self.spellingToken = token
            self.updateCandidateStrip(values: decision?.candidates ?? [token.text])
        }
    }

    private func updateCandidateStrip(values: [String]) {
        guard let stack = candidateStack else { return }
        candidateValues = Array(values.prefix(3))
        for (index, view) in stack.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            guard index < candidateValues.count else {
                button.setTitle(nil, for: .normal)
                button.isHidden = true
                button.accessibilityLabel = nil
                button.accessibilityHint = nil
                continue
            }
            let value = candidateValues[index]
            let isOriginal = index == 0
            button.isHidden = false
            button.setTitle(value, for: .normal)
            button.accessibilityLabel = isOriginal ? "\(value), original" : value
            button.accessibilityHint = isOriginal
                ? "Keeps or restores the original word"
                : "Replaces the current word"
            button.accessibilityTraits = isOriginal ? [.button, .selected] : [.button]
        }
    }

    @objc private func candidateTapped(_ sender: UIButton) {
        guard candidateValues.indices.contains(sender.tag) else { return }
        let value = candidateValues[sender.tag]
        if let record = autocorrectionRecord, value == record.original {
            let beforeMutation = effectiveDocumentContextBeforeInput
            guard let afterMutation = restoreAutocorrection(
                record,
                keepBoundary: true,
                contextBeforeInput: beforeMutation
            ) else { return }
            playInputClick()
            recordDocumentMutation(from: beforeMutation, to: afterMutation)
            return
        }
        guard let expected = spellingToken,
              let plan = SpellingMutationPlan.candidate(
                liveToken: SpellingToken.current(
                    before: textDocumentProxy.documentContextBeforeInput ?? "",
                    after: textDocumentProxy.documentContextAfterInput ?? "",
                    host: currentHostSession
                ),
                expected: expected,
                replacement: value
              ) else { return }
        applySpellingMutation(plan)
        autocorrectionRecord = nil
        spellingDecision = nil
        spellingToken = nil
        playInputClick()
        refreshSpellingSuggestions()
    }

    private func commitBoundary(
        _ boundary: String,
        contextBeforeInput: String
    ) -> String {
        let live = SpellingToken.current(
            in: contextBeforeInput,
            host: currentHostSession
        )
        let plan = SpellingMutationPlan.boundary(
            liveToken: live,
            expected: spellingToken,
            decision: spellingDecision,
            boundary: boundary
        )
        let appliedPlan: SpellingMutationPlan
        if plan.deleteCount > 0,
           let live = live,
           let replacement = spellingDecision?.automaticReplacement,
           spellingHostPolicy.allowsSuggestions {
            applySpellingMutation(plan)
            appliedPlan = plan
            autocorrectionRecord = AutoCorrectionRecord(
                original: live.text,
                replacement: replacement,
                boundary: boundary
            )
            spellingService.cancel()
            spellingDecision = nil
            spellingToken = nil
            updateCandidateStrip(values: [live.text])
        } else {
            let boundaryPlan = SpellingMutationPlan(deleteCount: 0, insertion: boundary)
            autocorrectionRecord = nil
            applySpellingMutation(boundaryPlan)
            appliedPlan = boundaryPlan
        }
        return contextAfterApplying(appliedPlan, to: contextBeforeInput)
    }

    private func contextAfterApplying(
        _ plan: SpellingMutationPlan,
        to contextBeforeInput: String
    ) -> String {
        TonoDocumentContextMutation.applying(
            deleteCount: plan.deleteCount,
            insertion: plan.insertion,
            to: contextBeforeInput
        )
    }

    private func applySpellingMutation(_ plan: SpellingMutationPlan) {
        if plan.cursorAdvance > 0 {
            textDocumentProxy.adjustTextPosition(byCharacterOffset: plan.cursorAdvance)
        }
        for _ in 0..<plan.deleteCount { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(plan.insertion)
    }

    private func isSpellingBoundary(_ text: String) -> Bool {
        text == "\n" || text == " " || [".", ",", "?", "!", ";", ":"].contains(text)
    }

    private func validateAutocorrectionRecord() {
        guard let record = autocorrectionRecord else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        if !context.hasSuffix(record.correctedSuffix) {
            autocorrectionRecord = nil
        }
    }

    private func restoreOriginalAfterBackspaceIfPossible(
        contextBeforeInput: String
    ) -> String? {
        guard let record = autocorrectionRecord else { return nil }
        return restoreAutocorrection(
            record,
            keepBoundary: false,
            contextBeforeInput: contextBeforeInput
        )
    }

    private func restoreAutocorrection(
        _ record: AutoCorrectionRecord,
        keepBoundary: Bool,
        contextBeforeInput: String
    ) -> String? {
        guard contextBeforeInput.hasSuffix(record.correctedSuffix) else {
            autocorrectionRecord = nil
            return nil
        }
        for _ in record.correctedSuffix { textDocumentProxy.deleteBackward() }
        let restored = keepBoundary ? record.restoredText : record.original
        textDocumentProxy.insertText(restored)
        autocorrectionRecord = nil
        spellingDecision = nil
        spellingToken = nil
        updateCandidateStrip(values: keepBoundary ? [] : [record.original])
        return TonoDocumentContextMutation.restoring(
            correctedSuffix: record.correctedSuffix,
            restoredText: restored,
            in: contextBeforeInput
        )
    }

    @objc private func spaceTapped() {
        let beforeMutation = effectiveDocumentContextBeforeInput
        let contextSuffix = String(beforeMutation.suffix(8))
        let transformedDoubleSpace = DoubleSpacePolicy.shouldTransform(
            contextSuffix: contextSuffix,
            host: spellingHostPolicy,
            hasPendingAutocorrectionUndo: autocorrectionRecord != nil
        )
        let afterMutation: String
        if transformedDoubleSpace {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            spellingService.cancel()
            spellingDecision = nil
            spellingToken = nil
            updateCandidateStrip(values: [])
            afterMutation = String(beforeMutation.dropLast()) + ". "
        } else {
            afterMutation = commitBoundary(" ", contextBeforeInput: beforeMutation)
        }
        playInputClick()
        recordDocumentMutation(from: beforeMutation, to: afterMutation)
    }

    @objc private func quickCharacterTapped(_ sender: UIButton) {
        guard let character = sender.title(for: .normal), !character.isEmpty else { return }
        let beforeMutation = effectiveDocumentContextBeforeInput
        let afterMutation: String
        if isSpellingBoundary(character) {
            afterMutation = commitBoundary(character, contextBeforeInput: beforeMutation)
        } else {
            autocorrectionRecord = nil
            textDocumentProxy.insertText(character)
            afterMutation = beforeMutation + character
        }
        playInputClick()
        recordDocumentMutation(from: beforeMutation, to: afterMutation)
    }

    @objc private func backspaceTouchDown() {
        cancelDeleteRepeat()
        let beforeMutation = effectiveDocumentContextBeforeInput
        let afterMutation: String
        if let restored = restoreOriginalAfterBackspaceIfPossible(
            contextBeforeInput: beforeMutation
        ) {
            afterMutation = restored
        } else {
            autocorrectionRecord = nil
            textDocumentProxy.deleteBackward()
            afterMutation = String(beforeMutation.dropLast())
        }
        playInputClick()
        recordDocumentMutation(from: beforeMutation, to: afterMutation)
        deleteRepeatCount = 0
        let generation = deleteRepeatGeneration
        scheduleDeleteRepeat(after: Const.deleteRepeatInitialDelay, generation: generation)
    }

    @objc private func backspaceTouchEnded() {
        cancelDeleteRepeat()
        applyAutoCapitalizationIfNeeded(
            context: effectiveDocumentContextBeforeInput,
            callbackGeneration: documentMutationGeneration
        )
        refreshSpellingSuggestions()
    }

    private func scheduleDeleteRepeat(after delay: TimeInterval, generation: Int) {
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, generation == self.deleteRepeatGeneration else { return }
            let beforeMutation = self.effectiveDocumentContextBeforeInput
            self.textDocumentProxy.deleteBackward()
            self.recordDocumentMutation(
                from: beforeMutation,
                to: String(beforeMutation.dropLast())
            )
            self.playInputClick()
            self.deleteRepeatCount += 1
            let accelerated = Const.deleteRepeatInterval - Double(self.deleteRepeatCount) * 0.004
            let next = max(Const.deleteRepeatMinimumInterval, accelerated)
            self.scheduleDeleteRepeat(after: next, generation: generation)
        }
        deleteRepeatWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelDeleteRepeat() {
        deleteRepeatGeneration &+= 1
        deleteRepeatWorkItem?.cancel()
        deleteRepeatWorkItem = nil
        deleteRepeatCount = 0
    }

    @objc private func returnTapped() {
        let beforeMutation = effectiveDocumentContextBeforeInput
        let afterMutation = commitBoundary("\n", contextBeforeInput: beforeMutation)
        playInputClick()
        recordDocumentMutation(from: beforeMutation, to: afterMutation)
    }

    private func showKeyPreview(for button: UIButton) {
        dismissKeyPreview()
        guard let title = button.title(for: .normal), !title.isEmpty else { return }
        let bubble = UIView(frame: CGRect(x: 0, y: 0, width: 48, height: 62))
        bubble.backgroundColor = UIColor.secondarySystemBackground
        bubble.layer.cornerRadius = 8
        bubble.layer.borderWidth = Const.keyBorderWidth
        bubble.layer.borderColor = keyboardKeyBorder().cgColor
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.18
        bubble.layer.shadowRadius = 2
        bubble.layer.shadowOffset = CGSize(width: 0, height: 1)
        bubble.isUserInteractionEnabled = false

        let label = UILabel(frame: bubble.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.text = title
        label.textAlignment = .center
        label.textColor = .label
        label.font = .systemFont(ofSize: 28, weight: .regular)
        bubble.addSubview(label)

        let keyFrame = button.convert(button.bounds, to: view)
        let proposedX = keyFrame.midX - bubble.bounds.width / 2
        bubble.frame.origin.x = min(max(2, proposedX), max(2, view.bounds.width - bubble.bounds.width - 2))
        bubble.frame.origin.y = max(0, keyFrame.minY - bubble.bounds.height + 7)
        view.addSubview(bubble)
        previewOwner = button
        keyPreview = bubble
    }

    private func dismissKeyPreview() {
        keyPreview?.removeFromSuperview()
        keyPreview = nil
        previewOwner = nil
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
    /// 8 reusable emoji cells per row, with category tabs at the top and a
    /// footer row carrying an `ABC` return control + `space` + `⌫`.
    private func showEmojiPanel() {
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        spellingService.cancel()
        spellingDecision = nil
        spellingToken = nil
        autocorrectionRecord = nil
        updateCandidateStrip(values: [])
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        emojiCollectionView = nil
        emojiCategoryStack = nil
        preferredHeightConstraint?.constant = currentVisualMetrics.preferredContentHeight

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

        // Top: horizontally scrollable category tabs. Ten 44pt tabs cannot fit
        // side-by-side on compact phones, so scrolling preserves honest hit
        // targets rather than compressing them below the minimum.
        let tabsScroll = UIScrollView()
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.showsHorizontalScrollIndicator = false
        tabsScroll.alwaysBounceHorizontal = true
        panel.addSubview(tabsScroll)

        let tabsRow = UIStackView()
        tabsRow.axis = .horizontal
        tabsRow.alignment = .fill
        tabsRow.distribution = .fill
        tabsRow.spacing = 0
        tabsRow.translatesAutoresizingMaskIntoConstraints = false
        tabsRow.accessibilityIdentifier = Const.idEmojiCategory
        tabsScroll.addSubview(tabsRow)
        for category in EmojiCategory.allCases {
            let tab = makeEmojiCategoryTab(category)
            tab.widthAnchor.constraint(greaterThanOrEqualToConstant: TonoKeyboardMetrics.ControlGeometry.emojiCategoryTabWidth).isActive = true
            tabsRow.addArrangedSubview(tab)
        }
        emojiCategoryStack = tabsRow

        // Body: dense, memory-safe reusable grid. Only visible cells exist.
        let flow = UICollectionViewFlowLayout()
        flow.minimumInteritemSpacing = 2
        flow.minimumLineSpacing = 1
        flow.sectionInset = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        let collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.alwaysBounceVertical = true
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(EmojiCollectionCell.self, forCellWithReuseIdentifier: Const.emojiCellReuseIdentifier)
        panel.addSubview(collection)
        emojiVisibleGlyphs = emojiActiveCategory.glyphs
        emojiCollectionView = collection

        // Footer preserves Apple semantics: ABC | emoji | space | return.
        let footer = UIStackView()
        footer.axis = .horizontal
        footer.alignment = .fill
        footer.distribution = .fill
        footer.spacing = Const.rowSpacing
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.accessibilityIdentifier = Const.idEmojiFooter
        panel.addSubview(footer)

        let abc = KeyboardButton(frame: .zero)
        abc.setTitle("ABC", for: .normal)
        abc.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        abc.setTitleColor(.label, for: .normal)
        abc.normalBackgroundColor = keyboardKeyBackground(.tertiary)
        abc.layer.cornerRadius = Const.keyCornerRadius
        abc.layer.borderWidth = Const.keyBorderWidth
        abc.layer.borderColor = keyboardKeyBorder().cgColor
        abc.accessibilityIdentifier = "\(Const.idModeToggle).emojiFooter"
        abc.accessibilityLabel = "Letters"
        abc.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        abc.widthAnchor.constraint(equalToConstant: Const.modeToggleWidth).isActive = true
        abc.addTarget(self, action: #selector(emojiHideTapped), for: .touchUpInside)
        footer.addArrangedSubview(abc)

        if needsInputModeSwitchKey {
            footer.addArrangedSubview(makeGlobeButton(systemName: "globe"))
        }

        let selectedEmoji = makeSymbolControlButton(
            systemName: "face.smiling.fill",
            action: #selector(emojiHideTapped),
            width: Const.emojiButtonWidth,
            bg: UIColor.systemFill,
            id: "emoji"
        )
        selectedEmoji.tintColor = .systemBlue
        footer.addArrangedSubview(selectedEmoji)

        let emojiSpace = KeyboardButton(frame: .zero)
        emojiSpace.setTitle("space", for: .normal)
        emojiSpace.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        emojiSpace.setTitleColor(.label, for: .normal)
        emojiSpace.normalBackgroundColor = keyboardKeyBackground(.secondary)
        emojiSpace.layer.cornerRadius = Const.keyCornerRadius
        emojiSpace.layer.borderWidth = Const.keyBorderWidth
        emojiSpace.layer.borderColor = keyboardKeyBorder().cgColor
        emojiSpace.accessibilityIdentifier = Const.idSpace
        emojiSpace.accessibilityLabel = "Space"
        emojiSpace.heightAnchor.constraint(greaterThanOrEqualToConstant: Const.keyMinHeight).isActive = true
        emojiSpace.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        footer.addArrangedSubview(emojiSpace)

        let returnKeySpec = self.returnKeySpec
        let emojiReturn = makeReturnButton()
        emojiReturn.accessibilityLabel = returnKeySpec.accessibilityLabel
        footer.addArrangedSubview(emojiReturn)

        NSLayoutConstraint.activate([
            tabsScroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tabsScroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tabsScroll.topAnchor.constraint(equalTo: panel.topAnchor),
            tabsScroll.heightAnchor.constraint(equalToConstant: Const.emojiCategoryTabHeight),
            tabsRow.leadingAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.leadingAnchor),
            tabsRow.trailingAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.trailingAnchor),
            tabsRow.topAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.topAnchor),
            tabsRow.bottomAnchor.constraint(equalTo: tabsScroll.contentLayoutGuide.bottomAnchor),
            tabsRow.heightAnchor.constraint(equalTo: tabsScroll.frameLayoutGuide.heightAnchor),

            collection.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            collection.topAnchor.constraint(equalTo: tabsScroll.bottomAnchor),
            collection.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Const.emojiPanelFooterHeight),
        ])

        emojiPanelView = panel
        isEmojiPanelVisible = true
        NSLog("TONO_KB BUILD86 emoji-panel: visible categories=\(EmojiCategory.allCases.count) active=\(emojiActiveCategory.rawValue)")
    }

    @objc private func emojiHideTapped() {
        hideEmojiPanel()
    }

    private func hideEmojiPanel() {
        cancelTransientInteractions()
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        emojiCollectionView = nil
        emojiCategoryStack = nil
        emojiVisibleGlyphs = []
        isEmojiPanelVisible = false
        installKeyboardLayout()
        refreshSpellingSuggestions()
    }

    private func makeEmojiCategoryTab(_ category: EmojiCategory) -> UIButton {
        let b = TonoMinimumHitTargetButton(type: .system)
        b.setImage(UIImage(systemName: category.symbolName), for: .normal)
        b.imageView?.contentMode = .scaleAspectFit
        let isActive = (category == emojiActiveCategory)
        b.backgroundColor = .clear
        b.tintColor = isActive ? .systemBlue : .secondaryLabel
        b.accessibilityLabel = category.accessibilityName
        b.accessibilityTraits = isActive ? [.button, .selected] : [.button]
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
        guard emojiPanelView != nil, let collection = emojiCollectionView else { return }
        emojiActiveCategory = category
        if let tabsRow = emojiCategoryStack {
            for (idx, sub) in tabsRow.arrangedSubviews.enumerated() {
                if let b = sub as? UIButton, let cat = EmojiCategory(rawValue: idx) {
                    let isActive = (cat == emojiActiveCategory)
                    b.backgroundColor = .clear
                    b.tintColor = isActive ? .systemBlue : .secondaryLabel
                    b.accessibilityTraits = isActive ? [.button, .selected] : [.button]
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
        emojiVisibleGlyphs = category.glyphs
        collection.reloadData()
        collection.setContentOffset(.zero, animated: false)
    }

    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        emojiVisibleGlyphs.count
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: Const.emojiCellReuseIdentifier,
            for: indexPath
        ) as! EmojiCollectionCell
        let emoji = emojiVisibleGlyphs[indexPath.item]
        cell.configure(emoji: emoji, identifier: Const.emojiId(emoji))
        return cell
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let flow = collectionViewLayout as! UICollectionViewFlowLayout
        let horizontalInsets = flow.sectionInset.left + flow.sectionInset.right
        let columns = TonoKeyboardMetrics.ControlGeometry.emojiGridColumns(
            availableWidth: collectionView.bounds.width,
            insets: horizontalInsets,
            spacing: flow.minimumInteritemSpacing
        )
        let gaps = CGFloat(columns - 1) * flow.minimumInteritemSpacing
        let width = floor((collectionView.bounds.width - horizontalInsets - gaps) / CGFloat(columns))
        return CGSize(width: width, height: TonoKeyboardMetrics.ControlGeometry.emojiResultCellHeight)
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard emojiVisibleGlyphs.indices.contains(indexPath.item) else { return }
        insertEmoji(emojiVisibleGlyphs[indexPath.item])
    }

    private func insertEmoji(_ emoji: String) {
        guard !emoji.isEmpty else { return }
        textDocumentProxy.insertText(emoji)
        playInputClick()
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
        cancelTransientInteractions()
        spellingService.cancel()
        updateCandidateStrip(values: [])
        if isEmojiPanelVisible { hideEmojiPanel() }
        let proxy = textDocumentProxy
        guard let target = CoachRewriteTarget.capture(
            before: proxy.documentContextBeforeInput ?? "",
            after: proxy.documentContextAfterInput ?? "",
            host: currentHostSession
        ) else {
            presentCoachEmptyState()
            return
        }
        coachRewriteTarget = target
        runCoach(draft: target.draft)
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
        invalidateCoachWork(restoreKeyboard: false, clearTarget: false)
        cancelTransientInteractions()
        coachBusy = true
        coachButton?.isEnabled = false
        presentCoachLoading()
        let client = TonoCoachClient(endpoint: Const.backendURL, timeout: Const.coachTimeout)
        let requestID = UUID()
        coachRequestID = requestID
        NSLog("TONO_KB BUILD86 coach: begin POST /v1/analyze (len=\(draft.count))")
        coachTask = client.coach(draft: draft) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self,
                      self.coachRequestID == requestID,
                      let target = self.coachRewriteTarget,
                      target.isCurrent(
                        liveBefore: self.textDocumentProxy.documentContextBeforeInput ?? "",
                        liveAfter: self.textDocumentProxy.documentContextAfterInput ?? "",
                        host: self.currentHostSession
                      ) else { return }
                self.coachTask = nil
                self.coachRequestID = nil
                self.coachBusy = false
                self.coachButton?.isEnabled = true
                switch result {
                case .success(let response):
                    NSLog("TONO_KB BUILD86 coach: OK risk=\(response.riskLevel) suggestions=\(response.suggestions.count)")
                    self.presentCoachResults(response)
                case .failure(let err):
                    NSLog("TONO_KB BUILD86 coach: FAIL \(err.userFacingMessage)")
                    self.presentCoachError(err)
                }
            }
        }
    }

    private func presentCoachLoading() {
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        preferredHeightConstraint?.constant = currentVisualMetrics.preferredContentHeight
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

    // Internal so the XCTest target can exercise the real UIKit results state.
    // This is not API surface outside the keyboard module.
    func presentCoachResults(_ response: TonoCoachClient.CoachResponse) {
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        preferredHeightConstraint?.constant = currentVisualMetrics.coachResultsContentHeight
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachStatusLabel = nil
        coachResultsStack = nil

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
        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14, weight: .semibold)
        )
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.numberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        title.accessibilityIdentifier = Const.idRiskBadge
        panel.addSubview(title)
        let titleHeight = ceil(title.font.lineHeight)

        let back = TonoMinimumHitTargetButton(type: .system)
        back.setTitle("Back", for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        back.translatesAutoresizingMaskIntoConstraints = false
        back.accessibilityIdentifier = Const.idCoachBack
        back.addTarget(self, action: #selector(backToKeysTapped), for: .touchUpInside)
        panel.addSubview(back)

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = false
        scroll.showsVerticalScrollIndicator = true
        scroll.accessibilityIdentifier = "\(Const.idRewrites).scroll"
        panel.addSubview(scroll)

        let stack = UIStackView()
        stack.axis = .vertical
        // Each card's required top-to-bottom label chain determines the exact
        // content height. Do not also make the stack at least as tall as the
        // viewport: when natural content is shorter than the viewport that
        // inequality leaves every arranged-subview height underdetermined.
        stack.distribution = .fill
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.accessibilityIdentifier = Const.idRewrites
        scroll.addSubview(stack)

        let suggestionsByAxis = Dictionary(
            response.suggestions.map { ($0.axis.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let shown = TonoCoachPalette.orderedAxes.compactMap {
            suggestionsByAxis[$0.rawValue]
        }
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
            title.heightAnchor.constraint(equalToConstant: titleHeight),

            back.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            back.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            back.heightAnchor.constraint(equalToConstant: TonoKeyboardMetrics.ControlGeometry.coachBackControlHeight),
            back.widthAnchor.constraint(greaterThanOrEqualToConstant: TonoKeyboardMetrics.ControlGeometry.coachBackControlWidth),

            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])

        coachContainer = panel
        coachResultsStack = stack
    }

    private func makeRewriteChip(suggestion: TonoCoachClient.CoachRewrite, index: Int) -> UIView {
        let chip = TonoCoachChoiceControl()
        let style = coachAxisStyle(for: suggestion.axis)
        chip.layer.cornerRadius = Const.keyCornerRadius
        chip.layer.borderWidth = 2
        chip.layer.borderColor = style.accent.cgColor
        chip.semanticAccent = style.accent
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.accessibilityIdentifier = Const.rewriteId(suggestion.axis, index)
        chip.accessibilityLabel = "Tono rewrite \(suggestion.axis)"

        let axis = UILabel()
        axis.text = "● \(style.label)"
        axis.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 11, weight: .bold)
        )
        axis.adjustsFontForContentSizeCategory = true
        axis.textColor = style.labelColor
        axis.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(axis)
        let axisHeight = ceil(axis.font.lineHeight)

        let text = UILabel()
        text.text = suggestion.text
        text.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 14, weight: .regular)
        )
        text.adjustsFontForContentSizeCategory = true
        text.textColor = .label
        text.numberOfLines = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(text)
        let textHeight = ceil(text.font.lineHeight * CGFloat(text.numberOfLines))

        NSLayoutConstraint.activate([
            chip.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            axis.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            axis.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),
            axis.trailingAnchor.constraint(lessThanOrEqualTo: chip.trailingAnchor, constant: -10),
            axis.heightAnchor.constraint(equalToConstant: axisHeight),

            text.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: axis.bottomAnchor, constant: 2),
            text.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -6),
            text.heightAnchor.constraint(equalToConstant: textHeight),
        ])

        let rewriteText = suggestion.text
        chip.addAction(UIAction { [weak self] _ in
            self?.applyRewrite(rewriteText)
        }, for: .touchUpInside)
        return chip
    }

    private func coachAxisStyle(
        for axis: String
    ) -> (label: String, labelColor: UIColor, accent: UIColor) {
        guard let semantic = TonoCoachPalette.axis(axis) else {
            return (axis.capitalized, .label, .separator)
        }
        return (semantic.label, semantic.accessibleLabel, semantic.accent)
    }

    @objc private func backToKeysTapped() {
        cancelTransientInteractions()
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil
        installKeyboardLayout()
    }

    private func applyRewrite(_ rewrite: String) {
        let proxy = textDocumentProxy
        let originalBefore = proxy.documentContextBeforeInput ?? ""
        let originalAfter = proxy.documentContextAfterInput ?? ""
        guard let target = coachRewriteTarget,
              let plan = target.mutationPlan(
            liveBefore: originalBefore,
            liveAfter: originalAfter,
            replacement: rewrite,
            host: currentHostSession
        ) else {
            NSLog("TONO_KB BUILD86 rewrite: rejected stale or edited draft")
            presentCoachError(.staleDraft)
            return
        }
        if plan.initialCursorOffset != 0 {
            proxy.adjustTextPosition(byCharacterOffset: plan.initialCursorOffset)
        }
        let adjustedBefore = proxy.documentContextBeforeInput ?? ""
        let adjustedAfter = proxy.documentContextAfterInput ?? ""
        guard target.isAtMutationPosition(
            liveBefore: adjustedBefore,
            liveAfter: adjustedAfter
        ) else {
            if let restoreOffset = target.cursorOffset(
                liveBefore: adjustedBefore,
                liveAfter: adjustedAfter,
                toBeforeCount: originalBefore.count
            ), restoreOffset != 0 {
                proxy.adjustTextPosition(byCharacterOffset: restoreOffset)
            }
            NSLog("TONO_KB BUILD86 rewrite: rejected clamped or ignored caret move")
            presentCoachError(.staleDraft)
            return
        }
        for _ in 0..<plan.deleteCount { proxy.deleteBackward() }
        proxy.insertText(plan.insertion)
        if plan.finalCursorOffset != 0 {
            proxy.adjustTextPosition(byCharacterOffset: plan.finalCursorOffset)
        }
        coachRewriteTarget = nil
        NSLog("TONO_KB BUILD86 rewrite: inserted len=\(rewrite.count) (deleted \(plan.deleteCount))")
    }

    // MARK: - Coach error

    private func presentCoachError(_ err: TonoCoachClient.CoachError) {
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        preferredHeightConstraint?.constant = currentVisualMetrics.preferredContentHeight
        coachContainer?.removeFromSuperview()
        coachContainer = nil
        coachStatusLabel = nil
        coachResultsStack = nil

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

        let retry = TonoCoachButton(type: .custom)
        retry.setTitle("Retry", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        retry.layer.cornerRadius = Const.keyCornerRadius
        retry.layer.masksToBounds = true
        retry.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.accessibilityIdentifier = Const.idCoachRetry
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        panel.addSubview(retry)

        let back = TonoMinimumHitTargetButton(type: .system)
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
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: TonoKeyboardMetrics.ControlGeometry.coachBackControlHeight),

            back.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            back.centerYAnchor.constraint(equalTo: retry.centerYAnchor),
            back.heightAnchor.constraint(greaterThanOrEqualToConstant: TonoKeyboardMetrics.ControlGeometry.coachBackControlHeight),
            back.widthAnchor.constraint(greaterThanOrEqualToConstant: TonoKeyboardMetrics.ControlGeometry.coachBackControlWidth),
        ])

        coachContainer = panel
        coachErrorContainer = panel
        coachErrorLabel = detail
    }

    @objc private func retryTapped() {
        coachErrorContainer?.removeFromSuperview()
        coachErrorContainer = nil
        coachErrorLabel = nil
        guard let target = CoachRewriteTarget.capture(
            before: textDocumentProxy.documentContextBeforeInput ?? "",
            after: textDocumentProxy.documentContextAfterInput ?? "",
            host: currentHostSession
        ) else {
            presentCoachEmptyState()
            return
        }
        coachRewriteTarget = target
        runCoach(draft: target.draft)
    }
}

/// Shared keycap press treatment. It changes in the same event frame as
/// UIButton's highlighted state and always restores on UIKit cancellation.
private final class KeyboardButton: TonoMinimumHitTargetButton {
    var accessibilityActivationHandler: (() -> Bool)?
    var normalBackgroundColor: UIColor? {
        didSet { if !isHighlighted { backgroundColor = normalBackgroundColor } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let metrics = TonoKeyboardMetrics.portrait(availableWidth: UIScreen.main.bounds.width)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = metrics.keyShadowOpacity
        layer.shadowRadius = metrics.keyShadowRadius
        layer.shadowOffset = metrics.keyShadowOffset
        adjustsImageWhenHighlighted = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityActivate() -> Bool {
        accessibilityActivationHandler?() ?? super.accessibilityActivate()
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? normalBackgroundColor?.withAlphaComponent(0.68)
                : normalBackgroundColor
            let metrics = TonoKeyboardMetrics.portrait(availableWidth: UIScreen.main.bounds.width)
            layer.shadowOpacity = isHighlighted ? 0.04 : metrics.keyShadowOpacity
            transform = isHighlighted
                ? CGAffineTransform(translationX: 0, y: 1)
                : .identity
        }
    }
}

/// Reusable emoji cell: the collection view owns only enough labels for the
/// visible viewport, rather than materializing hundreds of UIButtons.
private final class EmojiCollectionCell: UICollectionViewCell {
    private let glyphLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        glyphLabel.font = .systemFont(ofSize: 27)
        glyphLabel.textAlignment = .center
        glyphLabel.adjustsFontSizeToFitWidth = true
        glyphLabel.minimumScaleFactor = 0.8
        contentView.addSubview(glyphLabel)
        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            glyphLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            glyphLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            glyphLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        glyphLabel.text = nil
        accessibilityLabel = nil
        accessibilityIdentifier = nil
    }

    func configure(emoji: String, identifier: String) {
        glyphLabel.text = emoji
        accessibilityLabel = "Emoji \(emoji)"
        accessibilityIdentifier = identifier
    }
}
