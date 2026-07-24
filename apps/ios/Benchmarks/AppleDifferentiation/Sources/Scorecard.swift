// Scorecard.swift
// Finite, deterministic scorecard + blind-rating worksheet generator.
//
// What is machine-scored here (against the shipping offline MockToneAnalyzer):
//   - detection recall on socially-risky cases
//   - benign false-positive rate / specificity
//   - precision
//   - risk-severity match
//   - rewrite-distinctness proxy (are the four axes textually different)
//
// What is deliberately left to BLIND HUMAN rating (worksheet):
//   - explanation usefulness, rewrite diversity (quality), intent preservation,
//     and risk-reduction — these require judgment and the WIRED LLM backend,
//     which this lane does not call. No Apple API is called; Apple capability
//     facts are the baseline, not synthetic comparison rows.

import Foundation

struct CaseOutcome {
    let id: String
    let category: String
    let context: String
    let expectedNudge: Bool
    let mustNotNudge: Bool
    let detected: Bool
    let risk: RiskLevel
    let severityMatched: Bool
    let rewritesDistinct: Bool
}

struct ScoreReport {
    let total: Int
    let riskyCount: Int
    let benignCount: Int
    let mustNotNudgeCount: Int
    let truePositives: Int
    let falsePositives: Int
    let severityMatches: Int
    let distinctRewriteCases: Int
    let perCategory: [(String, Int)]
    let outcomes: [CaseOutcome]

    var recall: Double { riskyCount == 0 ? 0 : Double(truePositives) / Double(riskyCount) }
    var falsePositiveRate: Double { benignCount == 0 ? 0 : Double(falsePositives) / Double(benignCount) }
    var specificity: Double { 1 - falsePositiveRate }
    var precision: Double {
        let denom = truePositives + falsePositives
        return denom == 0 ? 0 : Double(truePositives) / Double(denom)
    }
}

enum Scorecard {

    static func score(_ corpus: BenchmarkCorpus,
                      analyze: (AnalysisRequest) -> ToneAnalysis) -> ScoreReport {
        var outcomes: [CaseOutcome] = []
        var tp = 0, fp = 0, sevMatch = 0, distinct = 0
        var categoryCounts: [String: Int] = [:]

        for c in corpus.cases {
            categoryCounts[c.category, default: 0] += 1
            let a = analyze(AnalysisRequest(draft: c.text, mode: .coach))
            let detected = Severity.isDetected(a.riskLevel)

            let sevOK: Bool = {
                guard c.expectedNudge, let min = c.expectedMinRisk else { return false }
                return Severity.rank(a.riskLevel) >= Severity.rank(min)
            }()
            if c.expectedNudge && sevOK { sevMatch += 1 }

            // Distinctness proxy: the four axis texts are mutually distinct.
            let texts = a.suggestions.map(\.text)
            let rewritesDistinct = texts.count == 4 && Set(texts).count == 4
            if rewritesDistinct { distinct += 1 }

            if c.expectedNudge {
                if detected { tp += 1 }
            } else {
                if detected { fp += 1 }
            }

            outcomes.append(CaseOutcome(
                id: c.id, category: c.category, context: c.context,
                expectedNudge: c.expectedNudge, mustNotNudge: c.mustNotNudge ?? false,
                detected: detected, risk: a.riskLevel,
                severityMatched: sevOK, rewritesDistinct: rewritesDistinct))
        }

        let risky = corpus.cases.filter(\.expectedNudge).count
        let benign = corpus.cases.count - risky
        let mustNot = corpus.cases.filter { $0.mustNotNudge == true }.count
        let perCat = categoryCounts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        return ScoreReport(
            total: corpus.cases.count, riskyCount: risky, benignCount: benign,
            mustNotNudgeCount: mustNot, truePositives: tp, falsePositives: fp,
            severityMatches: sevMatch, distinctRewriteCases: distinct,
            perCategory: perCat, outcomes: outcomes)
    }

    // MARK: - Rendering (deterministic; no timestamps)

    static func markdown(_ corpus: BenchmarkCorpus, _ r: ScoreReport,
                         contracts: [ContractResult]) -> String {
        func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
        var s = ""
        s += "# Apple-Differentiation Scorecard\n\n"
        s += "Lane: `\(corpus.lane)` · Corpus schema `\(corpus.schemaVersion)`\n\n"
        s += "> Regenerate with `./run.sh`. Output is deterministic (no timestamps), so a\n"
        s += "> committed copy stays byte-identical unless the corpus or analyzer changes.\n\n"

        s += "## Differentiated job under test\n\n> \(corpus.differentiatedJob)\n\n"
        s += "## Apple baseline (capability fact, not synthetic output)\n\n\(corpus.appleBaseline)\n\n"

        s += "## 1. Product-contract gate (shipping types)\n\n"
        let passed = contracts.filter(\.passed).count
        s += "**\(passed)/\(contracts.count) contracts pass.** These fail the build gate if Tono\n"
        s += "regresses toward a generic, rewrite-only product.\n\n"
        s += "| ID | Contract | Result |\n|----|----------|--------|\n"
        for c in contracts {
            s += "| \(c.id) | \(c.name) | \(c.passed ? "PASS" : "**FAIL**") |\n"
        }
        s += "\n"

        s += "## 2. Corpus composition\n\n"
        s += "- Total cases: **\(r.total)**\n"
        s += "- Socially-risky (should nudge): **\(r.riskyCount)**\n"
        s += "- Benign controls (should NOT nudge): **\(r.benignCount)**, of which must-not-nudge adversarial: **\(r.mustNotNudgeCount)**\n"
        s += "- All risky cases are grammatically valid by construction — the exact blind spot of a proofreader.\n\n"
        s += "| Category | Cases |\n|----------|-------|\n"
        for (k, v) in r.perCategory { s += "| \(k) | \(v) |\n" }
        s += "\n"

        s += "## 3. Offline analyzer measurement (MockToneAnalyzer)\n\n"
        s += "This is the shipped **offline fallback**, not the LLM backend. It is measured here\n"
        s += "honestly to establish the floor and to prove the gate runs end-to-end.\n\n"
        s += "| Metric | Value |\n|--------|-------|\n"
        s += "| Detection recall on risky cases | **\(pct(r.recall))** (\(r.truePositives)/\(r.riskyCount)) |\n"
        s += "| Benign false-positive rate | **\(pct(r.falsePositiveRate))** (\(r.falsePositives)/\(r.benignCount)) |\n"
        s += "| Specificity | \(pct(r.specificity)) |\n"
        s += "| Precision | \(pct(r.precision)) |\n"
        s += "| Risk-severity match (risky) | \(r.severityMatches)/\(r.riskyCount) |\n"
        s += "| Cases with 4 distinct rewrite texts | \(r.distinctRewriteCases)/\(r.total) |\n\n"

        s += "### Per-case detail\n\n"
        s += "| id | category | expect nudge | offline risk | detected | sev-match | distinct rewrites |\n"
        s += "|----|----------|:---:|:---:|:---:|:---:|:---:|\n"
        for o in r.outcomes {
            s += "| \(o.id) | \(o.category) | \(o.expectedNudge ? "Y" : "n") | \(o.risk.rawValue) | \(o.detected ? "Y" : "·") | \(o.severityMatched ? "Y" : "·") | \(o.rewritesDistinct ? "Y" : "·") |\n"
        }
        s += "\n"

        s += "## 4. Reading the result\n\n"
        s += "The **contract gate** proves the schema can express the differentiated outcome\n"
        s += "(risk + perception + subtext + reason + four distinct axes + risk-after). The\n"
        s += "**offline recall** is deliberately low: the keyword MockToneAnalyzer catches only a\n"
        s += "few overt patterns and cannot read contempt, coercion, or context. That is the gap\n"
        s += "integration must close with the wired LLM backend — this harness is the gate that\n"
        s += "will then measure it. No superiority to Apple is claimed here; a rewrite-only tool\n"
        s += "would score 0% recall on this corpus by definition, because every case is already\n"
        s += "grammatically correct.\n\n"
        s += "The quality axes that decide the product — explanation usefulness, rewrite\n"
        s += "diversity, intent preservation, and measurable risk reduction — are rated by humans\n"
        s += "in `report/blind_rating_worksheet.csv` (labels held in `report/answer_key.csv`).\n"
        return s
    }

    static func blindWorksheetCSV(_ corpus: BenchmarkCorpus) -> String {
        var rows: [String] = []
        rows.append([
            "id", "context", "message",
            "model_perception", "model_subtext", "model_reason",
            "rewrite_warmer", "rewrite_clearer", "rewrite_funnier", "rewrite_safer",
            "human_detected_risk_Y_N", "explanation_useful_0_2", "rewrite_diversity_0_2",
            "intent_preserved_0_2", "risk_reduced_0_2", "notes"
        ].map(csv).joined(separator: ","))
        // Blind: category and expected label are intentionally withheld here.
        for c in corpus.cases {
            rows.append([
                c.id, c.context, c.text,
                "", "", "", "", "", "", "",  // model + human columns filled during rating
                "", "", "", "", "", ""
            ].map(csv).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func answerKeyCSV(_ corpus: BenchmarkCorpus) -> String {
        var rows: [String] = []
        rows.append(["id", "category", "context", "expected_nudge", "expected_min_risk",
                     "expected_max_risk", "must_not_nudge", "how_it_may_land"].map(csv).joined(separator: ","))
        for c in corpus.cases {
            rows.append([
                c.id, c.category, c.context,
                c.expectedNudge ? "yes" : "no",
                c.expectedMinRisk ?? "",
                c.expectedMaxRisk ?? "",
                (c.mustNotNudge ?? false) ? "yes" : "no",
                c.howItMayLand
            ].map(csv).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func csv(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
