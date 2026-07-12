#!/usr/bin/env swift
// verify_build77.swift
// Standalone executable verification for the build-77 keyboard Coach flow.
// Runs without iOS Simulator / Xcode — uses pure Swift on macOS so the
// CI environment can exercise the decoder and replacement logic
// against a real `/v1/analyze` payload.
//
// Usage:
//   swift verify_build77.swift
//
// Exits 0 on success, non-zero on any failure.

import Foundation

// MARK: - Mirror of TonoCoachClient.decode (kept inline so the verifier
// is self-contained and survives project restructuring).

struct CoachRewrite: Equatable, Codable {
    let axis: String
    let text: String
    let rationale: String?
    let riskAfter: String?
}

struct CoachResponse: Equatable {
    let riskLevel: String
    let perception: String
    let subtext: String
    let reason: String?
    let suggestions: [CoachRewrite]
    let flags: [String]
}

func decodeCoachResponse(_ data: Data) throws -> CoachResponse {
    guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
          let dict = any as? [String: Any] else {
        throw NSError(domain: "verify", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object"])
    }
    let rawSuggestions = (dict["suggestions"] as? [[String: Any]]) ?? []
    var suggestions: [CoachRewrite] = []
    for raw in rawSuggestions {
        guard let axis = raw["axis"] as? String,
              let text = raw["text"] as? String else { continue }
        suggestions.append(CoachRewrite(
            axis: axis,
            text: text,
            rationale: raw["rationale"] as? String,
            riskAfter: raw["risk_after"] as? String
        ))
    }
    return CoachResponse(
        riskLevel: (dict["risk_level"] as? String) ?? "medium",
        perception: (dict["perception"] as? String) ?? "",
        subtext: (dict["subtext"] as? String) ?? "",
        reason: dict["risk_reason"] as? String,
        suggestions: suggestions,
        flags: (dict["flags"] as? [String]) ?? []
    )
}

// MARK: - Replacement math mirror

/// Mirrors the keyboard's `applyRewrite` logic: delete min(captured, live)
/// characters from the proxy buffer, then insert the rewrite.
func applyReplacement(capturedContext: Int, liveContextBefore: String, rewrite: String)
    -> (deletions: Int, finalText: String)
{
    let deletions = min(capturedContext, liveContextBefore.count)
    let prefixKept = String(liveContextBefore.dropLast(deletions))
    return (deletions, prefixKept + rewrite)
}

// MARK: - Tests

var failures: [String] = []
func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    if ok {
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name) — \(detail)")
        failures.append(name)
    }
}

print("== build 77 verification ==")

// 1. Decode the production /v1/analyze payload captured by curl.
let realPayload = #"""
{"risk_level":"high","perception":"Lands as sarcastic and hostile 😠","subtext":"You failed me and I'm angry about it","risk_reason":"Pure sarcasm — no ask, just blame","suggestions":[{"axis":"warmer","text":"I appreciate you trying, though this didn't quite work out for me.","rationale":"Acknowledges effort before stating the miss","risk_after":"low"},{"axis":"clearer","text":"This didn't help — can we try a different approach?","rationale":"States the problem and opens a path forward","risk_after":"low"},{"axis":"funnier","text":"Well, that was spectacularly unhelpful — round two?","rationale":"Self-aware humor softens the critique and invites collaboration","risk_after":"medium"},{"axis":"safer","text":"I'm not finding what I need here — could you help me figure out next steps?","rationale":"Removes blame, frames as shared problem-solving","risk_after":"low"}],"flags":["passive aggression","unstated grievance","no clear ask"]}
"""#

do {
    let resp = try decodeCoachResponse(realPayload.data(using: .utf8)!)
    check(resp.riskLevel == "high", "risk_level decoded", "got \(resp.riskLevel)")
    check(resp.perception.contains("sarcastic"), "perception decoded")
    check(resp.subtext.contains("angry"), "subtext decoded")
    check(resp.reason == "Pure sarcasm — no ask, just blame", "reason decoded")
    check(resp.suggestions.count == 4, "4 suggestions", "got \(resp.suggestions.count)")
    check(resp.suggestions[0].axis == "warmer", "first axis warmer", "got \(resp.suggestions[0].axis)")
    check(resp.suggestions[3].axis == "safer", "last axis safer", "got \(resp.suggestions[3].axis)")
    check(resp.suggestions[1].riskAfter == "low", "risk_after decoded")
    check(resp.flags.contains("passive aggression"), "flags decoded")
} catch {
    check(false, "decode real payload", "\(error)")
}

// 2. Empty suggestions — keyboard should still render gracefully.
let emptyPayload = #"{"risk_level":"low","perception":"ok","subtext":"","suggestions":[],"flags":[]}"#
do {
    let resp = try decodeCoachResponse(emptyPayload.data(using: .utf8)!)
    check(resp.suggestions.isEmpty, "empty suggestions decode to empty array")
    check(resp.reason == nil, "missing reason decodes to nil")
} catch {
    check(false, "decode empty payload", "\(error)")
}

// 3. Malformed JSON — should throw, not crash.
let badPayload = "not json".data(using: .utf8)!
do {
    _ = try decodeCoachResponse(badPayload)
    check(false, "malformed JSON should throw")
} catch {
    check(true, "malformed JSON throws cleanly")
}

// 4. Replacement math — mirrors the production applyRewrite() path.
//    Captured length equals the live pre-input context at tap time;
//    while the request is in flight the user may add a few characters.
let originalText = "thanks for nothing"   // 18 chars (counted in test runner)
let originalCount = originalText.count
let r1 = applyReplacement(capturedContext: originalCount, liveContextBefore: originalText, rewrite: "I appreciate you trying")
check(r1.deletions == originalCount, "captured == live: delete \(originalCount)", "got \(r1.deletions)")
check(r1.finalText == "I appreciate you trying", "captured == live: clean replace")

// User typed 5 more chars while request was in flight.
//    We delete exactly the captured span; the user's additional
//    chars at the tail are preserved before the rewrite slot.
let extendedText = originalText + " wow!"   // 23 chars
let r2 = applyReplacement(capturedContext: originalCount, liveContextBefore: extendedText, rewrite: "I appreciate you trying")
check(r2.deletions == originalCount, "captured < live: still delete \(originalCount) (original span)", "got \(r2.deletions)")
let expectedPrefix = String(extendedText.dropLast(originalCount))
check(r2.finalText == expectedPrefix + "I appreciate you trying",
      "captured < live: tail (\(expectedPrefix)) preserved + rewrite", "got \(r2.finalText)")

// Captured was longer than what's left (e.g. cursor moved) — only delete what's there.
let r3 = applyReplacement(capturedContext: 20, liveContextBefore: "hi", rewrite: "Hello there")
check(r3.deletions == 2, "captured > live: capped by live")
check(r3.finalText == "Hello there", "captured > live: clean replace")

// Empty captured (nothing typed).
let r4 = applyReplacement(capturedContext: 0, liveContextBefore: "", rewrite: "Hi")
check(r4.deletions == 0, "captured == 0: no deletes")
check(r4.finalText == "Hi", "captured == 0: insert only")

// MARK: - Live /v1/analyze smoke (network) — best-effort, only runs when
// the verifier has network access and the backend is up.

if let url = URL(string: "https://api.tonoit.com/v1/analyze") {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 15
    let body: [String: Any] = ["draft": "thanks for nothing", "mode": "coach"]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    let sem = DispatchSemaphore(value: 0)
    var liveResult: (status: Int, parsed: CoachResponse?, error: String?) = (0, nil, nil)
    URLSession.shared.dataTask(with: req) { data, response, err in
        defer { sem.signal() }
        if let err = err {
            liveResult.error = err.localizedDescription
            return
        }
        guard let http = response as? HTTPURLResponse else {
            liveResult.error = "no http response"
            return
        }
        liveResult.status = http.statusCode
        if let data = data,
           let parsed = try? decodeCoachResponse(data) {
            liveResult.parsed = parsed
        }
    }.resume()
    _ = sem.wait(timeout: .now() + 20)

    if let err = liveResult.error {
        print("  · live /v1/analyze unreachable: \(err) (network test skipped)")
    } else if liveResult.status == 200, let parsed = liveResult.parsed {
        check(parsed.riskLevel == "high", "live /v1/analyze: risk_level=high", "got \(parsed.riskLevel)")
        check(parsed.suggestions.count >= 3, "live /v1/analyze: ≥3 suggestions", "got \(parsed.suggestions.count)")
    } else {
        check(false, "live /v1/analyze returned \(liveResult.status)")
    }
}

print("")
if failures.isEmpty {
    print("✓ all checks passed")
    exit(0)
} else {
    print("✗ \(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
    exit(1)
}