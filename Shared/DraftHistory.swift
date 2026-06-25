// DraftHistory.swift
// Ring buffer (last 5 entries) of tone-analysis results stored in the
// App Group so both the keyboard extension and the host app can read them.

import Foundation

public struct HistoryEntry: Codable, Identifiable {
    public var id: UUID
    public var draft: String
    public var analysis: ToneAnalysis
    public var date: Date

    public init(draft: String, analysis: ToneAnalysis) {
        self.id = UUID()
        self.draft = draft
        self.analysis = analysis
        self.date = Date()
    }
}

public enum DraftHistory {
    private static let maxEntries = 5

    public static func all() -> [HistoryEntry] {
        guard let data = SharedStore.defaults.data(forKey: SharedKeys.draftHistory),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    public static func push(draft: String, analysis: ToneAnalysis) {
        var entries = all()
        entries.insert(HistoryEntry(draft: draft, analysis: analysis), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        if let data = try? JSONEncoder().encode(entries) {
            SharedStore.defaults.set(data, forKey: SharedKeys.draftHistory)
        }
    }
}
