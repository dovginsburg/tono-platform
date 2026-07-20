// LiveToneIndicatorView.swift
// Tono Live Tone v1 — shipping release passive keyboard indicator.
//
// Renders exactly the contract-spec visible states:
//
//   * .none        → fully hidden.
//   * .l1(category) → subtle tint on the tone chip with the L1 body copy.
//   * .l2(category) → chip + banner with [Rewrite] [Dismiss] buttons.
//
// No red. No third level. No diagnosis of the user. The indicator is
// purely passive — the rewrite flow is user-invoked only via the
// [Rewrite] button; tapping it never happens automatically.

import UIKit

public final class LiveToneIndicatorView: UIView {

    // MARK: - Public observers

    /// User tapped the [Rewrite] button. The integration lane opens the
    /// rewrite flow (never auto-opened).
    public var onRewrite: (() -> Void)?

    /// User tapped the [Dismiss] button. The integration lane drives
    /// the session machine's dismissal.
    public var onDismiss: (() -> Void)?

    // MARK: - Subviews

    private let chipLabel = UILabel()
    private let bannerLabel = UILabel()
    private let rewriteButton = UIButton(type: .system)
    private let dismissButton = UIButton(type: .system)
    private let stack = UIStackView()

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSubviews()
    }

    private func setupSubviews() {
        backgroundColor = .clear
        isAccessibilityElement = false

        chipLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        chipLabel.numberOfLines = 1
        chipLabel.adjustsFontForContentSizeCategory = true
        chipLabel.textAlignment = .center
        chipLabel.layer.cornerRadius = 10
        chipLabel.layer.cornerCurve = .continuous
        chipLabel.layer.masksToBounds = true
        chipLabel.text = nil
        chipLabel.isHidden = true
        chipLabel.accessibilityIdentifier = LiveToneCopy.axChip

        bannerLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        bannerLabel.numberOfLines = 0
        bannerLabel.adjustsFontForContentSizeCategory = true
        bannerLabel.textAlignment = .center
        bannerLabel.text = nil
        bannerLabel.isHidden = true
        bannerLabel.accessibilityIdentifier = LiveToneCopy.axBanner

        rewriteButton.setTitle(LiveToneCopy.l2RewriteLabel, for: .normal)
        rewriteButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        rewriteButton.accessibilityIdentifier = LiveToneCopy.axRewriteButton
        rewriteButton.addTarget(self, action: #selector(rewriteTapped), for: .touchUpInside)
        rewriteButton.isHidden = true

        dismissButton.setTitle(LiveToneCopy.l2DismissLabel, for: .normal)
        dismissButton.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        dismissButton.accessibilityIdentifier = LiveToneCopy.axDismissButton
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        dismissButton.isHidden = true

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(chipLabel)
        stack.addArrangedSubview(bannerLabel)
        stack.addArrangedSubview(rewriteButton)
        stack.addArrangedSubview(dismissButton)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        ])

        isHidden = true
    }

    // MARK: - Public API

    /// Apply a visible warning. `.none` clears the indicator.
    public func apply(_ warning: LiveToneVisibleWarning) {
        switch warning {
        case .none:
            clearImmediately()
        case .l1:
            renderL1()
        case .l2:
            renderL2()
        }
    }

    /// Synchronously clear the indicator and hide it.
    public func clearImmediately() {
        chipLabel.text = nil
        chipLabel.isHidden = true
        bannerLabel.text = nil
        bannerLabel.isHidden = true
        rewriteButton.isHidden = true
        dismissButton.isHidden = true
        isHidden = true
    }

    // MARK: - Rendering

    private func renderL1() {
        chipLabel.text = LiveToneCopy.l1Chip
        chipLabel.isHidden = false
        chipLabel.backgroundColor = Self.chipBackgroundColor(forLevel: .l1)
        bannerLabel.isHidden = true
        rewriteButton.isHidden = true
        dismissButton.isHidden = true
        isHidden = false
    }

    private func renderL2() {
        chipLabel.text = LiveToneCopy.l1Chip
        chipLabel.isHidden = false
        chipLabel.backgroundColor = Self.chipBackgroundColor(forLevel: .l2)
        bannerLabel.text = LiveToneCopy.l2Banner
        bannerLabel.isHidden = false
        rewriteButton.isHidden = false
        dismissButton.isHidden = false
        isHidden = false
    }

    @objc private func rewriteTapped() { onRewrite?() }

    @objc private func dismissTapped() { onDismiss?() }

    // MARK: - Styling

    private static func chipBackgroundColor(forLevel level: LiveToneLevel) -> UIColor {
        switch level {
        case .l1: return UIColor.systemYellow.withAlphaComponent(0.18)
        case .l2: return UIColor.systemOrange.withAlphaComponent(0.22)
        }
    }
}