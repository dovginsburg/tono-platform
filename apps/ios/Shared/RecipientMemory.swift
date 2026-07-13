// RecipientMemory.swift
// Lightweight per-recipient context stored in the App Group.
// The `voiceHint` is passed to the backend as `recipient_hint` so the
// model can tailor the tone to a known relationship.

import Foundation

public struct Recipient: Codable, Identifiable {
    public var id: UUID
    public var label: String       // "Mom", "Boss", "Alex"
    public var voiceHint: String?  // e.g. "prefers formal; no humor"
    public var preferSafer: Bool   // always weight the safer axis
    /// Stable Contacts identifier for de-duplication. No phone/email data is stored.
    public var contactIdentifier: String?

    public init(
        label: String,
        voiceHint: String? = nil,
        preferSafer: Bool = false,
        contactIdentifier: String? = nil
    ) {
        self.id = UUID()
        self.label = label
        self.voiceHint = voiceHint
        self.preferSafer = preferSafer
        self.contactIdentifier = contactIdentifier
    }
}

public enum RecipientMemory {
    public static func all() -> [Recipient] {
        guard let data = SharedStore.defaults.data(forKey: SharedKeys.recipients),
              let list = try? JSONDecoder().decode([Recipient].self, from: data)
        else { return [] }
        return list
    }

    public static func save(_ recipients: [Recipient]) {
        if let data = try? JSONEncoder().encode(recipients) {
            SharedStore.defaults.set(data, forKey: SharedKeys.recipients)
        }
    }

    public static func add(_ r: Recipient) {
        var list = all()
        list.append(r)
        save(list)
    }

    /// Adds only new recipient profiles. Contact-backed records use Apple's stable
    /// identifier; older/manual records fall back to a normalized label match.
    /// Existing recipient memory is never overwritten or silently deleted.
    @discardableResult
    public static func importContacts(_ incoming: [Recipient]) -> Int {
        var list = all()
        var added = 0
        let existingContactIDs = Set(list.compactMap(\.contactIdentifier))
        var seenContactIDs = existingContactIDs
        var seenLabels = Set(list.map { normalizedLabel($0.label) })

        for recipient in incoming {
            let contactID = recipient.contactIdentifier
            let normalized = normalizedLabel(recipient.label)
            let duplicate = contactID.map { seenContactIDs.contains($0) }
                ?? seenLabels.contains(normalized)
            guard !duplicate else { continue }
            list.append(recipient)
            if let contactID { seenContactIDs.insert(contactID) }
            seenLabels.insert(normalized)
            added += 1
        }
        if added > 0 { save(list) }
        return added
    }

    public static func update(_ r: Recipient) {
        var list = all()
        if let idx = list.firstIndex(where: { $0.id == r.id }) { list[idx] = r }
        save(list)
    }

    public static func delete(id: UUID) {
        save(all().filter { $0.id != id })
    }

    private static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
