// UserMemory.swift
// On-device memory store. Learns from rewrite-tap patterns and lets users
// add manual facts about themselves. Facts are sent as short context hints
// with each LLM request so rewrites improve without repeating the same
// analysis. Everything stays on device — only the plain-text hint strings
// (e.g. "tends to sound cold") are sent to the backend; no raw history,
// no message content, no names.

import Foundation

// MARK: - MemoryFact

public struct MemoryFact: Codable, Identifiable, Equatable {
    public let id: UUID
    public var content: String
    public var source: Source
    public var category: Category
    public var createdAt: Date
    public var useCount: Int

    public enum Source: String, Codable {
        case inferred, manual
    }

    public enum Category: String, Codable, CaseIterable {
        case tendency     = "Tendencies"
        case communication = "Communication style"
        case profile       = "About me"
    }

    public init(
        id: UUID = UUID(),
        content: String,
        source: Source,
        category: Category,
        createdAt: Date = Date(),
        useCount: Int = 1
    ) {
        self.id = id
        self.content = content
        self.source = source
        self.category = category
        self.createdAt = createdAt
        self.useCount = useCount
    }
}

// MARK: - Recent session (sliding-window inference)

struct RecentSession: Codable {
    let flags: [String]
    let chosenAxis: String
    let ts: TimeInterval

    enum CodingKeys: String, CodingKey {
        case flags, ts
        case chosenAxis = "axis"
    }
}

// MARK: - UserMemory

public enum UserMemory {

    // Sliding window: look at the most recent N sessions to decide
    // whether a pattern is strong enough to store as a fact.
    private static let maxSessions = 10
    private static let inferenceWindow = 5
    private static let inferenceThreshold = 3

    // MARK: Public read API

    /// All facts sorted by useCount desc, then newest first.
    public static func allFacts() -> [MemoryFact] {
        loadFacts().sorted {
            $0.useCount != $1.useCount
                ? $0.useCount > $1.useCount
                : $0.createdAt > $1.createdAt
        }
    }

    /// Up to `limit` hint strings ready for injection into LLM prompts.
    public static func topFacts(limit: Int = 5) -> [String] {
        Array(allFacts().prefix(limit).map(\.content))
    }

    // MARK: Public write API

    /// Add a user-authored fact. No-op on duplicate content.
    public static func addManual(content: String, category: MemoryFact.Category) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var facts = loadFacts()
        guard !facts.contains(where: { $0.content.lowercased() == trimmed.lowercased() }) else { return }
        facts.append(MemoryFact(content: trimmed, source: .manual, category: category))
        saveFacts(facts)
    }

    /// Delete one fact by ID.
    public static func remove(id: UUID) {
        var facts = loadFacts()
        facts.removeAll { $0.id == id }
        saveFacts(facts)
    }

    /// Wipe all facts and session history.
    public static func removeAll() {
        SharedStore.defaults.removeObject(forKey: SharedKeys.memoryFacts)
        SharedStore.defaults.removeObject(forKey: SharedKeys.recentSessions)
    }

    /// Called after every successful coach session. Records the session
    /// into the sliding window, then runs the inference engine.
    public static func recordSession(flags: [String], chosenAxis: String) {
        var sessions = loadSessions()
        sessions.append(RecentSession(
            flags: flags,
            chosenAxis: chosenAxis,
            ts: Date().timeIntervalSince1970
        ))
        if sessions.count > maxSessions {
            sessions = Array(sessions.suffix(maxSessions))
        }
        saveSessions(sessions)
        inferFacts(from: sessions)
    }

    // MARK: Inference engine

    private static func inferFacts(from sessions: [RecentSession]) {
        let window = Array(sessions.suffix(inferenceWindow))
        guard window.count >= inferenceWindow else { return }

        var facts = loadFacts()

        // Flag-based patterns
        let flagRules: [(substring: String, content: String, category: MemoryFact.Category)] = [
            ("passive-aggressive",
             "Tends to use passive-aggressive phrasing without realizing it",
             .tendency),
            ("ambiguous ask",
             "Often sends messages with ambiguous asks that lack a clear deadline",
             .tendency),
            ("terse",
             "Messages sometimes read as cold or dismissive when kept very short",
             .tendency),
            ("unstated assumption",
             "Frequently makes unstated assumptions in messages",
             .tendency),
            ("guilt",
             "Writing sometimes contains subtle guilt-tripping",
             .tendency),
        ]

        for rule in flagRules {
            let hits = window.filter { session in
                session.flags.contains { $0.localizedCaseInsensitiveContains(rule.substring) }
            }.count
            if hits >= inferenceThreshold {
                upsert(content: rule.content, category: rule.category, in: &facts)
            }
        }

        // Axis-choice patterns
        let axisRules: [(axis: String, content: String, category: MemoryFact.Category)] = [
            ("warmer",
             "Default tone often runs cold — warmth rewrites are frequently preferred",
             .tendency),
            ("clearer",
             "Often writes messages with unclear asks or missing details",
             .tendency),
            ("safer",
             "Frequently sends messages that could be misread — prefers safer rewrites",
             .tendency),
            ("funnier",
             "Prefers a lighter, more playful tone when the context allows",
             .communication),
        ]

        for rule in axisRules {
            let hits = window.filter { $0.chosenAxis == rule.axis }.count
            if hits >= inferenceThreshold {
                upsert(content: rule.content, category: rule.category, in: &facts)
            }
        }

        saveFacts(facts)
    }

    /// If a fact with the same content already exists, increment its useCount;
    /// otherwise append a new fact.
    private static func upsert(
        content: String,
        category: MemoryFact.Category,
        in facts: inout [MemoryFact]
    ) {
        if let idx = facts.firstIndex(where: {
            $0.content == content && $0.source == .inferred
        }) {
            facts[idx].useCount += 1
        } else if !facts.contains(where: {
            $0.content.lowercased() == content.lowercased()
        }) {
            facts.append(MemoryFact(content: content, source: .inferred, category: category))
        }
    }

    // MARK: Persistence

    private static func loadFacts() -> [MemoryFact] {
        guard let data = SharedStore.defaults.data(forKey: SharedKeys.memoryFacts),
              let facts = try? JSONDecoder().decode([MemoryFact].self, from: data)
        else { return [] }
        return facts
    }

    private static func saveFacts(_ facts: [MemoryFact]) {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        SharedStore.defaults.set(data, forKey: SharedKeys.memoryFacts)
    }

    private static func loadSessions() -> [RecentSession] {
        guard let data = SharedStore.defaults.data(forKey: SharedKeys.recentSessions),
              let sessions = try? JSONDecoder().decode([RecentSession].self, from: data)
        else { return [] }
        return sessions
    }

    private static func saveSessions(_ sessions: [RecentSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        SharedStore.defaults.set(data, forKey: SharedKeys.recentSessions)
    }
}
