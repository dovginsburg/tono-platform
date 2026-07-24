// main.swift
// Entry point for the Apple-differentiation benchmark harness.
//
//   bench <corpus.json> [--emit <outdir>]
//
// Runs the product-contract gate and the corpus measurement against the real
// shipping analyzer. Exits non-zero if ANY contract fails (the regression
// gate). With --emit, writes the deterministic scorecard + blind worksheet +
// answer key into <outdir>.

import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let corpusPath = args.first else { fail("usage: bench <corpus.json> [--emit <outdir>]") }

var emitDir: String?
if let i = args.firstIndex(of: "--emit") {
    guard i + 1 < args.count else { fail("--emit requires a directory") }
    emitDir = args[i + 1]
}

let corpus: BenchmarkCorpus
do {
    corpus = try BenchmarkCorpus.load(from: corpusPath)
} catch {
    fail("could not load corpus at \(corpusPath): \(error)")
}

// 1. Contract gate.
let contracts = ProductContract.runAll()
print("== Product-contract gate ==")
for c in contracts {
    print("  [\(c.passed ? "PASS" : "FAIL")] \(c.id) \(c.name)")
    if !c.passed { print("        \(c.detail)") }
}
let contractsPassed = contracts.filter(\.passed).count
print("  \(contractsPassed)/\(contracts.count) contracts pass\n")

// 2. Corpus measurement against the real MockToneAnalyzer (offline fallback).
let report = Scorecard.score(corpus) { ProductContract.blockingAnalyze($0) }
print("== Corpus measurement (offline MockToneAnalyzer) ==")
print(String(format: "  cases=%d  risky=%d  benign=%d  must-not-nudge=%d",
             report.total, report.riskyCount, report.benignCount, report.mustNotNudgeCount))
print(String(format: "  recall=%.0f%%  benign-FP-rate=%.0f%%  precision=%.0f%%  sev-match=%d/%d",
             report.recall * 100, report.falsePositiveRate * 100, report.precision * 100,
             report.severityMatches, report.riskyCount))
print("  (offline recall is expected to be low — the gap the wired LLM backend must close)\n")

// 3. Optional artifact emission (deterministic).
if let dir = emitDir {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func write(_ name: String, _ contents: String) {
        let path = (dir as NSString).appendingPathComponent(name)
        do { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { fail("could not write \(path): \(error)") }
        print("  wrote \(path)")
    }
    print("== Emitting artifacts ==")
    write("scorecard.md", Scorecard.markdown(corpus, report, contracts: contracts))
    write("blind_rating_worksheet.csv", Scorecard.blindWorksheetCSV(corpus))
    write("answer_key.csv", Scorecard.answerKeyCSV(corpus))
    print("")
}

// 4. Exit status = contract gate.
if contractsPassed != contracts.count {
    fail("\(contracts.count - contractsPassed) product-contract assertion(s) failed")
}
print("OK: product-contract gate green.")
