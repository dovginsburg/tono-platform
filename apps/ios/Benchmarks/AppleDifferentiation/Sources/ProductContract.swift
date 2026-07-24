// ProductContract.swift
// Executable product-contract assertions. These are the regression gate that
// keeps Tono from decaying into a generic, Apple-Writing-Tools-like
// rewrite-only product. Every assertion runs against the REAL shipping types
// (ToneAnalysis / RewriteAxis / RiskLevel / TonoCoachClient / FeatureFlag),
// compiled from apps/ios via run.sh. A failure here means the differentiated
// contract has been broken in source, not merely unmet by a model.

import Foundation

struct ContractResult {
    let id: String
    let name: String
    let passed: Bool
    let detail: String
}

enum ProductContract {

    /// Run every contract. Synchronous; the one async analyzer call is bridged.
    static func runAll() -> [ContractResult] {
        var out: [ContractResult] = []
        out.append(c1_diagnosisFieldsAreDistinctFromRewrites())
        out.append(c2_coachYieldsExactlyFourDistinctAxes())
        out.append(c3_riskIsThreeTierGuidance())
        out.append(c4_schemaSupportsRiskAfter())
        out.append(c5_axisSemanticsAreDistinct())
        out.append(c6_clientFailsClosedOnRewriteOnlyPayload())
        out.append(c7_readModeDiagnosesReceivedMessages())
        out.append(c8_manualCoachIsDiagnosisPlusRewrite())
        out.append(c9_recipientMemoryNotClaimedUnlessWired())
        return out
    }

    // C1 — A ToneAnalysis is NOT a rewrite blob: it carries risk + a "how it
    // lands" perception + subtext + a concrete reason. If any collapses to
    // empty on a well-formed payload, the diagnosis product is gone.
    private static func c1_diagnosisFieldsAreDistinctFromRewrites() -> ContractResult {
        let json = """
        {"risk_level":"high","perception":"Might land as a guilt-trip. 📩",
         "subtext":"frustrated, wants acknowledgment",
         "risk_reason":"Implies they ignored you.",
         "suggestions":[
           {"axis":"warmer","text":"a"},{"axis":"clearer","text":"b"},
           {"axis":"funnier","text":"c"},{"axis":"safer","text":"d"}],
         "flags":["passive-aggressive"]}
        """
        do {
            let a = try ToneEngine.decode(json)
            let ok = a.riskLevel == .high
                && !a.perception.trimmingCharacters(in: .whitespaces).isEmpty
                && !a.subtext.trimmingCharacters(in: .whitespaces).isEmpty
                && !(a.reason ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                && !a.flags.isEmpty
            return ContractResult(id: "C1", name: "Diagnosis fields survive decode (risk+perception+subtext+reason+flags)",
                                  passed: ok, detail: ok ? "risk/perception/subtext/reason/flags all populated" : "a diagnosis field decoded empty")
        } catch {
            return ContractResult(id: "C1", name: "Diagnosis fields survive decode", passed: false, detail: "decode threw: \(error)")
        }
    }

    // C2 — Coach must present exactly the four canonical axes, distinct and
    // complete. Partial sets must throw, not silently degrade to fewer choices.
    private static func c2_coachYieldsExactlyFourDistinctAxes() -> ContractResult {
        let expected: [RewriteAxis] = [.warmer, .clearer, .funnier, .safer]
        let full = expected.map { RewriteSuggestion(axis: $0, text: "x") }
        let incomplete = [RewriteSuggestion(axis: .warmer, text: "x"),
                          RewriteSuggestion(axis: .clearer, text: "y")]
        let allCasesOK = RewriteAxis.allCases == expected
        var completeOK = false
        var rejectsIncomplete = false
        if let canonical = try? full.canonicalCoachChoices() {
            completeOK = canonical.map(\.axis) == expected
        }
        do { _ = try incomplete.canonicalCoachChoices() } catch { rejectsIncomplete = true }
        let ok = allCasesOK && completeOK && rejectsIncomplete
        return ContractResult(id: "C2", name: "Coach = exactly four canonical distinct axes; partial sets rejected",
                              passed: ok, detail: "allCases=\(allCasesOK) complete=\(completeOK) rejectsIncomplete=\(rejectsIncomplete)")
    }

    // C3 — Risk is a three-tier signal with guidance-framed labels, not a
    // pass/fail proofread verdict.
    private static func c3_riskIsThreeTierGuidance() -> ContractResult {
        let levels: [RiskLevel] = [.low, .medium, .high]
        let names = levels.map(\.displayName)
        let distinct = Set(names).count == 3
        let notRaw = names != levels.map(\.rawValue) // labels are coaching copy, not "low/medium/high"
        let icons = Set(levels.map(\.systemIcon)).count == 3
        let ok = distinct && notRaw && icons
        return ContractResult(id: "C3", name: "Risk is 3-tier guidance with distinct labels + a11y icons",
                              passed: ok, detail: "labels=\(names) distinctIcons=\(icons)")
    }

    // C4 — The schema can express risk AFTER a rewrite. Without this field the
    // "measurable interpersonal-risk reduction" claim is unbacked.
    private static func c4_schemaSupportsRiskAfter() -> ContractResult {
        let s = RewriteSuggestion(axis: .safer, text: "x", rationale: "r", riskAfter: .low)
        let json = """
        {"risk_level":"high","perception":"p","subtext":"s","risk_reason":"why",
         "suggestions":[
           {"axis":"warmer","text":"a","risk_after":"medium"},
           {"axis":"clearer","text":"b","risk_after":"low"},
           {"axis":"funnier","text":"c"},
           {"axis":"safer","text":"d","risk_after":"low"}],
         "flags":[]}
        """
        let decodedCarries = (try? ToneEngine.decode(json))?.suggestions.contains { $0.riskAfter != nil } ?? false
        let ok = s.riskAfter == .low && decodedCarries
        return ContractResult(id: "C4", name: "RewriteSuggestion carries risk-after (enables risk-reduction metric)",
                              passed: ok, detail: "constructed=\(s.riskAfter?.rawValue ?? "nil") decodedCarries=\(decodedCarries)")
    }

    // C5 — The four axes must be semantically distinct coaching directions, not
    // four synonyms. If help/bestWhen copy collapses, the product is a synonym
    // machine (exactly the Apple-rewrite trap).
    private static func c5_axisSemanticsAreDistinct() -> ContractResult {
        let axes = RewriteAxis.allCases
        let help = Set(axes.map(\.helpText))
        let bestWhen = Set(axes.map(\.bestWhen))
        let display = Set(axes.map(\.displayName))
        let ok = help.count == axes.count && bestWhen.count == axes.count && display.count == axes.count
        return ContractResult(id: "C5", name: "Rewrite axes are semantically distinct (help + bestWhen + name)",
                              passed: ok, detail: "helpDistinct=\(help.count) bestWhenDistinct=\(bestWhen.count) of \(axes.count)")
    }

    // C6 — The keyboard client fails CLOSED on a degraded/rewrite-only payload
    // (missing axis, duplicate axis, unsupported axis, blank text). It must
    // reject rather than render a partial, misleading result.
    private static func c6_clientFailsClosedOnRewriteOnlyPayload() -> ContractResult {
        func body(_ s: String) -> Data {
            "{\"risk_level\":\"low\",\"perception\":\"p\",\"subtext\":\"s\",\"suggestions\":[\(s)],\"flags\":[]}".data(using: .utf8)!
        }
        let missing = body("{\"axis\":\"warmer\",\"text\":\"a\"},{\"axis\":\"clearer\",\"text\":\"b\"}")
        let dup = body("{\"axis\":\"warmer\",\"text\":\"a\"},{\"axis\":\"warmer\",\"text\":\"b\"},{\"axis\":\"clearer\",\"text\":\"c\"},{\"axis\":\"funnier\",\"text\":\"d\"}")
        let unsupported = body("{\"axis\":\"formal\",\"text\":\"a\"},{\"axis\":\"clearer\",\"text\":\"b\"},{\"axis\":\"funnier\",\"text\":\"c\"},{\"axis\":\"safer\",\"text\":\"d\"}")
        let full = body("{\"axis\":\"warmer\",\"text\":\"a\"},{\"axis\":\"clearer\",\"text\":\"b\"},{\"axis\":\"funnier\",\"text\":\"c\"},{\"axis\":\"safer\",\"text\":\"d\"}")
        func rejects(_ d: Data) -> Bool { (try? TonoCoachClient.decode(d)) == nil }
        let acceptsFull = (try? TonoCoachClient.decode(full)) != nil
        let ok = rejects(missing) && rejects(dup) && rejects(unsupported) && acceptsFull
        return ContractResult(id: "C6", name: "Keyboard client fails closed on missing/duplicate/unsupported axes",
                              passed: ok, detail: "rejectMissing=\(rejects(missing)) rejectDup=\(rejects(dup)) rejectUnsupported=\(rejects(unsupported)) acceptsFull=\(acceptsFull)")
    }

    // C7 — Tono can DIAGNOSE a received message (read mode) with no rewrites —
    // a job Apple Writing Tools does not do at all.
    private static func c7_readModeDiagnosesReceivedMessages() -> ContractResult {
        let a = blockingAnalyze(AnalysisRequest(draft: "As per my last message, please respond.", mode: .read))
        let ok = a.suggestions.isEmpty
            && !a.perception.trimmingCharacters(in: .whitespaces).isEmpty
            && Severity.rank(a.riskLevel) >= 1
        return ContractResult(id: "C7", name: "Read mode diagnoses received messages (perception, no rewrites)",
                              passed: ok, detail: "suggestions=\(a.suggestions.count) risk=\(a.riskLevel.rawValue)")
    }

    // C8 — Manual Coach remains available AND is diagnosis+rewrite, not
    // rewrite-only: a coach analysis returns both a perception and the four axes.
    private static func c8_manualCoachIsDiagnosisPlusRewrite() -> ContractResult {
        let a = blockingAnalyze(AnalysisRequest(draft: "As per my last message, the report was due yesterday.", mode: .coach))
        let hasPerception = !a.perception.trimmingCharacters(in: .whitespaces).isEmpty
        let axes = Set(a.suggestions.map(\.axis))
        let ok = hasPerception && axes == Set(RewriteAxis.allCases)
        return ContractResult(id: "C8", name: "Manual Coach stays available as diagnosis + four rewrites",
                              passed: ok, detail: "perception=\(hasPerception) axes=\(axes.count)")
    }

    // C9 — Honesty gate: per-recipient memory must NOT be claimed as a live,
    // default-on capability, because the flag is dormant. If someone flips the
    // default to true here without wiring it, the "Live remembers your
    // recipient" claim would become false-by-default. Guard the default.
    private static func c9_recipientMemoryNotClaimedUnlessWired() -> ContractResult {
        let dormant = FeatureFlag.recipientMemory.defaultValue == false
        // The plumbing (a place to pass recipient context) may exist even while
        // the capability is dormant; that is fine. The contract is only that it
        // is OFF by default until integration wires it.
        let plumbingExists = AnalysisRequest(draft: "x", recipientHint: "boss — formal").recipientHint != nil
        let ok = dormant && plumbingExists
        return ContractResult(id: "C9", name: "Recipient memory dormant-by-default (not falsely claimed as live)",
                              passed: ok, detail: "defaultOff=\(dormant) plumbingExists=\(plumbingExists)")
    }

    // MARK: - async bridge

    static func blockingAnalyze(_ req: AnalysisRequest) -> ToneAnalysis {
        let sem = DispatchSemaphore(value: 0)
        var result: ToneAnalysis!
        Task {
            result = try? await MockToneAnalyzer().analyze(req)
            sem.signal()
        }
        sem.wait()
        return result
    }
}
