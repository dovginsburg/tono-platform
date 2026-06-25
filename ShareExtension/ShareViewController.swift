// ShareExtension/ShareViewController.swift
// Entry point for the Tono Share Extension. Extracts selected plain text
// from the host app and presents the SwiftUI analysis sheet.
//
// Xcode setup required:
//   1. File > New > Target > Share Extension, name "TonoShare"
//   2. Add the App Group "group.com.tonocoach.shared" to the share extension target
//   3. Add keychain-access-groups entitlement (same group as the keyboard)
//   4. In Info.plist set NSExtensionActivationRule to filter for public.plain-text
//
// The target must include Shared/ sources (ToneEngine.swift, TonoBackend.swift,
// SharedKeychain.swift, etc.) compiled for the share extension target.

import UIKit
import SwiftUI

class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        extractText { [weak self] text in
            DispatchQueue.main.async {
                if let text {
                    self?.presentAnalysis(for: text)
                } else {
                    self?.completeRequest()
                }
            }
        }
    }

    private func extractText(completion: @escaping (String?) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else {
            completion(nil)
            return
        }
        let textType = "public.plain-text"
        for provider in providers where provider.hasItemConformingToTypeIdentifier(textType) {
            provider.loadItem(forTypeIdentifier: textType) { item, _ in
                completion(item as? String)
            }
            return
        }
        completion(nil)
    }

    private func presentAnalysis(for text: String) {
        let root = ShareAnalysisView(draft: text, onDismiss: { [weak self] in
            self?.completeRequest()
        })
        let host = UIHostingController(rootView: root)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func completeRequest() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
