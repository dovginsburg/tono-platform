// RecipientsManagerView.swift
// The dedicated, searchable and lazily rendered recipient-management surface.

import Foundation
import SwiftUI

enum ContactsAccessSummary: Equatable {
    case notDetermined
    case denied
    case limited
    case full

    var detail: String {
        switch self {
        case .notDetermined: return "Contacts not connected"
        case .denied: return "No Contacts access"
        case .limited: return "Limited Contacts access"
        case .full: return "All contacts"
        }
    }
}

extension TonoContactsAuthorization {
    var summary: ContactsAccessSummary {
        switch self {
        case .notRequested: return .notDetermined
        case .full: return .full
        case .limited: return .limited
        case .denied, .restricted: return .denied
        }
    }
}

struct RecipientsSettingsSummary: Equatable {
    static let rowCount = 1

    let title = "Recipients"
    let detail: String
    let accessDetail: String
    let accessibilityLabel: String

    init(recipientCount: Int, contactsAccess: ContactsAccessSummary) {
        let count = max(0, recipientCount)
        let countDetail: String
        switch count {
        case 0: countDetail = "None yet"
        case 1: countDetail = "1 recipient"
        default:
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            countDetail = "\(formatter.string(from: NSNumber(value: count)) ?? "\(count)") recipients"
        }
        detail = countDetail
        accessDetail = contactsAccess.detail
        accessibilityLabel = "Recipients, \(countDetail), \(contactsAccess.detail)"
    }
}

enum RecipientSearch {
    static func filter(
        _ recipients: [Recipient],
        query: String
    ) -> [Recipient] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).folded }
        guard !tokens.isEmpty else { return recipients }
        return recipients.filter { recipient in
            let haystack = "\(recipient.label) \(recipient.voiceHint ?? "")".folded
            return tokens.allSatisfy(haystack.contains)
        }
    }
}

private extension String {
    var folded: String {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

@MainActor
struct RecipientsManagerView: View {
    @State private var recipients: [Recipient] = []
    @State private var query = ""
    @State private var showAddRecipient = false
    @State private var editing: Recipient?
    @State private var pendingDelete: Recipient?
    @StateObject private var contacts = ContactsAccessModel()

    private var filtered: [Recipient] {
        RecipientSearch.filter(recipients, query: query)
    }

    var body: some View {
        List {
            if recipients.isEmpty {
                emptyRosterSection
            } else if filtered.isEmpty {
                noMatchesSection
            } else {
                rosterSection
            }
            importSection
            privacyFooterSection
        }
        .listStyle(.insetGrouped)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search recipients"
        )
        .navigationTitle("Recipients")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddRecipient = true
                } label: {
                    Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Add recipient")
            }
        }
        .onAppear {
            reload()
            contacts.refreshAuthorization()
        }
        .sheet(isPresented: $showAddRecipient) {
            RecipientEditorView(recipient: nil) { saved in
                RecipientMemory.add(saved)
                reload()
            }
        }
        .sheet(item: $editing) { recipient in
            RecipientEditorView(recipient: recipient) { saved in
                RecipientMemory.update(saved)
                reload()
            }
        }
        .confirmationDialog(
            "Delete \(pendingDelete?.label ?? "recipient")?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = pendingDelete {
                    RecipientMemory.delete(id: target.id)
                    reload()
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the profile and its voice hint from this device. Your Contacts are not changed.")
        }
    }

    private var rosterSection: some View {
        Section {
            ForEach(filtered) { recipient in
                Button {
                    editing = recipient
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recipient.label)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            if let hint = recipient.voiceHint, !hint.isEmpty {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = recipient
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editing = recipient
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.indigo)
                }
            }
        } header: {
            let count = filtered.count
            Text(query.isEmpty ? RecipientsSettingsSummary(
                recipientCount: recipients.count,
                contactsAccess: contacts.status.summary
            ).detail : "\(count) match\(count == 1 ? "" : "es")")
        }
    }

    private var emptyRosterSection: some View {
        Section {
            Label("No recipients yet", systemImage: "person.crop.circle.badge.questionmark")
            Button {
                showAddRecipient = true
            } label: {
                Label("Add a recipient", systemImage: "plus.circle.fill")
                    .frame(minHeight: 44)
            }
        }
    }

    private var noMatchesSection: some View {
        Section {
            Label("No matches", systemImage: "magnifyingglass")
            Text("Try part of a name or voice hint.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var importSection: some View {
        Section("Import") {
            NavigationLink {
                ContactsAccessView(model: contacts)
            } label: {
                HStack {
                    Label("Contacts Access & Import", systemImage: "person.crop.circle.badge.checkmark")
                    Spacer()
                    Text(contacts.status.summary.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            Button {
                showAddRecipient = true
            } label: {
                Label("Add manually", systemImage: "square.and.pencil")
                    .frame(minHeight: 44)
            }
        }
    }

    private var privacyFooterSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text("Recipient profiles stay on this device. Tono never uploads your address book; only a chosen recipient's voice hint is sent with a coaching request.")
        }
    }

    private func reload() {
        recipients = RecipientMemory.all()
    }
}

struct RecipientEditorView: View {
    let recipient: Recipient?
    let onSave: (Recipient) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var voiceHint: String
    @State private var preferSafer: Bool

    init(recipient: Recipient?, onSave: @escaping (Recipient) -> Void) {
        self.recipient = recipient
        self.onSave = onSave
        _label = State(initialValue: recipient?.label ?? "")
        _voiceHint = State(initialValue: recipient?.voiceHint ?? "")
        _preferSafer = State(initialValue: recipient?.preferSafer ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name or label", text: $label)
                TextField("How they read", text: $voiceHint, axis: .vertical)
                Toggle("Always weight Safer", isOn: $preferSafer)
            }
            .navigationTitle(recipient == nil ? "Add Recipient" : "Edit Recipient")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHint = voiceHint.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = recipient ?? Recipient(label: cleanLabel)
        saved.label = cleanLabel
        saved.voiceHint = cleanHint.isEmpty ? nil : cleanHint
        saved.preferSafer = preferSafer
        onSave(saved)
        dismiss()
    }
}
