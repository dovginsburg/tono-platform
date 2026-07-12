// KeyboardViewController.swift
// Custom iOS keyboard extension. Hosts a SwiftUI view that:
//   1. shows the keyboard's standard layout with a "Coach" button,
//   2. on tap, fetches the current text from the host text field,
//   3. calls ToneEngine.analyze, displays risk badge + rewrites,
//   4. on selection, inserts the chosen rewrite back into the text field.
//
// NEW (Tono keyboard rewrite):
//   - Inline 3-word suggestion strip above the keys with tap-to-insert.
//   - Long-press the return key to invoke the Coach rewrite flow without
//     switching to the Coach screen (a SwiftUI confirmation sheet replaces
//     tapping the explicit Coach button).
//   - First-launch Full Access onboarding prompt that explains why Tono
//     asks for Full Access before the user hits the keyboard's Coach path.
//
// IMPORTANT: iOS keyboard extensions cannot present UIAlertController;
// any confirmations ("Coach this draft?") are rendered as SwiftUI views
// inside the keyboard's own view hierarchy.

import UIKit

@objc(KeyboardViewController)
public final class KeyboardViewController: UIInputViewController {

    public override func viewDidLoad() {
        super.viewDidLoad()
        NSLog("TONO_KB SAFE_ROOT 01: viewDidLoad")

        view.backgroundColor = .systemBlue

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

        let nextButton = UIButton(type: .system)
        nextButton.setTitle("Next keyboard", for: .normal)
        nextButton.setTitleColor(.white, for: .normal)
        nextButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        nextButton.addTarget(self, action: #selector(advanceToNextInputMode), for: .touchUpInside)
        nextButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nextButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            detail.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            nextButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            nextButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
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
    }
}
