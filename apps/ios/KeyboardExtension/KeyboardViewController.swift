// Build 98 — punctuation-key title refresh regression fix.
//
// Build 97 root cause: `makeCharButton(_:)` assigned EVERY character
// the identifier `"TonoKB.letter.\(char)"`. For the period key this
// produced `"TonoKB.letter."` (trailing dot, empty char component).
// `applyShiftToKey` later parsed with
// `id.split(separator: ".").last` — Swift's `String.split` defaults
// to `omittingEmptySubsequences: true`, so the trailing empty
// component is dropped and `.last` returned the literal substring
// `"letter"`. `displayLetter("letter")` is identity (the lowercase
// branch is a no-op on a non-`[a-zA-Z]` token), so the period
// key's title got overwritten with the word `"letter"` on the
// first shift refresh.
//
// Fix: split the identifier scheme by char class. Letter keys
// keep `TonoKB.letter.<ch>` (collision-safe — `<ch>` is always a
// single ASCII letter, no parser ambiguity). Non-letter keys use
// `TonoKB.char.U+<XXXX>` (Unicode scalar hex, no `.` ambiguity).
// `applyShiftToKey` operates ONLY on letter identifiers whose
// parsed suffix is a single ASCII letter; non-letter keys are
// skipped entirely, so their titles stay pinned to whatever
// `displayLetter` produced at construction (already the right
// glyph for numbers/symbols/punctuation). The raw char is also
// pinned on the button itself (`KeyboardButton.displayChar`) so
// any future refresh path reads the original character instead
// of round-tripping through an identifier.

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

        /// Diameter of the non-interactive on-device-intelligence dot.
        static let localBadgeDiameter: CGFloat = 6

        static func letterKeyWidth(availableWidth: CGFloat) -> CGFloat {
            let usable = max(availableWidth - edgePadding * 2, 320)
            return (usable - rowSpacing * 9) / 10
        }

        static func row2HorizontalInset(availableWidth: CGFloat) -> CGFloat {
            (letterKeyWidth(availableWidth: availableWidth) + rowSpacing) / 2
        }

        // Row 3 has no separate "inner gap" subview — the row stack's
        // 8pt `row.spacing` already separates shift / letters / backspace.
        // The two old `UIView()` spacers were pure dead gutters that ate
        // the very width the spec calls for on z..m (Sherlock regression
        // evidence, parent task t_eb68c50f).
        static func row3InnerGap(availableWidth: CGFloat) -> CGFloat { 0 }

        // Width each row-3 letter cap SHOULD occupy after the shift and
        // backspace modifiers take their fixed portions. The renderer
        // actually consumes this — see `makeRow3`'s middle-stack width
        // constraint. This helper is the single source of truth for both
        // SwiftUI (AppleFidelity) and UIKit (`KeyboardViewController`),
        // so the visible-bounds regression test below cannot drift.
        //
        // Apple portrait measurements: shift ≈ 44pt, backspace ≈ 54pt,
        // letterKeyWidth ≈ 30pt. The eight row spacings include the two
        // visible neighbours of the middle stack plus the six between
        // the seven letter caps.
        static func row3LetterKeyWidth(availableWidth: CGFloat) -> CGFloat {
            let usable = max(availableWidth - edgePadding * 2, 320)
            let shiftAndBackspace = shiftKeyWidth + backspaceWidth
            let spacings = rowSpacing * 8
            return max((usable - shiftAndBackspace - spacings) / 7, 0)
        }

        // Bottom-row widths — match the visible iOS layout.
        static let modeToggleWidth: CGFloat = 46
        static let emojiButtonWidth: CGFloat = TonoKeyboardMetrics.ControlGeometry.emojiToggleWidth
        static let backspaceWidth: CGFloat = 54
        // Apple-portrait shift key — narrower than the backspace but
        // still clears the 44pt accessibility tap target. Sourced once
        // here so the geometry helper and the button constraint agree
        // (Sherlock regression evidence, parent task t_eb68c50f).
        static let shiftKeyWidth: CGFloat = 44
        static let returnWidth: CGFloat = 72

        // Coach UX.
        static let coachTimeout: TimeInterval = 15
        // Build 107: the user-visible deadline. If a request is still in
        // flight ~10s after tap, the keyboard cancels it and shows a truthful
        // retry/error state rather than an indefinitely shimmering skeleton.
        // The 15s URLSession timeout above stays as a backstop.
        static let coachVisibleDeadline: TimeInterval = 10
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

        // Build 106. `idCandidates` (above) is the spelling-suggestion row and
        // keeps its historic identifier; `idToneChips` is the SEPARATE Coach
        // row that used to share those same three buttons. Two identifiers
        // means a physical inspector can confirm on-device which row it is
        // actually touching — the Build-105 defect was invisible precisely
        // because both roles wore one identifier.
        static let idToneChips        = "TonoKB.toneChips"
        /// Subtle on-device-intelligence indicator (see `LocalIntelligence`).
        static let idLocalBadge       = "TonoKB.localBadge"

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
            idToneChips, idLocalBadge,
        ]

        /// Returns every TonoKB.* identifier this file declares.
        /// Marked `@inline(never)` so the optimiser can't fold the
        /// array back into its constituent literals and
        /// dead-code-eliminate each one as a single-use constant.
        @inline(never)
        static func allIdentifiers() -> [String] {
            return registry
        }

        /// Identifier scheme for a single-character alphabetic letter
        /// keycap. The suffix is always exactly one ASCII letter in
        /// `[a-z]` (lower-case rendered form), so the
        /// `TonoKB.letter.<suffix>` parse in `applyShiftToKey` is
        /// collision-safe — there is no ambiguity about where the
        /// suffix starts.
        static func letterId(_ ch: String) -> String { "TonoKB.letter.\(ch)" }

        /// Identifier scheme for any non-letter keycap
        /// (punctuation, numbers, symbols, currency, whitespace).
        /// The suffix is the character's Unicode scalar in `U+XXXX`
        /// hex form, so the identifier can never end with a `.`
        /// that would round-trip to the literal `letter` token
        /// under `String.split(separator: ".").last` with
        /// `omittingEmptySubsequences: true` (the build-97
        /// shipping-defect shape — see file header).
        static func nonLetterId(_ ch: String) -> String {
            let scalars = ch.unicodeScalars
            // Single scalar is the common case; multi-scalar chars
            // (e.g. emoji) join all their hex codes with `_` so the
            // suffix is unambiguous.
            let hexes = scalars.map { String(format: "U+%04X", $0.value) }
            return "TonoKB.char." + hexes.joined(separator: "_")
        }

        /// Returns the standard `TonoKB.*` identifier for the given
        /// raw character. Letters use `TonoKB.letter.<ch>`; every
        /// other char uses `TonoKB.char.U+<XXXX>` (or
        /// `U+XXXX_U+YYYY` for multi-scalar). This is the single
        /// source of truth — `makeCharButton`, `applyShiftToKey`,
        /// and UI-automation consumers all read from here.
        static func charId(for ch: String) -> String {
            if ch.count == 1, let scalar = ch.unicodeScalars.first, scalar.isASCII {
                let isLowercaseLetter = (scalar.value >= 0x61 && scalar.value <= 0x7A)
                if isLowercaseLetter {
                    return "TonoKB.letter.\(ch)"
                }
            }
            return nonLetterId(ch)
        }

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
    private var coachRequestGuard: CoachRequestLifecycleGuard?
    private var coachVariantSettings = CoachVariantSettings()
    /// Whether Coach tone chips are the live role — DERIVED, never stored.
    ///
    /// Build 109 removes the last stored mirror of the strip's role. Until now
    /// this was a separate `Bool` assigned at the top of `setToneChipsEnabled`,
    /// running in parallel with `stripMode`. The two happened to agree, because
    /// `applyStripMode` had exactly three call sites — but nothing enforced it,
    /// and `coachTapped` toggled against the *flag* while every dispatch gate in
    /// `TonoStripRoutingPolicy` decided against the *mode*. Any future path that
    /// set the mode without also setting the flag would desynchronise them, and
    /// the visible symptom is that TONO stops responding: with the flag stale at
    /// `true` while the strip shows suggestions, one tap computes
    /// `setToneChipsEnabled(false)` and turns Coach off again instead of on.
    ///
    /// A second boolean that can disagree with what the strip is actually
    /// showing is the shape of the original Build-105 defect. Deriving it makes
    /// disagreement unrepresentable rather than merely unlikely, and `stripMode`
    /// becomes the single authority for both the toggle and the dispatch gate.
    private var toneChipsEnabled: Bool { stripMode == .toneChips }
    private var selectedToneAxes: [String] = []
    private var coachRequestID: UUID?
    private var coachTask: URLSessionDataTask?
    /// Monotonic anchor for the active request, captured at tap. Drives the
    /// privacy-safe lifecycle clocks; durations only, never message content.
    private var coachClockTapTime: DispatchTime?
    /// Fires ~10s after tap if the request is still in flight, replacing the
    /// skeleton with a truthful retry/error state. Cancelled the instant a
    /// real completion lands or the session is invalidated.
    private var coachDeadline: DispatchWorkItem?
    private lazy var coachClient = TonoCoachClient(
        endpoint: Const.backendURL.replacingOccurrences(of: "/v1/analyze", with: "/api/analyze/variant"),
        timeout: Const.coachTimeout,
        // Build 96: the bearer token comes from the app's shared Keychain
        // access group. When it is absent the client makes zero network
        // requests and surfaces a visible missing-token state.
        tokenProvider: { SharedKeychain.get(KeychainKeys.apiToken) }
    )

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
            documentIdentifier: HostDocumentIdentifier.read(from: documentProxy),
            traitSignature: signature,
            session: hostSessionSerial
        )
    }

    private func advanceHostSession() {
        hostSessionSerial &+= 1
        // Live Tone v1 — field / editing-session boundary. Per-draft
        // suppression must reset here so a new field starts fresh.
        // Pure observer call; never touches the keystroke path. Wired
        // unconditionally (build 96) so the test build and the shipping
        // build run the identical path.
        liveToneManager?.fieldDidReset()
    }

    private var keysStack: UIStackView?
    private var coachContainer: UIView?
    /// The result-shaped loading skeleton currently installed, if any. Build
    /// 107 replaced the plain "Coaching…" label + spinner with this.
    private var coachSkeleton: TonoCoachSkeletonView?
    private var coachResultsStack: UIStackView?
    private var coachErrorContainer: UIView?
    private var coachErrorLabel: UILabel?
    private var coachBusy: Bool = false
    /// Identifies the request whose loading surface is currently installed in
    /// the body container. A completion may replace only *its own* loading
    /// surface, so a superseded request, an invalidated session, or a
    /// duplicate delivery can never reattach to a surface it does not own.
    private var coachLoadingRequestID: UUID?
    /// Coach requests this controller has started. One tap starts exactly
    /// one; a tap the busy gate refuses starts none. Debug seam for the 1:1
    /// contract, mirroring `TonoCoachClient.providerCallCount` on the client
    /// side. Production never reads it.
    private(set) var coachRequestsStarted = 0

    // Build 107 test seams (internal, read-only): the live request identity
    // and busy state, so the XCTest target can drive the ~10s deadline path
    // without reaching into private state or waiting the real interval.
    // Production never reads these.
    var activeCoachRequestIDForTesting: UUID? { coachRequestID }
    var coachIsBusyForTesting: Bool { coachBusy }
    /// The tone axes the chip row is currently backed by. Read-only seam so a
    /// test can pin the Build-107 "turning Coach off clears the stale axes"
    /// contract without reaching into private state.
    var selectedToneAxesForTesting: [String] { selectedToneAxes }
    /// Which role the strip believes it is presenting. Read-only seam for the
    /// same contract.
    var stripModeForTesting: TonoStripMode { stripMode }

    /// The host document. EVERY read and every mutation in this controller goes
    /// through this one accessor rather than touching `textDocumentProxy`
    /// directly, so a test can substitute a recording document.
    ///
    /// Why this exists (Build 109). A unit-test `UIInputViewController` has no
    /// connected host: its proxy reports nil context and silently discards
    /// `insertText` / `deleteBackward`. That left the POSITIVE half of the
    /// founder findings untestable. Every strip test could assert only that
    /// Coach was *not* invoked — never that the tap actually accepted the word,
    /// and never that a caret move left the text alone. A build in which
    /// `candidateTapped` did nothing whatsoever passed the entire suite, so the
    /// "suggestion taps stay local" guarantee rested on a measurement that could
    /// be true for the wrong reason.
    ///
    /// Production behaviour is unchanged: the override is nil on every shipping
    /// path, so this resolves to the real proxy. The class is `final`, so this
    /// is an injection point rather than an override point.
    var documentProxyOverride: UITextDocumentProxy?
    var documentProxy: UITextDocumentProxy { documentProxyOverride ?? textDocumentProxy }

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
    // Apple-fidelity space hold/drag caret trackpad. `SpaceCursorSession` owns
    // the pure engine plus the ONLY proxy operation this feature may perform —
    // `adjustTextPosition(byCharacterOffset:)`. Its `SpaceCursorTextProxy`
    // protocol has no insert or delete member, so no gesture path here can add
    // or remove text; the single insertion is `insertSpaceCommit()` on a
    // genuine quick tap. The activation timer is a generation-guarded work
    // item, mirroring backspace-repeat, so it can never fire stale.
    private lazy var spaceCursorSession = SpaceCursorSession(
        proxy: SpaceCursorProxyAdapter(owner: self),
        // Build 106: re-read at every takeover, so rotation and dynamic-type
        // changes are picked up without rebuilding the session (which would
        // reintroduce the Build-104 proxy-lifetime defect).
        wrapWidthProvider: { [weak self] in self?.estimatedWrapWidth() }
    )
    private var spaceCursorActivationWork: DispatchWorkItem?
    private var spaceCursorGeneration = 0
    private var spaceCursorOrigin: CGPoint = .zero
    private var spaceCursorLastLocation: CGPoint = .zero
    private var spaceCursorAffordanceActive = false
    private var spaceCursorRestoreTitle: String?
    private weak var spaceButton: UIButton?
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
    private weak var toneChipStack: UIStackView?
    private weak var localBadge: UIView?
    private weak var coachButton: TonoCoachButton?
    private var candidateValues: [String] = []

    /// Which role the top strip is presenting. Build 105 inferred this from
    /// `toneChipsEnabled` *and* from whichever selector happened to be attached
    /// to the shared buttons; the two could disagree, and did. Build 106 keeps
    /// one authority and gates both handlers on it.
    private var stripMode: TonoStripMode = .suggestions

    /// Every strip dispatch this controller refused, keyed by reason. Debug
    /// seam for the "a suggestion tap can never reach Coach" contract —
    /// `roleMismatch` must stay at zero for the process lifetime. Privacy-safe:
    /// counts only, never text.
    private(set) var stripRefusals: [TonoStripRoutingPolicy.Reason: Int] = [:]

    // Live Tone v1 — shipping release. Pure observer; never touches the
    // keystroke path. The manager owns the debouncer, the session state
    // machine, the preference reads, and the indicator view. Wired
    // unconditionally (build 96): it was formerly gated behind
    // `TONO_BUILD92_HOSTSESSION`, which is defined on the test target and
    // therefore stripped Live Tone from every test build.
    private var liveToneManager: LiveToneManager?
    /// The most recent character we observed via the proxy. Used to
    /// decide whether a sentence-ending punctuation should flush the
    /// debounce immediately (500 ms typing-idle OR punctuation, whichever
    /// fires first — binding Live Tone v1 contract).
    private var liveToneLastCommittedCharacter: Character?

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
        installLiveTone()
        #if !TONO_BUILD92_HOSTSESSION
        // Build 106: the user's own keyboard vocabulary now feeds BOTH lanes —
        // it suppresses false corrections (as before) and contributes the
        // shortcut expansions the user configured in Settings as real
        // candidates. Build 105 collapsed both halves into one flat word set
        // and used it only to bail out.
        requestSupplementaryLexicon { [weak self] lexicon in
            self?.spellingService.updateLexicon(
                LocalLexicon(lexiconEntries: lexicon.entries.map {
                    (userInput: $0.userInput, documentText: $0.documentText)
                })
            )
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
        recordSetupHeartbeat()
        advanceHostSession()
        refreshHostConfigurationIfNeeded()
        applyAutoCapitalizationIfNeeded()
        refreshSpellingSuggestions()
    }

    // MARK: - Setup Doctor heartbeat

    /// Leaves a content-free liveness record in the App Group so the host app's
    /// Setup Doctor can tell the user the truth about their setup.
    ///
    /// This exists because iOS gives the containing app no way to see any of it:
    /// it cannot read whether its keyboard is enabled, and `hasFullAccess` is
    /// readable *only* here, on `UIInputViewController`. Without this record the
    /// app can do nothing but guess, so the Doctor would either nag a
    /// correctly-configured user or show a green tick it cannot back up.
    ///
    /// PRIVACY (binding — see the contract note in `Shared/SetupDoctor.swift`):
    /// the record carries a schema number, a timestamp, and `hasFullAccess`.
    /// Nothing else. No typed text, no document context, no recipient, no host
    /// app identity, no counters. Deliberately written where no document proxy
    /// value is in scope, so there is nothing to accidentally include.
    private func recordSetupHeartbeat() {
        KeyboardHeartbeatStore().record(hasFullAccess: hasFullAccess, now: Date())
        // Repairs a documented-but-never-honoured contract: `keyboardLoaded` is
        // described in SharedUserDefaults.swift as "written by the keyboard
        // extension on first load", and the onboarding flow reads it, but no
        // write ever existed — so that check could never pass. It is a sticky
        // "has ever loaded" marker; the Setup Doctor deliberately does NOT use
        // it for any completed state, because a stale true is exactly the false
        // success the timestamped heartbeat above exists to avoid.
        SharedStore.defaults.set(true, forKey: SharedKeys.keyboardLoaded)
    }

    public override func textDidChange(_ textInput: UITextInput?) {
        refreshHostConfigurationIfNeeded()
        let liveBefore = documentProxy.documentContextBeforeInput ?? ""
        let liveAfter = documentProxy.documentContextAfterInput ?? ""
        let requestAction = coachRequestGuard?.action(
            liveBefore: liveBefore,
            liveAfter: liveAfter,
            host: currentHostSession
        )
        if requestAction == .cancel {
            advanceHostSession()
            invalidateCoachWork(restoreKeyboard: true)
        }
        spellingService.cancel()
        let liveContext = liveBefore
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
        // Live Tone v1 — passive observer. The keystroke path is untouched.
        // We forward the post-mutation context plus the last committed
        // character so the engine can decide whether to flush on
        // sentence-ending punctuation. Wired unconditionally (build 96).
        liveToneDidMutate(context: effectiveContext)
        // Build 96 Live Tone deferred proxy read: UIKit may publish
        // textDidChange before UITextDocumentProxy catches up (see
        // comment above `applyDocumentMutation`). Without a deferred
        // re-read the engine can repeatedly classify a stale/empty
        // pre-mutation draft. Schedule a one-tick-late Live Tone drive
        // that uses the freshly-catch-up live proxy as the post-
        // mutation context. The engine's own debounce + stale-result
        // discard mean the second drive is a safe no-op when nothing
        // changed. Live Tone never touches the document, never opens
        // the rewrite flow, never blocks the keystroke path.
        let deferredGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.documentMutationGeneration == deferredGeneration else { return }
            let liveNow = self.documentProxy.documentContextBeforeInput ?? ""
            self.liveToneDidMutate(context: liveNow)
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
        cancelSpaceCursorActivation()
        dismissKeyPreview()
    }

    public var enableInputClicksWhenVisible: Bool { true }

    private func playInputClick() {
        UIDevice.current.playInputClick()
    }

    /// Estimated characters per visual row in the host field.
    ///
    /// Derived from the extension's own width and the user's body-font advance,
    /// which are the only layout facts a keyboard extension can observe. The
    /// host's real field width, font and line breaking are not readable through
    /// any public API — see `SpaceCursorWrapEstimator` for why this is biased
    /// low and what it does not claim.
    private func estimatedWrapWidth() -> Int? {
        let width = view.bounds.width
        guard width > 0 else { return nil }
        let font = UIFont.preferredFont(forTextStyle: .body)
        let advance = ("n" as NSString).size(withAttributes: [.font: font]).width
        return SpaceCursorWrapEstimator.charactersPerRow(
            keyboardWidthPoints: Double(width),
            averageCharacterWidthPoints: Double(advance)
        )
    }

    private func cancelTransientInteractions() {
        cancelDeleteRepeat()
        dismissKeyPreview()
        resetSpaceCursorSession()
    }

    private func invalidateCoachWork(restoreKeyboard: Bool, clearTarget: Bool = true) {
        coachTask?.cancel()
        coachTask = nil
        coachRequestID = nil
        coachLoadingRequestID = nil
        // Disarm the visible deadline and drop the clock anchor: a cancelled
        // or superseded request must never leave a watchdog armed against a
        // stale requestID, and must not leak its tap anchor into the next one.
        coachDeadline?.cancel()
        coachDeadline = nil
        coachClockTapTime = nil
        if clearTarget {
            coachRewriteTarget = nil
            coachRequestGuard = nil
        }
        coachBusy = false
        coachButton?.isEnabled = true
        guard restoreKeyboard, coachContainer != nil, keysInstalled, !isRebuildingLayout else { return }
        removeAllCoachSurfaces()
        installKeyboardLayout()
    }

    // MARK: - Minimal Coach bar

    private func buildTopBar() {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.accessibilityIdentifier = Const.idTopBar
        view.addSubview(bar)

        let coach = TonoCoachButton(type: .custom)
        coach.setTitle("TONO", for: .normal)
        coach.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        coach.layer.cornerRadius = Const.keyCornerRadius
        coach.layer.masksToBounds = true
        coach.contentEdgeInsets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        coach.translatesAutoresizingMaskIntoConstraints = false
        coach.accessibilityIdentifier = Const.idCoachButton
        coach.accessibilityLabel = "Tono Coach"
        coach.addTarget(self, action: #selector(coachTapped), for: .touchUpInside)
        bar.addSubview(coach)

        // Build 106 — two physically distinct rows, one per role.
        //
        // These are separate view hierarchies with separate buttons and
        // separate, permanently-bound selectors. Exactly one row is visible and
        // hit-testable at a time (`applyStripMode`). No target/action table is
        // mutated after this function returns, which is what makes the
        // Build-105 "suggestion tap runs Coach" state unreachable rather than
        // merely unlikely.
        let candidates = makeStripStack(
            role: .suggestion,
            identifier: Const.idCandidates,
            action: #selector(candidateTapped(_:)),
            in: bar
        )
        let chips = makeStripStack(
            role: .toneChip,
            identifier: Const.idToneChips,
            action: #selector(toneChipTapped(_:)),
            in: bar
        )

        // Subtle, non-interactive "running on device" signal. Never a touch
        // target, so it cannot participate in any hit-region collision.
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isUserInteractionEnabled = false
        badge.backgroundColor = .systemGreen
        badge.layer.cornerRadius = Const.localBadgeDiameter / 2
        badge.accessibilityIdentifier = Const.idLocalBadge
        badge.isAccessibilityElement = true
        badge.accessibilityTraits = [.staticText]
        badge.accessibilityLabel = LocalIntelligenceCopy.badgeAccessibilityLabel
        badge.isHidden = true
        bar.addSubview(badge)

        // TONO is the leading anchor of the strip; the active row reads to its
        // right. Accessibility order matches the visual order.
        bar.accessibilityElements = [coach, badge] + candidates.arrangedSubviews
        // A Coach control narrower than the 44pt minimum touch target would
        // have its hit rect expanded outward by `TonoMinimumHitTargetButton`,
        // pushing it under the first suggestion. Flooring the width at the
        // minimum keeps the expansion purely vertical, and
        // `TonoStripGeometry.coachSeparation` covers the rest.
        let approvedCoachWidth = max(
            ceil(coach.intrinsicContentSize.width),
            TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget
        )
        coach.setContentHuggingPriority(.required, for: .horizontal)
        coach.setContentCompressionResistancePriority(.required, for: .horizontal)

        var constraints: [NSLayoutConstraint] = [
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Const.baselineMetrics.topBarHeight),

            // TONO remains anchored to the leading edge in every state.
            coach.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            coach.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            coach.heightAnchor.constraint(equalToConstant: Const.baselineMetrics.coachControlHeight),
            coach.widthAnchor.constraint(equalToConstant: approvedCoachWidth),

            badge.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: Const.localBadgeDiameter),
            badge.heightAnchor.constraint(equalToConstant: Const.localBadgeDiameter),
            badge.leadingAnchor.constraint(
                equalTo: coach.trailingAnchor,
                constant: TonoStripGeometry.coachSeparation
            ),
        ]
        // Both rows occupy the identical frame; visibility, not geometry,
        // selects between them.
        for stack in [candidates, chips] {
            constraints += [
                stack.leadingAnchor.constraint(
                    equalTo: badge.trailingAnchor,
                    constant: TonoStripGeometry.coachSeparation
                ),
                stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -3),
                stack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -4),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        self.topBar = bar
        self.candidateStack = candidates
        self.toneChipStack = chips
        self.localBadge = badge
        self.coachButton = coach
        applyStripMode(.suggestions)
    }

    /// Build one role's row. The selector is bound here, once, and never
    /// removed — `TonoStripButton.stripRole` is `let`, so the pair
    /// (button identity, action) is fixed for the button's lifetime.
    private func makeStripStack(
        role: TonoStripRole,
        identifier: String,
        action: Selector,
        in bar: UIView
    ) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.accessibilityIdentifier = identifier
        bar.addSubview(stack)
        for index in 0..<3 {
            let button = TonoStripButton(role: role, index: index)
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: 13, weight: .regular)
            )
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(.label, for: .normal)
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 5
            button.isHidden = true
            button.addTarget(self, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        return stack
    }

    /// Make exactly one row live. The inactive row is hidden **and** has
    /// interaction disabled, so it is excluded from hit testing twice over and
    /// z-order between the two rows can never decide a tap.
    private func applyStripMode(_ mode: TonoStripMode) {
        stripMode = mode
        let showSuggestions = mode == .suggestions
        candidateStack?.isHidden = !showSuggestions
        candidateStack?.isUserInteractionEnabled = showSuggestions
        toneChipStack?.isHidden = showSuggestions
        toneChipStack?.isUserInteractionEnabled = !showSuggestions
        if let bar = topBar, let coach = coachButton, let badge = localBadge {
            let active = showSuggestions ? candidateStack : toneChipStack
            bar.accessibilityElements = [coach, badge] + (active?.arrangedSubviews ?? [])
        }
        updateLocalBadge()
    }

    /// Record and log a refused strip dispatch. Counts only — the refused
    /// candidate text is never read, formatted or logged.
    private func noteStripRefusal(_ reason: TonoStripRoutingPolicy.Reason) {
        stripRefusals[reason, default: 0] += 1
        if reason == .roleMismatch {
            // Build-105 signature. Must never fire; loud if it ever does.
            NSLog("TONO_KB BUILD106 ERR: strip role mismatch (count=%d)", stripRefusals[reason] ?? 0)
        }
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
        documentProxy.keyboardType ?? .default
    }

    private var hostReturnKeyType: UIReturnKeyType {
        documentProxy.returnKeyType ?? .default
    }

    private var hostKeyboardAppearance: UIKeyboardAppearance {
        documentProxy.keyboardAppearance ?? .default
    }

    private var hostAutocapitalizationType: UITextAutocapitalizationType {
        documentProxy.autocapitalizationType ?? .sentences
    }

    private var hostAutocorrectionType: UITextAutocorrectionType {
        documentProxy.autocorrectionType ?? .default
    }

    private var hostSpellCheckingType: UITextSpellCheckingType {
        documentProxy.spellCheckingType ?? .default
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
        removeAllCoachSurfaces()
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

        // Build 96 Live Tone z-order fix: every layout rebuild appends a
        // fresh full-edge keyboard stack after the indicator, demoting
        // it in z-order so a published warning becomes invisible
        // (parent Sherlock diagnosis t_08d08e43). Re-promote the
        // indicator to the top of bodyContainer so the warning is
        // actually drawn over the keyboard stack. The manager-owned
        // indicator contract is preserved: we only re-order existing
        // subviews, never re-create or relocate the indicator view.
        if let indicator = liveToneManager?.indicator, indicator.superview === container {
            container.bringSubviewToFront(indicator)
        }

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

        // Row 3 has no separate "inner gap" UIView subview. The row
        // stack's 8pt `row.spacing` already separates shift / letters /
        // backspace. The two old `UIView()` spacers here were pure dead
        // gutters that ate the very width the spec calls for on z..m —
        // Sherlock regression evidence, parent task t_eb68c50f. The
        // middle stack's width is now anchored to
        // `row3LetterKeyWidth * 7` so the letters actually consume the
        // reclaimed space.

        let middle = UIStackView()
        middle.axis = .horizontal
        middle.alignment = .fill
        middle.distribution = .fillEqually
        middle.spacing = Const.rowSpacing
        for ch in row3BaseChars() {
            middle.addArrangedSubview(makeCharButton(ch))
        }
        // Wire the middle stack to the helper's computed width so the
        // letters actually get the reclaimed space (the failure mode in
        // the 339775cf candidate — helper defined but never consumed by
        // the UIKit row). The fillEqually distribution inside `middle`
        // then tiles its width into seven equal keycaps.
        middle.widthAnchor.constraint(
            equalToConstant: Const.row3LetterKeyWidth(availableWidth: currentKeyboardWidth) * 7
        ).isActive = true
        row.addArrangedSubview(middle)

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
        // Build 98 — collision-proof identifier scheme. Single ASCII
        // lowercase letters stay on `TonoKB.letter.<ch>` (collision-
        // safe parse). Everything else (numbers, punctuation,
        // symbols, currency, multi-scalar) goes to `TonoKB.char.U+…`
        // which has no `.` ambiguity and cannot round-trip through
        // `id.split(separator: ".").last` to the literal `letter`.
        b.accessibilityIdentifier = Const.charId(for: char)
        // Build 98 — pin the raw character on the button itself so
        // any refresh path reads from a non-parser-dependent store.
        b.displayChar = char
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
        b.widthAnchor.constraint(equalToConstant: Const.shiftKeyWidth).isActive = true
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
        if id == "space" {
            spaceButton = b
            attachSpaceCursorGesture(to: b)
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
            documentProxy.insertText(title)
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
        return documentProxy.documentContextBeforeInput ?? ""
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
            return
        }
        // Build 98 — letter-only refresh guard.
        //
        // Build 97's shipping defect: this branch matched
        // `id.hasPrefix("TonoKB.letter.")` for EVERY char, then
        // parsed with `id.split(separator: ".").last`. For the
        // period key the identifier was `"TonoKB.letter."` and the
        // split dropped the trailing empty component, returning
        // the literal substring `"letter"` — which got rendered as
        // the keycap title.
        //
        // Build 98 contract: the title refresh only fires for
        // identifiers that parse to exactly one ASCII lowercase
        // letter. Anything else (numbers, punctuation, symbols,
        // multi-scalar) is a no-op here — its title is whatever
        // `displayLetter` produced at construction time, which is
        // already the correct glyph. We also fall back to the
        // button's pinned `displayChar` if parsing succeeds, so a
        // future identifier rename can't silently re-break the
        // shift path.
        guard let id = b.accessibilityIdentifier,
              id.hasPrefix("TonoKB.letter."),
              let raw = id
                .split(separator: ".", omittingEmptySubsequences: false)
                .last,
              raw.count == 1,
              let scalar = raw.unicodeScalars.first,
              (scalar.value >= 0x61 && scalar.value <= 0x7A) else {
            return
        }
        let ch = String(raw)
        b.setTitle(displayLetter(ch), for: .normal)
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
        let before = documentProxy.documentContextBeforeInput ?? ""
        let after = documentProxy.documentContextAfterInput ?? ""
        guard let token = SpellingToken.current(before: before, after: after, host: currentHostSession) else {
            spellingService.cancel()
            spellingDecision = nil
            spellingToken = nil
            if autocorrectionRecord == nil { updateCandidateStrip(values: []) }
            return
        }
        let request = SpellingRequest(
            token: token,
            host: spellingHostPolicy,
            contextBefore: before
        )
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
                before: self.documentProxy.documentContextBeforeInput ?? "",
                after: self.documentProxy.documentContextAfterInput ?? "",
                host: self.currentHostSession
            )
            guard live == token else { return }
            self.spellingDecision = decision
            self.spellingToken = token
            self.updateCandidateStrip(values: decision?.candidates ?? [token.text])
        }
    }

    /// Render `values` onto the suggestion row.
    ///
    /// Internal, not private, so the XCTest target can drive the REAL strip:
    /// a unit-test controller has no connected host document, so no spelling
    /// pipeline can populate it, and the Build-105 defect lived precisely in
    /// what happened to a populated strip after a Coach toggle. Production
    /// callers are `refreshSpellingSuggestions` and the autocorrect paths.
    func updateCandidateStrip(values: [String]) {
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
            // Neutral candidate style. Build 106 paints tone tokens onto the
            // separate chip row, so a tone color can no longer reach a spelling
            // candidate even transiently.
            button.backgroundColor = .secondarySystemBackground
            button.setTitleColor(.label, for: .normal)
            button.setTitle(value, for: .normal)
            button.accessibilityLabel = isOriginal ? "\(value), original" : value
            button.accessibilityHint = isOriginal
                ? "Keeps or restores the original word"
                : "Replaces the current word"
            // Truthful provenance: every value on this row was produced on
            // device. VoiceOver reads it; it is never sent anywhere.
            button.accessibilityValue = LocalIntelligenceCopy.candidateProvenance
            button.accessibilityTraits = isOriginal ? [.button, .selected] : [.button]
        }
        updateLocalBadge()
    }

    /// Show the on-device indicator whenever the suggestion row is the live row
    /// and is actually offering locally-computed values. It is a statement about
    /// where the computation happened, not a network reachability light, so it
    /// never lies about connectivity.
    private func updateLocalBadge() {
        localBadge?.isHidden = !(stripMode == .suggestions && !candidateValues.isEmpty)
    }

    /// Accept one spelling/autocorrect suggestion.
    ///
    /// This path is local-only by construction: it performs exactly one bounded
    /// document mutation, updates local spelling state, plays the ordinary
    /// input click, and returns. It contains no Coach call, no task creation
    /// and no network I/O — and the routing gate above guarantees a tone chip
    /// can never arrive here, nor a suggestion arrive at `toneChipTapped`.
    @objc private func candidateTapped(_ sender: UIButton) {
        guard let candidate = sender as? TonoStripButton else {
            noteStripRefusal(.roleMismatch)
            return
        }
        let decision = TonoStripRoutingPolicy.decide(
            senderRole: candidate.stripRole,
            handlerRole: .suggestion,
            mode: stripMode,
            index: candidate.stripIndex,
            valueCount: candidateValues.count,
            isBusy: false
        )
        guard case .perform(_, let index) = decision else {
            if case .refuse(let reason) = decision { noteStripRefusal(reason) }
            return
        }
        let value = candidateValues[index]
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
                    before: documentProxy.documentContextBeforeInput ?? "",
                    after: documentProxy.documentContextAfterInput ?? "",
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
            documentProxy.adjustTextPosition(byCharacterOffset: plan.cursorAdvance)
        }
        for _ in 0..<plan.deleteCount { documentProxy.deleteBackward() }
        documentProxy.insertText(plan.insertion)
    }

    private func isSpellingBoundary(_ text: String) -> Bool {
        text == "\n" || text == " " || [".", ",", "?", "!", ";", ":"].contains(text)
    }

    private func validateAutocorrectionRecord() {
        guard let record = autocorrectionRecord else { return }
        let context = documentProxy.documentContextBeforeInput ?? ""
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
        for _ in record.correctedSuffix { documentProxy.deleteBackward() }
        let restored = keepBoundary ? record.restoredText : record.original
        documentProxy.insertText(restored)
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

    /// Space-key activation. This selector remains wired to `.touchUpInside`
    /// so assistive activation (VoiceOver double-tap synthesises a control
    /// event, not raw touches, and therefore bypasses the cursor gesture)
    /// still types a space. Direct touches are owned by the space-cursor
    /// gesture recognizer (`cancelsTouchesInView`), which routes a tap to the
    /// same commit below via the engine's `.insertSpace` effect.
    @objc private func spaceTapped() {
        insertSpaceCommit()
    }

    /// Single source of truth for "insert one space": the Apple double-space
    /// → ". " transform, spelling-boundary commit, and mutation bookkeeping.
    private func insertSpaceCommit() {
        let beforeMutation = effectiveDocumentContextBeforeInput
        let contextSuffix = String(beforeMutation.suffix(8))
        let transformedDoubleSpace = DoubleSpacePolicy.shouldTransform(
            contextSuffix: contextSuffix,
            host: spellingHostPolicy,
            hasPendingAutocorrectionUndo: autocorrectionRecord != nil
        )
        let afterMutation: String
        if transformedDoubleSpace {
            documentProxy.deleteBackward()
            documentProxy.insertText(". ")
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

    // MARK: - Space hold/drag cursor mode

    /// Attach the caret-trackpad gesture to a space key. `minimumPressDuration`
    /// is zero so the engine (not UIKit) owns the tap-vs-hold decision via its
    /// own activation delay; `cancelsTouchesInView` guarantees a direct touch
    /// never also fires the button's `.touchUpInside`, so a tap or a recognized
    /// hold inserts through exactly one path (no double space, no leak).
    private func attachSpaceCursorGesture(to button: UIButton) {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(spaceCursorGesture(_:))
        )
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        button.addGestureRecognizer(recognizer)
    }

    @objc private func spaceCursorGesture(_ recognizer: UILongPressGestureRecognizer) {
        let now = Date()
        let location = recognizer.location(in: view)
        switch recognizer.state {
        case .began:
            beginSpaceCursorSession(now: now, location: location, button: recognizer.view as? UIButton)
        case .changed:
            spaceCursorLastLocation = location
            // The session owns the proxy call. The ONLY proxy operation it can
            // perform is `adjustTextPosition(byCharacterOffset:)` — its protocol
            // has no delete or insert member — so a drag physically cannot
            // remove or add text.
            let dx = Double(location.x - spaceCursorOrigin.x)
            let dy = Double(location.y - spaceCursorOrigin.y)
            _ = spaceCursorSession.drag(translationX: dx, translationY: dy, at: now)
            updateSpaceCursorAffordance()
        case .ended:
            concludeSpaceCursorSession(effect: spaceCursorSession.end(at: now))
        case .cancelled, .failed:
            concludeSpaceCursorSession(effect: spaceCursorSession.cancel())
        default:
            break
        }
    }

    private func beginSpaceCursorSession(now: Date, location: CGPoint, button: UIButton?) {
        // Context is captured by the session at TAKEOVER, not here: capturing at
        // press froze a stale bound that could stop the caret short mid-drag
        // (one of the build-103 device rejections).
        spaceCursorOrigin = location
        spaceCursorLastLocation = location
        if let button { spaceButton = button }
        spaceButton?.isHighlighted = true
        spaceCursorSession.press(at: now)
        scheduleSpaceCursorActivation(after: spaceCursorSession.config.activationDelay)
    }

    private func scheduleSpaceCursorActivation(after delay: TimeInterval) {
        spaceCursorGeneration &+= 1
        let generation = spaceCursorGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.spaceCursorGeneration else { return }
            let effect = self.spaceCursorSession.tick(at: Date())
            if case .enteredCursorMode = effect {
                // Trackpad engaged. Re-base the drag origin to the finger's
                // current position so scrubbing starts from here, and freeze
                // the (now stale) candidate strip for the duration of the drag.
                self.spaceCursorOrigin = self.spaceCursorLastLocation
                self.updateSpaceCursorAffordance()
            }
        }
        spaceCursorActivationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Communicate trackpad mode without covering any system control.
    ///
    /// Deliberately restrained: the space key dims and its title is replaced by
    /// a caret glyph, and the candidate strip announces the mode for VoiceOver.
    /// Nothing is overlaid on the globe/dictation row, no popup is shown, and
    /// the keyboard's height never changes — an overlay there would hide the
    /// system keyboard-switch control.
    private func updateSpaceCursorAffordance() {
        let active = spaceCursorSession.isCursorActive
        guard active != spaceCursorAffordanceActive else { return }
        spaceCursorAffordanceActive = active
        guard let space = spaceButton else { return }
        if active {
            spaceCursorRestoreTitle = space.title(for: .normal)
            space.setTitle("⌷", for: .normal)
            space.accessibilityLabel = "Cursor trackpad active. Drag to move the insertion point."
            space.accessibilityHint = "Slide left or right to move by characters, up or down to change line."
            UIAccessibility.post(notification: .announcement, argument: "Cursor mode")
        } else {
            space.setTitle(spaceCursorRestoreTitle ?? "space", for: .normal)
            space.accessibilityLabel = "Space"
            space.accessibilityHint = nil
            spaceCursorRestoreTitle = nil
        }
        space.isHighlighted = active
    }

    private func cancelSpaceCursorActivation() {
        spaceCursorGeneration &+= 1
        spaceCursorActivationWork?.cancel()
        spaceCursorActivationWork = nil
    }

    private func concludeSpaceCursorSession(effect: SpaceCursorEngine.Effect) {
        cancelSpaceCursorActivation()
        let moved = spaceCursorSession.didMoveCaret
        updateSpaceCursorAffordance()
        spaceButton?.isHighlighted = false
        switch effect {
        case .insertSpace:
            // The ONLY insertion this whole gesture family can produce, and only
            // from a genuine quick tap that never entered cursor mode.
            insertSpaceCommit()
        case .endedCursorMode:
            if moved { resynchronizeAfterCaretMove() }
        case .none, .enteredCursorMode, .moveCaret:
            break
        }
        spaceCursorSession.clearMovementFlag()
    }

    /// Tear down any in-flight space-cursor session without inserting a space.
    /// Called from every lifecycle boundary (mode/appearance/geometry change,
    /// host-field switch, view disappearance) via `cancelTransientInteractions`.
    private func resetSpaceCursorSession() {
        cancelSpaceCursorActivation()
        let wasCursor = spaceCursorSession.isCursorActive
        let moved = spaceCursorSession.didMoveCaret
        if spaceCursorSession.isTracking {
            _ = spaceCursorSession.cancel()
        }
        updateSpaceCursorAffordance()
        spaceButton?.isHighlighted = false
        if wasCursor && moved {
            resynchronizeAfterCaretMove()
        }
        spaceCursorSession.clearMovementFlag()
    }

    /// After the caret is repositioned by the trackpad, the previous keystroke
    /// context is stale. Invalidate caret-dependent async work — spelling
    /// prediction, the Coach request/authorization guard, and any in-flight
    /// deferred document callbacks — then resynchronize UI to the new caret.
    private func resynchronizeAfterCaretMove() {
        // Callers gate on `spaceCursorSession.didMoveCaret`; a hold with no drag
        // never reaches here, so suggestions survive an aborted takeover.
        // New editing position ⇒ new host/editing session. This also drops any
        // Coach authorization captured for the old caret and resets per-field
        // Live Tone state (pure observer).
        advanceHostSession()
        // Invalidate stale prediction + Coach async work.
        spellingService.cancel()
        spellingDecision = nil
        spellingToken = nil
        autocorrectionRecord = nil
        invalidateCoachWork(restoreKeyboard: false)
        // Resynchronize the mutation-tracking generation: no local text change
        // occurred, so any pending mutation / deferred callback is now stale.
        documentMutationGeneration &+= 1
        pendingDocumentMutation = nil
        updateCandidateStrip(values: [])
        // Re-derive context-dependent state at the new caret.
        applyAutoCapitalizationIfNeeded()
        refreshSpellingSuggestions()
    }

    @objc private func quickCharacterTapped(_ sender: UIButton) {
        guard let character = sender.title(for: .normal), !character.isEmpty else { return }
        let beforeMutation = effectiveDocumentContextBeforeInput
        let afterMutation: String
        if isSpellingBoundary(character) {
            afterMutation = commitBoundary(character, contextBeforeInput: beforeMutation)
        } else {
            autocorrectionRecord = nil
            documentProxy.insertText(character)
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
            documentProxy.deleteBackward()
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
            self.documentProxy.deleteBackward()
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
        removeAllCoachSurfaces()

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
        spaceButton = emojiSpace
        attachSpaceCursorGesture(to: emojiSpace)
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
        documentProxy.insertText(emoji)
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
        setToneChipsEnabled(!toneChipsEnabled)
    }

    private func setToneChipsEnabled(_ enabled: Bool) {
        // No flag assignment here by design: `applyStripMode` below is the one
        // authority, and `toneChipsEnabled` reads back out of it. Both branches
        // call it unconditionally, so the role can never be left behind by an
        // early return further down.
        if !enabled {
            // Build 106 made switching back a pure visibility change: the two
            // roles own separate, permanently-targeted rows, so — unlike
            // Build 105 — no repaint can leave a suggestion button wired to
            // `toneChipTapped`. That half needs no undo and gets none.
            //
            // Build 107 closes what Build 106 left behind. Turning Coach off
            // used to fall through the axis assignment above, so the
            // controller kept a populated `selectedToneAxes` and a fully
            // painted, titled, VoiceOver-labelled chip row hidden behind the
            // stack. The single `mode.activeRole == senderRole` check in
            // `TonoStripRoutingPolicy` was then the only thing between that
            // stale row and a network rewrite. Clearing the model and the row
            // makes the refusal over-determined: a dispatch that somehow
            // reached `toneChipTapped` with the mode check broken is still
            // refused by `indexOutOfRange` against an empty `valueCount`.
            selectedToneAxes = []
            clearToneChipRow()
            applyStripMode(.suggestions)
            refreshSpellingSuggestions()
            return
        }
        coachVariantSettings = CoachVariantSettingsStore().load()
        // Safer is the fixed first token; exactly two configured optional
        // tokens follow. No hidden generation — the optional tokens come
        // straight from the persisted device selection, which the store
        // guarantees is exactly two (build-97 contract: Safer + two,
        // legacy 3→2 deterministically migrated). The keyboard chip
        // strip therefore always renders Safer + exactly two user
        // tones — never more, never less.
        let configuredOptional = Array(coachVariantSettings.enabled.prefix(
            CoachVariantSettings.maximumOptionalCount
        ))
        selectedToneAxes = ["safer"] + configuredOptional.map(\.rawValue)
        applyStripMode(.toneChips)
        for (index, view) in (toneChipStack?.arrangedSubviews ?? []).enumerated() {
            guard let button = view as? UIButton else { continue }
            guard index < selectedToneAxes.count else {
                button.setTitle(nil, for: .normal)
                button.isHidden = true
                continue
            }
            button.isHidden = false
            button.setTitle(selectedToneAxes[index].capitalized, for: .normal)
            applyToneTokenStyle(to: button, axis: selectedToneAxes[index])
        }
    }

    /// Undo `applyToneTokenStyle` across the whole chip row: no title, no tone
    /// accent, and no VoiceOver residue of the axis that was showing. Called
    /// only when Coach is switched off, so the hidden row carries no stale tone
    /// state that a later regression could surface or dispatch from.
    private func clearToneChipRow() {
        for view in toneChipStack?.arrangedSubviews ?? [] {
            guard let button = view as? UIButton else { continue }
            button.setTitle(nil, for: .normal)
            button.isHidden = true
            button.backgroundColor = .secondarySystemBackground
            button.setTitleColor(.label, for: .normal)
            button.accessibilityValue = nil
            button.accessibilityLabel = nil
            button.accessibilityHint = nil
            button.accessibilityTraits = [.button]
        }
    }

    /// Paint a tone chip with its canonical tonoit.com semantic token — an
    /// accent-tinted fill plus a contrast-safe label — so the three chips are
    /// visibly color-coded. Falls back to the neutral candidate style for an
    /// unknown axis rather than inventing a color.
    private func applyToneTokenStyle(to button: UIButton, axis: String) {
        button.accessibilityValue = axis
        guard let token = TonoCoachPalette.axis(axis) else {
            button.backgroundColor = .secondarySystemBackground
            button.setTitleColor(.label, for: .normal)
            return
        }
        button.backgroundColor = token.accent.withAlphaComponent(0.18)
        button.setTitleColor(token.accessibleLabel, for: .normal)
        button.accessibilityLabel = "\(token.label) tone"
        button.accessibilityHint = "Rewrites your message in a \(token.label.lowercased()) tone"
        button.accessibilityTraits = [.button]
    }

    @objc private func toneChipTapped(_ sender: UIButton) {
        guard let chip = sender as? TonoStripButton else {
            noteStripRefusal(.roleMismatch)
            return
        }
        let decision = TonoStripRoutingPolicy.decide(
            senderRole: chip.stripRole,
            handlerRole: .toneChip,
            mode: stripMode,
            index: chip.stripIndex,
            valueCount: selectedToneAxes.count,
            isBusy: coachBusy
        )
        guard case .perform(_, let index) = decision else {
            if case .refuse(let reason) = decision { noteStripRefusal(reason) }
            return
        }
        cancelTransientInteractions()
        spellingService.cancel()
        let proxy = documentProxy
        beginCoachRewrite(
            before: proxy.documentContextBeforeInput ?? "",
            after: proxy.documentContextAfterInput ?? "",
            axis: selectedToneAxes[index]
        )
    }

    /// Bind the rewrite target and the lifecycle guard to `before`/`after`,
    /// then issue exactly one request for `axis`. Returns the id of the
    /// request that was started, or nil when there was nothing to rewrite.
    ///
    /// Internal, and taking the document context as parameters, so the XCTest
    /// target can drive the real request lifecycle: a unit-test controller
    /// has no connected host document, so a chip tap can never reach this
    /// path. Every production caller passes the live proxy values.
    @discardableResult
    func beginCoachRewrite(before: String, after: String, axis: String) -> UUID? {
        guard let target = CoachRewriteTarget.capture(
            before: before,
            after: after,
            host: currentHostSession
        ) else {
            presentCoachEmptyState()
            return nil
        }
        coachRewriteTarget = target
        coachRequestGuard = CoachRequestLifecycleGuard(
            before: before,
            after: after,
            host: currentHostSession
        )
        runCoach(draft: target.draft, axis: axis)
        return coachRequestID
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

    // MARK: - Coach surface ownership
    //
    // Loading, results, and error are three presentations of one logical
    // surface: at most one of them may be parented in the body container at
    // any instant. Build 98 removed only the panel the `coachContainer`
    // reference happened to point at, so a rewrite issued from the results
    // state left the stale results panel parented *underneath* the new
    // loading panel — on device the previous rewrite stayed on screen behind
    // the spinner, and every further rewrite added another orphan.

    /// Accessibility identifiers of every coach presentation surface.
    private static let coachSurfaceIdentifiers: Set<String> = [
        Const.idCoachLoading,
        Const.idCoachResults,
        Const.idCoachError,
    ]

    /// Remove every coach surface currently parented in the body container —
    /// not merely the one the tracked reference points at — and drop all
    /// tracked coach view state. Idempotent.
    private func removeAllCoachSurfaces() {
        for surface in bodyContainer?.subviews ?? []
        where Self.coachSurfaceIdentifiers.contains(surface.accessibilityIdentifier ?? "") {
            surface.removeFromSuperview()
        }
        coachContainer?.removeFromSuperview()
        coachErrorContainer?.removeFromSuperview()
        coachContainer = nil
        coachSkeleton = nil
        coachResultsStack = nil
        coachErrorContainer = nil
        coachErrorLabel = nil
        coachLoadingRequestID = nil
    }

    /// Atomically install `panel` as the one and only coach surface: every
    /// prior surface is torn down first, then the new panel is parented and
    /// pinned. `requestID` is non-nil only for a loading surface, recording
    /// which in-flight request owns it.
    private func installCoachSurface(_ panel: UIView, in container: UIView, requestID: UUID? = nil) {
        removeAllCoachSurfaces()
        container.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            panel.topAnchor.constraint(equalTo: container.topAnchor),
            panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        coachContainer = panel
        coachLoadingRequestID = requestID
    }

    /// Decides whether a coach completion may take over the UI. Fail-closed:
    /// honored only when the completion's request is still the active one
    /// *and* the loading surface installed in the container is the one that
    /// request installed. A superseded request, an invalidated session, or a
    /// second delivery after the surface was already replaced is rejected.
    enum CoachCompletionGate {
        static func accepts(
            completion requestID: UUID,
            activeRequestID: UUID?,
            loadingSurfaceRequestID: UUID?
        ) -> Bool {
            guard let activeRequestID, activeRequestID == requestID else { return false }
            return loadingSurfaceRequestID == requestID
        }
    }

    // Internal so the XCTest target can drive the real request path — the
    // busy gate, the loading surface, and the 1:1 request contract — through
    // the same entry point the tap handlers use. Not API surface outside the
    // keyboard module.
    func runCoach(draft: String, axis: String) {
        invalidateCoachWork(restoreKeyboard: false, clearTarget: false)
        cancelTransientInteractions()
        coachBusy = true
        coachRequestsStarted += 1
        coachButton?.isEnabled = false
        let requestID = UUID()
        coachRequestID = requestID
        // Clock: tap. Every downstream phase is measured against this anchor.
        let tapTime = DispatchTime.now()
        coachClockTapTime = tapTime
        presentCoachLoading(requestID: requestID, axis: axis)
        // Clock: loading committed. The skeleton is built synchronously above,
        // before any network work, so this proves the result-shaped surface
        // lands within ~100ms of the tap. Privacy-safe: axis + duration only.
        NSLog("TONO_KB BUILD107 clock: phase=loading axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        NSLog("TONO_KB BUILD95 coach: begin selected variant axis=\(axis) len=\(draft.count)")
        let customPrompt = axis == "custom" ? coachVariantSettings.customInstruction : nil
        coachTask = coachClient.variant(draft: draft, axis: axis, customPrompt: customPrompt) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.completeCoach(
                    requestID: requestID,
                    liveBefore: self.documentProxy.documentContextBeforeInput ?? "",
                    liveAfter: self.documentProxy.documentContextAfterInput ?? "",
                    result: result
                )
            }
        }
        // Clock: request dispatched.
        NSLog("TONO_KB BUILD107 clock: phase=request axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        // Arm the ~10s user-visible deadline (fail-closed; see below).
        scheduleCoachDeadline(requestID: requestID, tapTime: tapTime, axis: axis)
    }

    /// Monotonic elapsed milliseconds since `start`. Privacy-safe: a duration,
    /// never content.
    private static func coachElapsedMs(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }

    /// Emit the terminal render clock. Privacy-safe: durations + the axis
    /// token + outcome + the server-measured provider milliseconds. Never
    /// logs draft text, credentials, or any identifier.
    private func logCoachRenderClock(
        tapTime: DispatchTime?, axis: String?, outcome: String, providerMs: Int?
    ) {
        guard let tapTime else { return }
        let provider = providerMs.map(String.init) ?? "na"
        NSLog(
            "TONO_KB BUILD107 clock: phase=render axis=\(axis ?? "na") outcome=\(outcome) provider_ms=\(provider) dt_ms=\(Self.coachElapsedMs(since: tapTime))"
        )
    }

    /// Arm the ~10s user-visible deadline. Fail-closed: it fires only when the
    /// request is still the active one AND still owns the installed loading
    /// surface — the same gate a completion passes — so it can never overwrite
    /// a newer request's state or a result that already landed. On fire it
    /// cancels the in-flight task (so no late response can reattach) and
    /// installs the truthful timeout error, which offers Retry.
    private func scheduleCoachDeadline(requestID: UUID, tapTime: DispatchTime, axis: String) {
        let work = DispatchWorkItem { [weak self] in
            self?.handleCoachDeadlineFired(requestID: requestID, tapTime: tapTime, axis: axis)
        }
        coachDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Const.coachVisibleDeadline, execute: work)
    }

    /// The visible-deadline body. Internal so the XCTest target can drive the
    /// watchdog synchronously — waiting the real ~10s interval in a unit test
    /// is untenable — through the same fail-closed path the timer fires.
    ///
    /// Fail-closed: honored only when the request is still active AND still
    /// owns the installed loading surface. A superseded request, an
    /// already-delivered result, or an invalidated session is dropped without
    /// touching the surface. On fire it cancels the in-flight task so no late
    /// response can reattach, then installs the truthful timeout error.
    func handleCoachDeadlineFired(requestID: UUID, tapTime: DispatchTime, axis: String) {
        guard CoachCompletionGate.accepts(
                completion: requestID,
                activeRequestID: coachRequestID,
                loadingSurfaceRequestID: coachLoadingRequestID
              ) else { return }
        coachTask?.cancel()
        coachTask = nil
        coachRequestID = nil
        coachBusy = false
        coachButton?.isEnabled = true
        coachDeadline = nil
        NSLog("TONO_KB BUILD107 clock: phase=deadline axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        presentCoachError(.timeout, replacingLoadingFor: requestID)
        coachClockTapTime = nil
    }

    /// Hand one finished round trip to the UI, replacing the loading surface
    /// that this request installed — and nothing else.
    ///
    /// Fail-closed in every ambiguous case: a superseded or cancelled
    /// request, a completion whose loading surface has already been replaced
    /// or torn down, and a draft that moved under the request are all
    /// dropped without touching the surface.
    ///
    /// Internal, and taking the live document context as parameters, so the
    /// XCTest target can drive the real delivery path: a unit-test controller
    /// has no connected host document, so the guard could otherwise never be
    /// exercised. Production passes the live proxy values, read at delivery.
    func completeCoach(
        requestID: UUID,
        liveBefore: String,
        liveAfter: String,
        result: Result<TonoCoachClient.VariantResponse, TonoCoachClient.CoachError>
    ) {
        guard CoachCompletionGate.accepts(
                completion: requestID,
                activeRequestID: coachRequestID,
                loadingSurfaceRequestID: coachLoadingRequestID
              ),
              let target = coachRewriteTarget,
              target.isCurrent(
                liveBefore: liveBefore,
                liveAfter: liveAfter,
                host: currentHostSession
              ) else { return }
        // A real completion landed inside the deadline: disarm the watchdog
        // so it can't fire and clobber the result the user is about to see.
        coachDeadline?.cancel()
        coachDeadline = nil
        let tapTime = coachClockTapTime
        coachTask = nil
        coachRequestID = nil
        coachBusy = false
        coachButton?.isEnabled = true
        // Clock: response received on the main thread.
        if let tapTime {
            NSLog("TONO_KB BUILD107 clock: phase=response dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        }
        switch result {
        case .success(let response):
            let rewrite = TonoCoachClient.CoachRewrite(
                axis: response.axis,
                text: response.text,
                rationale: response.rationale,
                riskAfter: response.riskAfter
            )
            let atomic = TonoCoachClient.CoachResponse(
                riskLevel: response.riskAfter ?? "medium",
                perception: "",
                subtext: "",
                reason: nil,
                suggestions: [rewrite],
                flags: []
            )
            presentCoachResults(atomic, replacingLoadingFor: requestID)
            // Clock: render committed (+ truthful server-measured provider ms).
            logCoachRenderClock(
                tapTime: tapTime, axis: response.axis, outcome: "ok",
                providerMs: response.providerMs
            )
        case .failure(let error):
            presentCoachError(error, replacingLoadingFor: requestID)
            logCoachRenderClock(
                tapTime: tapTime, axis: nil, outcome: "error", providerMs: nil
            )
        }
        coachClockTapTime = nil
    }

    // Internal so the XCTest target can drive the real UIKit loading state
    // through the same entry point the request path uses.
    // This is not API surface outside the keyboard module.
    //
    // Build 107: renders a result-shaped skeleton (title rule + Back
    // placeholder + one accent-bordered rewrite card) instead of the plain
    // "Coaching…" label + `UIActivityIndicatorView`. The whole hierarchy is
    // built synchronously on the main thread; the shimmer is a GPU-driven
    // gradient sweep. `axis` accents the card exactly like the real chip so
    // the loading state previews the specific selected-tone answer. It is
    // optional (default nil → neutral accent) so surface-lifecycle callers
    // that only exercise ownership still compile unchanged.
    func presentCoachLoading(requestID: UUID, axis: String? = nil) {
        // Record ownership before the container check so a controller without
        // a body container still completes its request — and clears its busy
        // state — exactly as it did before surfaces became request-owned.
        coachLoadingRequestID = requestID
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        // Reserve the SAME height the results surface uses so the
        // loading→results transition never resizes the keyboard extension
        // around the host field (stable geometry across the whole flow).
        preferredHeightConstraint?.constant = currentVisualMetrics.coachResultsContentHeight
        keysStack?.removeFromSuperview()
        keysStack = nil
        emojiPanelView?.removeFromSuperview()
        emojiPanelView = nil
        isEmojiPanelVisible = false

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idCoachLoading
        installCoachSurface(panel, in: container, requestID: requestID)

        let accent = TonoCoachPalette.axis(axis ?? "")?.accent ?? .separator
        let skeleton = TonoCoachSkeletonView(accent: accent)
        panel.addSubview(skeleton)
        NSLayoutConstraint.activate([
            skeleton.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: panel.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        skeleton.beginShimmer()
        coachSkeleton = skeleton
    }

    /// Completion entry point: install the results surface only when
    /// `requestID` still owns the loading surface that is installed. Returns
    /// whether the surface was replaced, so a refused delivery — superseded,
    /// duplicate, or invalidated — is observable rather than silent.
    @discardableResult
    func presentCoachResults(
        _ response: TonoCoachClient.CoachResponse,
        replacingLoadingFor requestID: UUID
    ) -> Bool {
        guard coachLoadingRequestID == requestID else { return false }
        presentCoachResults(response)
        return true
    }

    /// Failure counterpart of `presentCoachResults(_:replacingLoadingFor:)`.
    @discardableResult
    func presentCoachError(
        _ err: TonoCoachClient.CoachError,
        replacingLoadingFor requestID: UUID
    ) -> Bool {
        guard coachLoadingRequestID == requestID else { return false }
        presentCoachError(err)
        return true
    }

    // Internal so the XCTest target can exercise the real UIKit results state.
    // This is not API surface outside the keyboard module.
    func presentCoachResults(_ response: TonoCoachClient.CoachResponse) {
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        preferredHeightConstraint?.constant = currentVisualMetrics.coachResultsContentHeight

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idCoachResults
        installCoachSurface(panel, in: container)

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
            text.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -52),
            text.heightAnchor.constraint(equalToConstant: textHeight),
        ])

        let rewriteText = suggestion.text
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(actions)

        let replace = TonoMinimumHitTargetButton(type: .system)
        replace.setTitle("Replace", for: .normal)
        replace.addAction(UIAction { [weak self] _ in
            self?.applyRewrite(rewriteText)
        }, for: .touchUpInside)
        actions.addArrangedSubview(replace)

        let dismiss = TonoMinimumHitTargetButton(type: .system)
        dismiss.setTitle("Dismiss", for: .normal)
        dismiss.addAction(UIAction { [weak self] _ in
            self?.backToKeysTapped()
        }, for: .touchUpInside)
        actions.addArrangedSubview(dismiss)

        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            actions.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
            actions.heightAnchor.constraint(equalToConstant: 44),
        ])
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
        // Build 109. Back is the user-facing teardown of the whole Coach
        // interaction, not merely a view removal, and it is reachable while a
        // rewrite is still in flight (the results panel is shown for the
        // PREVIOUS request while a new one runs, and Retry re-enters from the
        // error surface). Removing the surfaces without invalidating the work
        // left `coachBusy` latched true forever: `coachTapped` guards on
        // `!coachBusy`, so TONO went permanently dead for the rest of the
        // session — and the abandoned `coachTask` and its ~10s deadline stayed
        // armed against a surface that no longer exists.
        //
        // `restoreKeyboard: false` because this function reinstalls the layout
        // itself immediately below; letting `invalidateCoachWork` do it as well
        // would install it twice.
        invalidateCoachWork(restoreKeyboard: false)
        removeAllCoachSurfaces()
        installKeyboardLayout()
    }

    private func applyRewrite(_ rewrite: String) {
        let proxy = documentProxy
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
        coachRequestGuard = nil
        NSLog("TONO_KB BUILD86 rewrite: inserted len=\(rewrite.count) (deleted \(plan.deleteCount))")
    }

    // MARK: - Coach error

    // Internal so the XCTest target can exercise the real UIKit error state.
    // This is not API surface outside the keyboard module.
    func presentCoachError(_ err: TonoCoachClient.CoachError) {
        guard let container = bodyContainer else { return }
        cancelTransientInteractions()
        preferredHeightConstraint?.constant = currentVisualMetrics.preferredContentHeight

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.accessibilityIdentifier = Const.idCoachError
        installCoachSurface(panel, in: container)

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

        coachErrorContainer = panel
        coachErrorLabel = detail
    }

    @objc private func retryTapped() {
        // Tear the error surface down before anything else: a retry that
        // lands on the empty state must not leave the failed attempt behind.
        removeAllCoachSurfaces()
        let proxy = documentProxy
        beginCoachRewrite(
            before: proxy.documentContextBeforeInput ?? "",
            after: proxy.documentContextAfterInput ?? "",
            axis: selectedToneAxes.first ?? "safer"
        )
    }

    // MARK: - Live Tone v1 integration
    //
    // Wired unconditionally (build 96). Formerly gated behind
    // `TONO_BUILD92_HOSTSESSION`, which the TonoTests target defines to
    // activate the host/session suite — so the test build compiled a
    // Live-Tone-stripped keyboard and the shipping integration had zero
    // coverage. Decoupling the two makes the test build and the shipping
    // build run the identical Live Tone path.

    /// Construct + install the Live Tone manager. Called once from
    /// `viewDidLoad` after the keyboard layout is in place. The manager
    /// owns its own indicator view which is added as a passive
    /// subview on top of the keyboard container so the warning never
    /// blocks typing.
    private func installLiveTone() {
        let manager = LiveToneManager()
        // Wire the [Rewrite] button to the existing Coach flow so the
        // user-invoked rewrite surface stays a single tap away. The
        // handler is the only path that opens the rewrite flow; Live
        // Tone never opens it uninvited.
        manager.setRewriteHandler { [weak self] in
            self?.coachTapped()
        }
        if let container = bodyContainer {
            manager.indicator.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(manager.indicator)
            NSLayoutConstraint.activate([
                manager.indicator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                manager.indicator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                manager.indicator.topAnchor.constraint(equalTo: container.topAnchor),
                manager.indicator.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
            ])
        }
        liveToneManager = manager
    }

    /// Observer hook called from `textDidChange(_:)`. Pure observer:
    /// never modifies the document, never blocks the keystroke path,
    /// never opens the rewrite flow. The manager debounces; punctuation
    /// is detected from the post-mutation context's trailing character.
    private func liveToneDidMutate(context: String) {
        guard let manager = liveToneManager else { return }
        let trailing = context.last
        manager.observe(character: trailing ?? " ", draft: context)
        liveToneLastCommittedCharacter = trailing
    }

    /// Test seam: drive the real shipping Live Tone observer path with a
    /// synthetic post-mutation context and return the installed manager so an
    /// integration test can read the engine + indicator it publishes to. This
    /// mirrors exactly what `textDidChange(_:)` forwards; it is never invoked
    /// in production.
    func integrationDriveLiveTone(context: String) -> LiveToneManager? {
        liveToneDidMutate(context: context)
        return liveToneManager
    }
}

/// Shared keycap press treatment. It changes in the same event frame as
/// UIButton's highlighted state and always restores on UIKit cancellation.
private final class KeyboardButton: TonoMinimumHitTargetButton {
    var accessibilityActivationHandler: (() -> Bool)?
    var normalBackgroundColor: UIColor? {
        didSet { if !isHighlighted { backgroundColor = normalBackgroundColor } }
    }

    /// Build 98 — pinned raw character. `makeCharButton` writes the
    /// char here at construction time so any refresh path
    /// (`applyShiftToKey`, future rebuild loops, UI-automation
    /// probes) reads the actual character without having to
    /// round-trip through an identifier parse. See file header for
    /// the build-97 defect this replaces.
    var displayChar: String?

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

// ───────────────────────────────────────────────────────────────────────────
// Space-cursor proxy adapter
// ───────────────────────────────────────────────────────────────────────────

/// Bridges the live `UITextDocumentProxy` to the UIKit-free
/// `SpaceCursorTextProxy` seam that `SpaceCursorSession` drives.
///
/// This adapter is the ENTIRE surface the space cursor has on the host
/// document. It exposes two read-only context properties and exactly one
/// mutating call — `adjustTextPosition(byCharacterOffset:)`. There is no
/// `insertText`, no `deleteBackward`, and no way to reach them from here, which
/// is what makes "cursor mode never deletes" a structural property rather than
/// a convention someone could regress.
///
/// The owner reference is weak: the session outlives individual gestures but
/// must never keep the input view controller alive.
final class SpaceCursorProxyAdapter: SpaceCursorTextProxy {
    /// Typed as `KeyboardViewController`, not `UIInputViewController`, so the
    /// caret path reads and moves through the same `documentProxy` seam as every
    /// other document access. Without this the space-cursor path would bypass
    /// the seam and "a wrapped caret move never mutates text" could not be
    /// observed in a test.
    private weak var owner: KeyboardViewController?

    init(owner: KeyboardViewController) {
        self.owner = owner
    }

    var documentContextBeforeInput: String? {
        owner?.documentProxy.documentContextBeforeInput
    }

    var documentContextAfterInput: String? {
        owner?.documentProxy.documentContextAfterInput
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        owner?.documentProxy.adjustTextPosition(byCharacterOffset: offset)
    }
}
