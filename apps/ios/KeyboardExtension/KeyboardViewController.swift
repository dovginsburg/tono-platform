// KeyboardViewController.swift
// Custom iOS keyboard extension. Hosts a SwiftUI view that:
//   1. shows the keyboard's standard layout with a "Coach" button,
//   2. on tap, fetches the current text from the host text field,
//   3. calls ToneEngine.analyze, displays risk badge + rewrites,
//   4. on selection, inserts the chosen rewrite back into the text field.
//
// IMPORTANT: iOS keyboard extensions cannot present alerts or modal sheets
// the way the host app can. The "Coach" sheet is rendered inside the
// keyboard's own view hierarchy.

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
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The system sets a default height; respect it but allow growth.
        let target = NSLayoutConstraint(
            item: view!, attribute: .height, relatedBy: .greaterThanOrEqual,
            toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 320
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
