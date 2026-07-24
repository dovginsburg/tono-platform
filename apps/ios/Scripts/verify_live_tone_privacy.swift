// verify_live_tone_privacy.swift
// Standalone red/green verifier for the Live Tone v1 privacy/control lane.
// Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit.
//
// Compiles the REAL production sources (LiveToneClassifier.swift,
// LiveToneEligibility.swift, LiveTonePrivacy.swift, LiveToneKeys.swift,
// LiveToneMasterToggle.swift, LiveToneCounters.swift, LiveToneCopy.swift)
// alongside this runner, so it exercises the shipping logic directly.
// The v1 contract collapses the build-90 experiment's three-axis gate
// (opt-in + user-paused + remote-disable + host-category allowlist) into
// a single default-ON master toggle persisted in App Group
// `UserDefaults`. `LiveToneClassifier.swift` is required because
// `LiveToneCounters.swift` references `LiveToneCategory` (defined in the
// classifier).
//
// Usage (from apps/ios):
//   swiftc -o /tmp/lt_verify \
//     Shared/LiveToneClassifier.swift \
//     Shared/LiveToneEligibility.swift \
//     Shared/LiveTonePrivacy.swift \
//     Shared/LiveToneKeys.swift \
//     Shared/LiveToneMasterToggle.swift \
//     Shared/LiveToneCounters.swift \
//     Shared/LiveToneCopy.swift \
//     Scripts/verify_live_tone_privacy.swift && /tmp/lt_verify
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

// MARK: - Isolated defaults for the preference layer

func makeDefaults() -> UserDefaults {
    let suite = "com.tono.livetone.verify.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

// MARK: - 1. Default ON (contract)

func testDefaultOn() {
    let pref = LiveTonePreference(defaults: makeDefaults())
    check(pref.masterEnabled == true,
          "master toggle must default ON with no prior write")
    let toggle = LiveToneMasterToggle(defaults: makeDefaults())
    check(toggle.isEnabled == true,
          "LiveToneMasterToggle must default ON with no prior write")
    check(toggle.evaluateNow() == true,
          "evaluateNow() must mirror default ON")
}

// MARK: - 2. Explicit OFF persists, fresh reader observes immediately

func testExplicitOffPersistsAcrossReader() {
    let d = makeDefaults()
    let writer = LiveTonePreference(defaults: d)
    check(writer.masterEnabled == true, "baseline must be ON")
    writer.setMasterEnabled(false)
    // Fresh reader, simulating the keyboard process picking up the App
    // Group write on the next keystroke.
    let reader = LiveTonePreference(defaults: d)
    check(reader.masterEnabled == false,
          "OFF must be observable to a fresh reader with no caching")
    let toggleReader = LiveToneMasterToggle(defaults: d)
    check(toggleReader.isEnabled == false,
          "OFF must also flow through LiveToneMasterToggle")
    check(toggleReader.evaluateNow() == false,
          "evaluateNow() must return false when explicitly OFF")

    writer.setMasterEnabled(true)
    check(LiveTonePreference(defaults: d).masterEnabled == true,
          "re-enable must round-trip through a fresh reader")
}

// MARK: - 3. App Group key names match the contract

func testKeysContract() {
    check(LiveToneKeys.appGroupSuite == "group.com.tonoit.shared",
          "App Group suite must be group.com.tonoit.shared")
    check(LiveToneKeys.masterEnabled == "tc.liveTone.masterEnabled",
          "master key must be tc.liveTone.masterEnabled")
    check(LiveToneKeys.localCounters == "tc.liveTone.localCounters",
          "counters key must be tc.liveTone.localCounters")
    check(LiveTonePrivacyKeys.appGroupSuite == LiveToneKeys.appGroupSuite,
          "LiveTonePrivacyKeys suite must mirror LiveToneKeys.appGroupSuite")
    check(LiveTonePrivacyKeys.masterEnabled == LiveToneKeys.masterEnabled,
          "LiveTonePrivacyKeys masterEnabled must mirror LiveToneKeys.masterEnabled")
}

// MARK: - 4. Eligibility exclusions (pure, fail-closed order)

func eligibleBase() -> LiveToneFieldContext {
    LiveToneFieldContext(
        isSecureTextEntry: false,
        before: "Hey, are we still on for tonight",
        after: "?",
        lastInsertionWasBulk: false
    )
}

func decision(_ ctx: LiveToneFieldContext, enabled: Bool = true) -> LiveToneEligibilityDecision {
    LiveToneEligibility.evaluate(context: ctx, masterEnabled: enabled)
}

func testEligibleHappyPath() {
    check(decision(eligibleBase()).isEligible,
          "a normal draft must be eligible")
}

func testMasterGateSuppresses() {
    check(decision(eligibleBase(), enabled: false) == .ineligible(.disabled),
          "master gate off must be ineligible even for a clean draft")
}

func testSecureFieldSuppressed() {
    var c = eligibleBase(); c.isSecureTextEntry = true
    check(decision(c) == .ineligible(.secureField),
          "secure fields must be suppressed")
}

func testBulkInsertionSuppressed() {
    var c = eligibleBase(); c.lastInsertionWasBulk = true
    check(decision(c) == .ineligible(.bulkInsertion),
          "paste/bulk insertion must be suppressed")
}

func testSensitiveNumericDrafts() {
    let sensitive = [
        "1234",                    // PIN / short OTP
        "492013",                  // 6-digit OTP
        "4111 1111 1111 1111",     // card, space grouped
        "4111-1111-1111-1111",     // card, hyphen grouped
        "123-45-6789",             // SSN
        "OTP: 492013",             // digit-dense mixed
        "code 8461 92",            // digit-dense with separators
    ]
    for draft in sensitive {
        var c = eligibleBase(); c.before = draft; c.after = ""
        check(decision(c) == .ineligible(.sensitiveNumericDraft),
              "sensitive numeric draft must be suppressed: \(draft)")
    }
    let benign = [
        "Hey, are we still on for tonight?",
        "See you at 3pm",
        "Room 12 works for me",
        "I'll call you later today",
        "Let's meet at 5:30 or 6 tomorrow",
    ]
    for draft in benign {
        var c = eligibleBase(); c.before = draft; c.after = ""
        check(decision(c).isEligible, "benign draft must remain eligible: \(draft)")
    }
}

func testFailClosedOrdering() {
    // A secure numeric OTP field: any single exclusion is enough; order must
    // never leak an eligible verdict.
    var c = eligibleBase()
    c.isSecureTextEntry = true
    c.lastInsertionWasBulk = true
    c.before = "492013"
    check(decision(c).isEligible == false,
          "stacked exclusions must never be eligible")
}

// MARK: - 5. Local counters round-trip through Codable + App Group store

func testLocalCounterRoundTripOnSameSuite() {
    let suite = "com.tono.livetone.verify.counter.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    let store = LiveToneCounterStore(defaults: d)
    check(store.load().bucket(for: .classBHyperbolicViolence) == LiveToneBucket(),
          "fresh store must yield empty buckets")

    var snap = LiveToneLocalCounters()
    snap = snap.incrementShown(.classBHyperbolicViolence)
    snap = snap.incrementShown(.classBHyperbolicViolence)
    snap = snap.incrementDismissed(.classBHyperbolicViolence)
    store.save(snap)

    // Fresh reader on the same suite proves the store reads back the
    // persisted payload without caching.
    let freshReader = LiveToneCounterStore(defaults:
        UserDefaults(suiteName: suite)!
    ).load()
    let bucket = freshReader.bucket(for: .classBHyperbolicViolence)
    check(bucket.shown == 2, "shown must round-trip as 2")
    check(bucket.dismissed == 1, "dismissed must round-trip as 1")
}

func testLocalCounterRoundTripAcrossCategories() {
    let suite = "com.tono.livetone.verify.counter.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    let store = LiveToneCounterStore(defaults: d)
    var snap = LiveToneLocalCounters()
    snap = snap.incrementShown(.hostility)
    snap = snap.incrementDismissed(.hostility)
    snap = snap.incrementShown(.capsEscalation)
    store.save(snap)

    let freshReader = LiveToneCounterStore(defaults:
        UserDefaults(suiteName: suite)!
    ).load()
    let h = freshReader.bucket(for: .hostility)
    let c = freshReader.bucket(for: .capsEscalation)
    check(h.shown == 1 && h.dismissed == 1,
          "fresh reader on the same App Group must observe persisted hostility counts")
    check(c.shown == 1 && c.dismissed == 0,
          "fresh reader on the same App Group must observe persisted capsEscalation counts")
}

// MARK: - 6. Exact copy contract

func testExactCopyContract() {
    check(LiveToneCopy.l1Chip == "This might land harsher than you mean.",
          "L1 chip copy must match contract byte-for-byte")
    check(LiveToneCopy.l2Banner == "This could read as hurtful or threatening. Want a Safer version?",
          "L2 banner copy must match contract byte-for-byte")
    check(LiveToneCopy.l2RewriteLabel == "Rewrite",
          "Rewrite button label must match contract")
    check(LiveToneCopy.l2DismissLabel == "Dismiss",
          "Dismiss button label must match contract")
    check(LiveToneCopy.settingsDisclosure == "Tono can flag messages that might land harshly. It never blocks or changes anything.",
          "Settings disclosure copy must match contract")
    check(LiveTonePreference.settingsCopy == LiveToneCopy.settingsDisclosure,
          "LiveTonePreference.settingsCopy must mirror LiveToneCopy.settingsDisclosure")
}

// MARK: - 7. Static guards: no fingerprinting / networking / timers in core

func testStaticSourceGuards() {
    // Resolution uses the source files relative to this Script file.
    // The verifier's compile command pins an absolute set of production
    // sources below — every file in the v1 privacy/control lane is
    // covered by this guard so the privacy contract is enforced on the
    // shipping logic, not just on this runner.
    let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sharedDir = scriptDir.deletingLastPathComponent()
        .appendingPathComponent("Shared")
    let sources = [
        "LiveToneClassifier.swift",
        "LiveToneEligibility.swift",
        "LiveTonePrivacy.swift",
        "LiveToneKeys.swift",
        "LiveToneMasterToggle.swift",
        "LiveToneCounters.swift",
        "LiveToneCopy.swift",
    ]
    // Substrings that would indicate host fingerprinting, networking, or
    // background polling/timers sneaking into the privacy lane. The
    // classifier / eligibility / privacy / keys / toggle / counters /
    // copy modules must all read as pure Foundation over App Group
    // UserDefaults — no URLSession, no Timer, no Bundle.main.
    let forbidden = [
        "URLSession", "URLRequest", "dataTask", "URLConnection",
        "import Network", "NWConnection", "NWPathMonitor",
        "scheduledTimer", "asyncAfter", "DispatchSource",
        "CADisplayLink",
        "bundleIdentifier", "Bundle.main", "hostBundleID",
        "openURL", "canOpenURL", "UIPasteboard", "generalPasteboard",
        "MobileGestalt", "sysctl", "proc_", "import UIKit",
    ]
    for name in sources {
        let path = sharedDir.appendingPathComponent(name).path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "could not read source for guard: \(path)")
            continue
        }
        for token in forbidden {
            check(!text.contains(token),
                  "\(name) must not reference '\(token)' (fingerprinting/networking/timer)")
        }
    }
}

func testClassifierVersionIsPinned() {
    check(LiveToneClassifier.version == 2,
          "LiveToneClassifier.version must remain pinned at 2 for the v1 contract")
}

func testClassifierDeterministicAcrossRuns() {
    // Smoke check: 100 runs over a small hostile / benign sample produce
    // identical verdicts. No clock, no network, no randomness are
    // involved in the classifier so this should be flat-stable.
    let classifier = LiveToneClassifier()
    let samples = [
        "Sounds good, see you at 7!",
        "I'll kill you",
        "lol you're an idiot 😂",
        "He said \"you're worthless\" to me",
        "If you loved me you'd answer",
        "I want to kill myself",
        "You're killing me lol",
    ]
    let baseline = samples.map { classifier.classify($0) }
    for _ in 0..<100 {
        let again = samples.map { classifier.classify($0) }
        check(again == baseline,
              "classifier verdicts must be deterministic across 100 runs")
    }
}

func testClassifierEvaluationIsBounded() {
    // The v1 contract binds `maxScannedCharacters = 2_000` so very
    // large drafts get normalized to a bounded prefix and never make
    // scanning cost grow with field size. Confirm normalization is
    // bounded; pure determinism of evaluation cost is hardware-bound so
    // we don't enforce a wall-clock budget here.
    let classifier = LiveToneClassifier()
    let huge = String(repeating: "the quick brown fox. ", count: 10_000)
    check(huge.count > LiveToneClassifier.maxScannedCharacters,
          "huge corpus must exceed the 2,000-char scanned-character cap")
    check(LiveToneClassifier.normalize(huge).count <= LiveToneClassifier.maxScannedCharacters,
          "normalize(_:) must clamp drafts to the scanned-character cap")
    // The classifier itself never throws on extreme inputs.
    let v = classifier.classify(huge)
    check(true, "classify(_:) returned: \(v) (no throw / no crash)")
}

// MARK: - Run

@main
enum LiveTonePrivacyVerifier {
    static func main() {
        testDefaultOn()
        testExplicitOffPersistsAcrossReader()
        testKeysContract()
        testEligibleHappyPath()
        testMasterGateSuppresses()
        testSecureFieldSuppressed()
        testBulkInsertionSuppressed()
        testSensitiveNumericDrafts()
        testFailClosedOrdering()
        testLocalCounterRoundTripOnSameSuite()
        testLocalCounterRoundTripAcrossCategories()
        testExactCopyContract()
        testStaticSourceGuards()
        testClassifierVersionIsPinned()
        testClassifierDeterministicAcrossRuns()
        testClassifierEvaluationIsBounded()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
            exit(1)
        }
    }
}