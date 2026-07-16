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
    let coachControlWidth: CGFloat
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
            coachControlWidth: 96,
            coachControlHeight: 44,
            keyMinHeight: 44,
            rowSpacing: 6,
            edgePadding: 4,
            keyCornerRadius: 5,
            keyFontSize: 22,
            keyShadowOpacity: 0.18,
            keyShadowRadius: 0.75,
            keyShadowOffset: CGSize(width: 0, height: 1)
        )
    }

    func letterKeyWidth(availableWidth: CGFloat) -> CGFloat {
        let usable = max(availableWidth - edgePadding * 2, 320)
        return (usable - rowSpacing * 9) / 10
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

    /// Approved build-84 semantic axis colors. These values are intentionally
    /// centralized so result labels cannot collapse back to a single color.
    static func axisAccent(for axis: String) -> UIColor {
        switch axis.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "warmer": return dynamic(light: UIColor(hexRGB: "B4234D"), dark: UIColor(hexRGB: "FF6B8A"))
        case "clearer": return dynamic(light: UIColor(hexRGB: "006A8E"), dark: UIColor(hexRGB: "49C7F2"))
        case "funnier": return dynamic(light: UIColor(hexRGB: "7A5100"), dark: UIColor(hexRGB: "FFC247"))
        case "safer": return dynamic(light: UIColor(hexRGB: "147A36"), dark: UIColor(hexRGB: "4CD471"))
        default: return foreground
        }
    }

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

enum TonoKeyHitGeometry {
    static func expansionInsets(spacing: CGFloat) -> UIEdgeInsets {
        let halfGap = max(0, spacing) / 2
        return UIEdgeInsets(top: -halfGap, left: -halfGap, bottom: -halfGap, right: -halfGap)
    }

    static func expandedFrame(_ frame: CGRect, spacing: CGFloat) -> CGRect {
        frame.inset(by: expansionInsets(spacing: spacing))
    }
}

enum TonoShiftState: Equatable {
    case lowercase
    case oneShotUppercase
    case capsLock
}

struct TonoShiftStateMachine: Equatable {
    static let doubleTapInterval: TimeInterval = 0.35

    private(set) var state: TonoShiftState = .lowercase
    private(set) var isAutomaticOneShot = false
    private var lastManualTapAt: TimeInterval?

    mutating func manualTap(at timestamp: TimeInterval) {
        if state == .capsLock {
            state = .lowercase
            isAutomaticOneShot = false
            lastManualTapAt = nil
            return
        }
        let isIntentionalDoubleTap = state == .oneShotUppercase
            && !isAutomaticOneShot
            && lastManualTapAt.map {
                timestamp >= $0 && timestamp - $0 <= Self.doubleTapInterval
            } == true
        if isIntentionalDoubleTap {
            state = .capsLock
            isAutomaticOneShot = false
            lastManualTapAt = nil
            return
        }
        state = state == .lowercase ? .oneShotUppercase : .lowercase
        isAutomaticOneShot = false
        lastManualTapAt = state == .oneShotUppercase ? timestamp : nil
    }

    mutating func applyAutoCapitalization(_ recommended: Bool) {
        guard state != .capsLock else { return }
        if state == .oneShotUppercase, !isAutomaticOneShot { return }
        state = recommended ? .oneShotUppercase : .lowercase
        isAutomaticOneShot = recommended
        lastManualTapAt = nil
    }

    mutating func consumeEligibleLetter() {
        guard state == .oneShotUppercase else { return }
        state = .lowercase
        isAutomaticOneShot = false
        lastManualTapAt = nil
    }

    mutating func invalidatePendingDoubleTap() {
        lastManualTapAt = nil
    }

    mutating func resetForExtensionLifecycle() {
        self = Self()
    }
}

/// Shared keycap press treatment and gap-filling hit region. Expanding each
/// key by exactly half the inter-key spacing makes adjacent hit regions meet
/// without overlap, eliminating dead strips while preserving target ownership.
final class TonoKeyboardButton: UIButton {
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
        super.init(coder: coder)
    }

    override func accessibilityActivate() -> Bool {
        accessibilityActivationHandler?() ?? super.accessibilityActivate()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let spacing = TonoKeyboardMetrics.portrait(
            availableWidth: max(bounds.width, UIScreen.main.bounds.width)
        ).rowSpacing
        return bounds.inset(by: TonoKeyHitGeometry.expansionInsets(spacing: spacing)).contains(point)
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

/// Stateful semantic Coach control. It centralizes normal, pressed and disabled
/// presentation so Coach actions cannot drift back to generic system blue.
final class TonoCoachButton: UIButton {
    private static let fixedSize = CGSize(
        width: TonoKeyboardMetrics.portrait(availableWidth: 402).coachControlWidth,
        height: TonoKeyboardMetrics.portrait(availableWidth: 402).coachControlHeight
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureCoachControl()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCoachControl()
    }

    override var intrinsicContentSize: CGSize { Self.fixedSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize { Self.fixedSize }

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

    private func configureCoachControl() {
        adjustsImageWhenHighlighted = false
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.numberOfLines = 1
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setTitleColor(TonoCoachPalette.foreground, for: .normal)
        setTitleColor(TonoCoachPalette.foreground, for: .highlighted)
        setTitleColor(TonoCoachPalette.foreground, for: .disabled)
        updateCoachAppearance()
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
