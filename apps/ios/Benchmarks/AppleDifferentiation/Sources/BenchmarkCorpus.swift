// BenchmarkCorpus.swift
// Decodable model + loader for the checked-in Apple-differentiation corpus.
// Foundation-only; compiled together with the real Tono Shared analyzer so the
// benchmark exercises shipping code, not a re-implementation.

import Foundation

struct BenchmarkCorpus: Decodable {
    let schemaVersion: String
    let lane: String
    let appleBaseline: String
    let differentiatedJob: String
    let cases: [BenchmarkCase]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case lane
        case appleBaseline = "apple_baseline"
        case differentiatedJob = "differentiated_job"
        case cases
    }

    static func load(from path: String) throws -> BenchmarkCorpus {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BenchmarkCorpus.self, from: data)
    }
}

struct BenchmarkCase: Decodable {
    let id: String
    let category: String
    let context: String
    let text: String
    let grammaticallyValid: Bool
    let expectedNudge: Bool
    let mustNotNudge: Bool?
    let expectedMinRisk: String?
    let expectedMaxRisk: String?
    let howItMayLand: String

    enum CodingKeys: String, CodingKey {
        case id, category, context, text
        case grammaticallyValid = "grammatically_valid"
        case expectedNudge = "expected_nudge"
        case mustNotNudge = "must_not_nudge"
        case expectedMinRisk = "expected_min_risk"
        case expectedMaxRisk = "expected_max_risk"
        case howItMayLand = "how_it_may_land"
    }

    var isBenignControl: Bool { !expectedNudge }
}

// Severity ordering for RiskLevel, which is not Comparable in the shipping type.
enum Severity {
    static func rank(_ level: RiskLevel) -> Int {
        switch level {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func rank(_ raw: String) -> Int {
        RiskLevel(rawValue: raw).map(rank) ?? 1
    }

    /// A case counts as "detected" when the analyzer surfaces medium-or-higher
    /// risk — the threshold at which Tono would actually nudge before send.
    static func isDetected(_ level: RiskLevel) -> Bool { rank(level) >= 1 }
}
