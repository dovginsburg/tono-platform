// ContactsSync.swift
// Privacy-preserving Contacts access and recipient import.
//
// Tono never mutates Contacts and never uploads the address book. Contacts are
// read only after an explicit user action; only reviewed recipient profiles are
// persisted in the existing App Group recipient store.

import Contacts
import ContactsUI
import SwiftUI

public enum TonoContactsAuthorization: Equatable {
    case notRequested
    case full
    case limited
    case denied
    case restricted

    public var title: String {
        switch self {
        case .notRequested: return "Not Requested"
        case .full: return "Full Access"
        case .limited: return "Limited Access"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}

/// Small seam around CNContactStore so authorization tests never touch a real
/// address book. Production uses SystemContactsStore; tests inject a mock.
public protocol ContactsStoreProviding {
    func authorizationStatus() -> TonoContactsAuthorization
    func requestAccess() async throws -> Bool
    func fetchRecipients() throws -> [Recipient]
}

public struct SystemContactsStore: ContactsStoreProviding {
    private let store = CNContactStore()

    public init() {}

    public func authorizationStatus() -> TonoContactsAuthorization {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notRequested
        case .authorized: return .full
        case .denied: return .denied
        case .restricted: return .restricted
        case .limited: return .limited
        @unknown default: return .restricted
        }
    }

    public func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    public func fetchRecipients() throws -> [Recipient] {
        // Deliberately omit phone numbers, email addresses, postal addresses,
        // notes, birthdays, images, and social profiles.
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        var result: [Recipient] = []
        try store.enumerateContacts(with: request) { contact, _ in
            result.append(contactToRecipient(contact))
        }
        return result
    }
}

@MainActor
public final class ContactsAccessModel: ObservableObject {
    @Published public private(set) var status: TonoContactsAuthorization
    @Published public private(set) var candidates: [Recipient] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var errorMessage: String?

    private let store: ContactsStoreProviding

    public init(store: ContactsStoreProviding = SystemContactsStore()) {
        self.store = store
        self.status = store.authorizationStatus()
    }

    public func refreshAuthorization() {
        status = store.authorizationStatus()
    }

    /// The only full-access request path. iOS owns the prompt and the user may
    /// choose full access, limited access, or deny it.
    public func requestSystemAccess() async {
        guard status == .notRequested else {
            refreshAuthorization()
            return
        }
        isWorking = true
        errorMessage = nil
        do {
            _ = try await store.requestAccess()
            refreshAuthorization()
        } catch {
            errorMessage = "Contacts access could not be requested. Please try again."
            refreshAuthorization()
        }
        isWorking = false
    }

    /// Reads the currently accessible set only after an explicit Review action.
    public func prepareImportReview() {
        guard status == .full || status == .limited else { return }
        isWorking = true
        errorMessage = nil
        do {
            candidates = try store.fetchRecipients()
        } catch {
            candidates = []
            errorMessage = "Tono couldn’t read the contacts currently available to it."
        }
        isWorking = false
    }

    public func setPickerCandidates(_ recipients: [Recipient]) {
        candidates = recipients
        errorMessage = nil
    }

    @discardableResult
    public func importReviewed(_ selected: [Recipient]) -> Int {
        RecipientMemory.importContacts(selected)
    }
}

// MARK: - System contact picker (private one-off selection)

public struct ContactPicker: UIViewControllerRepresentable {
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

    public func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    public final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: ([Recipient]) -> Void

        init(onSelect: @escaping ([Recipient]) -> Void) { self.onSelect = onSelect }

        public func contactPicker(_: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            onSelect(contacts.map(contactToRecipient))
        }

        public func contactPickerDidCancel(_: CNContactPickerViewController) { onSelect([]) }
    }
}

// MARK: - Host-app access and review UI

@MainActor
public struct ContactsAccessView: View {
    @StateObject private var model: ContactsAccessModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showPrivatePicker = false
    @State private var showLimitedAccessPicker = false
    @State private var showReview = false

    public init() {
        _model = StateObject(wrappedValue: ContactsAccessModel())
    }

    public init(model: ContactsAccessModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        Form {
            Section("Contacts Access") {
                LabeledContent("Status", value: model.status.title)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Contacts access status: \(model.status.title)")

                Text("Contacts help Tono tailor coaching to each recipient; you choose who to import, and only the reviewed name and work hint stay on this device.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                actionContent
            }

            Section("Privacy") {
                Text("Tono reads only contact names, job titles, and organizations. It never reads phone numbers or email addresses, never uploads your address book, and never changes or deletes Contacts. Removing Contacts access does not silently delete recipient memory you already chose to save.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshAuthorization() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refreshAuthorization() }
        }
        .sheet(isPresented: $showPrivatePicker) {
            ContactPicker { picked in
                if !picked.isEmpty {
                    model.setPickerCandidates(picked)
                    showReview = true
                }
            }
        }
        .sheet(isPresented: $showReview) {
            ContactImportReviewView(candidates: model.candidates) { selected in
                model.importReviewed(selected)
            }
        }
        .modifier(LimitedContactAccessPicker(
            isPresented: $showLimitedAccessPicker,
            onComplete: {
                model.refreshAuthorization()
                model.prepareImportReview()
                showReview = true
            }
        ))
    }

    @ViewBuilder
    private var actionContent: some View {
        switch model.status {
        case .notRequested:
            Button {
                Task { await model.requestSystemAccess() }
            } label: {
                Label("Allow All Contacts", systemImage: "person.crop.circle.badge.checkmark")
            }
            .disabled(model.isWorking)
            .accessibilityHint("Shows Apple’s Contacts permission choices. Tono cannot choose for you.")

            Button {
                showPrivatePicker = true
            } label: {
                Label("Choose Specific Contacts", systemImage: "person.2")
            }
            .accessibilityHint("Opens Apple’s private contact picker without granting full access.")

        case .full:
            Button {
                model.prepareImportReview()
                showReview = true
            } label: {
                Label("Review Contacts to Import", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isWorking)

        case .limited:
            if #available(iOS 18.0, *) {
                Button {
                    showLimitedAccessPicker = true
                } label: {
                    Label("Manage Access", systemImage: "person.crop.circle.badge.plus")
                }
                .accessibilityHint("Add or remove the contacts shared with Tono using Apple’s picker.")
            }
            Button {
                model.prepareImportReview()
                showReview = true
            } label: {
                Label("Review Accessible Contacts", systemImage: "square.and.arrow.down")
            }

        case .denied:
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            Text("You can change Contacts access in Settings. Tono cannot grant access itself.")
                .font(.footnote)
                .foregroundColor(.secondary)

        case .restricted:
            Text("Contacts access is restricted by this device’s settings or management policy.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }

        if model.isWorking { ProgressView().accessibilityLabel("Working") }
        if let error = model.errorMessage {
            Text(error).font(.footnote).foregroundColor(.red)
                .accessibilityLabel("Contacts error: \(error)")
        }
    }
}

private struct LimitedContactAccessPicker: ViewModifier {
    @Binding var isPresented: Bool
    let onComplete: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.contactAccessPicker(isPresented: $isPresented) { _ in onComplete() }
        } else {
            content
        }
    }
}

private struct ContactImportReviewView: View {
    let candidates: [Recipient]
    let onImport: ([Recipient]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID>
    @State private var importedCount: Int?

    init(candidates: [Recipient], onImport: @escaping ([Recipient]) -> Void) {
        self.candidates = candidates
        self.onImport = onImport
        _selectedIDs = State(initialValue: Set(candidates.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if candidates.isEmpty {
                        ContentUnavailableView(
                            "No Contacts Available",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text("Choose contacts in Apple’s picker, then try again.")
                        )
                    } else {
                        ForEach(candidates) { recipient in
                            Button {
                                if selectedIDs.contains(recipient.id) {
                                    selectedIDs.remove(recipient.id)
                                } else {
                                    selectedIDs.insert(recipient.id)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(recipient.label)
                                        if let hint = recipient.voiceHint {
                                            Text(hint).font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: selectedIDs.contains(recipient.id) ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(recipient.label), \(selectedIDs.contains(recipient.id) ? "selected" : "not selected")")
                        }
                    }
                } header: {
                    Text("Review Before Import")
                } footer: {
                    Text("Only selected recipient profiles are saved locally. Nothing is uploaded.")
                }

                if let importedCount {
                    Text(importedCount == 0 ? "No new recipients were added." : "Added \(importedCount) recipient\(importedCount == 1 ? "" : "s").")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Import Recipients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import Selected") {
                        let selected = candidates.filter { selectedIDs.contains($0.id) }
                        onImport(selected)
                        importedCount = selected.count
                        dismiss()
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityHint("Saves the selected recipient profiles on this device.")
                }
            }
        }
    }
}

// MARK: - Conversion

private func contactToRecipient(_ contact: CNContact) -> Recipient {
    let name = (CNContactFormatter.string(from: contact, style: .fullName) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let jobTitle = contact.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
    let hint: String?
    switch (jobTitle.isEmpty, organization.isEmpty) {
    case (false, false): hint = "\(jobTitle) at \(organization)"
    case (false, true): hint = jobTitle
    case (true, false): hint = organization
    case (true, true): hint = nil
    }
    return Recipient(
        label: name.isEmpty ? "Contact" : name,
        voiceHint: hint,
        contactIdentifier: contact.identifier
    )
}
