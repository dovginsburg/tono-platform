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
        case safer, clearer, funnier, affectionate, professional, concise, custom

        var label: String { CoachToneChipContract.label(for: rawValue) }

        var accent: UIColor {
            // Every declared axis is covered by the shared source contract.
            UIColor(hexRGB: CoachToneChipContract.accentHex(for: rawValue) ?? "38BDF8")
        }

        var accessibleLabel: UIColor {
            let light: UIColor
            switch self {
            case .safer: light = UIColor(hexRGB: "065F46")
            case .clearer: light = UIColor(hexRGB: "075985")
            case .funnier: light = UIColor(hexRGB: "92400E")
            case .affectionate: light = UIColor(hexRGB: "9D174D")
            case .professional: light = UIColor(hexRGB: "5B21B6")
            case .concise: light = UIColor(hexRGB: "155E75")
            case .custom: light = UIColor(hexRGB: "9F1239")
            }
            return TonoCoachPalette.dynamic(light: light, dark: accent)
        }
    }

    static let orderedAxes: [Axis] = [.safer, .clearer, .funnier, .affectionate, .professional, .concise, .custom]

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

// MARK: - Build 107 result-shaped loading skeleton
//
// Reconciled into the Build-106 lineage from commit 3a80fb0, which fixed the
// physical Build-100 defect on a branch that never merged: the *active* UIKit
// loading surface (`KeyboardViewController.presentCoachLoading`) rendered a
// plain "Coaching…" label plus a `UIActivityIndicatorView`. A generic spinner
// tells the user nothing about what is forming. Build 107 replaces it with a
// result-shaped skeleton — a title rule, a Back placeholder, and one rewrite
// card (axis pill, two text lines, an action row) — that mirrors the results
// layout the user is about to receive, so the shape of the answer is visible
// the instant the request begins. Pure UIKit, built synchronously on the main
// thread in well under a frame; no spinner.
//
// The Build-106 request-ownership contract is untouched: this file renders
// only. `coachLoadingRequestID` ownership, cancellation, stale-completion
// rejection, the one-surface invariant and draft integrity all continue to
// live in `KeyboardViewController` and are unchanged by the skeleton.

/// One shimmering rounded placeholder block. The shimmer is a GPU-driven
/// gradient sweep (a light band travelling left→right), the standard skeleton
/// idiom. It self-manages against window attachment and honors Reduce Motion:
/// when Reduce Motion is on, the block is a static placeholder (still
/// result-shaped, just not animated).
final class TonoShimmerBlock: UIView {
    private let gradient = CAGradientLayer()
    private static let animationKey = "tono.shimmer"

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [0.0, 0.5, 1.0]
        layer.addSublayer(gradient)
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyColors()
        }
    }

    private func applyColors() {
        // A lighter band sweeping over a neutral placeholder fill. Both are
        // dynamic system grays, so the skeleton adapts to light/dark without
        // hardcoded hues. cgColors do not auto-resolve, so we re-resolve on
        // interface-style changes above.
        let base = UIColor.systemGray5.resolvedColor(with: traitCollection)
        let band = UIColor.systemGray3.resolvedColor(with: traitCollection)
        backgroundColor = base
        gradient.colors = [base.cgColor, band.cgColor, base.cgColor]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopShimmer() } else { beginShimmer() }
    }

    /// True while the sweep animation is attached. Test seam.
    var isShimmering: Bool { gradient.animation(forKey: Self.animationKey) != nil }

    /// Start the sweep unless Reduce Motion is on. Idempotent. The
    /// reduce-motion flag is a parameter (defaulting to the live setting) so
    /// both branches are unit-testable without mutating global accessibility
    /// state.
    func beginShimmer(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard !reduceMotion else { stopShimmer(); return }
        guard gradient.animation(forKey: Self.animationKey) == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.1
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        gradient.add(sweep, forKey: Self.animationKey)
    }

    func stopShimmer() {
        gradient.removeAnimation(forKey: Self.animationKey)
    }
}

/// Result-shaped Coach loading skeleton. Mirrors the geometry of the results
/// surface (a title rule + Back placeholder on top, then one rewrite card with
/// an axis pill, two text lines, and a two-button action row) so the loading
/// state previews the shape of the answer. The card wears the selected axis
/// accent, exactly like the real rewrite chip. A single VoiceOver element
/// announces the loading state; every shimmer block is hidden from
/// accessibility.
final class TonoCoachSkeletonView: UIView {
    static let identifier = "TonoKB.coachLoadingSkeleton"
    static let cardIdentifier = "TonoKB.coachSkeletonCard"

    /// Every placeholder block, so a test can assert the skeleton is
    /// result-shaped (a card with an axis pill, two text lines, two actions —
    /// not a lone spinner) and drive the shimmer.
    private(set) var shimmerBlocks: [TonoShimmerBlock] = []
    /// The accent-bordered rewrite-card placeholder.
    let card = UIView()

    init(accent: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = Self.identifier
        // One VoiceOver element for the whole loading state.
        isAccessibilityElement = true
        accessibilityLabel = "Coaching your rewrite"
        accessibilityTraits = [.updatesFrequently]
        build(accent: accent)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeBlock(cornerRadius: CGFloat) -> TonoShimmerBlock {
        let block = TonoShimmerBlock(cornerRadius: cornerRadius)
        shimmerBlocks.append(block)
        return block
    }

    private func build(accent: UIColor) {
        // Header: a title rule (where "Tono · <risk>" renders) and a Back
        // placeholder — the same top row the results surface presents.
        let title = makeBlock(cornerRadius: 4)
        addSubview(title)
        let back = makeBlock(cornerRadius: 6)
        addSubview(back)

        // One rewrite card, accent-bordered like the real chip.
        card.translatesAutoresizingMaskIntoConstraints = false
        card.accessibilityIdentifier = Self.cardIdentifier
        card.isAccessibilityElement = false
        card.layer.cornerRadius = 5
        card.layer.borderWidth = 2
        card.layer.borderColor = accent.cgColor
        card.backgroundColor = accent.withAlphaComponent(0.06)
        addSubview(card)

        let axisPill = makeBlock(cornerRadius: 6)     // "● Funnier"
        card.addSubview(axisPill)
        let line1 = makeBlock(cornerRadius: 4)        // rewrite line 1
        card.addSubview(line1)
        let line2 = makeBlock(cornerRadius: 4)        // rewrite line 2 (short)
        card.addSubview(line2)
        let actionLeft = makeBlock(cornerRadius: 5)   // Replace
        card.addSubview(actionLeft)
        let actionRight = makeBlock(cornerRadius: 5)  // Dismiss
        card.addSubview(actionRight)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.widthAnchor.constraint(equalToConstant: 132),
            title.heightAnchor.constraint(equalToConstant: 15),

            back.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            back.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            back.widthAnchor.constraint(equalToConstant: 44),
            back.heightAnchor.constraint(equalToConstant: 24),

            card.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            axisPill.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            axisPill.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            axisPill.widthAnchor.constraint(equalToConstant: 72),
            axisPill.heightAnchor.constraint(equalToConstant: 12),

            line1.topAnchor.constraint(equalTo: axisPill.bottomAnchor, constant: 12),
            line1.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            line1.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            line1.heightAnchor.constraint(equalToConstant: 12),

            line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: 8),
            line2.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            line2.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.6),
            line2.heightAnchor.constraint(equalToConstant: 12),

            actionLeft.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            actionLeft.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            actionLeft.heightAnchor.constraint(equalToConstant: 36),

            actionRight.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            actionRight.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            actionRight.leadingAnchor.constraint(equalTo: actionLeft.trailingAnchor, constant: 8),
            actionRight.widthAnchor.constraint(equalTo: actionLeft.widthAnchor),
            actionRight.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    /// Refresh the accent-bordered card color after an interface-style change.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle,
           let accent = card.layer.borderColor.map({ UIColor(cgColor: $0) }) {
            card.layer.borderColor = accent.resolvedColor(with: traitCollection).cgColor
        }
    }

    /// Drive every block's shimmer. Called by the controller when the surface
    /// is installed; blocks also self-start on window attachment.
    func beginShimmer(reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        shimmerBlocks.forEach { $0.beginShimmer(reduceMotion: reduceMotion) }
    }
}
