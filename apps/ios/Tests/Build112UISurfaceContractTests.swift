import XCTest

/// Build 112 — the founder's UI correction, as a whole-surface contract.
///
/// The rejected Build 111 host app failed on two counts a screenshot makes
/// obvious and a unit test previously did not:
///
///   1. "We were combining Playground and Coach on the app — don't need both."
///   2. "Backend details still showing."
///
/// The Build 111 Settings contract only ever scanned the `SettingsView` struct
/// body, and it explicitly REQUIRED the DEBUG endpoint diagnostics to survive.
/// That is why a Playground tab and an internal endpoint row could both ship
/// green. This contract replaces that scope:
///
///   * it reads the top-level tab bar, not just Settings;
///   * it scans every production SwiftUI surface a user can reach, including
///     sibling structs (`PaywallView`, `AccountDeletionView`, `EmailSignInSheet`)
///     and the recipient manager, not one struct body;
///   * it evaluates BOTH compilation modes, so nothing hides behind `#if DEBUG`;
///   * it judges string LITERALS, so a comment or a type name (`TonoBackendError`)
///     is not mistaken for something a user can read;
///   * it inspects Xcode target membership, so deleted UI cannot linger in the
///     app binary.
///
/// Pure Foundation by design: it reads reviewed sources exactly as a reviewer
/// would, so it fails on a bad surface rather than on a missing simulator.
final class Build112UISurfaceContractTests: XCTestCase {

    // MARK: - Surfaces under contract

    /// Every production SwiftUI surface the host app can put in front of a
    /// user: the tab bar, the one Coach experience, Settings and everything
    /// reachable from it, and the onboarding covers.
    private static let consumerSurfaces = [
        "App/TonoApp.swift",
        "App/CoachView.swift",
        "App/SettingsView.swift",
        "App/RecipientsManagerView.swift",
        "App/SetupDoctorView.swift",
        "App/MemoryView.swift",
        "App/DigestView.swift",
        "App/HomeView.swift",
        "App/OnboardingEntryPointsView.swift",
        "App/OnboardingCalibrationView.swift",
        // Supplies the paywall's user-visible failure copy.
        "Shared/StoreKitManager.swift",
    ]

    private static let productionDirectories = [
        "App", "Shared", "KeyboardExtension", "ShareExtension",
        "TonoMessagesExtension", "Widget",
    ]

    private static let shippedPlists = [
        "App/Info.plist",
        "KeyboardExtension/Info.plist",
        "ShareExtension/Info.plist",
        "TonoMessagesExtension/Info.plist",
    ]

    private static let expectedTabs = ["Coach", "This Week", "Settings"]

    /// Implementation vocabulary that must never reach a consumer string.
    private static let forbiddenTerms = [
        "backend", "server", "endpoint", "api key", "apikey", "bearer",
        "auth token", "api token", "access key", "provider", "proxy", "llm",
        "transport", "non-2xx", "staging", "userdefaults", "app group",
        "api.tonoit.com", "://", "http",
    ]

    /// Whole-word bans — substring matching would fire on ordinary prose.
    private static let forbiddenWords = ["url", "urls", "token", "tokens"]

    /// Generic infrastructure phrasing the founder named directly.
    private static let forbiddenPhrases = [
        "runs on tono's service", "runs on tono\u{2019}s service",
        "reach its service", "reach our service", "sign-in service",
        "temporarily unavailable", "on our side",
        "tono's servers", "tono\u{2019}s servers", "local app group",
    ]

    /// Endpoint diagnostics, by every name they went under.
    private static let settingsDiagnosticMarkers = [
        "Endpoint", "Custom backend URL", "Test Connection", "api.tonoit.com",
        "tc.backendURL", "developerDiagnostics", "diagnosticHealthText",
        "resolvedBackendLabel", "runDiagnosticHealthCheck",
        "Developer diagnostics", ".health()",
    ]

    // MARK: - Objective A — one Coach experience

    func testTopLevelTabsAreExactlyCoachThisWeekAndSettings() throws {
        let app = try Self.source("App/TonoApp.swift")
        let body = try XCTUnwrap(
            SwiftSource.body(ofDeclaration: "struct RootView", in: SwiftSource.stripComments(app)),
            "TonoApp must declare RootView"
        )
        XCTAssertEqual(
            SwiftSource.tabItemLabels(in: body), Self.expectedTabs,
            "the shipped tab bar must be exactly Coach, This Week, Settings — no Playground, History, or Recents"
        )
    }

    func testExactlyOneCoachDestinationAndNoPlaygroundNavigation() throws {
        let app = try Self.source("App/TonoApp.swift")
        XCTAssertEqual(
            app.components(separatedBy: "CoachView()").count - 1, 1,
            "there must be exactly one Coach destination"
        )
        XCTAssertFalse(
            app.contains("Playground"),
            "no Playground tab, label, or navigation may ship"
        )
    }

    func testPlaygroundProductionCodeIsAbsentFromEveryShippedTarget() throws {
        let root = Self.sourceRoot()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("App/PlaygroundView.swift").path),
            "App/PlaygroundView.swift is fully superseded by CoachView and must be deleted"
        )

        for directory in Self.productionDirectories {
            for file in Self.swiftFiles(under: root.appendingPathComponent(directory)) {
                let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
                XCTAssertFalse(
                    file.lastPathComponent.contains("Playground"),
                    "\(relative) is Playground production code and must not ship"
                )
                let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                XCTAssertFalse(
                    contents.contains("Playground"),
                    "\(relative) still references Playground"
                )
            }
        }

        let project = try Self.source("Tono.xcodeproj/project.pbxproj")
        XCTAssertFalse(
            project.contains("PlaygroundView"),
            "PlaygroundView must have no file reference, build file, group entry, or target membership"
        )
    }

    /// Every `App/*.swift` on disk compiles into the host app, and nothing that
    /// was deleted lingers in the Sources phase. Membership drift is how a
    /// removed screen keeps shipping inside the binary.
    func testHostAppTargetMembershipMatchesTheFilesOnDisk() throws {
        let root = Self.sourceRoot()
        let project = try Self.source("Tono.xcodeproj/project.pbxproj")
        for file in Self.swiftFiles(under: root.appendingPathComponent("App")) {
            let name = file.lastPathComponent
            XCTAssertEqual(
                project.components(separatedBy: "/* \(name) in Sources */").count - 1, 2,
                "\(name) must have exactly one build file and one Sources-phase entry in the host target"
            )
        }
        for required in ["CoachView.swift", "SettingsView.swift", "RecipientsManagerView.swift"] {
            XCTAssertTrue(
                project.contains("/* \(required) in Sources */"),
                "\(required) must remain a member of the host app target"
            )
        }
    }

    /// One draft editor, one action path, one request owner, one result
    /// presentation — the shape a "combined Playground and Coach" violated.
    func testCoachHasOneEditorOneActionOneRequestOwnerAndOneResultSurface() throws {
        let coach = try Self.source("App/CoachView.swift")
        XCTAssertEqual(
            coach.components(separatedBy: "TextEditor(text: $draft)").count - 1, 1,
            "the single Coach experience must have exactly one draft editor"
        )
        XCTAssertEqual(
            coach.components(separatedBy: "private func runCoach()").count - 1, 1,
            "there must be exactly one Coach action path"
        )
        XCTAssertEqual(
            coach.components(separatedBy: "TonoBackend.shared.analyze(").count - 1, 1,
            "there must be exactly one coaching request owner in the host app"
        )
        XCTAssertEqual(
            coach.components(separatedBy: "private func resultsCard(").count - 1, 1,
            "there must be exactly one result presentation"
        )
        for secondMode in ["isPlaygroundMode", "selectedMode", "rehearsal", "Rehearse"] {
            XCTAssertFalse(
                coach.contains(secondMode),
                "Coach must not hide a second mode (\(secondMode)) inside the one experience"
            )
        }
    }

    // MARK: - Objective B — zero backend details in UI

    func testNoConsumerStringNamesImplementationDetailInEitherCompilationMode() throws {
        for relative in Self.consumerSurfaces {
            let raw = try Self.source(relative)
            for debug in [false, true] {
                let mode = debug ? "DEBUG" : "Release"
                let source = try SwiftSource.preprocess(raw, debug: debug)
                for literal in SwiftSource.stringLiterals(in: source) {
                    let haystack = literal.lowercased()
                    for term in Self.forbiddenTerms {
                        XCTAssertFalse(
                            haystack.contains(term),
                            "\(mode) \(relative) shows the user “\(term)”: \(literal)"
                        )
                    }
                    for word in Self.forbiddenWords {
                        XCTAssertFalse(
                            SwiftSource.containsWord(word, in: haystack),
                            "\(mode) \(relative) shows the user the word “\(word)”: \(literal)"
                        )
                    }
                    for phrase in Self.forbiddenPhrases {
                        XCTAssertFalse(
                            haystack.contains(phrase),
                            "\(mode) \(relative) describes implementation rather than an action: \(literal)"
                        )
                    }
                }
            }
        }
    }

    /// The keyboard's error strip is a consumer surface too. Only
    /// `userFacingMessage` is judged — the rest of the client legitimately
    /// names URLs and headers, because that is the request it builds rather
    /// than copy anyone reads.
    func testKeyboardCoachErrorsNameNoImplementationDetail() throws {
        let client = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        let body = try XCTUnwrap(
            SwiftSource.body(
                ofDeclaration: "public var userFacingMessage: String",
                in: SwiftSource.stripComments(client)
            ),
            "the keyboard must map Coach failures through userFacingMessage"
        )
        for literal in SwiftSource.stringLiterals(in: body) {
            let haystack = literal.lowercased()
            for term in Self.forbiddenTerms {
                XCTAssertFalse(
                    haystack.contains(term),
                    "the keyboard shows the user “\(term)”: \(literal)"
                )
            }
            for phrase in Self.forbiddenPhrases {
                XCTAssertFalse(
                    haystack.contains(phrase),
                    "the keyboard describes implementation rather than an action: \(literal)"
                )
            }
        }
        XCTAssertTrue(
            body.contains("LocalIntelligenceCopy.coachRequiresInternet"),
            "Build 111's offline copy must be unchanged"
        )
        XCTAssertTrue(
            body.contains("Request timed out. Check your connection and tap Retry."),
            "Build 111's timeout copy must be unchanged"
        )
    }

    func testSettingsCarriesNoEndpointDiagnosticsUnderAnyCompilationMode() throws {
        let raw = try Self.source("App/SettingsView.swift")
        XCTAssertFalse(
            raw.contains("#if DEBUG"),
            "Settings must compile one surface — an internal build may not reveal extra UI"
        )
        for debug in [false, true] {
            let mode = debug ? "DEBUG" : "Release"
            let source = try SwiftSource.preprocess(raw, debug: debug)
            for marker in Self.settingsDiagnosticMarkers {
                XCTAssertFalse(
                    source.contains(marker),
                    "\(mode) Settings still carries the “\(marker)” diagnostic"
                )
            }
        }
    }

    func testSettingsNeverRendersARawErrorDescription() throws {
        let raw = try Self.source("App/SettingsView.swift")
        XCTAssertFalse(
            raw.contains("localizedDescription"),
            "raw error text is implementation detail; Settings must map failures to an action"
        )
        let coach = try Self.source("App/CoachView.swift")
        XCTAssertFalse(
            coach.contains("errorMessage = error.localizedDescription"),
            "Coach must map failures to an action-oriented message, not render the raw error"
        )
    }

    func testAccountAndPrivacyCopySaysWhatTheUserOwnsNotWhereItLives() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("Recipient profiles stay on this device."),
            "recipient privacy copy must say “on this device”, never “local App Group”"
        )
        XCTAssertTrue(
            settings.contains("permanently deletes your account and everything saved with it"),
            "account-deletion copy must say the account and its data are deleted, not “from Tono's servers”"
        )
        let manager = try Self.source("App/RecipientsManagerView.swift")
        XCTAssertTrue(
            manager.contains("Recipient profiles stay on this device."),
            "the recipient manager must carry the same on-device claim"
        )
    }

    // MARK: - Preserved accepted fixes

    func testSettingsKeepsOneCompactRecipientRowAndNoDirectRoster() throws {
        let release = try SwiftSource.preprocess(try Self.source("App/SettingsView.swift"), debug: false)
        let recipients = try XCTUnwrap(
            SwiftSource.body(ofDeclaration: "private var recipientsSection", in: release),
            "Settings must keep a recipients section"
        )
        for rosterUI in [
            "ForEach(recipients", ".swipeActions", "Button(\"Add manually\")",
            "Label(\"Contacts Access & Import\"", ".sheet(isPresented: $showAddRecipient)",
        ] {
            XCTAssertFalse(
                recipients.contains(rosterUI),
                "main Settings must not render the roster directly (\(rosterUI))"
            )
        }
        XCTAssertEqual(
            recipients.components(separatedBy: "NavigationLink").count - 1, 1,
            "there must be exactly one compact recipient manager row"
        )
        XCTAssertTrue(recipients.contains("RecipientsManagerView()"))
        XCTAssertTrue(recipients.contains("RecipientsSettingsSummary("))

        let manager = try Self.source("App/RecipientsManagerView.swift")
        XCTAssertTrue(
            manager.contains("static let rowCount = 1"),
            "the compact summary must stay a single row"
        )
        for required in [".searchable(", "ForEach(filtered)", "ContactsAccessView(model: contacts)"] {
            XCTAssertTrue(
                manager.contains(required),
                "the dedicated manager must stay searchable, lazy, and own access management (\(required))"
            )
        }
    }

    func testSetupDoctorAndConsumerControlsRemainReachableFromSettings() throws {
        let settings = try Self.source("App/SettingsView.swift")
        XCTAssertTrue(settings.contains("SetupDoctorView()"), "Setup Doctor must stay reachable from Settings")
        XCTAssertTrue(settings.contains("AccountDeletionView"), "account management must stay in Settings")
        XCTAssertTrue(settings.contains("showPaywall"), "subscription management must stay in Settings")
        XCTAssertTrue(settings.contains("LiveTonePreference.settingsCopy"), "Live Tone control must stay in Settings")
        XCTAssertTrue(settings.contains("CoachOptionalVariant.allCases"), "Coach variant settings must stay in Settings")
        XCTAssertTrue(settings.contains("LocalIntelligenceSelfTest.run("), "the local self-test must stay in Settings")
    }

    func testBuild111CursorAndReconnectSourcesAndTestsAreUnchanged() throws {
        let engine = try Self.source("KeyboardExtension/AppleFidelity/SpaceCursorEngine.swift")
        for (symbol, value) in [
            ("finePointsPerCharacter", "12.0"),
            ("precisionZonePoints", "36.0"),
            ("accelerationScalePoints", "180.0"),
        ] {
            XCTAssertTrue(
                engine.contains("public var \(symbol): Double = \(value)"),
                "Build 111's slower space cursor must keep \(symbol) at \(value)"
            )
        }

        let client = try Self.source("KeyboardExtension/TonoCoachClient.swift")
        XCTAssertTrue(client.contains("waitsForConnectivity: Bool = true"))
        XCTAssertTrue(client.contains("configuration.waitsForConnectivity = waitsForConnectivity"))
        let intelligence = try Self.source("KeyboardExtension/LocalIntelligence.swift")
        XCTAssertTrue(
            intelligence.contains("\"Waiting for connection… Coach resumes on its own\""),
            "Build 111's offline→online recovery copy must be untouched"
        )

        let cursorTests = try Self.source("Tests/Build111CursorSensitivityTests.swift")
        XCTAssertTrue(cursorTests.contains("testTheCurveIsAPureDilationOfBuild110"))
        XCTAssertTrue(cursorTests.contains("XCTAssertEqual(now.finePointsPerCharacter, then.finePointsPerCharacter * 1.5)"))
        let reconnectTests = try Self.source("Tests/Build111CoachReconnectTests.swift")
        XCTAssertTrue(reconnectTests.contains("testParkedRequestCompletesExactlyOnceWhenConnectivityReturns"))
        XCTAssertTrue(reconnectTests.contains("testNoApplicationLevelReplayAfterATransportFailure"))
    }

    // MARK: - Release identity

    func testAllFourShippedBundlesAreBuild112AtVersion11() throws {
        let root = Self.sourceRoot()
        let guardScript = try Self.source("Scripts/bump-build.sh")
        XCTAssertTrue(
            guardScript.contains("EXPECTED_BUILD=\"112\""),
            "the single build guard authority must pin 112"
        )
        for relative in Self.shippedPlists {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            XCTAssertEqual(plist?["CFBundleVersion"] as? String, "112", "\(relative) must declare build 112")
            XCTAssertEqual(
                plist?["CFBundleShortVersionString"] as? String, "1.1",
                "\(relative) must stay at marketing version 1.1"
            )
            XCTAssertTrue(guardScript.contains(relative), "the guard must still cover \(relative)")
        }
    }

    // MARK: - Helpers

    /// `#filePath` is `<srcroot>/Tests/…`; SRCROOT is two directories up.
    private static func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}

// MARK: - Swift source lexing
//
// Deliberately small and dependency-free. Comments are dropped before any
// judgement so prose about a backend cannot fail a consumer-copy assertion,
// and `#if DEBUG` is evaluated both ways so no UI can hide in one mode.

enum SwiftSource {

    static func stripComments(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var inString = false
        var blockDepth = 0
        func pair(at i: String.Index) -> String {
            let next = source.index(i, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
            return String(source[i..<next])
        }
        while index < source.endIndex {
            let character = source[index]
            let two = pair(at: index)
            if blockDepth > 0 {
                if two == "/*" {
                    blockDepth += 1
                    index = source.index(index, offsetBy: 2)
                } else if two == "*/" {
                    blockDepth -= 1
                    index = source.index(index, offsetBy: 2)
                } else {
                    if character == "\n" { output.append("\n") }
                    index = source.index(after: index)
                }
            } else if inString {
                output.append(character)
                if character == "\\", source.index(after: index) < source.endIndex {
                    output.append(source[source.index(after: index)])
                    index = source.index(index, offsetBy: 2)
                } else {
                    if character == "\"" { inString = false }
                    index = source.index(after: index)
                }
            } else if two == "//" {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
            } else if two == "/*" {
                blockDepth = 1
                index = source.index(index, offsetBy: 2)
            } else {
                output.append(character)
                if character == "\"" { inString = true }
                index = source.index(after: index)
            }
        }
        return output
    }

    struct UnbalancedConditional: Error {}

    /// Evaluates `#if DEBUG` / `#else` / `#endif`, so a surface can be judged
    /// exactly as each compilation mode would build it.
    static func preprocess(_ source: String, debug: Bool) throws -> String {
        var output: [String] = []
        var active = true
        var stack: [(parent: Bool, condition: Bool)] = []
        for line in stripComments(source).components(separatedBy: "\n") {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                let condition = String(directive.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                let value = condition == "DEBUG" ? debug : true
                stack.append((active, value))
                active = active && value
            } else if directive == "#else" {
                guard let top = stack.last else { throw UnbalancedConditional() }
                active = top.parent && !top.condition
            } else if directive == "#endif" {
                guard let top = stack.popLast() else { throw UnbalancedConditional() }
                active = top.parent
            } else if active {
                output.append(line)
            }
        }
        guard stack.isEmpty else { throw UnbalancedConditional() }
        return output.joined(separator: "\n")
    }

    /// Ordinary and multi-line string literals — what a user can actually read.
    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var current = ""
        var inLine = false
        var inBlock = false
        var index = source.startIndex
        func matches(_ needle: String, at i: String.Index) -> Bool {
            guard let end = source.index(i, offsetBy: needle.count, limitedBy: source.endIndex) else {
                return false
            }
            return source[i..<end] == needle
        }
        while index < source.endIndex {
            let character = source[index]
            if inBlock {
                if matches("\"\"\"", at: index) {
                    literals.append(current)
                    current = ""
                    inBlock = false
                    index = source.index(index, offsetBy: 3)
                    continue
                }
                current.append(character)
                index = source.index(after: index)
            } else if inLine {
                if character == "\\", source.index(after: index) < source.endIndex {
                    current.append(source[source.index(after: index)])
                    index = source.index(index, offsetBy: 2)
                    continue
                }
                if character == "\"" || character == "\n" {
                    literals.append(current)
                    current = ""
                    inLine = false
                    index = source.index(after: index)
                    continue
                }
                current.append(character)
                index = source.index(after: index)
            } else if matches("\"\"\"", at: index) {
                inBlock = true
                index = source.index(index, offsetBy: 3)
            } else if character == "\"" {
                inLine = true
                index = source.index(after: index)
            } else {
                index = source.index(after: index)
            }
        }
        return literals
    }

    /// Brace-balanced body of a declaration, so an assertion can be scoped to
    /// one section rather than a 1,200-line file.
    static func body(ofDeclaration marker: String, in source: String) -> String? {
        guard let start = source.range(of: marker) else { return nil }
        guard let open = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Tab titles in declaration order.
    static func tabItemLabels(in body: String) -> [String] {
        var labels: [String] = []
        var remainder = Substring(body)
        let marker = ".tabItem { Label(\""
        while let start = remainder.range(of: marker) {
            let rest = remainder[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            labels.append(String(rest[..<end]))
            remainder = rest[end...]
        }
        return labels
    }

    static func containsWord(_ word: String, in haystack: String) -> Bool {
        let letters = CharacterSet.alphanumerics
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: word, range: searchRange) {
            let beforeOK: Bool = {
                guard found.lowerBound > haystack.startIndex else { return true }
                let previous = haystack[haystack.index(before: found.lowerBound)]
                return previous.unicodeScalars.allSatisfy { !letters.contains($0) }
            }()
            let afterOK: Bool = {
                guard found.upperBound < haystack.endIndex else { return true }
                let next = haystack[found.upperBound]
                return next.unicodeScalars.allSatisfy { !letters.contains($0) }
            }()
            if beforeOK && afterOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }
}
