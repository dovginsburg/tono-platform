import UIKit

enum TonoKeyboardShiftState: Equatable {
    case lowercase
    case oneShotUppercase
    case capsLock
}

/// Pure shift reducer shared by the shipping UIKit keyboard and its tests.
struct TonoKeyboardShiftMachine {
    private(set) var state: TonoKeyboardShiftState
    private var oneShotWasAutomatic = false

    init(state: TonoKeyboardShiftState = .lowercase) {
        self.state = state
    }

    mutating func singleTapShift() {
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

    mutating func applyAutomaticCapitalization(
        policy: UITextAutocapitalizationType,
        context: String
    ) {
        guard state != .capsLock else { return }
        guard state != .oneShotUppercase || oneShotWasAutomatic else { return }
        let capitalize = Self.recommendsCapitalization(policy: policy, context: context)
        state = capitalize ? .oneShotUppercase : .lowercase
        oneShotWasAutomatic = capitalize
    }

    mutating func insert(
        _ letter: String,
        policy: UITextAutocapitalizationType,
        contextAfterInsertion: String
    ) -> String {
        let inserted = state == .lowercase ? letter.lowercased() : letter.uppercased()
        if state != .capsLock {
            state = policy == .allCharacters ? .oneShotUppercase : .lowercase
            oneShotWasAutomatic = policy == .allCharacters
        }
        return inserted
    }

    static func stateAfterCharacter(
        _ state: TonoKeyboardShiftState,
        policy: UITextAutocapitalizationType
    ) -> TonoKeyboardShiftState {
        guard state != .capsLock else { return .capsLock }
        return policy == .allCharacters ? .oneShotUppercase : .lowercase
    }

    static func recommendsCapitalization(
        policy: UITextAutocapitalizationType,
        context: String
    ) -> Bool {
        switch policy {
        case .none: return false
        case .allCharacters: return true
        case .words: return context.isEmpty || context.last?.isWhitespace == true
        case .sentences:
            if context.isEmpty || context.hasSuffix("\n") { return true }
            let trimmed = context.replacingOccurrences(
                of: #"\s+$"#,
                with: "",
                options: .regularExpression
            )
            guard trimmed.count < context.count else { return false }
            if trimmed.isEmpty { return true }
            return trimmed.last.map { ".!?".contains($0) } ?? false
        @unknown default: return false
        }
    }
}

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
            coachControlHeight: 36,
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

/// Stateful semantic Coach control. It centralizes normal, pressed and disabled
/// presentation so Coach actions cannot drift back to generic system blue.
final class TonoCoachButton: UIButton {
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
