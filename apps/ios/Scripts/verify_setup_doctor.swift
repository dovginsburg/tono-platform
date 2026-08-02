// verify_setup_doctor.swift
// Standalone executable verification for the Setup Doctor. Pure Swift on
// macOS — no iOS Simulator, no Xcode, no UIKit — so the contract can be run
// while the native build lane is busy.
//
// It compiles against the REAL production sources (`Shared/SetupDoctor.swift`
// and its App Group dependencies), not a copy, so drift in the shipping rules
// fails here. It mirrors the assertions in `Tests/SetupDoctorTests.swift`;
// that suite remains the authority under Xcode.
//
// Usage (from apps/ios):
//   swiftc -o /tmp/tono_setup_doctor \
//       Scripts/setup_doctor_verifier_shim.swift Shared/SharedKeychain.swift \
//       Shared/SharedUserDefaults.swift Shared/SetupDoctor.swift \
//       Scripts/verify_setup_doctor.swift
//   /tmp/tono_setup_doctor
//
// See the shim's header for why two unrelated enums are stood in for rather
// than compiling `ToneEngine.swift`; `sourceContracts()` pins them so they
// cannot drift from the real declarations.
//
// Exit codes: 0 — all checks passed; 1 — one or more checks failed.

import Foundation

// MARK: - Harness

private var failures: [String] = []

private func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label)")
        failures.append(label)
    }
}

private func section(_ title: String) {
    print("\n\(title)")
}

/// A fixed instant, so every freshness assertion is an offset rather than a
/// dependency on wall-clock time.
private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func snapshot(
    _ state: EntitlementState?,
    checkedAt: Date?,
    registered: Bool = true
) -> SetupEntitlementSnapshot {
    SetupEntitlementSnapshot(isRegistered: registered, state: state, checkedAt: checkedAt)
}

private func derive(
    heartbeat: KeyboardHeartbeat?,
    entitlement: SetupEntitlementSnapshot? = nil,
    testStartedAt: Date? = nil
) -> SetupDoctorState {
    SetupDoctorState.derive(
        heartbeat: heartbeat,
        entitlement: entitlement ?? snapshot(.entitled, checkedAt: now),
        testStartedAt: testStartedAt,
        now: now
    )
}

private func isolatedDefaults() -> UserDefaults {
    let suite = "verify_setup_doctor.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

// Repo paths, resolved from this file's compile-time location.
private let iosRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func source(_ relativePath: String) -> String {
    (try? String(contentsOf: iosRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
}

/// Line-comment-stripped string literals — what a user can actually read.
private func stringLiterals(in source: String) -> [String] {
    var literals: [String] = []
    for line in source.components(separatedBy: .newlines) {
        let code = line.contains("//") ? String(line[..<line.range(of: "//")!.lowerBound]) : line
        var inside = false
        var current = ""
        for character in code {
            if character == "\"" {
                if inside { literals.append(current); current = "" }
                inside.toggle()
            } else if inside {
                current.append(character)
            }
        }
    }
    return literals
}

/// Case names of a named enum, in declaration order. Used to pin the
/// verifier's stand-in enums against their real declarations.
private func enumCases(named name: String, in source: String) -> [String] {
    guard let start = source.range(of: "enum \(name)") else { return [] }
    let tail = source[start.upperBound...]
    guard let end = tail.range(of: "\n}") else { return [] }
    return tail[..<end.lowerBound]
        .components(separatedBy: .newlines)
        .compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { return nil }
            let name = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            // Skip `switch` arms inside computed properties (`case .warmer:`)
            // and associated-value declarations — only bare cases count.
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            else { return nil }
            return name
        }
}

/// Brace-balanced body of a named function, so an assertion can be scoped to
/// that function rather than the whole 170KB controller.
private func functionBody(named name: String, in source: String) -> String? {
    guard let start = source.range(of: "func \(name)(") else { return nil }
    guard let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
    var depth = 0
    var index = open.lowerBound
    while index < source.endIndex {
        let character = source[index]
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return String(source[open.upperBound..<index]) }
        }
        index = source.index(after: index)
    }
    return nil
}

// MARK: - Entry point

@main
enum SetupDoctorVerifier {

    static func main() {
        print("Setup Doctor — standalone contract verification")

        heartbeatFreshness()
        fullAccess()
        contentFreeSchema()
        entitlementRendering()
        testDrive()
        wholeSurface()
        navigationCapability()
        sourceContracts()

        print("")
        if failures.isEmpty {
            print("✓ all Setup Doctor checks passed")
            exit(0)
        } else {
            print("✗ \(failures.count) check(s) failed:")
            failures.forEach { print("   - \($0)") }
            exit(1)
        }
    }

    // MARK: Heartbeat freshness

    static func heartbeatFreshness() {
        section("heartbeat freshness")

        check(
            derive(heartbeat: KeyboardHeartbeat(observedAt: now.addingTimeInterval(-30), fullAccess: true))
                .step(.keyboardEnabled).status == .complete,
            "a check-in from 30s ago completes the keyboard step"
        )
        check(
            derive(heartbeat: KeyboardHeartbeat(
                observedAt: now.addingTimeInterval(-SetupDoctorPolicy.liveWindow), fullAccess: true
            )).step(.keyboardEnabled).status == .complete,
            "a check-in exactly at the window edge still counts"
        )

        let staleAt = now.addingTimeInterval(-SetupDoctorPolicy.liveWindow - 1)
        let staleStep = derive(heartbeat: KeyboardHeartbeat(observedAt: staleAt, fullAccess: true))
            .step(.keyboardEnabled)
        check(staleStep.status == .confirmedEarlier(at: staleAt), "one second past the window degrades to confirmed-earlier")
        check(!staleStep.status.isComplete, "a stale check-in never reads as success")

        check(
            derive(heartbeat: nil).step(.keyboardEnabled).status == .cannotConfirm,
            "a missing check-in reads as cannot-confirm, not as not-enabled"
        )
        check(
            !derive(heartbeat: nil).step(.keyboardEnabled).detail.lowercased().contains("not enabled"),
            "absence of evidence is not reported as evidence of absence"
        )

        let future = derive(heartbeat: KeyboardHeartbeat(observedAt: now.addingTimeInterval(3_600), fullAccess: true))
        check(!future.step(.keyboardEnabled).status.isComplete, "a future-dated record is not treated as live")
        check(future.step(.fullAccess).status == .cannotConfirm, "a future-dated record cannot confirm Full Access")
    }

    // MARK: Full Access

    static func fullAccess() {
        section("full access")

        check(
            derive(heartbeat: KeyboardHeartbeat(observedAt: now, fullAccess: true)).step(.fullAccess).status == .complete,
            "a live check-in reporting Full Access on completes the step"
        )
        check(
            derive(heartbeat: KeyboardHeartbeat(observedAt: now, fullAccess: false)).step(.fullAccess).status == .actionNeeded,
            "Full Access off is action-needed"
        )
        check(
            derive(heartbeat: KeyboardHeartbeat(
                observedAt: now.addingTimeInterval(-SetupDoctorPolicy.liveWindow - 1), fullAccess: true
            )).step(.fullAccess).status == .cannotConfirm,
            "a stale Full-Access-on reading does not survive as complete"
        )
    }

    // MARK: Content-free schema

    static func contentFreeSchema() {
        section("content-free schema")

        let encoded = KeyboardHeartbeat(observedAt: now, fullAccess: true).encoded()
        check(Set(encoded.keys) == KeyboardHeartbeat.encodedKeys, "encoded heartbeat carries exactly the contract keys")
        check(
            KeyboardHeartbeat.encodedKeys == ["schema", "observedAt", "fullAccess"],
            "the contract is schema + timestamp + fullAccess and nothing else"
        )

        let store = KeyboardHeartbeatStore(defaults: isolatedDefaults())
        store.record(hasFullAccess: false, now: now)
        let readBack = store.read()
        check(readBack?.fullAccess == false, "recorded Full Access round-trips")
        check(
            abs((readBack?.observedAt.timeIntervalSince1970 ?? 0) - now.timeIntervalSince1970) < 0.001,
            "recorded timestamp round-trips"
        )
        store.clear()
        check(store.read() == nil, "clear() removes the record so a re-check measures a new appearance")

        check(KeyboardHeartbeat.decoded(from: nil) == nil, "nil decodes to nil")
        check(KeyboardHeartbeat.decoded(from: "not a dictionary") == nil, "a non-dictionary decodes to nil")
        check(
            KeyboardHeartbeat.decoded(from: ["schema": 1, "observedAt": 1.0] as [String: Any]) == nil,
            "a record missing fullAccess decodes to nil"
        )
        check(
            KeyboardHeartbeat.decoded(from: ["schema": 1, "fullAccess": true] as [String: Any]) == nil,
            "a record missing its timestamp decodes to nil"
        )
        check(
            KeyboardHeartbeat.decoded(from: ["schema": 0, "observedAt": 0.0, "fullAccess": true] as [String: Any]) == nil,
            "a zero timestamp is not a real observation"
        )
        check(
            KeyboardHeartbeat.decoded(from: [
                "schema": KeyboardHeartbeat.currentSchema + 1, "observedAt": 1.0, "fullAccess": true,
            ] as [String: Any]) == nil,
            "a schema from the future is refused rather than guessed at"
        )
    }

    // MARK: Entitlement rendering

    static func entitlementRendering() {
        section("entitlement rendering")

        check(
            derive(heartbeat: nil, entitlement: snapshot(nil, checkedAt: nil, registered: false))
                .step(.account).status == .actionNeeded,
            "signed out is action-needed"
        )
        check(
            derive(heartbeat: nil, entitlement: snapshot(.entitled, checkedAt: now)).step(.account).status == .complete,
            "a fresh entitled verdict completes the account step"
        )
        check(
            derive(heartbeat: nil, entitlement: snapshot(.notEntitled, checkedAt: now)).step(.account).status == .actionNeeded,
            "not-entitled is action-needed"
        )
        check(
            derive(heartbeat: nil, entitlement: snapshot(.unknown, checkedAt: now)).step(.account).status == .cannotConfirm,
            "unknown fails closed"
        )
        check(
            derive(heartbeat: nil, entitlement: snapshot(nil, checkedAt: nil)).step(.account).status == .cannotConfirm,
            "a never-checked entitlement fails closed"
        )
        check(
            derive(
                heartbeat: nil,
                entitlement: snapshot(.entitled, checkedAt: now.addingTimeInterval(-SetupDoctorPolicy.entitlementWindow - 1))
            ).step(.account).status == .cannotConfirm,
            "a stale entitled verdict stops claiming an active subscription"
        )
        check(
            derive(heartbeat: nil, entitlement: snapshot(.entitled, checkedAt: nil)).step(.account).status == .cannotConfirm,
            "entitled with no recorded check time is not complete"
        )
    }

    // MARK: Test drive

    static func testDrive() {
        section("test drive")

        let started = now.addingTimeInterval(-10)
        check(
            derive(
                heartbeat: KeyboardHeartbeat(observedAt: now.addingTimeInterval(-60), fullAccess: true),
                testStartedAt: started
            ).step(.testDrive).status == .cannotConfirm,
            "a check-in from before the test began is a replay, not a pass"
        )
        check(
            derive(
                heartbeat: KeyboardHeartbeat(observedAt: now.addingTimeInterval(-5), fullAccess: true),
                testStartedAt: started
            ).step(.testDrive).status == .complete,
            "a check-in during the test passes it"
        )
        check(
            derive(heartbeat: KeyboardHeartbeat(observedAt: now, fullAccess: true), testStartedAt: nil)
                .step(.testDrive).status == .cannotConfirm,
            "the test is unconfirmed until the user starts it"
        )
        let detail = derive(
            heartbeat: KeyboardHeartbeat(observedAt: now, fullAccess: true),
            testStartedAt: started
        ).step(.testDrive).detail.lowercased()
        check(!detail.contains("this field"), "success copy does not claim the specific text field")
    }

    // MARK: Whole surface

    static func wholeSurface() {
        section("whole-surface derivation")

        check(derive(heartbeat: nil).steps.map(\.id) == SetupStepID.allCases, "every step is produced exactly once, in order")

        let started = now.addingTimeInterval(-10)
        let allGood = KeyboardHeartbeat(observedAt: now, fullAccess: true)
        check(derive(heartbeat: allGood, testStartedAt: started).isFullySetUp, "all four live-verified reads as fully set up")
        check(!derive(heartbeat: allGood, testStartedAt: nil).isFullySetUp, "no test drive breaks the summary")
        check(
            !derive(heartbeat: KeyboardHeartbeat(observedAt: now, fullAccess: false), testStartedAt: started).isFullySetUp,
            "Full Access off breaks the summary"
        )
        check(
            !derive(heartbeat: allGood, entitlement: snapshot(.unknown, checkedAt: now), testStartedAt: started).isFullySetUp,
            "an unknown entitlement breaks the summary"
        )

        let barren = SetupDoctorState.derive(
            heartbeat: nil,
            entitlement: SetupEntitlementSnapshot(isRegistered: false, state: nil, checkedAt: nil),
            testStartedAt: nil,
            now: now
        )
        check(barren.steps.allSatisfy { !$0.status.isComplete }, "with zero evidence, no step reports complete")
    }

    // MARK: Navigation capability

    static func navigationCapability() {
        section("navigation capability")

        let addKeyboard = SetupNavigation.addKeyboard
        check(!addKeyboard.landsOnExactPane, "the Keyboards pane is admitted to be unreachable by deep link")
        check(!addKeyboard.writtenSteps.isEmpty, "written steps always exist")
        check(addKeyboard.buttonTitle == "Open Settings", "an honest Settings button is still offered")
        check(
            addKeyboard.buttonFootnote?.contains("can’t jump straight") == true,
            "the caption tells the user the button lands short of the keyboard list"
        )

        check(SetupNavigation.fullAccess.landsOnExactPane, "Tono's own Settings page is reachable")
        check(SetupNavigation.fullAccess.buttonTitle == "Open Settings", "Full Access offers a Settings button")

        check(!SetupNavigation.switchToTono.opensAppSettingsRoot, "switching keyboards offers no Settings button")
        check(SetupNavigation.switchToTono.buttonTitle == nil, "no fake button where no API goes anywhere")
        check(!SetupNavigation.switchToTono.writtenSteps.isEmpty, "switching still has written steps")

        for nav in [SetupNavigation.addKeyboard, .fullAccess, .switchToTono] where nav.buttonTitle != nil {
            check(nav.opensAppSettingsRoot, "a button exists only where a real API opens something")
        }
    }

    // MARK: Source contracts

    static func sourceContracts() {
        section("source contracts")

        let banned = ["http", "://", "/v1", "/api", ".com", ".io", "bearer", "token",
                      "localhost", "staging", "endpoint", "backendurl", "api key"]
        var leaked: [String] = []
        for file in ["App/SetupDoctorView.swift", "Shared/SetupDoctor.swift"] {
            let text = source(file)
            if text.isEmpty { leaked.append("could not read \(file)"); continue }
            for literal in stringLiterals(in: text) {
                let haystack = literal.lowercased()
                for needle in banned where haystack.contains(needle) {
                    leaked.append("\(file): “\(needle)” in “\(literal)”")
                }
            }
        }
        check(leaked.isEmpty, "consumer copy exposes no endpoints, tokens, or environment labels")
        leaked.forEach { print("      ↳ \($0)") }

        let copy = (FullAccessExplainer.body + FullAccessExplainer.neverCollected)
            .joined(separator: " ").lowercased()
        check(!copy.contains("nothing leaves your device"), "copy does not claim nothing leaves the device")
        check(!copy.contains("never leaves your device"), "copy does not claim data never leaves the device")
        check(!copy.contains("no data is sent"), "copy does not claim no data is sent")
        check(copy.contains("sends that one draft"), "copy positively discloses the Coach round-trip")

        check(
            source("Shared/SetupDoctor.swift").contains("public func record(hasFullAccess: Bool, now: Date)"),
            "the recording API accepts only a Bool and a timestamp"
        )

        let controller = source("KeyboardExtension/KeyboardViewController.swift")
        check(
            controller.contains("KeyboardHeartbeatStore().record(hasFullAccess: hasFullAccess, now: Date())"),
            "the extension records only the live Full Access reading and the time"
        )
        check(
            controller.components(separatedBy: "KeyboardHeartbeatStore(").count - 1 == 1,
            "there is exactly one heartbeat write site to review"
        )
        check(
            !controller.contains("record(hasFullAccess: true") && !controller.contains("record(hasFullAccess: false"),
            "Full Access is read from UIInputViewController, never assumed"
        )

        // The stand-in enums must still match the real declarations, or this
        // whole harness would be verifying a fiction.
        let engine = source("Shared/ToneEngine.swift")
        check(
            enumCases(named: "LLMProvider", in: engine) == LLMProvider.allCases.map(\.rawValue),
            "the verifier's LLMProvider stand-in matches ToneEngine.swift"
        )
        check(
            enumCases(named: "RewriteAxis", in: engine) == RewriteAxis.allCases.map(\.rawValue),
            "the verifier's RewriteAxis stand-in matches ToneEngine.swift"
        )

        if let body = functionBody(named: "recordSetupHeartbeat", in: controller) {
            for forbidden in ["documentProxy", "documentContext", "textDocumentProxy", "bundleIdentifier",
                              "hostSession", "recipient", "draft"] {
                check(!body.contains(forbidden), "heartbeat write does not touch \(forbidden)")
            }
        } else {
            check(false, "recordSetupHeartbeat() body could be located for scanning")
        }
    }
}
