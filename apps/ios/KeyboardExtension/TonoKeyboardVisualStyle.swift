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
        let preferredHeight: CGFloat
        if availableWidth < 390 {
            preferredHeight = 252
        } else if availableWidth >= 430 {
            preferredHeight = 264
        } else {
            preferredHeight = 256
        }

        return Self(
            preferredContentHeight: preferredHeight,
            coachResultsContentHeight: preferredHeight + 36,
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

    static func background(enabled: Bool, highlighted: Bool) -> UIColor {
        guard enabled else { return disabledBackground }
        return highlighted ? pressed : normal
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
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
        backgroundColor = TonoCoachPalette.background(
            enabled: isEnabled,
            highlighted: isHighlighted || isSelected
        )
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
