// ContactsSync.swift
// UIViewControllerRepresentable wrapping CNContactPickerViewController.
//
// The system picker handles privacy internally — no NSContactsUsageDescription
// and no CNContactStore authorization request required. The picker shows the
// user's contacts, they select one or more, and the delegate fires with the
// chosen CNContact objects which we convert to Recipient values.
//
// Multi-select is enabled by implementing the plural delegate method
// contactPicker(_:didSelectContacts:). The picker UI shows checkboxes.

import Contacts
import ContactsUI
import SwiftUI

public struct ContactPicker: UIViewControllerRepresentable {
    /// Invoked on the main thread with the selected recipients (may be empty
    /// if the user cancelled — caller should handle that gracefully).
    public let onSelect: ([Recipient]) -> Void

    public init(onSelect: @escaping ([Recipient]) -> Void) {
        self.onSelect = onSelect
    }

    public func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_: CNContactPickerViewController, context _: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    public class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: ([Recipient]) -> Void

        init(onSelect: @escaping ([Recipient]) -> Void) {
            self.onSelect = onSelect
        }

        public func contactPicker(_: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onSelect(contacts.map(contactToRecipient))
        }

        public func contactPickerDidCancel(_: CNContactPickerViewController) {
            onSelect([])
        }
    }
}

// MARK: - CNContact → Recipient

private func contactToRecipient(_ contact: CNContact) -> Recipient {
    let name = (CNContactFormatter.string(from: contact, style: .fullName) ?? "")
        .trimmingCharacters(in: .whitespaces)

    // Derive a voice hint from job title + company so the model has
    // useful relationship context without the user typing anything.
    let jobTitle = contact.jobTitle.trimmingCharacters(in: .whitespaces)
    let org = contact.organizationName.trimmingCharacters(in: .whitespaces)
    let hint: String? = {
        switch (jobTitle.isEmpty, org.isEmpty) {
        case (false, false): return "\(jobTitle) at \(org)"
        case (false, true):  return jobTitle
        case (true, false):  return org
        case (true, true):   return nil
        }
    }()

    return Recipient(
        label: name.isEmpty ? "Contact" : name,
        voiceHint: hint
    )
}
