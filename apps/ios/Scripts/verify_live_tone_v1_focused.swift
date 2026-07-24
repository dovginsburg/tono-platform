// verify_live_tone_v1_focused.swift
// Standalone red/green verifier for the Live Tone v1 focused test spine.
// Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit, no XCTest.
//
// Mirrors the new XCTest-only `Tests/LiveToneV1AcceptanceTests.swift`
// additions (port of the build-90 legacy core coverage onto the v1
// closed-pattern shape) in a deterministic, runnable harness. The
// macOS runnable spine proves the new coverage is wired right; the
// XCTest class proves the same coverage against the proper test
// target.
//
// Compiles the REAL production sources (LiveToneClassifier.swift,
// LiveToneSession.swift) alongside this runner, so it exercises the
// shipping logic directly. The v1 contract collapses the build-90
// experiment's labeled-corpus / boundary / session state machine
// semantics onto a closed-pattern, no-clock, deterministic function
// over an isolated draft string.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/lt_focused \
//     Shared/LiveToneClassifier.swift \
//     Shared/LiveToneSession.swift \
//     Shared/LiveTonePrivacy.swift \
//     Shared/LiveToneKeys.swift \
//     Shared/LiveToneCopy.swift \
//     Scripts/verify_live_tone_v1_focused.swift && /tmp/lt_focused
//
// Exits 0 on success, non-zero on the first failure.

import Foundation

// MARK: - Tiny assert harness

var failures = 0
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}
func xfail(_ message: String) {
    failures += 1
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
}

// MARK: - Section 1: Classifier contract (port from legacy core tests)

func testClassifierVersionIsPinned() {
    check(LiveToneClassifier.version == 2,
          "LiveToneClassifier.version must remain pinned at 2 for the v1 contract")
    check(LiveToneClassifier.patternSetVersion == 1,
          "LiveToneClassifier.patternSetVersion must remain 1 for the v1 closed pattern set")
}

func testEmptyAndWhitespaceDraftsAreSilent() {
    let c = LiveToneClassifier()
    check(c.classify("") == .silent,
          "empty draft must classify as .silent")
    check(c.classify(" ") == .silent,
          "single-space draft must classify as .silent")
    check(c.classify("\n\n  \t  ") == .silent,
          "whitespace-only draft must classify as .silent")
}

func testDeterministicAcross100Runs() {
    let c = LiveToneClassifier()
    let samples = [
        "Sounds good, see you at 7!",
        "I'll kill you",
        "lol you're an idiot 😂",
        "He said \"you're worthless\" to me",
        "If you loved me you'd answer",
        "I want to kill myself",
        "You're killing me lol",
        "you never listen",
        "send the money or I'm posting the photos",
    ]
    let baseline = samples.map { c.classify($0) }
    for _ in 0..<100 {
        let again = samples.map { c.classify($0) }
        check(again == baseline,
              "classifier verdicts must be deterministic across 100 offline runs")
    }
}

func testNormalizationIsBoundedByMaxScannedCharacters() {
    let huge = String(repeating: "the quick brown fox. ", count: 10_000)
    check(huge.count > LiveToneClassifier.maxScannedCharacters,
          "huge corpus must exceed the 2,000-char scanned-character cap")
    check(LiveToneClassifier.normalize(huge).count <= LiveToneClassifier.maxScannedCharacters,
          "normalize(_:) must clamp drafts to the scanned-character cap")
    // The classifier itself never throws / never crashes on extreme
    // input; it returns a valid verdict (silent in this case).
    check(LiveToneClassifier().classify(huge) == .silent,
          "classify(_:) on extreme input must return a valid verdict (silent)")
}

func testNormalizationFoldsSmartPunctuationAndCollapsesSpacing() {
    let c = LiveToneClassifier()
    for input in [
        "honestly it's not rocket science.",
        "for the last time — stop.",
        "  LOOK,  AS  PER  MY  LAST note.",
    ] {
        let v = c.classify(input)
        let coherent: Bool
        if v.level == nil {
            coherent = v.category == nil || v.category == .crisis
        } else {
            coherent = v.category != nil && v.category != .crisis
        }
        check(coherent,
              "verdict shape must be coherent for normalized input \(input): \(v)")
    }
}

// MARK: - Section 2: Session state machine (port from legacy core tests)

func testSessionFreshStartsSilent() {
    let s = LiveToneSession()
    check(s.warning == .none,
          "fresh session must start with .none warning")
    check(s.dismissals.dismissed.isEmpty,
          "fresh session must have no dismissals")
    check(s.boundHash == nil,
          "fresh session must have nil boundHash")
}

func testSessionCrisisOrSilentClearsWarning() {
    var s = LiveToneSession(
        warning: .l2(.classBHyperbolicViolence),
        dismissals: .empty,
        boundHash: 42
    )
    s.apply(verdict: .crisisSilence, draftHash: 7)
    check(s.warning == .none,
          "crisisSilence verdict must clear the visible warning")
    check(s.boundHash == 7,
          "apply(_:draftHash:) must rebind boundHash even on cleared warning")
}

func testSessionVisibleVerdictShowsUnlessDismissed() {
    var s = LiveToneSession()
    let verdict = LiveToneVerdict(level: .l2, category: .classBHyperbolicViolence)
    s.apply(verdict: verdict, draftHash: 1)
    check(s.warning == .l2(.classBHyperbolicViolence),
          "L2 verdict on empty session must surface L2 warning")
}

func testSessionDismissalSilencesPerDraftUntilFieldReset() {
    var s = LiveToneSession()
    let draftA: Int = 100
    let draftB: Int = 200
    s.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility), draftHash: draftA)
    check(s.warning == .l1(.hostility), "step 1: L1 hostility must surface")
    s.dismissCurrent()
    check(s.warning == .none, "step 2: dismissCurrent must clear warning")
    // Same category, same draft (hash unchanged) — silenced.
    s.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility), draftHash: draftA)
    check(s.warning == .none,
          "step 3: per-draft dismissal must silence the dismissed category")
    // New draft (fieldReset) — suppression cleared, warning can show.
    s.fieldReset()
    check(s.warning == .none, "step 4: fieldReset must keep warning as .none")
    s.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility), draftHash: draftB)
    check(s.warning == .l1(.hostility),
          "step 5: fieldReset must clear per-draft suppression on a new draft")
}

func testSessionBenignVerdictClearsPriorWarning() {
    var s = LiveToneSession()
    s.apply(verdict: LiveToneVerdict(level: .l2, category: .classBHyperbolicViolence),
            draftHash: 1)
    check(s.warning == .l2(.classBHyperbolicViolence), "step 1: L2 hostility must surface")
    s.apply(verdict: .silent, draftHash: 2)
    check(s.warning == .none, "step 2: benign verdict must clear the prior warning")
}

func testSessionDismissalsArePerCategory() {
    var s = LiveToneSession()
    s.apply(verdict: LiveToneVerdict(level: .l1, category: .hostility), draftHash: 1)
    s.dismissCurrent()
    check(s.dismissals.contains(.hostility),
          "dismissCurrent must record hostility as dismissed")
    check(!s.dismissals.contains(.capsEscalation),
          "dismissCurrent must NOT record capsEscalation as dismissed")
    s.apply(verdict: LiveToneVerdict(level: .l2, category: .capsEscalation), draftHash: 1)
    check(s.warning == .l2(.capsEscalation),
          "dismissing hostility must NOT silence capsEscalation")
}

// MARK: - Section 3: Static source guards on Focused production sources

func testFocusedSourcesHaveNoUITokens() {
    // Pure-Foundation invariant: LiveToneClassifier + LiveToneSession
    // must contain no UIKit tokens in the shipping code paths they
    // execute from the test spine (the engine is the only file that
    // imports UIKit, and the test spine is engine-agnostic).
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sharedDir = scriptDir.deletingLastPathComponent()
        .appendingPathComponent("Shared")
    let sources = ["LiveToneClassifier.swift", "LiveToneSession.swift"]
    let forbidden: [String] = [
        "URLSession", "URLRequest", "dataTask", "URLConnection",
        "import Network", "NWConnection", "NWPathMonitor",
        "Timer.scheduledTimer", "DispatchSource", "CADisplayLink",
        "UIPasteboard", "import UIKit",
    ]
    for name in sources {
        let path = sharedDir.appendingPathComponent(name).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            xfail("could not read source for guard: \(path)")
            continue
        }
        for token in forbidden {
            check(!text.contains(token),
                  "\(name) must not reference '\(token)' (engine-agnostic token)")
        }
    }
}

// MARK: - Run

@main
enum LiveToneV1FocusedVerifier {
    static func main() {
        // Section 1 — Classifier contract
        testClassifierVersionIsPinned()
        testEmptyAndWhitespaceDraftsAreSilent()
        testDeterministicAcross100Runs()
        testNormalizationIsBoundedByMaxScannedCharacters()
        testNormalizationFoldsSmartPunctuationAndCollapsesSpacing()
        // Section 2 — Session state machine
        testSessionFreshStartsSilent()
        testSessionCrisisOrSilentClearsWarning()
        testSessionVisibleVerdictShowsUnlessDismissed()
        testSessionDismissalSilencesPerDraftUntilFieldReset()
        testSessionBenignVerdictClearsPriorWarning()
        testSessionDismissalsArePerCategory()
        // Section 3 — Static source guards on Focused production sources
        testFocusedSourcesHaveNoUITokens()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
            exit(1)
        }
    }
}
