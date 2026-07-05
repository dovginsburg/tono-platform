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
import SwiftUI

class KeyboardViewController: UIInputViewController {

    private var hostingController: UIHostingController<KeyboardRootView>?
    private var keyboardModel: KeyboardModel?

    override func updateViewConstraints() {
        super.updateViewConstraints()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Signal to the host app that the keyboard is enabled and has loaded.
        // HomeView polls this on scenePhase changes to show a checkmark.
        SharedStore.defaults.set(true, forKey: SharedKeys.keyboardLoaded)
        installRootView()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // hasFullAccess can change while the app is backgrounded (user toggles
        // Full Access in Settings), so refresh it every time the keyboard appears.
        keyboardModel?.hasFullAccess = hasFullAccess

        // First-launch onboarding: if this is the very first time the user is
        // seeing the keyboard and Full Access is off, surface a friendly intro
        // view BEFORE they tap Coach. We only show this once per device.
        if !hasFullAccess,
           !SharedStore.defaults.bool(forKey: SharedKeys.fullAccessExplained) {
            keyboardModel?.mode = .fullAccessOnboarding
        }

        // Recompute shift state against wherever the cursor now sits. The
        // field being edited (and its auto-cap-relevant surrounding text)
        // can be completely different each time the keyboard shows — same
        // logic as Tono Android's TonoInputMethodService.onStartInputView.
        keyboardModel?.applyAutoCapitalizationIfNeeded()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The system sets a default height; respect it but allow growth.
        // Increased from 320 to 360 because the new suggestion strip + Coach
        // confirmation sheet need extra vertical room. iOS clamps this softly.
        let target = NSLayoutConstraint(
            item: view!, attribute: .height, relatedBy: .greaterThanOrEqual,
            toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 360
        )
        target.priority = .defaultHigh
        view.addConstraint(target)
    }

    private func installRootView() {
        let model = KeyboardModel(
            initialText: "",
            proxy: { [weak self] in self?.textDocumentProxy },
            advance: { [weak self] in self?.advanceToNextInputMode() },
            dismiss: { [weak self] in self?.dismissKeyboard() }
        )
        model.hasFullAccess = hasFullAccess
        self.keyboardModel = model
        let root = KeyboardRootView(
            model: model,
            proxyProvider: { [weak self] in self?.textDocumentProxy }
        )
        let host = UIHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.hostingController = host
    }
}
