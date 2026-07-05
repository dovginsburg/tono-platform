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

    public init(label: String, voiceHint: String? = nil, preferSafer: Bool = false) {
        self.id = UUID()
        self.label = label
        self.voiceHint = voiceHint
        self.preferSafer = preferSafer
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

    public static func update(_ r: Recipient) {
        var list = all()
        if let idx = list.firstIndex(where: { $0.id == r.id }) { list[idx] = r }
        save(list)
    }

    public static func delete(id: UUID) {
        save(all().filter { $0.id != id })
    }
}
