// verify_live_tone_privacy.swift
// Standalone red/green verifier for the Live Tone privacy/control lane.
// Pure Swift on macOS — no iOS Simulator, no Xcode, no UIKit.
//
// Unlike the mirror-based verify_build7x scripts, this compiles the REAL
// production sources (LiveToneEligibility.swift + LiveTonePrivacy.swift)
// alongside this runner, so it exercises the shipping logic directly.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/lt_verify \
//     Shared/LiveToneEligibility.swift Shared/LiveTonePrivacy.swift \
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

// MARK: - 1. Default OFF

func testDefaultOff() {
    let pref = LiveTonePreference(defaults: makeDefaults())
    check(pref.isOptedIn == false, "opt-in must default to false")
    check(pref.isUserPaused == false, "kill switch must default to not-paused")
    check(pref.isRemoteDisabled == false, "remote-disable must default to allowed")
    check(pref.masterEnabled == false, "master gate must be OFF with no opt-in")
    check(pref.allowedHostCategories.isEmpty, "host allowlist must default empty")
}

// MARK: - 2. Immediate kill switch (no cache, no network)

func testImmediateKillSwitch() {
    let d = makeDefaults()
    let pref = LiveTonePreference(defaults: d)
    pref.isOptedIn = true
    pref.allowedHostCategories = [.messaging]
    check(pref.masterEnabled == true, "opted-in user should be master-enabled")

    // A *fresh* reader (mimicking the keyboard process) sees the kill instantly.
    pref.kill()
    let freshReader = LiveTonePreference(defaults: d)
    check(freshReader.isUserPaused == true, "kill must be observable by a fresh reader")
    check(freshReader.masterEnabled == false, "kill must disable the master gate immediately")

    pref.resume()
    check(LiveTonePreference(defaults: d).masterEnabled == true, "resume must re-enable")
}

// MARK: - 5. Remote-disable directive, refreshed only via a Coach round-trip

func testRemoteDisableContract() {
    let d = makeDefaults()
    let pref = LiveTonePreference(defaults: d)
    pref.isOptedIn = true
    pref.allowedHostCategories = [.messaging]
    check(pref.masterEnabled == true, "baseline enabled before remote directive")

    // The parser maps the EXISTING Coach response `flags` array — no new call.
    let disable = LiveTonePreference.directive(fromCoachFlags: ["something", LiveTonePreference.disableFlag])
    check(disable.isDisabled, "disable flag must produce a disabled directive")
    let allow = LiveTonePreference.directive(fromCoachFlags: ["warmer_ok"])
    check(allow.isDisabled == false, "absence of the flag must produce an allowed directive")

    // Applying persists locally and kills the gate immediately for fresh readers.
    pref.refreshRemoteDirective(fromCoachFlags: [LiveTonePreference.disableFlag])
    check(LiveTonePreference(defaults: d).isRemoteDisabled, "applied directive must persist")
    check(LiveTonePreference(defaults: d).masterEnabled == false, "remote disable must gate off")

    // Directive round-trips through Codable with a schema for forward-compat.
    let encoded = try! JSONEncoder().encode(LiveToneRemoteDirective(disabled: true))
    let decoded = try! JSONDecoder().decode(LiveToneRemoteDirective.self, from: encoded)
    check(decoded.isDisabled && decoded.schema == LiveToneRemoteDirective.currentSchema,
          "directive must round-trip with schema")
}

// MARK: - 3. Eligibility exclusions (pure)

let allowed: Set<LiveToneHostCategory> = [.messaging, .social, .notes]

func eligibleBase() -> LiveToneFieldContext {
    LiveToneFieldContext(
        isSecureTextEntry: false,
        keyboardType: .default,
        hostCategory: .messaging,
        before: "Hey, are we still on for tonight",
        selected: nil,
        after: "?",
        lastInsertionWasBulk: false
    )
}

func decision(_ ctx: LiveToneFieldContext, enabled: Bool = true) -> LiveToneEligibilityDecision {
    LiveToneEligibility.evaluate(context: ctx, allowedHostCategories: allowed, masterEnabled: enabled)
}

func testEligibleHappyPath() {
    check(decision(eligibleBase()).isEligible, "a normal messaging draft must be eligible")
}

func testMasterGateSuppresses() {
    check(decision(eligibleBase(), enabled: false) == .ineligible(.disabled),
          "master gate off must be ineligible even for a clean draft")
}

func testSecureFieldSuppressed() {
    var c = eligibleBase(); c.isSecureTextEntry = true
    check(decision(c) == .ineligible(.secureField), "secure fields must be suppressed")
}

func testExcludedKeyboardTypes() {
    let excluded: [LiveToneKeyboardType] = [
        .emailAddress, .url, .numberPad, .decimalPad, .phonePad,
        .namePhonePad, .asciiCapableNumberPad, .numbersAndPunctuation,
    ]
    for kt in excluded {
        var c = eligibleBase(); c.keyboardType = kt
        check(decision(c) == .ineligible(.excludedKeyboardType(kt)),
              "keyboard type \(kt) must be excluded")
    }
    let allowedTypes: [LiveToneKeyboardType] = [.default, .asciiCapable, .twitter, .webSearch]
    for kt in allowedTypes {
        var c = eligibleBase(); c.keyboardType = kt
        check(decision(c).isEligible, "keyboard type \(kt) must remain eligible")
    }
}

func testUnknownHostCategorySuppressed() {
    var c = eligibleBase(); c.hostCategory = nil
    check(decision(c) == .ineligible(.unknownHostCategory),
          "nil/unknown host category must fail closed")
}

func testHostCategoryNotInAllowlist() {
    var c = eligibleBase(); c.hostCategory = .email
    check(decision(c) == .ineligible(.hostCategoryNotAllowed(.email)),
          "category outside the user allowlist must be suppressed")
}

func testBulkInsertionSuppressed() {
    var c = eligibleBase(); c.lastInsertionWasBulk = true
    check(decision(c) == .ineligible(.bulkInsertion), "paste/bulk insertion must be suppressed")
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
    c.keyboardType = .numberPad
    c.hostCategory = nil
    c.before = "492013"
    check(decision(c).isEligible == false, "stacked exclusions must never be eligible")
}

// MARK: - 6. Static guards: no fingerprinting / networking / timers

func testStaticSourceGuards() {
    let sources = [
        "Shared/LiveToneEligibility.swift",
        "Shared/LiveTonePrivacy.swift",
    ]
    // Substrings that would indicate host fingerprinting, networking, or
    // background polling/timers sneaking into the privacy lane.
    let forbidden = [
        "URLSession", "URLRequest", "dataTask", "URLConnection",
        "import Network", "NWConnection", "NWPathMonitor",
        "Timer", "scheduledTimer", "asyncAfter", "DispatchSource",
        "CADisplayLink", "RunLoop",
        "bundleIdentifier", "Bundle.main", "hostBundleID",
        "openURL", "canOpenURL", "UIPasteboard", "generalPasteboard",
        "MobileGestalt", "sysctl", "proc_", "import UIKit",
    ]
    for path in sources {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            check(false, "could not read source for guard: \(path)")
            continue
        }
        for token in forbidden {
            check(!text.contains(token),
                  "\(path) must not reference '\(token)' (fingerprinting/networking/timer)")
        }
    }
}

// MARK: - Run

@main
enum LiveTonePrivacyVerifier {
    static func main() {
        testDefaultOff()
        testImmediateKillSwitch()
        testRemoteDisableContract()
        testEligibleHappyPath()
        testMasterGateSuppresses()
        testSecureFieldSuppressed()
        testExcludedKeyboardTypes()
        testUnknownHostCategorySuppressed()
        testHostCategoryNotInAllowlist()
        testBulkInsertionSuppressed()
        testSensitiveNumericDrafts()
        testFailClosedOrdering()
        testStaticSourceGuards()

        if failures == 0 {
            print("ok — \(checks) checks passed")
            exit(0)
        } else {
            FileHandle.standardError.write(Data("\(failures)/\(checks) checks FAILED\n".utf8))
            exit(1)
        }
    }
}
