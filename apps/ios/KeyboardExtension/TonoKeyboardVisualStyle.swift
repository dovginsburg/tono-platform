import UIKit

/// Resolves the appearance boundary between a host text field and the keyboard
/// extension. Messages reports `.default` in both appearances, while the
/// extension process can retain a light trait even when the device is dark.
/// For `.default`, the device/window-system trait is therefore authoritative;
/// the extension trait is only a fallback when the system style is unspecified.
enum TonoKeyboardAppearanceResolver {
    static func resolve(
        hostAppearance: UIKeyboardAppearance,
        extensionStyle: UIUserInterfaceStyle,
        systemStyle: UIUserInterfaceStyle
    ) -> UIUserInterfaceStyle {
        switch hostAppearance {
        case .dark:
            return .dark
        case .light:
            return .light
        case .default, .alert:
            if systemStyle != .unspecified { return systemStyle }
            return extensionStyle
        @unknown default:
            if systemStyle != .unspecified { return systemStyle }
            return extensionStyle
        }
    }
}

/// Measured keyboard geometry for the Tono extension. The extension owns the
/// suggestion/Coach strip and four typing rows; iOS owns any lower system
/// input-mode area. Values are intentionally close to Apple's portrait
/// keyboard instead of shrinking the typing rows to make room for Coach.
struct TonoKeyboardMetrics: Equatable {
    let preferredContentHeight: CGFloat
    let coachResultsContentHeight: CGFloat
    let topBarHeight: CGFloat
    let coachControlHeight: CGFloat
    let keyMinHeight: CGFloat
    let rowSpacing: CGFloat
    let edgePadding: CGFloat
    let keyCornerRadius: CGFloat
    let keyFontSize: CGFloat
    let keyShadowOpacity: Float
    let keyShadowRadius: CGFloat
    let keyShadowOffset: CGSize

    static func portrait(availableWidth: CGFloat) -> Self {
        let typingHeight: CGFloat
        if availableWidth < 390 {
            typingHeight = 252
        } else if availableWidth >= 430 {
            typingHeight = 264
        } else {
            typingHeight = 256
        }

        // Build 86 already established +36pt as the reviewed results geometry.
        // Build 93 reserves that space in every state so idle/loading/error/results
        // and Back never resize the keyboard extension around the host field.
        let stableHeight = typingHeight + 36

        return Self(
            preferredContentHeight: stableHeight,
            coachResultsContentHeight: stableHeight,
            topBarHeight: 46,
            coachControlHeight: ControlGeometry.minimumTouchTarget,
            keyMinHeight: 44,
            rowSpacing: 8,
            edgePadding: 4,
            keyCornerRadius: 5,
            keyFontSize: 22,
            keyShadowOpacity: 0.18,
            keyShadowRadius: 0.75,
            keyShadowOffset: CGSize(width: 0, height: 1)
        )
    }
}

/// Minimum interactive-control geometry for the keyboard extension. Every
/// tappable control must present an effective hit target of at least
/// `minimumTouchTarget`×`minimumTouchTarget` points in every state. This is the
/// single exported source of truth the runtime layout constrains against; the
/// values are width-independent so key construction can read them before the
/// first layout pass.
extension TonoKeyboardMetrics {
    enum ControlGeometry {
        /// Apple's minimum comfortable touch target.
        static let minimumTouchTarget: CGFloat = 44

        static let emojiToggleWidth: CGFloat = minimumTouchTarget
        static let quickCharacterWidth: CGFloat = minimumTouchTarget
        static let emojiCategoryTabHeight: CGFloat = minimumTouchTarget
        static let emojiCategoryTabWidth: CGFloat = minimumTouchTarget
        static let emojiPanelFooterHeight: CGFloat = minimumTouchTarget
        static let emojiResultCellHeight: CGFloat = minimumTouchTarget
        static let emojiResultCellWidth: CGFloat = minimumTouchTarget
        static let coachBackControlHeight: CGFloat = minimumTouchTarget
        static let coachBackControlWidth: CGFloat = minimumTouchTarget

        static func emojiGridColumns(availableWidth: CGFloat, insets: CGFloat = 4, spacing: CGFloat = 2) -> Int {
            let usable = max(0, availableWidth - insets)
            return max(1, min(8, Int(floor((usable + spacing) / (emojiResultCellWidth + spacing)))))
        }

        static func emojiGridCellWidth(availableWidth: CGFloat, insets: CGFloat = 4, spacing: CGFloat = 2) -> CGFloat {
            let columns = emojiGridColumns(availableWidth: availableWidth, insets: insets, spacing: spacing)
            let gaps = CGFloat(columns - 1) * spacing
            return floor((availableWidth - insets - gaps) / CGFloat(columns))
        }
    }
}

/// The only branded color family in the keyboard extension. Ordinary typing
/// keys remain system-neutral; Coach entry/retry actions use these stateful
/// colors in both appearances.
enum TonoCoachPalette {
    private static let normalLight = UIColor(hexRGB: "5E1F78")
    private static let normalDark = UIColor(hexRGB: "8D4CB3")
    private static let pressedLight = UIColor(hexRGB: "451258")
    private static let pressedDark = UIColor(hexRGB: "713090")
    private static let disabled = UIColor(hexRGB: "76617D")

    static let normal = dynamic(light: normalLight, dark: normalDark)
    static let pressed = dynamic(light: pressedLight, dark: pressedDark)
    static let disabledBackground = disabled
    static let foreground = UIColor.white

    /// Canonical tonoit.com semantic tokens. The exact accent remains visible
    /// as the card rule/dot; labels use a contrast-safe dynamic companion.
    enum Axis: String, CaseIterable {
        case warmer, clearer, funnier, safer

        var label: String { rawValue.capitalized }

        var accent: UIColor {
            switch self {
            case .warmer: return UIColor(hexRGB: "F472B6")
            case .clearer: return UIColor(hexRGB: "38BDF8")
            case .funnier: return UIColor(hexRGB: "FBBF24")
            case .safer: return UIColor(hexRGB: "34D399")
            }
        }

        var accessibleLabel: UIColor {
            let light: UIColor
            switch self {
            case .warmer: light = UIColor(hexRGB: "9D174D")
            case .clearer: light = UIColor(hexRGB: "075985")
            case .funnier: light = UIColor(hexRGB: "92400E")
            case .safer: light = UIColor(hexRGB: "065F46")
            }
            return TonoCoachPalette.dynamic(light: light, dark: accent)
        }
    }

    static let orderedAxes: [Axis] = [.warmer, .clearer, .funnier, .safer]

    static func axis(_ rawValue: String) -> Axis? {
        Axis(rawValue: rawValue.lowercased())
    }

    static func background(enabled: Bool, highlighted: Bool) -> UIColor {
        guard enabled else { return disabledBackground }
        return highlighted ? pressed : normal
    }

    fileprivate static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}

/// Explicit normal / one-shot / Caps Lock transition model. It also rejects
/// automatic-capitalization callbacks captured before a newer document mutation.
struct TonoShiftStateMachine: Equatable {
    enum State: Equatable {
        case lowercase
        case oneShotUppercase
        case capsLock
    }

    private(set) var state: State = .lowercase
    private(set) var oneShotWasAutomatic = false

    func display(_ text: String) -> String {
        state == .lowercase ? text.lowercased() : text.uppercased()
    }

    mutating func tapShift() {
        oneShotWasAutomatic = false
        switch state {
        case .lowercase: state = .oneShotUppercase
        case .oneShotUppercase, .capsLock: state = .lowercase
        }
    }

    mutating func doubleTapShift() {
        oneShotWasAutomatic = false
        state = state == .capsLock ? .lowercase : .capsLock
    }

    mutating func consumeEligibleCapital(_ text: String) {
        guard state == .oneShotUppercase,
              text.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return }
        state = .lowercase
        oneShotWasAutomatic = false
    }

    @discardableResult
    mutating func applyAutomaticCapitalization(
        recommended: Bool,
        callbackGeneration: UInt64,
        documentGeneration: UInt64
    ) -> Bool {
        guard callbackGeneration == documentGeneration, state != .capsLock else { return false }
        guard state != .oneShotUppercase || oneShotWasAutomatic else { return false }
        let next: State = recommended ? .oneShotUppercase : .lowercase
        let changed = state != next
        state = next
        oneShotWasAutomatic = recommended
        return changed
    }
}

struct TonoPendingDocumentMutation: Equatable {
    let generation: UInt64
    let contextBefore: String
    let contextAfter: String

    func canExplain(notificationContext: String) -> Bool {
        notificationContext == contextBefore || notificationContext == contextAfter
    }
}

enum TonoDocumentContextMutation {
    static func applying(
        deleteCount: Int,
        insertion: String,
        to contextBeforeInput: String
    ) -> String {
        let boundedDeleteCount = min(max(0, deleteCount), contextBeforeInput.count)
        return String(contextBeforeInput.dropLast(boundedDeleteCount)) + insertion
    }

    static func restoring(
        correctedSuffix: String,
        restoredText: String,
        in contextBeforeInput: String
    ) -> String? {
        guard contextBeforeInput.hasSuffix(correctedSuffix) else { return nil }
        return String(contextBeforeInput.dropLast(correctedSuffix.count)) + restoredText
    }
}

class TonoMinimumHitTargetButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isHidden, isUserInteractionEnabled, alpha > 0.01 else { return false }
        let minimum = TonoKeyboardMetrics.ControlGeometry.minimumTouchTarget
        let dx = max(0, (minimum - bounds.width) / 2)
        let dy = max(0, (minimum - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// Stateful semantic Coach control. It centralizes normal, pressed and disabled
/// presentation so Coach actions cannot drift back to generic system blue.
final class TonoCoachButton: TonoMinimumHitTargetButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        adjustsImageWhenHighlighted = false
        setTitleColor(TonoCoachPalette.foreground, for: .normal)
        setTitleColor(TonoCoachPalette.foreground, for: .highlighted)
        setTitleColor(TonoCoachPalette.foreground, for: .disabled)
        updateCoachAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateCoachAppearance()
    }

    override var isHighlighted: Bool {
        didSet { updateCoachAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateCoachAppearance() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateCoachAppearance()
        }
    }

    private func updateCoachAppearance() {
        backgroundColor = TonoCoachPalette.background(
            enabled: isEnabled,
            highlighted: isHighlighted
        )
        alpha = 1
    }
}

/// Branded rewrite choice with the same mechanically verified color states as
/// the Coach entry and retry actions.
final class TonoCoachChoiceControl: UIControl {
    /// Axis cards opt into their canonical tonoit.com accent. Generic Coach
    /// choices retain the branded purple state palette used elsewhere.
    var semanticAccent: UIColor? {
        didSet { updateCoachAppearance() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        updateCoachAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateCoachAppearance()
    }

    override var isHighlighted: Bool {
        didSet { updateCoachAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateCoachAppearance() }
    }

    override var isSelected: Bool {
        didSet { updateCoachAppearance() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateCoachAppearance()
        }
    }

    private func updateCoachAppearance() {
        if let semanticAccent {
            let stateAlpha: CGFloat
            if !isEnabled {
                stateAlpha = 0.06
            } else if isHighlighted || isSelected {
                stateAlpha = 0.24
            } else {
                stateAlpha = 0.12
            }
            backgroundColor = semanticAccent.withAlphaComponent(stateAlpha)
        } else {
            backgroundColor = TonoCoachPalette.background(
                enabled: isEnabled,
                highlighted: isHighlighted || isSelected
            )
        }
        alpha = 1
    }
}

extension UIColor {
    convenience init(hexRGB: String) {
        var value: UInt64 = 0
        Scanner(string: hexRGB).scanHexInt64(&value)
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
