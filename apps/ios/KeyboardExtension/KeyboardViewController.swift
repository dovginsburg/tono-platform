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

        // Build 111 — connectivity recovery.
        //
        // `coachTimeout` above is the per-request IDLE timeout, which only
        // applies once a connection exists. `coachResourceTimeout` caps the
        // WHOLE lifetime of a request including any time the transport spends
        // parked waiting for connectivity to return, so "Coach waits for the
        // network" is a bounded promise: a prolonged outage still fails.
        static let coachResourceTimeout: TimeInterval = 30
        // The visible deadline once the transport has told us it is waiting.
        // The 10s deadline above is correct for a CONNECTED request and wrong
        // for a parked one — firing it would cancel exactly the task that is
        // about to recover, which is the Build-110 behaviour this build fixes.
        // Sits just past `coachResourceTimeout` so the transport's own
        // truthful error normally lands first; this stays a backstop.
        static let coachOfflineVisibleDeadline: TimeInterval = 33

        // Build 115 — the on-device deadline.
        //
        // A different budget because it bounds a different thing: no connection
        // is involved, so neither the connected 10s nor the parked 33s says
        // anything true about it. Measured on the iOS 26.5 Simulator (Apple M1,
        // Apple Intelligence on): ~10s wall clock for one three-tone structured
        // generation, ~11s cold. 30s is that measurement with room for a longer
        // message and slower hardware, and it is a HARD bound — the request is
        // cancelled and the person is told, exactly as on the connected path.
        //
        // Deliberately not longer than `coachOfflineVisibleDeadline`: a
        // keyboard must not sit on a shimmer for a minute, whichever route it
        // took.
        // Read from `LocalCoachRoutePolicy`, not declared again here. Two
        // literals for one deadline is how a bound and the test that guards it
        // drift apart without anybody noticing.
        static let coachLocalVisibleDeadline: TimeInterval =
            LocalCoachRoutePolicy.visibleDeadlineSeconds
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

        // Build 114 — the three rewrite-card actions and the version cue.
        static let idUseRewrite       = "TonoKB.useRewrite"
        static let idTryAnother       = "TonoKB.tryAnother"
        static let idDismissRewrite   = "TonoKB.dismissRewrite"
        static let idVersionCue       = "TonoKB.versionCue"
        static let idAlternativeNotice = "TonoKB.alternativeNotice"
        static let idVersionBack      = "TonoKB.versionBack"
        static let idVersionForward   = "TonoKB.versionForward"

        // Build 115 — the route badge and the on-device substitution note.
        // The badge states where the rewrites on screen were actually produced.
        // It is set from the delivered result's own route, never from the route
        // that was attempted, so it cannot claim the device for an answer that
        // came over the network.
        static let idCoachRoute       = "TonoKB.coachRoute"
        static let idLocalNote        = "TonoKB.localNote"

        /// The exact customer-visible action labels. Held as constants because
        /// they are a reviewed product contract, not incidental strings: the
        /// Build 114 UI tests assert on these, so renaming one has to be a
        /// deliberate edit here rather than a drive-by in the view code.
        static let useRewriteLabel    = "Use rewrite"
        static let tryAnotherLabel    = "Try another"
        static let dismissLabel       = "Dismiss"
        /// The step-back control. A chevron, not a word, because it sits
        /// beside the "2 of 3" cue where it reads as navigation between
        /// versions rather than as a fourth action.
        static let versionBackLabel   = "‹"
        static let versionForwardLabel = "›"

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
            idToneChips,
            idUseRewrite, idTryAnother, idDismissRewrite, idVersionCue,
            idAlternativeNotice, idVersionBack, idVersionForward,
            idCoachRoute, idLocalNote,
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

    // Build 114 — "Try another". The sequence tracks how many versions have
    // been SUCCESSFULLY DISPLAYED for the current (source message, host, axis);
    // `coachAlternativeRequestID` is the separate in-flight token for an
    // alternative request, which — unlike an initial rewrite — deliberately
    // does NOT install a loading surface, because the contract requires the
    // current card to stay on screen while the next one is fetched.
    private var coachSequence: CoachAlternativeSequence?
    private var coachAlternativeRequestID: UUID?
    /// Retained so a completion can restore or update the card in place.
    private weak var coachTryAnotherButton: UIButton?
    private weak var coachTryAnotherSpinner: UIActivityIndicatorView?
    private weak var coachAlternativeNotice: UILabel?
    /// Build 122 — the notice's rounded, tinted host. Held so show/hide toggles
    /// the whole banner (background + padding), not just the label inside it.
    private weak var coachAlternativeNoticeBanner: UIView?
    private weak var coachVersionBackButton: UIButton?
    private weak var coachVersionForwardButton: UIButton?

    /// Test seam: the version currently displayed and the cap, so a unit test
    /// asserts the real sequence rather than re-deriving it.
    var coachSequenceStateForTesting: (displayed: Int, limit: Int, canRequestAnother: Bool)? {
        guard let coachSequence else { return nil }
        return (
            coachSequence.displayedVersion,
            coachSequence.versionLimit,
            coachSequence.canRequestAnother
        )
    }

    /// Test seam: whether an alternative request is currently in flight.
    var coachAlternativeInFlightForTesting: Bool { coachAlternativeRequestID != nil }

    /// Test seam: the in-flight alternative's token, so a test can deliver to
    /// the exact request the tap created (and prove a second tap made none).
    var alternativeRequestIDForTesting: UUID? { coachAlternativeRequestID }

    /// Test seam: the real teardown, so "cancellation cannot leave Coach
    /// permanently busy" is asserted against production code rather than a
    /// re-enactment of it.
    func invalidateCoachWorkForTesting() {
        invalidateCoachWork(restoreKeyboard: false)
    }
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
    /// Build 111. True once the transport has reported that the ACTIVE request
    /// is parked waiting for connectivity. Two jobs: it widens the visible
    /// deadline (a parked request must not be cancelled by the connected-path
    /// watchdog), and it keeps the terminal error honest — a request that
    /// never got a connection is offline, not "timed out". Reset at every
    /// request boundary, so it can never describe a previous request.
    private var coachWaitingForConnectivity = false

    // MARK: Build 115 — the on-device route
    //
    // The engine the live Coach flow calls. `AppleRewriteBridge.shared` is the
    // production value and the only one that ships; the property is settable and
    // internal solely so a unit test can drive the routing, cancellation,
    // validation and zero-network contracts on a machine where Apple
    // Intelligence may be unavailable. `testShippingDefaultEngineIsTheRealBridge`
    // pins that the default is the real bridge.
    //
    // Resolved on read rather than stored at init: the XCTest target compiles
    // this file into its own module, where a stored-property initialiser cannot
    // name the bridge, and a lazily-resolved default keeps ONE expression of
    // "what ships" instead of a second one behind a compilation condition.
    private var injectedLocalCoachEngine: LocalCoachRewriteEngine?
    var localCoachEngine: LocalCoachRewriteEngine {
        get { injectedLocalCoachEngine ?? Self.productionLocalCoachEngine() }
        set { injectedLocalCoachEngine = newValue }
    }

    /// The shipped engine. One call site, so the binary reachability proof has
    /// exactly one branch to find.
    ///
    /// The compilation condition is a TARGET-GRAPH fact, not a behaviour switch,
    /// and it is worth being explicit about why — Build 96 was burned by exactly
    /// this shape. `TONO_BUILD92_HOSTSESSION` is defined only by TonoTests, which
    /// compiles this file into its OWN module; `AppleRewriteBridge` lives in the
    /// host-app module and its `rewriteSet` takes that module's request type, so
    /// naming it here would not type-check in the XCTest module at all.
    ///
    /// What keeps this from repeating the Build 96 mistake is that it changes no
    /// behaviour the tests could otherwise reach: every behavioural test injects
    /// an engine through `localCoachEngine`, so the default is never the thing
    /// under test. That the SHIPPED default is the real bridge is proved two
    /// other ways — `testTheShippedDefaultEngineIsTheRealBridge` reads this
    /// source, and `Scripts/verify_build115_binary_reachability.py` finds the
    /// branch to `AppleRewriteBridge` in the built Release .appex.
    static func productionLocalCoachEngine() -> LocalCoachRewriteEngine {
        #if TONO_BUILD92_HOSTSESSION
        return UnavailableLocalCoachEngine()
        #else
        return AppleRewriteBridge.shared
        #endif
    }

    /// The in-flight on-device request, so a superseded tap, a host change or a
    /// teardown can cancel it. Cooperative: the service checks `Task.isCancelled`
    /// on both sides of the model call.
    private var coachLocalTask: Task<Void, Never>?

    /// Which route produced what is currently on screen. Written ONLY from a
    /// delivered result — never from an attempt — so the badge cannot claim the
    /// device for a rewrite that came over the network.
    private var coachDeliveredRoute: CoachDeliveredRoute?

    /// The truthful substitution note for the presented set, if any.
    private var coachLocalNote: String?

    /// Why the on-device route declined the ACTIVE request, when it did. Two
    /// jobs: the connected route's error surface can name it, and a request
    /// that turns out to have no connection at all can be re-run locally
    /// instead of dying with "Coach needs internet" on a device that could
    /// have answered.
    private var coachPendingLocalRefusal: LocalCoachUnavailableReason?

    /// Test seam: the reason the on-device route declined the active request.
    var coachLocalRefusalForTesting: String? { coachPendingLocalRefusal?.rawValue }

    /// The request that has already used its one on-device substitution.
    ///
    /// A hard, structural bound rather than a property of the routing rules:
    /// "connected request parks → run it on the device instead" happens AT MOST
    /// ONCE per request, so no combination of policy and transport behaviour
    /// can turn it into a cancel/re-issue loop.
    private var coachSubstitutedRequestID: UUID?

    /// Cached per-process, because probing costs a cross-process hop and the
    /// answer only changes when the OS, the Settings switch or the asset state
    /// changes — none of which happen inside one keyboard presentation. Cleared
    /// at every host-session boundary so a person who turns Apple Intelligence
    /// on in Settings and comes straight back is not told the stale answer.
    private var cachedLocalAvailability: LocalRewriteAvailability?

    // MARK: Build 116 — Stage 2, the tones behind the one that was tapped
    //
    // Stage 1 asks the device for the SELECTED tone alone and renders it. Only
    // once that card is on screen does Stage 2 begin, asking for the remaining
    // tones one at a time and appending each as it lands. The selected card is
    // never moved, rebuilt or replaced by any of this.

    /// Identifies the delivered set the appended cards belong to. Taken fresh
    /// at every Stage 1 delivery and cleared by every teardown, so a Stage 2
    /// answer that arrives after the person moved on fails a plain identity
    /// check rather than needing a rule of its own.
    private var coachSetDeliveryID: UUID?

    /// The in-flight Stage 2 work. ONE task for the whole tail, which is what
    /// makes the generations sequential: it awaits each tone before asking for
    /// the next, so two Foundation Models generations can never overlap.
    private var coachSecondaryTask: Task<Void, Never>?

    /// Bounds Stage 2 in time. It has no visible surface of its own — the
    /// person already has their answer — so nothing else would ever end it if
    /// the model stopped answering.
    private var coachSecondaryDeadline: DispatchWorkItem?

    /// The tones Stage 2 will ask for, in the plan's order.
    private var coachSecondaryPlan: [LocalCoachAxis] = []

    /// The secondary cards actually delivered for the set on screen. Retained
    /// so a version step can put them back: stepping back to the on-device
    /// version 1 restores exactly the set the person was looking at rather than
    /// stranding them on a lone card.
    private var coachSecondaryOptions: [LocalCoachOption] = []

    /// The request that has already been handed to the connected route.
    ///
    /// The contract is "hand off exactly once". Two paths can reach
    /// `startConnectedCoach` for one request — the routing decision and a
    /// recoverable on-device failure — and they are mutually exclusive today.
    /// This makes that a structural fact instead of an argument, so no future
    /// arrangement of those branches can bill the person for two provider calls.
    private var coachHandoffRequestID: UUID?

    /// Build 116 — privacy-safe stage clocks for the request on screen, in
    /// milliseconds from the tap. Durations only; no axis text, no draft, no
    /// identifiers. Read by the acceptance tests so "the skeleton is up before
    /// any model work" and "Stage 1 rendered before Stage 2 started" are
    /// measured against the real controller rather than asserted about it.
    private(set) var coachStageClockMilliseconds: [String: Int] = [:]

    /// Clock keys. Named constants so the log line and the test read the same
    /// spelling.
    enum CoachStageClock {
        static let skeleton = "skeleton"
        static let selectedResult = "selected_result"
        static let secondaryStarted = "secondary_started"
        static let secondaryResult = "secondary_result"
    }

    private func recordStageClock(_ key: String, since start: DispatchTime) {
        coachStageClockMilliseconds[key] = Self.coachElapsedMs(since: start)
    }

    enum CoachDeliveredRoute: String {
        case onDevice
        case connected
    }

    /// Test seam: the route that produced the rewrites on screen.
    var coachDeliveredRouteForTesting: String? { coachDeliveredRoute?.rawValue }

    /// Test seam: whether an on-device request is in flight.
    var coachLocalRequestInFlightForTesting: Bool { coachLocalTask != nil }

    /// Build 116 test seams. Read-only; production never reads them.
    ///
    /// The secondary tones DELIVERED so far, in the order they were appended —
    /// so "the selected card stays first while the rest arrive behind it" is
    /// measured rather than inferred from the view tree alone.
    var coachSecondaryAxesForTesting: [String] { coachSecondaryOptions.map(\.axis.rawValue) }
    /// Whether Stage 2 is still working.
    var coachSecondaryInFlightForTesting: Bool { coachSecondaryTask != nil }
    /// The identity of the delivered set on screen; nil once it is torn down.
    var coachSetDeliveryIDForTesting: UUID? { coachSetDeliveryID }
    /// The request already handed to the connected route, if any.
    var coachHandoffRequestIDForTesting: UUID? { coachHandoffRequestID }
    /// The route recorded against the version currently displayed.
    var coachDisplayedVersionRouteForTesting: String? { coachSequence?.currentRoute }

    /// Test seam: the network client is built lazily and ONLY on the branch
    /// that needs it, so "the successful offline route made zero network calls"
    /// is provable by the strongest available evidence — the URLSession-backed
    /// client was never even constructed.
    var coachNetworkClientWasConstructedForTesting: Bool { storedCoachClient != nil }

    /// Test seam: provider requests actually dispatched, or 0 when no client
    /// was ever built.
    var coachProviderCallCountForTesting: Int { storedCoachClient?.providerCallCount ?? 0 }

    /// Test seam: install a client whose transport a test owns, WITHOUT
    /// constructing the production one. Used by the offline harness to prove
    /// that a local success leaves an injected spy transport at zero requests.
    func installCoachClientForTesting(_ client: TonoCoachClient) {
        storedCoachClient = client
    }

    private var storedCoachClient: TonoCoachClient?

    /// The connected client. Deliberately NOT a `lazy var`: a lazy property is
    /// constructed by the first read from anywhere, which would make "was the
    /// network stack built" unobservable and would let a future refactor build
    /// a URLSession on the on-device path by accident. This form makes the
    /// construction a single, greppable event on exactly one branch.
    private var coachClient: TonoCoachClient {
        if let storedCoachClient { return storedCoachClient }
        let client = Self.makeCoachClient()
        storedCoachClient = client
        return client
    }

    private static func makeCoachClient() -> TonoCoachClient {
        TonoCoachClient(
        endpoint: Const.backendURL.replacingOccurrences(of: "/v1/analyze", with: "/api/analyze/variant"),
        timeout: Const.coachTimeout,
        // Build 111: a dedicated connectivity-aware transport. Build 110 used
        // `URLSession.shared`, whose configuration cannot wait for
        // connectivity, so a tap made with the radio off failed terminally and
        // only a manual Retry could recover. See `CoachTransportPolicy`.
        transport: CoachTransportPolicy(
            waitsForConnectivity: true,
            requestTimeout: Const.coachTimeout,
            resourceTimeout: Const.coachResourceTimeout
        ),
        // Build 96: the bearer token comes from the app's shared Keychain
        // access group. When it is absent the client makes zero network
        // requests and surfaces a visible missing-token state.
        tokenProvider: { SharedKeychain.get(KeychainKeys.apiToken) }
        )
    }

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
        // Build 115 — re-ask the model at every editing-session boundary. This
        // is the point where the person may have just come back from Settings
        // having switched Apple Intelligence on (or off), and answering from a
        // cached probe would tell them the state they left rather than the one
        // they are in. `viewDidAppear` calls this, so returning to the keyboard
        // is enough; no process reload is required.
        cachedLocalAvailability = nil
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
    /// Build 111 test seam: whether the ACTIVE request is parked waiting for
    /// connectivity. Read-only; production never reads it.
    var coachIsWaitingForConnectivityForTesting: Bool { coachWaitingForConnectivity }
    /// Build 111 test seam: the installed loading skeleton, so a test can
    /// assert the surface stays result-shaped AND states the truth while the
    /// transport waits.
    var coachSkeletonForTesting: TonoCoachSkeletonView? { coachSkeleton }
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
        // Build 115: the on-device request is work too, and it is the one kind
        // that keeps running with no transport to cancel it. Cancellation is
        // cooperative — `OnDeviceAppleRewriteService` checks `Task.isCancelled`
        // on both sides of the model call — and the completion additionally
        // fails the same request-identity gate, so a result that arrives after
        // teardown reaches nothing either way.
        coachLocalTask?.cancel()
        coachLocalTask = nil
        // Build 116: Stage 2 is work too, and it is the longest-lived kind —
        // it outlives the request that started it by design, because it runs
        // BEHIND a delivered answer. Every teardown ends it here, so a tone
        // still being written when the person walks away cannot keep the model
        // busy or arrive on somebody else's card.
        cancelSecondaryLocalCoach()
        coachSecondaryPlan = []
        coachSecondaryOptions = []
        coachPendingLocalRefusal = nil
        coachSubstitutedRequestID = nil
        coachHandoffRequestID = nil
        coachDeliveredRoute = nil
        coachLocalNote = nil
        coachRequestID = nil
        coachLoadingRequestID = nil
        coachStageClockMilliseconds = [:]
        // Disarm the visible deadline and drop the clock anchor: a cancelled
        // or superseded request must never leave a watchdog armed against a
        // stale requestID, and must not leak its tap anchor into the next one.
        coachDeadline?.cancel()
        coachDeadline = nil
        coachClockTapTime = nil
        // Build 111: a cancelled or superseded request must never leave its
        // connectivity state describing the next one. Cancellation is final —
        // the task is already cancelled above, so nothing can resume it, and
        // the flag going false means a later deadline cannot claim "offline"
        // on a request that never waited.
        coachWaitingForConnectivity = false
        // Build 114: an in-flight "Try another" is work too. Dropping its token
        // here is what makes teardown terminal for the alternative path — a
        // late completion fails `acceptsAlternative` and cannot revive a
        // surface that is gone, and `coachBusy` cannot latch true behind it.
        coachAlternativeRequestID = nil
        if clearTarget {
            coachRewriteTarget = nil
            coachRequestGuard = nil
            // The sequence belongs to a captured target; without one there is
            // no source message for an alternative to be an alternative OF.
            coachSequence = nil
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

        // TONO is the leading anchor of the strip; the active row reads to its
        // right. Accessibility order matches the visual order.
        //
        // Build 115 removed the six-point green dot that used to sit between
        // TONO and the row. A bare coloured dot is a shape people already read
        // as a status light, so next to a keyboard it invited exactly the
        // reading it could not support — "connected", "recording", "listening".
        // The row's provenance is still stated, where it can be said in words:
        // every suggestion carries `LocalIntelligenceCopy.candidateProvenance`
        // as its accessibility value, and the Coach card carries the route
        // badge. Nothing replaces the dot, and its space goes back to the row.
        bar.accessibilityElements = [coach] + candidates.arrangedSubviews
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
        ]
        // Both rows occupy the identical frame; visibility, not geometry,
        // selects between them. Each now hangs off TONO directly, one
        // `coachSeparation` away — the reviewed minimum, and the same gap the
        // disjointness test measures. The dot used to sit inside that gap and
        // double it; the row is that much wider without it.
        for stack in [candidates, chips] {
            constraints += [
                stack.leadingAnchor.constraint(
                    equalTo: coach.trailingAnchor,
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
        if let bar = topBar, let coach = coachButton {
            let active = showSuggestions ? candidateStack : toneChipStack
            bar.accessibilityElements = [coach] + (active?.arrangedSubviews ?? [])
        }
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
        // Build 114 — sequence identity is (source message, host session,
        // axis). A new captured message resets it; a different tone starts a
        // SEPARATE sequence, so switching tone never inherits the previous
        // tone's remaining budget. Re-tapping the same tone on the same
        // unchanged draft also restarts at 1 of 3, because that is a fresh
        // deliberate request rather than a continuation.
        coachSequence = CoachAlternativeSequence(
            axis: axis,
            sourceDraft: target.draft,
            host: currentHostSession
        )
        coachAlternativeRequestID = nil
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
        // Build 116: the appended secondary cards went with the surface, so the
        // set they belonged to no longer exists. Dropping the identity here —
        // in the one place every surface change goes through — is what makes a
        // late Stage 2 answer unable to attach itself to whatever replaced it.
        coachSetDeliveryID = nil
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
        // Nothing on screen may describe the previous answer's route.
        coachDeliveredRoute = nil
        coachLocalNote = nil
        presentCoachLoading(requestID: requestID, axis: axis)
        // Clock: loading committed. The skeleton is built synchronously above,
        // before any network work, so this proves the result-shaped surface
        // lands within ~100ms of the tap. Privacy-safe: axis + duration only.
        NSLog("TONO_KB BUILD107 clock: phase=loading axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        // Build 116 — recorded, not merely logged, so an acceptance test can
        // measure that the skeleton was up before any model or network work
        // rather than reading a log line and believing it.
        coachStageClockMilliseconds = [:]
        recordStageClock(CoachStageClock.skeleton, since: tapTime)
        NSLog("TONO_KB BUILD95 coach: begin selected variant axis=\(axis) len=\(draft.count)")

        // Build 115 — THE repair. The route is chosen here, before any network
        // object exists, and the on-device branch never reaches `coachClient`,
        // so a successful offline rewrite cannot have made a request: the
        // URLSession-backed client was never constructed.
        //
        // Build 114 went straight to `coachClient.variant(...)` from this line.
        // `KeyboardViewController` — the class `Info.plist` names as the
        // extension's principal class — held no reference to
        // `SystemLanguageModel`, `AppleRewriteBridge` or `OnDeviceAppleRewrite`
        // at all, so with the radio off there was no rewrite to be had.
        //
        // The watchdog is armed HERE, before the availability probe, not inside
        // whichever route wins. The probe is a cross-process hop; if it never
        // answered, a deadline armed only by the route that follows it would
        // never be armed at all, and Coach would sit on a shimmer with no bound.
        // Each route re-arms against its own budget the moment it starts.
        scheduleCoachDeadline(requestID: requestID, tapTime: tapTime, axis: axis)
        resolveLocalAvailability(requestID: requestID) { [weak self] availability in
            self?.startCoachRoute(
                requestID: requestID, draft: draft, axis: axis,
                tapTime: tapTime, availability: availability
            )
        }
    }

    /// Ask the on-device model what it can do, then continue on the main thread.
    ///
    /// Cached per host session because the answer changes only when the OS, the
    /// Apple Intelligence switch or the downloaded assets change — never inside
    /// one keyboard presentation — and an uncached probe would put a
    /// cross-process hop in front of every connected request too.
    /// `advanceHostSession()` clears it, so turning Apple Intelligence on in
    /// Settings and coming straight back is observed rather than remembered.
    private func resolveLocalAvailability(
        requestID: UUID, then continuation: @escaping (LocalRewriteAvailability) -> Void
    ) {
        if let cachedLocalAvailability {
            continuation(cachedLocalAvailability)
            return
        }
        let engine = localCoachEngine
        coachLocalTask = Task { [weak self] in
            let availability = await engine.availability(locale: Locale.current)
            DispatchQueue.main.async {
                guard let self, self.coachRequestID == requestID else { return }
                self.coachLocalTask = nil
                self.cachedLocalAvailability = availability
                continuation(availability)
            }
        }
    }

    /// The one place the local/connected decision is taken.
    private func startCoachRoute(
        requestID: UUID, draft: String, axis: String,
        tapTime: DispatchTime, availability: LocalRewriteAvailability,
        connectivityKnownAbsent: Bool = false
    ) {
        guard coachRequestID == requestID else { return }
        let route = LocalCoachRoutePolicy.decide(
            requestedAxis: axis,
            draft: draft,
            remoteKillSwitchAllows: FeatureFlags.isEnabled(.appleIntelligenceRewriteEnabled),
            preference: LocalRewritePreferenceStore().load(),
            availability: availability,
            saferCorpusGateOpen: FeatureFlags.isEnabled(.appleIntelligenceAllowsSaferRoute),
            connectivityKnownAbsent: connectivityKnownAbsent
        )
        switch route {
        case .local(let plan):
            startLocalCoach(
                requestID: requestID, draft: draft, axis: axis,
                tapTime: tapTime, plan: plan
            )
        case .cloud(let reason):
            startConnectedCoach(
                requestID: requestID, draft: draft, axis: axis,
                tapTime: tapTime, localRefusal: reason
            )
        case .terminal(let reason):
            // Build 116 — the person asked that Tono rewrite only on this
            // iPhone, and this iPhone cannot serve this request. There is no
            // second route to try: ending here IS the promise being kept.
            // Nothing is sent, the draft is untouched, and one sentence says
            // both what went wrong and why nothing was sent.
            endCoachRequestWithoutNetwork(requestID: requestID, axis: axis, reason: reason)
        }
    }

    /// Finish the active request without any network work at all, showing one
    /// truthful terminal sentence.
    ///
    /// Deliberately shaped like `handleCoachDeadlineFired`'s tail rather than
    /// like a new lifecycle: the same fields are cleared, in the same order, so
    /// there is no state a terminal on-device-only refusal can leave behind
    /// that a timeout would not.
    private func endCoachRequestWithoutNetwork(
        requestID: UUID, axis: String, reason: LocalCoachUnavailableReason
    ) {
        guard coachRequestID == requestID else { return }
        NSLog(
            "TONO_KB BUILD116 coach: on-device-only terminal axis=\(axis) reason=\(reason.rawValue)"
        )
        logOnDeviceRoute(
            axis: axis,
            route: "onDeviceOnlyTerminal",
            reason: reason.rawValue,
            availabilityReason: cachedLocalAvailability?.rawValue,
            bytesIn: nil, bytesOut: nil, completionMs: nil
        )
        coachLocalTask?.cancel()
        coachLocalTask = nil
        cancelSecondaryLocalCoach()
        coachDeadline?.cancel()
        coachDeadline = nil
        coachRequestID = nil
        coachBusy = false
        coachWaitingForConnectivity = false
        coachButton?.isEnabled = true
        coachPendingLocalRefusal = nil
        coachClockTapTime = nil
        coachDeliveredRoute = nil
        coachSequence = nil
        presentCoachFailureSurface(
            detail: LocalCoachCopy.onDeviceOnlySentence(for: reason),
            replacingLoadingFor: requestID
        )
    }

    /// Build 116 — Stage 1. Ask the device for the SELECTED tone, alone.
    ///
    /// Touches no network type, by construction. The rest of the plan is parked
    /// in `coachSecondaryPlan` and does not become work until this answer is on
    /// screen, which is the whole of "the selected tone arrives first": there is
    /// no ordering rule to get wrong downstream, because nothing else has been
    /// asked for yet.
    private func startLocalCoach(
        requestID: UUID, draft: String, axis: String,
        tapTime: DispatchTime, plan: LocalCoachPlan
    ) {
        // Privacy: tone names from a closed vocabulary and a character count.
        // Never the message.
        NSLog(
            "TONO_KB BUILD116 coach: on-device stage1 axis=\(axis) primary=\(plan.primaryAxis.rawValue) "
                + "secondary=\(plan.secondaryAxes.count) len=\(draft.count)"
        )
        coachLocalNote = plan.substitutionNote
        coachPendingLocalRefusal = nil
        coachSecondaryPlan = plan.secondaryAxes
        coachSecondaryOptions = []
        let engine = localCoachEngine
        let request = LocalCoachSetRequest(
            draft: draft, axes: [plan.primaryAxis], locale: Locale.current
        )
        coachLocalTask = Task { [weak self] in
            let outcome: Result<LocalCoachSetResult, LocalCoachFailure>
            do {
                outcome = .success(try await engine.rewriteSet(request))
            } catch let declined as LocalCoachFailure {
                outcome = .failure(declined)
            } catch {
                outcome = .failure(LocalCoachFailure(.generationFailed))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.completeLocalCoach(
                    requestID: requestID,
                    draft: draft,
                    axis: axis,
                    tapTime: tapTime,
                    liveBefore: self.documentProxy.documentContextBeforeInput ?? "",
                    liveAfter: self.documentProxy.documentContextAfterInput ?? "",
                    outcome: outcome
                )
            }
        }
        NSLog("TONO_KB BUILD115 clock: phase=on_device_request axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        scheduleCoachDeadline(
            requestID: requestID, tapTime: tapTime, axis: axis,
            after: Const.coachLocalVisibleDeadline
        )
    }

    /// The connected route — Build 114's path, unchanged apart from carrying
    /// the reason the on-device route declined, so the surface can say it.
    private func startConnectedCoach(
        requestID: UUID, draft: String, axis: String,
        tapTime: DispatchTime, localRefusal: LocalCoachUnavailableReason?
    ) {
        guard coachRequestID == requestID else { return }
        // Build 116 — hand off EXACTLY once. Two paths lead here for a single
        // request (the routing decision, and a recoverable on-device failure)
        // and today they are mutually exclusive; this makes that structural, so
        // no future arrangement of those branches can bill one tap twice.
        guard coachHandoffRequestID != requestID else {
            NSLog("TONO_KB BUILD116 coach: refused a second hand-off for one request axis=\(axis)")
            return
        }
        coachHandoffRequestID = requestID
        coachPendingLocalRefusal = localRefusal
        if let localRefusal {
            NSLog("TONO_KB BUILD115 coach: connected axis=\(axis) local_declined=\(localRefusal.rawValue)")
        }
        let customPrompt = axis == "custom" ? coachVariantSettings.customInstruction : nil
        coachTask = coachClient.variant(
            draft: draft,
            axis: axis,
            customPrompt: customPrompt,
            // Build 111: the transport parked this request because the device
            // has no route. Nothing is retried here — the same single task is
            // still in flight and completes by itself when the network is back.
            waitingForConnectivity: { [weak self] in
                self?.handleCoachWaitingForConnectivity(
                    requestID: requestID, tapTime: tapTime, axis: axis
                )
            }
        ) { [weak self] result in
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

    /// Which on-device refusals may be revisited once the transport proves
    /// there is no route.
    ///
    /// Only the two axis-policy refusals. Every other reason is a statement
    /// about the model or the input — an ineligible device, a disabled Apple
    /// Intelligence, an unready model, an unsupported language, a draft that is
    /// too long — and none of those become false just because the network is
    /// also gone. Retrying them would produce the same refusal a second time.
    /// Which on-device refusals say something truer than "Coach needs internet"
    /// once the transport has proved there is no route.
    ///
    /// Exactly one, and only because it is a statement about the person's own
    /// draft that they can act on with the radio still off. Everything else is
    /// either about the model — an ineligible device, an unready model, an
    /// unsupported language — where "no connection" is the more useful of two
    /// true statements because the connected route is genuinely the way out; or
    /// about a draft the cloud can serve better than this iPhone
    /// (`.draftTooLong`), where waiting for a connection IS the next step.
    static func localRefusalOutranksTheOfflineMessage(
        _ reason: LocalCoachUnavailableReason
    ) -> Bool {
        switch reason {
        case .draftTooShort: return true
        default: return false
        }
    }

    static func localSubstitutionIsOffered(for reason: LocalCoachUnavailableReason) -> Bool {
        switch reason {
        case .saferNeedsReview, .customStyleNeedsConnection: return true
        default: return false
        }
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
    private func scheduleCoachDeadline(
        requestID: UUID,
        tapTime: DispatchTime,
        axis: String,
        after interval: TimeInterval = Const.coachVisibleDeadline
    ) {
        // Exactly one watchdog may be armed at a time: re-arming always
        // cancels the previous work item, so the connectivity path below
        // replaces the connected-path deadline rather than racing it.
        coachDeadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleCoachDeadlineFired(requestID: requestID, tapTime: tapTime, axis: axis)
        }
        coachDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Build 111. The transport reported that the active request is parked
    /// waiting for connectivity.
    ///
    /// Three things happen, and nothing else — in particular NO request is
    /// issued, cancelled or replayed here:
    ///
    ///   1. the loading surface stops implying progress and states the truth;
    ///   2. the visible deadline is re-armed against the bounded connectivity
    ///      budget, because the 10s connected-path watchdog would otherwise
    ///      cancel exactly the task that is about to recover;
    ///   3. the terminal error is pre-qualified as offline rather than timeout.
    ///
    /// Fail-closed on the same gate a completion passes, so a notification for
    /// a superseded request cannot touch a newer request's surface. Internal so
    /// the XCTest target can drive it without a live radio.
    func handleCoachWaitingForConnectivity(requestID: UUID, tapTime: DispatchTime, axis: String) {
        guard CoachCompletionGate.accepts(
                completion: requestID,
                activeRequestID: coachRequestID,
                loadingSurfaceRequestID: coachLoadingRequestID
              ) else { return }
        // URLSession may report waiting more than once for one task; the
        // client already de-duplicates, and this is idempotent regardless.
        guard !coachWaitingForConnectivity else { return }
        coachWaitingForConnectivity = true
        NSLog("TONO_KB BUILD111 clock: phase=awaiting_connectivity axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")

        // Build 115 — this notification is the keyboard's ONLY truthful
        // connectivity signal, and it is the transport's own: the request has
        // no route to send on. (A reachability object is banned here for good
        // reason — Build 111 removed the last one.)
        //
        // It is exactly the moment a request that deferred to the connected
        // route can be answered on the device instead. That is what a Safer tap
        // in airplane mode is: Safer keeps its corpus-quality gate, so it went
        // connected on purpose, and without this it would sit on a shimmer and
        // then say "Coach needs internet" on a phone that could have written
        // three rewrites. Nothing is labelled Safer — `LocalCoachRoutePolicy`
        // is asked again with the connectivity fact it did not have before, and
        // it returns the base tones plus a note naming what is missing.
        if let refusal = coachPendingLocalRefusal,
           Self.localSubstitutionIsOffered(for: refusal),
           coachSubstitutedRequestID != requestID,
           let availability = cachedLocalAvailability, availability.isAvailable,
           let target = coachRewriteTarget {
            NSLog("TONO_KB BUILD115 coach: no route — substituting on-device axis=\(axis)")
            coachSubstitutedRequestID = requestID
            // Cancel the parked request FIRST. Nothing is replayed: the one task
            // that existed is cancelled and no second connected one is issued.
            coachTask?.cancel()
            coachTask = nil
            coachWaitingForConnectivity = false
            coachPendingLocalRefusal = nil
            coachDeadline?.cancel()
            coachDeadline = nil
            // Re-identify. Cancelling a URLSession task still delivers a
            // completion, and that completion would pass the gate — it names the
            // request that is still active and still owns the loading surface —
            // and replace the on-device answer with a cancellation error. Taking
            // a fresh identity for the on-device leg makes the dead connected
            // completion fail the same fail-closed gate every other superseded
            // delivery fails, rather than adding a special case for it.
            let localRequestID = UUID()
            coachRequestID = localRequestID
            coachLoadingRequestID = localRequestID
            startCoachRoute(
                requestID: localRequestID, draft: target.draft, axis: axis,
                tapTime: tapTime, availability: availability,
                connectivityKnownAbsent: true
            )
            return
        }

        // Build 115 repair — the local route declined on the DRAFT, and the
        // transport has just proved there is no connection either. "Coach needs
        // internet" would be true and useless: waiting for a connection is not
        // the next step, and the person can act on the real reason right now.
        // Terminal, because no substitution is possible — a message with
        // nothing in it to rewrite is exactly what makes the model invent a
        // reply, which is the defect this refusal exists to prevent.
        if let refusal = coachPendingLocalRefusal,
           Self.localRefusalOutranksTheOfflineMessage(refusal) {
            NSLog("TONO_KB BUILD115 coach: no route — local refusal is the truer answer axis=\(axis) reason=\(refusal.rawValue)")
            coachTask?.cancel()
            coachTask = nil
            coachDeadline?.cancel()
            coachDeadline = nil
            coachRequestID = nil
            coachBusy = false
            coachWaitingForConnectivity = false
            coachButton?.isEnabled = true
            coachPendingLocalRefusal = nil
            coachClockTapTime = nil
            presentLocalCoachRefusal(refusal, replacingLoadingFor: requestID)
            return
        }

        coachSkeleton?.showWaitingForConnection()
        // Re-arm against the remaining connectivity budget, measured from the
        // tap so a late notification cannot extend the bound.
        let elapsed = Double(Self.coachElapsedMs(since: tapTime)) / 1000.0
        let remaining = max(Const.coachOfflineVisibleDeadline - elapsed, 1)
        scheduleCoachDeadline(
            requestID: requestID, tapTime: tapTime, axis: axis, after: remaining
        )
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
        // Build 115: whichever route owns this request, the watchdog ends it.
        // An on-device generation has no transport to cancel it, so the task is
        // cancelled here explicitly; its completion additionally fails the
        // identity gate below, so a late answer reaches nothing either way.
        coachLocalTask?.cancel()
        coachLocalTask = nil
        coachPendingLocalRefusal = nil
        coachRequestID = nil
        coachBusy = false
        coachButton?.isEnabled = true
        coachDeadline = nil
        // Build 111: a request that spent its life parked waiting for a
        // connection did not "time out" — it never got a network. Say the
        // true thing. Both are bounded and both offer Retry.
        let waited = coachWaitingForConnectivity
        coachWaitingForConnectivity = false
        NSLog("TONO_KB BUILD107 clock: phase=deadline axis=\(axis) dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        presentCoachError(waited ? .offline : .timeout, replacingLoadingFor: requestID)
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
        coachWaitingForConnectivity = false
        coachButton?.isEnabled = true
        // Clock: response received on the main thread.
        if let tapTime {
            NSLog("TONO_KB BUILD107 clock: phase=response dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        }
        switch result {
        case .success(let response):
            // Build 114 — this is version 1 of the sequence. Recorded BEFORE
            // rendering so the card's "1 of 3" cue reads the committed state
            // rather than a value the render has to guess.
            if var sequence = coachSequence,
               sequence.matches(
                   axis: response.axis,
                   sourceDraft: target.draft,
                   host: currentHostSession
               ) {
                sequence.recordDisplayed(
                    response.text, route: CoachDeliveredRoute.connected.rawValue
                )
                coachSequence = sequence
            }
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
            // Build 115 — an answer actually arrived over the connection, so
            // the badge may say so. Set here, at delivery, and nowhere earlier.
            coachDeliveredRoute = .connected
            coachLocalNote = nil
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

    // MARK: - Build 115 · on-device delivery

    /// Deliver one on-device result set.
    ///
    /// Fail-closed on exactly the gate the connected path uses, so a superseded
    /// tap, a replaced loading surface or a draft that moved under the request
    /// are all dropped without touching the screen. Internal, and taking the
    /// live document context, so the XCTest target drives the real guard.
    ///
    /// Terminal-versus-recoverable is decided here and nowhere else:
    ///
    ///   * `.cancelled` is silent — something newer already owns the surface.
    ///   * `.guardrail` and `.refusal` are TERMINAL. Apple's model declined this
    ///     specific text; quietly posting the same text to the connected route
    ///     would be routing around a safety decision, so the person is told the
    ///     truth instead.
    ///   * every other failure hands over to the connected route, which is
    ///     honest about connectivity by construction: it parks, says it is
    ///     waiting, and ends in the offline message if no route appears. The
    ///     badge only ever says "checked with Tono" for an answer that landed.
    func completeLocalCoach(
        requestID: UUID,
        draft: String,
        axis: String,
        tapTime: DispatchTime,
        liveBefore: String,
        liveAfter: String,
        outcome: Result<LocalCoachSetResult, LocalCoachFailure>
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
        coachLocalTask = nil

        switch outcome {
        case .success(let result):
            // Stage 1 asked for one tone, so one validated option is what comes
            // back. An empty set cannot reach here — the engine throws
            // `.noValidRewrite` when nothing survives validation — but reading
            // it as an optional means a future engine that returns an empty
            // success degrades into the ordinary recoverable path rather than
            // rendering a card with no text in it.
            guard let selected = result.options.first else {
                startConnectedCoach(
                    requestID: requestID, draft: draft, axis: axis,
                    tapTime: tapTime, localRefusal: .noValidRewrite
                )
                return
            }
            coachDeadline?.cancel()
            coachDeadline = nil
            coachRequestID = nil
            coachBusy = false
            coachWaitingForConnectivity = false
            coachButton?.isEnabled = true
            coachDeliveredRoute = .onDevice
            // Build 116 — the selected tone is version 1 of its own sequence,
            // on this route exactly as on the connected one.
            //
            // Build 115 set `coachSequence = nil` for every local delivery,
            // because a local delivery WAS the whole set: three tones arrived
            // together, so there was no second version to ask for and offering
            // `Try another` would have been offering a control that could not
            // act. Staging removes that reason. The card now holds one tone —
            // the tone that was asked for — and "give me a different wording of
            // this one" is exactly as meaningful here as it is online.
            //
            // The sequence is bound to the tone ON THE CARD, which is the tone
            // that was tapped in every case where it could be served. In the two
            // substitution cases the card is a stand-in and says so, and binding
            // to the tapped tone instead would let `Try another` return a Safer
            // rewrite under a Warmer label.
            var sequence = CoachAlternativeSequence(
                axis: selected.axis.rawValue,
                sourceDraft: target.draft,
                host: currentHostSession
            )
            sequence.recordDisplayed(
                selected.text, route: CoachDeliveredRoute.onDevice.rawValue
            )
            coachSequence = sequence
            coachAlternativeRequestID = nil
            // Privacy: counts and durations. `bytesIn`/`bytesOut` are sizes,
            // not content, and nothing here writes the draft anywhere.
            NSLog(
                "TONO_KB BUILD116 clock: phase=selected_result axis=\(axis) tone=\(selected.axis.rawValue) model_ms=\(Int(result.metrics.completionMilliseconds)) dt_ms=\(Self.coachElapsedMs(since: tapTime))"
            )
            recordStageClock(CoachStageClock.selectedResult, since: tapTime)
            // Build 115 repair — the breadcrumb is LOCAL, and that is the whole
            // point. See `logOnDeviceRoute` for why nothing here may be sent.
            logOnDeviceRoute(
                axis: axis,
                route: "onDevice",
                reason: "success",
                availabilityReason: result.metrics.availabilityReason,
                bytesIn: result.metrics.bytesIn,
                bytesOut: result.metrics.bytesOut,
                completionMs: result.metrics.completionMilliseconds
            )
            presentCoachResults(
                TonoCoachClient.CoachResponse(
                    riskLevel: "medium",
                    perception: "",
                    subtext: "",
                    reason: nil,
                    suggestions: [
                        TonoCoachClient.CoachRewrite(
                            axis: selected.axis.rawValue, text: selected.text,
                            rationale: nil, riskAfter: nil
                        )
                    ],
                    flags: []
                ),
                replacingLoadingFor: requestID
            )
            coachClockTapTime = nil
            // AFTER the render, never before: `presentCoachResults` tears down
            // every prior surface, which clears this identity, so taking it
            // here is what ties the appended cards to the surface they will be
            // appended to.
            let deliveryID = UUID()
            coachSetDeliveryID = deliveryID
            startSecondaryLocalCoach(
                deliveryID: deliveryID, draft: draft, tapTime: tapTime
            )

        case .failure(let declined):
            let reason = declined.reason
            logOnDeviceRoute(
                axis: axis,
                route: "declined",
                reason: reason.rawValue,
                availabilityReason: cachedLocalAvailability?.rawValue,
                bytesIn: draft.utf8.count,
                bytesOut: nil,
                completionMs: nil
            )
            switch reason {
            case .cancelled:
                return
            case .guardrail, .refusal, .rewriteDidNotFinish:
                // Build 115 repair — `.rewriteDidNotFinish` joins the terminal
                // set, for a different reason than the other two.
                //
                // Guardrail and refusal are terminal because re-posting text
                // Apple's model declined would route around a safety decision.
                // `.rewriteDidNotFinish` is terminal because it is the one
                // failure that PROVES the device was writing the answer: the
                // model emitted a partial object and the decode threw. Handing
                // that to the connected route spends the connectivity budget
                // and, in airplane mode, ends on "Coach needs internet" — after
                // ~17–27 s in which this iPhone was producing the rewrite. That
                // sentence would be the most misleading thing the keyboard
                // could say, so the person is told what actually happened and
                // what to do about it instead.
                //
                // The cost, stated: a CONNECTED person loses the cloud rewrite
                // for this class, and on the local route this tap ends here —
                // no rewrite and no hand-off, only the sentence
                // `presentLocalCoachRefusal` shows: "This device ran out of
                // room finishing that rewrite. Try a shorter message."
                //
                // BUILD 117 CORRECTION — this paragraph used to claim "every
                // admitted length is served" and that this "fires only on input
                // that sends the model into a loop". Build 117 measured the
                // shape that actually ships and both claims are false for it.
                // The figures cited (545 / 919 / 996 characters × 3 tones and
                // 749 × 4) are trio and quartet calls; no shipping site issues
                // those. Every user-visible on-device action issues ONE axis,
                // and in that shape — ordinary non-repetitive prose truncated
                // at a WORD boundary, at the 919-character draft
                // `maximumDraftCharacters(forAxisCount: 1)` admits — `clearer`
                // ends HERE, in `.rewriteDidNotFinish`, EVERY time it has been
                // measured: a dozen runs across Debug and Release, none faster
                // than 13.1 s and none slower than 18.1 s, worst margin 1.66x
                // inside the 30 s watchdog. `safer` ends in
                // `noValidRewrite`, which does hand off. That is the ordinary
                // case, not the adversarial one: the adversarial input on
                // record is the MID-word cut, which the B115 record measures at
                // 80 s to `exceededContextWindowSize` uncapped and
                // `decodingFailure` at 27 s capped
                // (`Build115LocalCoachTests.realisticDraft`). Both cuts reach
                // this branch. Measured by
                // `Build115LocalCoachTests.testTheRealModelMeetsTheVisibleDeadlineOnEveryShippingGeneration`.
                //
                // The terminal disposition is retained anyway, on the cap
                // evidence rather than on "every admitted length is served":
                // in the counter-experiment that lifted the response budget to
                // `responseTokenCeiling` (2,048), that same generation ran
                // 45.3 s and STILL ended in `.rewriteDidNotFinish` — past the
                // 30 s watchdog, so the person would have watched a spinner
                // until it was cancelled. Loosening the budget makes this
                // strictly worse. What the watchdog promises is that the person
                // is answered before it fires, and they are: truthfully, with
                // something to do about it, in 13-18 s. The lost cloud rewrite
                // is the price of not lying to them, and it is a bigger price
                // than this comment used to admit.
                coachDeadline?.cancel()
                coachDeadline = nil
                coachRequestID = nil
                coachBusy = false
                coachButton?.isEnabled = true
                coachClockTapTime = nil
                presentLocalCoachRefusal(reason, replacingLoadingFor: requestID)
            default:
                // Hand over. `startConnectedCoach` re-arms the watchdog against
                // the connected budget, and that budget is measured from the
                // original tap — so the on-device attempt cannot buy the
                // connected one extra time.
                startConnectedCoach(
                    requestID: requestID, draft: draft, axis: axis,
                    tapTime: tapTime, localRefusal: reason
                )
            }
        }
    }

    // MARK: - Build 116 · Stage 2 · the tones behind the selected one

    /// Begin Stage 2 for the set just delivered.
    ///
    /// Strictly after Stage 1 has rendered, and strictly one tone at a time.
    /// The single `Task` with an `await` per tone is what makes that true
    /// rather than intended: there is no second task to overlap with, so two
    /// Foundation Models generations cannot be in flight together. (The engine
    /// would refuse the second with `.busy` anyway — but a design that relies
    /// on the callee refusing is a design that produces a visible failure the
    /// first time the callee changes.)
    ///
    /// A warmed session is deliberately NOT reused between tones. `LanguageModelSession`
    /// carries a transcript, so reusing one would feed each tone the previous
    /// tone's answer, and nothing here has measured what that does to the
    /// result. Serializing fresh sessions is the cheaper claim to keep true.
    private func startSecondaryLocalCoach(
        deliveryID: UUID, draft: String, tapTime: DispatchTime
    ) {
        let axes = coachSecondaryPlan
        coachSecondaryPlan = []
        guard !axes.isEmpty else { return }
        NSLog(
            "TONO_KB BUILD116 clock: phase=secondary_started tones=\(axes.count) dt_ms=\(Self.coachElapsedMs(since: tapTime))"
        )
        recordStageClock(CoachStageClock.secondaryStarted, since: tapTime)
        let engine = localCoachEngine
        let locale = Locale.current
        // Bounded in time. Stage 2 has no surface of its own to time out, so
        // without this a model that stopped answering would hold a generation
        // open for the life of the keyboard presentation.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.coachSetDeliveryID == deliveryID else { return }
            NSLog("TONO_KB BUILD116 coach: stage2 deadline — remaining tones abandoned")
            self.cancelSecondaryLocalCoach()
        }
        coachSecondaryDeadline = watchdog
        DispatchQueue.main.asyncAfter(
            // Build 117 — the same expression the timing test bounds itself
            // with, so the watchdog and its guard cannot drift apart.
            deadline: .now() + LocalCoachRoutePolicy.visibleDeadline(
                forGenerations: axes.count
            ),
            execute: watchdog
        )
        coachSecondaryTask = Task { [weak self] in
            for axis in axes {
                if Task.isCancelled { break }
                let outcome: Result<LocalCoachSetResult, LocalCoachFailure>
                do {
                    outcome = .success(try await engine.rewriteSet(
                        LocalCoachSetRequest(draft: draft, axes: [axis], locale: locale)
                    ))
                } catch let declined as LocalCoachFailure {
                    outcome = .failure(declined)
                } catch {
                    outcome = .failure(LocalCoachFailure(.generationFailed))
                }
                if Task.isCancelled { break }
                DispatchQueue.main.async { [weak self] in
                    self?.appendSecondaryLocalCoach(
                        deliveryID: deliveryID, axis: axis,
                        outcome: outcome, tapTime: tapTime
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishSecondaryLocalCoach(deliveryID: deliveryID)
            }
        }
    }

    /// Deliver one Stage 2 tone.
    ///
    /// Fail-closed on the same shape every other completion uses: the set it
    /// belongs to must still be the set on screen, and the draft must still be
    /// the one it was written for. A stale answer returns without touching
    /// anything — it cannot append to a newer set, a version step, an error
    /// surface, or a keyboard the person went back to.
    ///
    /// A Stage 2 FAILURE is silent and terminal for that tone. It must not hand
    /// over to the connected route: the person already has the answer they
    /// asked for, and quietly spending a provider call to fill in an extra they
    /// never requested is exactly the duplicate work the contract forbids.
    private func appendSecondaryLocalCoach(
        deliveryID: UUID,
        axis: LocalCoachAxis,
        outcome: Result<LocalCoachSetResult, LocalCoachFailure>,
        tapTime: DispatchTime
    ) {
        guard coachSetDeliveryID == deliveryID else { return }
        guard let target = coachRewriteTarget,
              target.isCurrent(
                liveBefore: documentProxy.documentContextBeforeInput ?? "",
                liveAfter: documentProxy.documentContextAfterInput ?? "",
                host: currentHostSession
              ) else {
            // The draft moved under the set. Nothing further belongs on this
            // screen, so the remaining tones are abandoned rather than queued
            // up behind a card the person can no longer use.
            cancelSecondaryLocalCoach()
            return
        }
        switch outcome {
        case .success(let result):
            guard let option = result.options.first(where: { $0.axis == axis }) else { return }
            // Two tones that produced the same sentence are one choice. The
            // engine already deduplicates WITHIN a request; staging means each
            // tone is its own request, so the comparison has to happen here as
            // well — against the selected card and every secondary already
            // appended.
            let onScreen = [coachSequence?.currentVersion].compactMap { $0 }
                + coachSecondaryOptions.map(\.text)
            let normalized = LocalCoachValidator.normalizedForNoOp(option.text)
            guard !onScreen.contains(where: {
                LocalCoachValidator.normalizedForNoOp($0) == normalized
            }) else {
                NSLog("TONO_KB BUILD116 coach: stage2 duplicate dropped tone=\(axis.rawValue)")
                return
            }
            coachSecondaryOptions.append(option)
            appendSecondaryRewriteCard(option, index: coachSecondaryOptions.count)
            NSLog(
                "TONO_KB BUILD116 clock: phase=secondary_result tone=\(axis.rawValue) "
                    + "model_ms=\(Int(result.metrics.completionMilliseconds)) "
                    + "dt_ms=\(Self.coachElapsedMs(since: tapTime))"
            )
            recordStageClock(
                "\(CoachStageClock.secondaryResult).\(axis.rawValue)", since: tapTime
            )
            logOnDeviceRoute(
                axis: axis.rawValue,
                route: "onDeviceSecondary",
                reason: "success",
                availabilityReason: result.metrics.availabilityReason,
                bytesIn: result.metrics.bytesIn,
                bytesOut: result.metrics.bytesOut,
                completionMs: result.metrics.completionMilliseconds
            )

        case .failure(let declined):
            // Silent by design. The selected answer is already on screen and
            // unaffected; an extra tone that could not be written is not a
            // failure of anything the person asked for, and putting an error
            // over their result would be.
            NSLog("TONO_KB BUILD116 coach: stage2 tone=\(axis.rawValue) declined=\(declined.reason.rawValue)")
            logOnDeviceRoute(
                axis: axis.rawValue,
                route: "onDeviceSecondaryDeclined",
                reason: declined.reason.rawValue,
                availabilityReason: cachedLocalAvailability?.rawValue,
                bytesIn: nil, bytesOut: nil, completionMs: nil
            )
        }
    }

    private func finishSecondaryLocalCoach(deliveryID: UUID) {
        guard coachSetDeliveryID == deliveryID else { return }
        coachSecondaryTask = nil
        coachSecondaryDeadline?.cancel()
        coachSecondaryDeadline = nil
    }

    /// End Stage 2 now. Idempotent, and safe to call from any teardown.
    private func cancelSecondaryLocalCoach() {
        coachSecondaryTask?.cancel()
        coachSecondaryTask = nil
        coachSecondaryDeadline?.cancel()
        coachSecondaryDeadline = nil
        coachSecondaryPlan = []
    }

    /// Append one secondary card BELOW the selected one.
    ///
    /// Appending to the live stack rather than re-rendering the panel is the
    /// contract, not an optimisation: a re-render would rebuild the selected
    /// card, drop the `Try another` control the person may be reaching for, and
    /// reset the scroll position under their thumb. The card built here is a
    /// SET card — Use rewrite and Dismiss — because a secondary tone is not a
    /// version of the selected one and must not offer to iterate it.
    private func appendSecondaryRewriteCard(_ option: LocalCoachOption, index: Int) {
        guard let stack = coachResultsStack else { return }
        stack.addArrangedSubview(makeRewriteChip(
            suggestion: TonoCoachClient.CoachRewrite(
                axis: option.axis.rawValue, text: option.text,
                rationale: nil, riskAfter: nil
            ),
            index: index,
            offersSequence: false
        ))
    }

    /// The on-device route's ONLY record of itself: a local log line.
    ///
    /// Build 115 as first written called `TonoAnalytics.track` from both arms of
    /// `completeLocalCoach`, and `TonoAnalytics.track` ends in
    /// `URLSession.shared.dataTask(with:).resume()` — a POST to `/v1/events`.
    /// So the delivery path of a feature whose whole promise is "this never
    /// leaves your phone" made an outbound request on every success AND every
    /// failure. The payload carried no message text, so nothing leaked; the
    /// CLAIM leaked, and for a privacy-positioned feature the claim is the
    /// product. The invariant is now true rather than argued: a local route
    /// reaches the URL loading system zero times, and the connected route —
    /// which fires no analytics either — keeps exactly the shape it had.
    ///
    /// What is kept: the same fields, in the same vocabulary, written where
    /// only this device can read them. `NSLog` neither transmits nor persists
    /// beyond the system log, and every value below is an enum name, a byte
    /// COUNT or a duration. No draft, no rewrite, no identifier.
    ///
    /// Deliberately NOT deferred-and-flushed-later either. A queue would mean
    /// writing route records to the App Group from the keyboard and posting
    /// them from the app, which trades a false claim for a durable one; the
    /// route these events describe is the one the person was promised nothing
    /// is collected about.
    private func logOnDeviceRoute(
        axis: String,
        route: String,
        reason: String,
        availabilityReason: String?,
        bytesIn: Int?,
        bytesOut: Int?,
        completionMs: Double?
    ) {
        NSLog(
            "TONO_KB BUILD115 route: axis=\(axis) route=\(route) reason=\(reason) "
                + "availability=\(availabilityReason ?? "unknown") "
                + "bytes_in=\(bytesIn.map(String.init) ?? "-") "
                + "bytes_out=\(bytesOut.map(String.init) ?? "-") "
                + "completion_ms=\(completionMs.map { String(Int($0)) } ?? "-") "
                + "full_access=\(hasFullAccess)"
        )
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

    /// Build 115 — a terminal on-device refusal, said in its own words.
    ///
    /// Routed through the same error surface (one Retry, one Back, one detail
    /// label) so there is still exactly one failure presentation in this
    /// keyboard; only the sentence differs, and it comes from the reviewed
    /// `LocalCoachCopy` table rather than from a failure's own description.
    @discardableResult
    func presentLocalCoachRefusal(
        _ reason: LocalCoachUnavailableReason,
        replacingLoadingFor requestID: UUID
    ) -> Bool {
        guard coachLoadingRequestID == requestID else { return false }
        presentLocalCoachRefusal(reason)
        return true
    }

    /// Internal so the XCTest target can exercise the real UIKit surface for
    /// every reason in the table.
    func presentLocalCoachRefusal(_ reason: LocalCoachUnavailableReason) {
        coachDeliveredRoute = nil
        presentCoachFailureSurface(detail: LocalCoachCopy.sentence(for: reason))
    }

    /// Build 116 — the request-owned form of the one failure surface, so a
    /// terminal on-device-only refusal replaces only the loading surface it
    /// owns. Same gate as every other completion.
    @discardableResult
    func presentCoachFailureSurface(
        detail message: String, replacingLoadingFor requestID: UUID
    ) -> Bool {
        guard coachLoadingRequestID == requestID else { return false }
        presentCoachFailureSurface(detail: message)
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

        // Build 115 — where these words came from, stated on the card.
        //
        // Read from `coachDeliveredRoute`, which is written only by a delivery,
        // so it cannot claim the device for an answer that arrived over the
        // network. Absent (nil) when neither route has delivered — a version
        // step re-presenting text already held, for instance — and then the
        // badge is simply not shown rather than guessed at.
        let route = UILabel()
        route.accessibilityIdentifier = Const.idCoachRoute
        route.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 11, weight: .medium)
        )
        route.adjustsFontForContentSizeCategory = true
        route.textColor = .secondaryLabel
        route.numberOfLines = 1
        route.translatesAutoresizingMaskIntoConstraints = false
        // Build 116 — the route of the VERSION on screen, not of the most
        // recent delivery.
        //
        // A sequence can now be mixed: version 1 written on this iPhone,
        // version 2 fetched from Tono online. `coachDeliveredRoute` remembers
        // the last thing that happened, so stepping back to version 1 would
        // have left "Checked with Tono" over text that never left the device.
        // Reading the route recorded WITH the displayed version makes the badge
        // a fact about what is being looked at. The fallback keeps every
        // pre-existing caller — which records no per-version route — behaving
        // exactly as it did.
        let displayedRoute = coachSequence?.currentRoute
            .flatMap(CoachDeliveredRoute.init(rawValue:)) ?? coachDeliveredRoute
        switch displayedRoute {
        case .onDevice:
            route.text = LocalCoachCopy.onDeviceRouteLabel
            // Build 116 — platform-neutral, for the same reason the visible
            // label is: Tono runs on iPad, and a VoiceOver user is no less
            // entitled to a true sentence than a sighted one.
            route.accessibilityLabel = "Written on this device"
        case .connected:
            route.text = LocalCoachCopy.cloudRouteLabel
            route.accessibilityLabel = "Checked with Tono"
        case nil:
            route.text = nil
            route.isHidden = true
        }
        // The provenance claim must not be the thing that truncates.
        route.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.addSubview(route)

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

        // Build 116 — DELIVERY order, not palette order.
        //
        // Build 115 sorted the cards into `TonoCoachPalette.orderedAxes`, which
        // is fine for a set that arrives all at once and wrong for a set whose
        // first member is the answer: tapping Funnier put Warmer and Clearer
        // above the tone that was actually asked for. The caller now decides
        // the order, and the caller always puts the selected tone first, so the
        // rule is "show them as they were delivered" and there is no second
        // ordering that could disagree with the first.
        //
        // What is kept from the old form: unknown axes are still dropped (they
        // have no label or accent to draw), and a repeated axis still renders
        // once.
        var seenAxes = Set<String>()
        let shown = response.suggestions.filter { suggestion in
            let key = suggestion.axis.lowercased()
            guard TonoCoachPalette.axis(key) != nil else { return false }
            return seenAxes.insert(key).inserted
        }
        // Build 115 — the truthful substitution note, above the cards it
        // qualifies. Present only when the tapped tone is genuinely absent from
        // what follows, so the person is never left to infer that a Safer card
        // is missing because Safer failed.
        if let note = coachLocalNote, !shown.isEmpty {
            let notice = UILabel()
            notice.accessibilityIdentifier = Const.idLocalNote
            notice.text = note
            notice.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
                for: .systemFont(ofSize: 11, weight: .regular)
            )
            notice.adjustsFontForContentSizeCategory = true
            notice.textColor = .secondaryLabel
            notice.numberOfLines = 3
            notice.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(notice)
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
            // A set of tones is not a version sequence. `Try another`, the
            // "2 of 3" cue and the version steppers all describe successive
            // wordings of ONE tone, so a card set must not offer them — every
            // alternative is already on screen.
            //
            // Build 115 repair — this asks whether a SEQUENCE exists, not how
            // many cards there are. Keying on `shown.count == 1` was wrong in
            // exactly one direction, and it was reachable: `validateSet` drops
            // options that are empty, over-long, identical to the draft or
            // duplicates of each other, so a local trio can collapse to a
            // single card (in a 7-draft probe on iOS 26.5, 4 of 7 already
            // collapsed from three options to two — one more drop is one
            // card). `completeLocalCoach` sets `coachSequence = nil` for every
            // local delivery, so that single card got the full sequence UI with
            // no sequence behind it: `applySequencePresentation` hid the cue and
            // both steppers but left `Try another` ENABLED, and
            // `tryAnotherTapped` returns immediately on the same nil. A visible,
            // enabled, inert control — precisely the thing the rule below bans.
            //
            // Every other caller of `presentCoachResults` already binds a
            // non-nil sequence before rendering (`completeCoach`,
            // `completeAlternativeCoach`, both steppers), so the connected path
            // is unchanged by construction rather than by coincidence.
            //
            // Build 116 narrows it one step further: the sequence belongs to
            // the SELECTED card, so only the first card may offer it. Later
            // cards are secondary tones — a different tone is not a different
            // wording of this one — and they now take the set-card path, which
            // never builds a cue, a stepper or a `Try another` at all rather
            // than building them and hiding them.
            let offersSequence = coachSequence != nil
            // Build 122 — the failed-"Try another" banner sits ABOVE the first
            // card, as its own row in the results stack, never inside a card.
            // Built (hidden) only when a version sequence exists, since only
            // "Try another" produces this failure — a set of tones has no such
            // control. It is rebuilt hidden on every render, so a successful new
            // version, a step back/forward, or a fresh Coach run all clear it.
            if offersSequence {
                let banner = makeAlternativeNoticeBanner()
                stack.addArrangedSubview(banner)
                coachAlternativeNoticeBanner = banner
            }
            for (idx, s) in shown.enumerated() {
                stack.addArrangedSubview(makeRewriteChip(
                    suggestion: s, index: idx, offersSequence: offersSequence && idx == 0
                ))
            }
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
            title.heightAnchor.constraint(equalToConstant: titleHeight),

            route.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            route.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            route.trailingAnchor.constraint(lessThanOrEqualTo: back.leadingAnchor, constant: -8),

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

    private func makeRewriteChip(
        suggestion: TonoCoachClient.CoachRewrite, index: Int, offersSequence: Bool = true
    ) -> UIView {
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

        // Build 115 — a card in a multi-tone set gets NO sequence controls at
        // all, rather than hidden ones. Hiding was not enough: the stepper stack
        // was hidden while its two chevrons stayed visible in their own right,
        // and `Try another` sat there enabled with no sequence behind it to do
        // anything with. A control that cannot act must not exist.
        //
        // The connected single-card path is unchanged: `offersSequence` is true
        // for it, and everything below is built exactly as Build 114 built it.
        guard offersSequence else {
            return finishSetRewriteChip(chip, rewriteText: rewriteText)
        }

        // Build 114 — the version cue ("2 of 3"). Truthful by construction: it
        // reads the sequence's successfully-displayed count, so a failed or
        // superseded attempt can never advance it.
        let cue = UILabel()
        cue.accessibilityIdentifier = Const.idVersionCue
        cue.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 11, weight: .semibold)
        )
        cue.adjustsFontForContentSizeCategory = true
        cue.textColor = .secondaryLabel
        cue.textAlignment = .right
        cue.translatesAutoresizingMaskIntoConstraints = false
        cue.setContentCompressionResistancePriority(.required, for: .horizontal)
        chip.addSubview(cue)

        // Build 122 — the failed-"Try another" notice is NOT a subview of this
        // card. A TestFlight screenshot showed it rendered inside the card,
        // where its two lines grew up over the rewrite text and left both
        // unreadable. The owner's rule is that the warning belongs ABOVE the
        // rewrite, never on top of it, so the notice now lives as a dedicated
        // banner in the results stack, one row above this card
        // (see `makeAlternativeNoticeBanner` / `presentCoachResults`).

        // Build 114 contract — the person must never be trapped on a worse
        // second attempt. Every version already generated stays reachable, and
        // `Use rewrite` applies whichever one is on screen, so asking for
        // another costs nothing but the tap.
        //
        // A compact stepper beside the cue rather than two more action buttons:
        // the action row is already three wide in a keyboard-height panel, and
        // moving between versions is navigation, not a peer of
        // "Use rewrite" / "Dismiss".
        //
        // BOTH directions, and that is the whole point. Shipping only the back
        // control made the trap symmetrical rather than fixing it: stepping
        // back to compare version 1 hid the back control (nothing further
        // back), while `Try another` stayed disabled because the generation
        // budget was spent — so version 2 became unreachable and the person was
        // stranded on the rewrite they had just stepped away from. "Either
        // rewrite can be used" requires being able to get back to either one.
        let stepper = UIStackView()
        stepper.axis = .horizontal
        stepper.spacing = 2
        stepper.translatesAutoresizingMaskIntoConstraints = false

        let back = Self.makeVersionStepButton(
            identifier: Const.idVersionBack, title: Const.versionBackLabel
        )
        back.addAction(UIAction { [weak self] _ in
            self?.showPreviousVersionTapped()
        }, for: .touchUpInside)
        stepper.addArrangedSubview(back)

        let forward = Self.makeVersionStepButton(
            identifier: Const.idVersionForward, title: Const.versionForwardLabel
        )
        forward.addAction(UIAction { [weak self] _ in
            self?.showNextVersionTapped()
        }, for: .touchUpInside)
        stepper.addArrangedSubview(forward)

        chip.addSubview(stepper)

        let actions = UIStackView()
        actions.axis = .horizontal
        // Three actions in a keyboard-height panel. `.fillProportionally` with
        // a scaled font lets "Try another" keep its full label at large Dynamic
        // Type sizes instead of truncating to "Try an…", while
        // TonoMinimumHitTargetButton keeps every one of them at the 44pt
        // minimum touch target even when its drawn box is narrower.
        actions.distribution = .fillProportionally
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(actions)

        let use = TonoMinimumHitTargetButton(type: .system)
        use.accessibilityIdentifier = Const.idUseRewrite
        use.setTitle(Const.useRewriteLabel, for: .normal)
        use.titleLabel?.font = UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: .systemFont(ofSize: 14, weight: .semibold)
        )
        use.titleLabel?.adjustsFontForContentSizeCategory = true
        use.titleLabel?.adjustsFontSizeToFitWidth = true
        use.titleLabel?.minimumScaleFactor = 0.75
        use.titleLabel?.lineBreakMode = .byTruncatingTail
        use.accessibilityLabel = Const.useRewriteLabel
        use.accessibilityHint = "Replaces your message with this rewrite"
        use.addAction(UIAction { [weak self] _ in
            self?.applyRewrite(rewriteText)
        }, for: .touchUpInside)
        actions.addArrangedSubview(use)

        let another = TonoMinimumHitTargetButton(type: .system)
        another.accessibilityIdentifier = Const.idTryAnother
        another.setTitle(Const.tryAnotherLabel, for: .normal)
        another.titleLabel?.font = use.titleLabel?.font
        another.titleLabel?.adjustsFontForContentSizeCategory = true
        another.titleLabel?.adjustsFontSizeToFitWidth = true
        another.titleLabel?.minimumScaleFactor = 0.75
        another.titleLabel?.lineBreakMode = .byTruncatingTail
        another.addAction(UIAction { [weak self] _ in
            self?.tryAnotherTapped()
        }, for: .touchUpInside)
        actions.addArrangedSubview(another)

        // The in-card busy indicator. It sits ON the card so the current
        // rewrite stays readable while the next one is fetched — the contract
        // forbids swapping the card out for a full-panel spinner here.
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(spinner)

        let dismiss = TonoMinimumHitTargetButton(type: .system)
        dismiss.accessibilityIdentifier = Const.idDismissRewrite
        dismiss.setTitle(Const.dismissLabel, for: .normal)
        dismiss.titleLabel?.font = use.titleLabel?.font
        dismiss.titleLabel?.adjustsFontForContentSizeCategory = true
        dismiss.titleLabel?.adjustsFontSizeToFitWidth = true
        dismiss.titleLabel?.minimumScaleFactor = 0.75
        dismiss.titleLabel?.lineBreakMode = .byTruncatingTail
        dismiss.accessibilityLabel = Const.dismissLabel
        dismiss.accessibilityHint = "Closes Coach and leaves your message unchanged"
        dismiss.addAction(UIAction { [weak self] _ in
            self?.backToKeysTapped()
        }, for: .touchUpInside)
        actions.addArrangedSubview(dismiss)

        NSLayoutConstraint.activate([
            cue.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            cue.topAnchor.constraint(equalTo: chip.topAnchor, constant: 6),

            stepper.trailingAnchor.constraint(equalTo: cue.leadingAnchor, constant: -4),
            stepper.centerYAnchor.constraint(equalTo: cue.centerYAnchor),
            stepper.leadingAnchor.constraint(greaterThanOrEqualTo: axis.trailingAnchor, constant: 6),

            spinner.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            spinner.centerYAnchor.constraint(equalTo: actions.centerYAnchor),

            actions.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
            actions.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
            actions.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
            actions.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Only the FIRST card (the selected-tone answer) owns the sequence
        // controls. A multi-suggestion response is not a "Try another"
        // sequence, so its later cards keep Use/Dismiss without a cue.
        //
        // Build 115 makes that second half real. Before, the later cards hid
        // their cue and stepper but the first card of a multi-card set still
        // showed an enabled `Try another` with no sequence behind it. A set
        // now returns above, at `finishSetRewriteChip`, before any of these
        // controls is built — so by here there IS a sequence.
        if index == 0 {
            coachTryAnotherButton = another
            coachTryAnotherSpinner = spinner
            coachVersionBackButton = back
            coachVersionForwardButton = forward
            applySequencePresentation(
                cue: cue, tryAnother: another, back: back, forward: forward
            )
        } else {
            cue.isHidden = true
            another.isHidden = true
            stepper.isHidden = true
        }
        return chip
    }

    /// Finish a card that belongs to a SET of tones rather than to a version
    /// sequence: Use rewrite and Dismiss, and nothing that would pretend there
    /// is another version to fetch or step to.
    ///
    /// The two actions and their geometry are the same ones the sequence card
    /// builds, so the person's reach and hit targets do not change between the
    /// on-device and connected answers.
    private func finishSetRewriteChip(
        _ chip: TonoCoachChoiceControl, rewriteText: String
    ) -> UIView {
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.distribution = .fillProportionally
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(actions)

        let use = TonoMinimumHitTargetButton(type: .system)
        use.accessibilityIdentifier = Const.idUseRewrite
        use.setTitle(Const.useRewriteLabel, for: .normal)
        use.titleLabel?.font = UIFontMetrics(forTextStyle: .callout).scaledFont(
            for: .systemFont(ofSize: 14, weight: .semibold)
        )
        use.titleLabel?.adjustsFontForContentSizeCategory = true
        use.titleLabel?.adjustsFontSizeToFitWidth = true
        use.titleLabel?.minimumScaleFactor = 0.75
        use.titleLabel?.lineBreakMode = .byTruncatingTail
        use.accessibilityLabel = Const.useRewriteLabel
        use.accessibilityHint = "Replaces your message with this rewrite"
        use.addAction(UIAction { [weak self] _ in
            self?.applyRewrite(rewriteText)
        }, for: .touchUpInside)
        actions.addArrangedSubview(use)

        let dismiss = TonoMinimumHitTargetButton(type: .system)
        dismiss.accessibilityIdentifier = Const.idDismissRewrite
        dismiss.setTitle(Const.dismissLabel, for: .normal)
        dismiss.titleLabel?.font = use.titleLabel?.font
        dismiss.titleLabel?.adjustsFontForContentSizeCategory = true
        dismiss.titleLabel?.adjustsFontSizeToFitWidth = true
        dismiss.titleLabel?.minimumScaleFactor = 0.75
        dismiss.titleLabel?.lineBreakMode = .byTruncatingTail
        dismiss.accessibilityLabel = Const.dismissLabel
        dismiss.accessibilityHint = "Closes Coach and leaves your message unchanged"
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

    /// One factory for both chevrons, so they cannot drift apart in font,
    /// touch target, or the identifier discipline the UI contract asserts.
    private static func makeVersionStepButton(
        identifier: String, title: String
    ) -> TonoMinimumHitTargetButton {
        let button = TonoMinimumHitTargetButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 13, weight: .semibold)
        )
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// Paint the version cue, the two step controls, and `Try another` from
    /// the sequence.
    ///
    /// At the generation limit `Try another` is DISABLED rather than removed,
    /// and says so in its accessibility label — a control that silently
    /// vanishes leaves a VoiceOver user with no explanation for why the option
    /// is gone. The step controls are hidden rather than disabled, because
    /// there genuinely is nothing in that direction and a permanently dead
    /// chevron is noise.
    private func applySequencePresentation(
        cue: UILabel, tryAnother: UIButton, back: UIButton, forward: UIButton
    ) {
        guard let sequence = coachSequence else {
            // Build 115 repair — defence in depth behind `offersSequence`. With
            // no sequence at all there is nothing for `Try another` to ask for:
            // `tryAnotherTapped` guards on the same nil and returns. Leaving it
            // enabled here is what made the one-option local card offer a dead
            // button, so the nil case now hides the whole control group instead
            // of enabling one member of it.
            cue.isHidden = true
            back.isHidden = true
            forward.isHidden = true
            tryAnother.isHidden = true
            tryAnother.isEnabled = false
            tryAnother.accessibilityLabel = Const.tryAnotherLabel
            return
        }
        guard sequence.displayedVersion > 0 else {
            cue.isHidden = true
            back.isHidden = true
            forward.isHidden = true
            tryAnother.isEnabled = true
            tryAnother.accessibilityLabel = Const.tryAnotherLabel
            return
        }
        let shown = sequence.displayedVersion
        let limit = sequence.versionLimit
        cue.isHidden = false
        cue.text = "\(shown) of \(limit)"
        cue.accessibilityLabel = "Version \(shown) of \(limit)"

        // The rollback affordance appears only once there is something to go
        // back TO, so the first rewrite is not cluttered by a control that
        // would do nothing.
        // Each direction appears only when there is something in it, so the
        // card never shows a control that would do nothing — and, critically,
        // the person can always reach whichever version they are not looking
        // at. At the cap there is no further generation to buy, so these two
        // controls ARE the whole of "either rewrite can be used".
        back.isHidden = !sequence.canGoBack
        back.accessibilityLabel = "Show previous version"
        back.accessibilityHint = "Goes back to version \(max(shown - 1, 1)) so you can use that one instead"

        forward.isHidden = !sequence.canGoForward
        forward.accessibilityLabel = "Show next version"
        forward.accessibilityHint =
            "Returns to version \(min(shown + 1, limit)) so you can use that one instead"

        if sequence.canRequestAnother {
            tryAnother.isEnabled = true
            tryAnother.alpha = 1.0
            tryAnother.accessibilityLabel = Const.tryAnotherLabel
            tryAnother.accessibilityHint = "Asks for a different version of this rewrite"
            tryAnother.accessibilityTraits = [.button]
        } else {
            tryAnother.isEnabled = false
            tryAnother.alpha = 0.5
            tryAnother.accessibilityLabel = "\(Const.tryAnotherLabel), unavailable"
            tryAnother.accessibilityHint =
                "You've seen all \(limit) versions of this rewrite. Use rewrite or Dismiss."
            tryAnother.accessibilityTraits = [.button, .notEnabled]
        }
    }

    private func coachAxisStyle(
        for axis: String
    ) -> (label: String, labelColor: UIColor, accent: UIColor) {
        guard let semantic = TonoCoachPalette.axis(axis) else {
            return (axis.capitalized, .label, .separator)
        }
        return (semantic.label, semantic.accessibleLabel, semantic.accent)
    }

    // MARK: - Build 114 · Try another
    //
    // A deliberately separate request path from `runCoach`. The differences
    // are the whole contract:
    //
    //   * it does NOT install a loading surface — the current rewrite stays on
    //     screen and the busy state is local to its card;
    //   * it carries the versions already shown so the answer is different;
    //   * a failure restores the card exactly as it was and consumes no slot.
    //
    // Everything else is reused verbatim: the same captured target, the same
    // stale-draft guard, the same deadline/cancellation lifecycle, the same
    // consumer-error mapper, the same entitlement rules, and the same
    // one-tap-one-request discipline.

    /// Step back to an already-generated version.
    ///
    /// Build 114 contract — "preserve the first rewrite so the user can choose
    /// either result". Without this, asking for another was a one-way door: a
    /// second attempt the person liked less replaced the one they had, and the
    /// only way back was to start over and spend another generation.
    ///
    /// Costs nothing and requests nothing: it re-presents text already held on
    /// the device. It deliberately does NOT restore a spent slot — the
    /// generation really happened and `canRequestAnother` still counts it —
    /// and it deliberately does NOT touch the rejected context, because
    /// looking at an earlier version again is not un-rejecting it.
    ///
    /// Internal so the XCTest target can drive the real path.
    @objc func showPreviousVersionTapped() {
        // Never mid-flight: the in-card busy state belongs to a request whose
        // answer is about to land, and swapping the card under it would race
        // the completion.
        guard coachAlternativeRequestID == nil, !coachBusy else { return }
        guard var sequence = coachSequence, sequence.canGoBack else { return }
        guard sequence.stepBack() != nil, let text = sequence.currentVersion else { return }
        coachSequence = sequence
        // Re-present through the ordinary results path so the card, the cue and
        // the controls are all rebuilt from the sequence — there is no second
        // rendering path that could disagree with the first.
        presentCoachResults(
            TonoCoachClient.CoachResponse(
                riskLevel: "medium",
                perception: "",
                subtext: "",
                reason: nil,
                suggestions: [
                    TonoCoachClient.CoachRewrite(
                        axis: sequence.axis, text: text, rationale: nil, riskAfter: nil
                    )
                ] + secondaryCardsForDisplayedVersion(),
                flags: []
            )
        )
    }

    /// Build 116 — the secondary tones that belong beside the version now on
    /// screen.
    ///
    /// They belong beside the on-device version 1 and nowhere else, for one
    /// reason: the card carries a SINGLE provenance badge. The secondaries were
    /// written on this iPhone, so showing them under a "Checked with Tono"
    /// badge — which is what an online version 2 must display — would make the
    /// badge false for two of the three cards on screen.
    ///
    /// So asking for a different wording hides them and stepping back brings
    /// them straight back. Nothing is regenerated and nothing is discarded:
    /// `coachSecondaryOptions` still holds the exact text, which is what makes
    /// "preserve the secondary choices" true rather than "re-derive them".
    private func secondaryCardsForDisplayedVersion() -> [TonoCoachClient.CoachRewrite] {
        guard let sequence = coachSequence,
              sequence.displayedVersion == 1,
              sequence.currentRoute == CoachDeliveredRoute.onDevice.rawValue
        else { return [] }
        return coachSecondaryOptions.map {
            TonoCoachClient.CoachRewrite(
                axis: $0.axis.rawValue, text: $0.text, rationale: nil, riskAfter: nil
            )
        }
    }

    /// Step forward to an already-generated version.
    ///
    /// The other half of "either rewrite can be used", and the half that was
    /// missing. Without it, stepping back to compare version 1 was a one-way
    /// trip: the back control hid itself (nothing further back) and
    /// `Try another` was already disabled by the spent generation budget, so
    /// version 2 could not be selected again.
    ///
    /// Exactly the same discipline as stepping back: it re-presents text the
    /// device already holds, requests nothing, spends nothing, and un-rejects
    /// nothing. It is refused mid-flight for the same reason.
    @objc func showNextVersionTapped() {
        guard coachAlternativeRequestID == nil, !coachBusy else { return }
        guard var sequence = coachSequence, sequence.canGoForward else { return }
        guard sequence.stepForward() != nil, let text = sequence.currentVersion else { return }
        coachSequence = sequence
        presentCoachResults(
            TonoCoachClient.CoachResponse(
                riskLevel: "medium",
                perception: "",
                subtext: "",
                reason: nil,
                suggestions: [
                    TonoCoachClient.CoachRewrite(
                        axis: sequence.axis, text: text, rationale: nil, riskAfter: nil
                    )
                ] + secondaryCardsForDisplayedVersion(),
                flags: []
            )
        )
    }

    /// Test seam: which version is on screen, and whether stepping back is
    /// offered — so the rollback contract is asserted against real state.
    var coachVersionCursorForTesting: (displayed: Int, generated: Int, canGoBack: Bool)? {
        guard let coachSequence else { return nil }
        return (
            coachSequence.displayedVersion,
            coachSequence.generatedCount,
            coachSequence.canGoBack
        )
    }

    /// Test seam: the text currently on the card.
    var coachDisplayedVersionForTesting: String? { coachSequence?.currentVersion }

    /// Internal so the XCTest target can drive the real path; the tap handler
    /// calls exactly this.
    @objc func tryAnotherTapped() {
        // One user action = one request. A second tap while the first is in
        // flight is dropped here rather than de-duplicated downstream, so no
        // duplicate request is ever issued.
        guard coachAlternativeRequestID == nil, !coachBusy else { return }
        guard let sequence = coachSequence, sequence.canRequestAnother else { return }
        guard let target = coachRewriteTarget else { return }
        // The draft must still be the one this sequence belongs to. A changed
        // host document means the sequence is stale: refuse rather than
        // generating an alternative for text the person no longer has.
        //
        // The axis argument is the sequence's own, and deliberately so: a tone
        // change goes through `runCoach`, which builds a FRESH sequence, so the
        // axis cannot have drifted by the time this runs. The two facts that
        // can have changed — the captured draft and the host session — are the
        // ones this guard is actually asking about.
        guard sequence.matches(
            axis: sequence.axis,
            sourceDraft: target.draft,
            host: currentHostSession
        ) else {
            presentCoachError(.staleDraft)
            return
        }

        // Build 116 — Stage 2 is superseded by this tap. The tones still being
        // written belong beside version 1; an alternative replaces version 1,
        // so a tone that landed afterwards would attach itself to a card it was
        // never generated for.
        cancelSecondaryLocalCoach()

        let requestID = UUID()
        coachAlternativeRequestID = requestID
        coachBusy = true
        coachButton?.isEnabled = false
        beginAlternativeBusyPresentation()

        let tapTime = DispatchTime.now()
        coachClockTapTime = tapTime
        let axis = sequence.axis

        // Build 116 — the person's explicit on-device-only choice binds here
        // too, and this is the branch that proves it.
        //
        // `Try another` is the ONE control in this keyboard that reaches the
        // network on a route that otherwise never does. Somebody who asked that
        // Tono rewrite only on this iPhone must not have their draft posted
        // because they tapped a button labelled "Try another" — so the request
        // is asked of the device instead, with the wording they just turned
        // down carried in the prompt so the model has something to differ from.
        if LocalRewritePreferenceStore().load().prohibitsNetwork {
            requestLocalAlternative(requestID: requestID, sequence: sequence, target: target)
            return
        }

        let customPrompt = axis == "custom" ? coachVariantSettings.customInstruction : nil
        NSLog(
            "TONO_KB BUILD114 coach: try-another axis=\(axis) version=\(sequence.displayedVersion + 1) of \(sequence.versionLimit)"
        )
        coachTask = coachClient.variant(
            draft: target.draft,
            axis: axis,
            customPrompt: customPrompt,
            priorVersions: sequence.priorVersions,
            waitingForConnectivity: { [weak self] in
                self?.handleAlternativeWaitingForConnectivity(requestID: requestID)
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.completeCoachAlternative(
                    requestID: requestID,
                    liveBefore: self.documentProxy.documentContextBeforeInput ?? "",
                    liveAfter: self.documentProxy.documentContextAfterInput ?? "",
                    result: result
                )
            }
        }
        scheduleAlternativeDeadline(requestID: requestID, tapTime: tapTime, axis: axis)
        // Nothing is written back to `coachSequence` here. A version is
        // consumed only when one is actually delivered and displayed, in
        // `completeCoachAlternative` — so a failed, timed-out, cancelled or
        // superseded request costs the person nothing.
    }

    /// Build 116 — one `Try another`, answered by the device, for a person who
    /// has ruled the connected route out.
    ///
    /// Everything the connected alternative guarantees is guaranteed here, and
    /// for the same reasons: the current card stays on screen and readable, no
    /// loading surface is installed, exactly one generation is issued, and a
    /// failure — including the failure where the device simply writes the same
    /// sentence again — restores the card and consumes no allowance.
    ///
    /// It is honest about its own odds. Greedy sampling on an unchanged prompt
    /// is deterministic, so the ONLY thing that can make this differ from
    /// version 1 is the prompt itself: the rejected wording travels with it and
    /// the instructions ask for a materially different one. When the model
    /// ignores that, `LocalCoachValidator` drops the repeat and the person is
    /// told plainly that this iPhone writes this one the same way every time —
    /// which is a truthful answer, and better than a second identical card
    /// numbered "2 of 2".
    private func requestLocalAlternative(
        requestID: UUID, sequence: CoachAlternativeSequence, target: CoachRewriteTarget
    ) {
        guard let axis = LocalCoachAxis(rawValue: sequence.axis) else {
            // The card is a tone the local route cannot write — it can only
            // have arrived over the connection, which this person has ruled
            // out. Nothing to ask, and nothing untrue to say about it.
            coachAlternativeRequestID = nil
            coachBusy = false
            coachButton?.isEnabled = true
            coachClockTapTime = nil
            endAlternativeBusyPresentation(
                notice: LocalCoachCopy.onDeviceOnlySentence(for: .toneNeedsConnection)
            )
            return
        }
        NSLog(
            "TONO_KB BUILD116 coach: try-another on-device axis=\(axis.rawValue) "
                + "version=\(sequence.displayedVersion + 1) of \(sequence.versionLimit)"
        )
        let engine = localCoachEngine
        let request = LocalCoachSetRequest(
            draft: target.draft,
            axes: [axis],
            locale: Locale.current,
            rejectedVersions: sequence.priorVersions
        )
        coachLocalTask = Task { [weak self] in
            let outcome: Result<LocalCoachSetResult, LocalCoachFailure>
            do {
                outcome = .success(try await engine.rewriteSet(request))
            } catch let declined as LocalCoachFailure {
                outcome = .failure(declined)
            } catch {
                outcome = .failure(LocalCoachFailure(.generationFailed))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.completeLocalCoachAlternative(
                    requestID: requestID,
                    liveBefore: self.documentProxy.documentContextBeforeInput ?? "",
                    liveAfter: self.documentProxy.documentContextAfterInput ?? "",
                    outcome: outcome
                )
            }
        }
        scheduleAlternativeDeadline(
            requestID: requestID, tapTime: coachClockTapTime ?? .now(),
            axis: axis.rawValue, after: Const.coachLocalVisibleDeadline
        )
    }

    /// Deliver one on-device alternative. Internal, and taking the live document
    /// context, so the XCTest target drives the real guard.
    ///
    /// Shares `endAlternativeBusyPresentation` and the sequence rules with the
    /// connected alternative, so the two cannot drift on what a failure costs.
    func completeLocalCoachAlternative(
        requestID: UUID,
        liveBefore: String,
        liveAfter: String,
        outcome: Result<LocalCoachSetResult, LocalCoachFailure>
    ) {
        guard acceptsAlternative(requestID) else { return }
        coachLocalTask = nil
        guard let target = coachRewriteTarget,
              target.isCurrent(
                liveBefore: liveBefore, liveAfter: liveAfter, host: currentHostSession
              ) else {
            coachAlternativeRequestID = nil
            coachBusy = false
            coachButton?.isEnabled = true
            coachDeadline?.cancel()
            coachDeadline = nil
            endAlternativeBusyPresentation(notice: nil)
            presentCoachError(.staleDraft)
            return
        }
        coachDeadline?.cancel()
        coachDeadline = nil
        coachAlternativeRequestID = nil
        coachBusy = false
        coachButton?.isEnabled = true

        switch outcome {
        case .success(let result):
            guard var sequence = coachSequence,
                  let option = result.options.first,
                  sequence.recordDisplayed(
                    option.text, route: CoachDeliveredRoute.onDevice.rawValue
                  )
            else {
                // Either nothing usable came back or it repeats what is already
                // on the card. No slot consumed, card untouched, one sentence.
                //
                // Both arrive here for the same underlying reason, which is why
                // they share a sentence: the ONLY thing that differed between
                // this request and the one that produced version 1 was the
                // rejected wording travelling with it, so "nothing survived
                // validation" on an alternative means the model wrote the same
                // thing again and the validator dropped it. Saying "nothing
                // usable came back" here would suggest something is broken; the
                // truth is narrower and more useful.
                endAlternativeBusyPresentation(
                    notice: LocalCoachCopy.sentence(for: .noLocalAlternative)
                )
                return
            }
            coachSequence = sequence
            coachDeliveredRoute = .onDevice
            logOnDeviceRoute(
                axis: option.axis.rawValue,
                route: "onDeviceAlternative",
                reason: "success",
                availabilityReason: result.metrics.availabilityReason,
                bytesIn: result.metrics.bytesIn,
                bytesOut: result.metrics.bytesOut,
                completionMs: result.metrics.completionMilliseconds
            )
            presentCoachResults(
                TonoCoachClient.CoachResponse(
                    riskLevel: "medium",
                    perception: "",
                    subtext: "",
                    reason: nil,
                    suggestions: [
                        TonoCoachClient.CoachRewrite(
                            axis: option.axis.rawValue, text: option.text,
                            rationale: nil, riskAfter: nil
                        )
                    ] + secondaryCardsForDisplayedVersion(),
                    flags: []
                )
            )
        case .failure(let declined):
            // No slot consumed; version 1 is still on the card behind this.
            // `.cancelled` alone is silent — something newer already owns the
            // surface — and matches the initial route's treatment of it.
            guard declined.reason != .cancelled else { return }
            // `.noValidRewrite` on an ALTERNATIVE is the same fact as the guard
            // above, arriving from the engine instead of from the sequence: the
            // model wrote the same wording again and validation dropped it.
            // Told as itself rather than as a generic failure.
            let reason: LocalCoachUnavailableReason =
                declined.reason == .noValidRewrite ? .noLocalAlternative : declined.reason
            endAlternativeBusyPresentation(
                notice: reason == .noLocalAlternative
                    ? LocalCoachCopy.sentence(for: reason)
                    : LocalCoachCopy.onDeviceOnlySentence(for: reason)
            )
        }
        coachClockTapTime = nil
    }

    private func beginAlternativeBusyPresentation() {
        hideAlternativeNotice()
        coachTryAnotherSpinner?.startAnimating()
        if let button = coachTryAnotherButton {
            button.isEnabled = false
            button.alpha = 0.5
            button.accessibilityLabel = "\(Const.tryAnotherLabel), working"
            button.accessibilityTraits = [.button, .notEnabled]
        }
    }

    /// Restore the card to exactly the state it had before the tap. Called on
    /// every non-success path, so a failed alternative never leaves the card
    /// stuck busy and never disturbs the rewrite already displayed.
    private func endAlternativeBusyPresentation(notice: String?) {
        coachTryAnotherSpinner?.stopAnimating()
        if let button = coachTryAnotherButton {
            let canRetry = coachSequence?.canRequestAnother ?? false
            button.isEnabled = canRetry
            button.alpha = canRetry ? 1.0 : 0.5
            button.accessibilityLabel = canRetry
                ? Const.tryAnotherLabel
                : "\(Const.tryAnotherLabel), unavailable"
            button.accessibilityTraits = canRetry ? [.button] : [.button, .notEnabled]
        }
        if let notice {
            showAlternativeNotice(notice)
        }
    }

    /// Build 122 — reveal the failed-"Try another" banner above the first card
    /// and announce it. It is a peer row of the rewrite, never a subview of it,
    /// so it cannot overlap the rewrite text at any Dynamic Type size. The
    /// warning is tied to the control that failed (`accessibilityValue` on
    /// "Try another") so VoiceOver reads them as one thing, and a layout-changed
    /// post moves focus to the banner the moment it appears.
    private func showAlternativeNotice(_ text: String) {
        coachAlternativeNotice?.text = text
        coachAlternativeNoticeBanner?.isHidden = false
        coachTryAnotherButton?.accessibilityValue = text
        if let banner = coachAlternativeNoticeBanner {
            UIAccessibility.post(notification: .layoutChanged, argument: banner)
        }
    }

    /// Build 122 — hide the banner and sever its VoiceOver tie to "Try another".
    /// Called before a retry and by every teardown, so a stale offline warning
    /// never rides along on the next attempt or the next Coach run.
    private func hideAlternativeNotice() {
        coachAlternativeNoticeBanner?.isHidden = true
        coachAlternativeNotice?.text = nil
        coachTryAnotherButton?.accessibilityValue = nil
    }

    /// Build 122 — the failed-"Try another" banner: a compact, high-contrast,
    /// rounded row that hosts the warning ABOVE the first rewrite card. Returns
    /// the container (hidden) and captures its inner label in
    /// `coachAlternativeNotice`. The label wraps freely (`numberOfLines = 0`) and
    /// the container hugs its content vertically, so the text is always fully
    /// readable — at the default size and at accessibility Dynamic Type — and it
    /// can never sit on top of the rewrite, because it is a sibling row, not a
    /// subview of the card.
    private func makeAlternativeNoticeBanner() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.22)
        container.layer.cornerRadius = Const.keyCornerRadius
        container.isHidden = true
        container.accessibilityIdentifier = "\(Const.idAlternativeNotice).banner"

        let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isAccessibilityElement = false

        let label = UILabel()
        label.accessibilityIdentifier = Const.idAlternativeNotice
        // High contrast: primary label color and a semibold caption, not the
        // secondary-label whisper the in-card note used.
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .semibold)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            icon.topAnchor.constraint(equalTo: label.firstBaselineAnchor, constant: -11),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        coachAlternativeNotice = label
        return container
    }

    /// The alternative path's fail-closed gate. Unlike the initial request it
    /// cannot key on the loading surface (there deliberately isn't one), so it
    /// keys on the alternative token alone — which a teardown clears.
    private func acceptsAlternative(_ requestID: UUID) -> Bool {
        coachAlternativeRequestID == requestID
    }

    func handleAlternativeWaitingForConnectivity(requestID: UUID) {
        guard acceptsAlternative(requestID) else { return }
        guard !coachWaitingForConnectivity else { return }
        coachWaitingForConnectivity = true
        showAlternativeNotice(TonoCoachClient.CoachError.offline.userFacingMessage)
    }

    private func scheduleAlternativeDeadline(
        requestID: UUID,
        tapTime: DispatchTime,
        axis: String,
        after interval: TimeInterval = Const.coachVisibleDeadline
    ) {
        coachDeadline?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.handleAlternativeDeadlineFired(requestID: requestID, tapTime: tapTime)
        }
        coachDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    /// Internal so a unit test can fire the watchdog synchronously.
    func handleAlternativeDeadlineFired(requestID: UUID, tapTime: DispatchTime) {
        guard acceptsAlternative(requestID) else { return }
        coachTask?.cancel()
        coachTask = nil
        // Build 116: an on-device alternative has no transport to cancel it, so
        // the watchdog ends it explicitly — the same treatment the initial
        // on-device route already gets.
        coachLocalTask?.cancel()
        coachLocalTask = nil
        coachAlternativeRequestID = nil
        coachBusy = false
        coachButton?.isEnabled = true
        coachDeadline = nil
        let waited = coachWaitingForConnectivity
        coachWaitingForConnectivity = false
        NSLog("TONO_KB BUILD114 clock: phase=alt_deadline dt_ms=\(Self.coachElapsedMs(since: tapTime))")
        // No slot consumed, prior card intact.
        endAlternativeBusyPresentation(
            notice: (waited
                ? TonoCoachClient.CoachError.offline
                : TonoCoachClient.CoachError.timeout).userFacingMessage
        )
        coachClockTapTime = nil
    }

    /// Deliver one alternative. Internal, and taking the live document context,
    /// so the XCTest target drives the real guard.
    func completeCoachAlternative(
        requestID: UUID,
        liveBefore: String,
        liveAfter: String,
        result: Result<TonoCoachClient.VariantResponse, TonoCoachClient.CoachError>
    ) {
        // Superseded / cancelled / already-delivered: drop silently. The card
        // on screen belongs to whatever replaced this request.
        guard acceptsAlternative(requestID) else { return }
        // The draft moved under the request — refuse rather than showing an
        // alternative for text that is no longer there.
        guard let target = coachRewriteTarget,
              target.isCurrent(
                liveBefore: liveBefore,
                liveAfter: liveAfter,
                host: currentHostSession
              ) else {
            coachAlternativeRequestID = nil
            coachBusy = false
            coachButton?.isEnabled = true
            coachDeadline?.cancel()
            coachDeadline = nil
            endAlternativeBusyPresentation(notice: nil)
            presentCoachError(.staleDraft)
            return
        }

        coachDeadline?.cancel()
        coachDeadline = nil
        let tapTime = coachClockTapTime
        coachTask = nil
        coachAlternativeRequestID = nil
        coachBusy = false
        coachWaitingForConnectivity = false
        coachButton?.isEnabled = true

        switch result {
        case .success(let response):
            guard var sequence = coachSequence else { return }
            // A provider that returned what we already showed has produced no
            // new version. Record nothing, keep the card, and say so plainly —
            // the bounded retry already happened server-side, so looping here
            // would be exactly the retry storm the contract forbids.
            guard sequence.recordDisplayed(
                response.text, route: CoachDeliveredRoute.connected.rawValue
            ) else {
                endAlternativeBusyPresentation(
                    notice: "That's the same wording. Try a different tone, or use this one."
                )
                logCoachRenderClock(
                    tapTime: tapTime, axis: response.axis, outcome: "duplicate",
                    providerMs: response.providerMs
                )
                coachClockTapTime = nil
                return
            }
            coachSequence = sequence
            // Build 116 — an answer arrived over the connection, so the badge
            // may say so. Set at delivery and nowhere earlier, exactly as the
            // initial connected route sets it. Before this, a version 2 fetched
            // online after an on-device version 1 inherited the on-device badge.
            coachDeliveredRoute = .connected
            let rewrite = TonoCoachClient.CoachRewrite(
                axis: response.axis,
                text: response.text,
                rationale: response.rationale,
                riskAfter: response.riskAfter
            )
            presentCoachResults(
                TonoCoachClient.CoachResponse(
                    riskLevel: response.riskAfter ?? "medium",
                    perception: "",
                    subtext: "",
                    reason: nil,
                    suggestions: [rewrite] + secondaryCardsForDisplayedVersion(),
                    flags: []
                )
            )
            logCoachRenderClock(
                tapTime: tapTime, axis: response.axis, outcome: "alternative",
                providerMs: response.providerMs
            )
        case .failure(let error):
            // No slot consumed; the previous rewrite is still on screen.
            endAlternativeBusyPresentation(notice: error.userFacingMessage)
            logCoachRenderClock(
                tapTime: tapTime, axis: nil, outcome: "alternative_error", providerMs: nil
            )
        }
        coachClockTapTime = nil
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
        // Build 116 — the person has chosen. The remaining tones are answers to
        // a question that is now settled, and the draft they were written for
        // no longer exists in the document, so Stage 2 ends here rather than
        // finishing into a card set nobody is looking at.
        cancelSecondaryLocalCoach()
        coachSetDeliveryID = nil
        NSLog("TONO_KB BUILD86 rewrite: inserted len=\(rewrite.count) (deleted \(plan.deleteCount))")
    }

    // MARK: - Coach error

    // Internal so the XCTest target can exercise the real UIKit error state.
    // This is not API surface outside the keyboard module.
    func presentCoachError(_ err: TonoCoachClient.CoachError) {
        presentCoachFailureSurface(detail: err.userFacingMessage)
    }

    /// The single failure presentation. Both the connected route's mapper and
    /// Build 115's on-device reason table feed a sentence into here, so there
    /// is exactly one error surface in this keyboard and neither caller can
    /// grow its own.
    private func presentCoachFailureSurface(detail message: String) {
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
        detail.text = message
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
