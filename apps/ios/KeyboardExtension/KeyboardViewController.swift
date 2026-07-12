// KeyboardViewController.swift
// Tono keyboard extension — build 76.
// UIKit-only minimal functional keyboard layered on top of the SAFE ROOT shell.
// NO SwiftUI, NO KeyboardModel, NO App Group, NO networking, NO assets.
//
// Build history:
//   75 — SAFE ROOT (blue shell, no typing, lifecycle markers only).
//   76 — adds a small QWERTY using UIKit buttons. Every key calls
//        textDocumentProxy.insertText; backspace calls deleteBackward;
//        return inserts "\n"; the globe button advances to the next
//        input mode. All construction is lazy in/after viewDidAppear
//        to avoid blocking the extension's first-frame startup.
//
// IMPORTANT: iOS keyboard extensions cannot present UIAlertController.
// Anything user-facing lives in the keyboard's own view hierarchy.

import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {

    // MARK: - Constants

    private enum Const {
        // QWERTY rows (small, capital-only to fit inside the diagnostic shell).
        static let row1: [String] = ["q","w","e","r","t","y","u","i","o","p"]
        static let row2: [String] = ["a","s","d","f","g","h","j","k","l"]
        static let row3: [String] = ["z","x","c","v","b","n","m"]
    }

    // MARK: - State

    private var keysInstalled = false

    // MARK: - Lifecycle (SAFE ROOT markers preserved)

    public override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("TONO_KB SAFE_ROOT 01: viewDidLoad")

        view.backgroundColor = .systemBlue

        // SAFE ROOT shell labels (preserved exactly from build 75).
        let label = UILabel()
        label.text = "TONO SAFE ROOT"
        label.textColor = .white
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        let detail = UILabel()
        detail.text = "UIKit-only diagnostic keyboard"
        detail.textColor = UIColor.white.withAlphaComponent(0.85)
        detail.font = .systemFont(ofSize: 14)
        detail.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detail)

        // Build-76 banner — distinguishes this build from SAFE ROOT 75 in
        // Dov's TestFlight screenshot, and is the label the task spec asks for.
        let buildBanner = UILabel()
        buildBanner.text = "TONO BUILD 76 \u{00b7} TYPE TEST"
        buildBanner.textColor = .white
        buildBanner.font = .systemFont(ofSize: 12, weight: .semibold)
        buildBanner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buildBanner)

        // Stack that will hold the keys. We add it and its empty constraints
        // here so Auto Layout has the view tree at viewDidLoad time, but we
        // populate it with buttons lazily in viewDidAppear to keep first-frame
        // startup cheap.
        let keysContainer = UIView()
        keysContainer.translatesAutoresizingMaskIntoConstraints = false
        keysContainer.accessibilityIdentifier = "TonoKB.keysContainer"
        view.addSubview(keysContainer)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            detail.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            buildBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            buildBanner.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 4),
            keysContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            keysContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            keysContainer.topAnchor.constraint(equalTo: buildBanner.bottomAnchor, constant: 8),
            keysContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
        ])

        NSLog("TONO_KB SAFE_ROOT 02: UIKit hierarchy installed")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NSLog("TONO_KB SAFE_ROOT 03: viewWillAppear")
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("TONO_KB SAFE_ROOT 04: viewDidAppear")
        installKeysIfNeeded()
    }

    // MARK: - Keys (lazy, after first appearance)

    private func installKeysIfNeeded() {
        guard !keysInstalled else { return }
        guard let container = view.viewWithAccessibilityIdentifier("TonoKB.keysContainer") else {
            NSLog("TONO_KB BUILD76 ERR: keys container not found")
            return
        }
        keysInstalled = true

        // Vertical stack: row1, row2, row3, bottom-row (backspace / space / return / globe).
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        stack.addArrangedSubview(makeLetterRow(Const.row1))
        stack.addArrangedSubview(makeLetterRow(Const.row2))
        stack.addArrangedSubview(makeLetterRow(Const.row3))
        stack.addArrangedSubview(makeBottomRow())

        NSLog("TONO_KB BUILD76 05: keys installed (\(Const.row1.count + Const.row2.count + Const.row3.count) letters + 4 bottom-row)")
    }

    private func makeLetterRow(_ chars: [String]) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .fill
        row.spacing = 4
        for ch in chars {
            row.addArrangedSubview(makeLetterButton(ch))
        }
        return row
    }

    private func makeLetterButton(_ char: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(char, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        b.layer.cornerRadius = 4
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Tono letter \(char)"
        b.addTarget(self, action: #selector(letterTapped(_:)), for: .touchUpInside)
        b.accessibilityIdentifier = "TonoKB.letter.\(char)"
        return b
    }

    private func makeBottomRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fill
        row.alignment = .fill
        row.spacing = 4

        let backspace = makeControlButton(title: "\u{232B}", action: #selector(backspaceTapped), width: 56, id: "backspace")
        let space = makeControlButton(title: "space", action: #selector(spaceTapped), width: nil, id: "space")
        let returnKey = makeControlButton(title: "return", action: #selector(returnTapped), width: 72, id: "return")
        let globe = makeControlButton(title: "\u{1F310}", action: #selector(advanceToNextInputMode), width: 44, id: "globe")

        row.addArrangedSubview(backspace)
        row.addArrangedSubview(space)
        row.addArrangedSubview(returnKey)
        row.addArrangedSubview(globe)
        return row
    }

    private func makeControlButton(title: String, action: Selector, width: CGFloat?, id: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        b.layer.cornerRadius = 4
        b.layer.borderWidth = 0.5
        b.layer.borderColor = UIColor.separator.cgColor
        b.accessibilityLabel = "Tono control \(id)"
        b.accessibilityIdentifier = "TonoKB.\(id)"
        b.addTarget(self, action: action, for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        if let width = width {
            b.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return b
    }

    // MARK: - Key actions

    @objc private func letterTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal) else { return }
        textDocumentProxy.insertText(title)
        NSLog("TONO_KB BUILD76 key: \(title)")
    }

    @objc private func spaceTapped() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func backspaceTapped() {
        textDocumentProxy.deleteBackward()
    }

    @objc private func returnTapped() {
        textDocumentProxy.insertText("\n")
    }
}

// MARK: - Tiny helper: view lookup by accessibility identifier.

private extension UIView {
    func viewWithAccessibilityIdentifier(_ id: String) -> UIView? {
        if self.accessibilityIdentifier == id { return self }
        for sub in subviews {
            if let hit = sub.viewWithAccessibilityIdentifier(id) { return hit }
        }
        return nil
    }
}
