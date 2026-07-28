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
        // Build 117 — Read the Ask's own surfaces. `Shared/ReadTheAsk.swift`
        // is deliberately NOT here: it is pure Foundation and renders nothing,
        // so the discovery pass below correctly does not see it as a surface.
        "App/ReadTheAskView.swift",
        "App/RecipientsManagerView.swift",
        "App/SetupDoctorView.swift",
        "App/MemoryView.swift",
        "App/DigestView.swift",
        "App/HomeView.swift",
        "App/OnboardingEntryPointsView.swift",
        "App/OnboardingCalibrationView.swift",
        // Supplies the paywall's user-visible failure copy.
        "Shared/StoreKitManager.swift",
        // Supplies every surface's failure copy.
        "Shared/ConsumerErrorCopy.swift",
    ]

    // MARK: - Build 112 repair: the whole-surface raw-error contract
    //
    // The first version of this contract claimed whole-surface coverage and
    // did not have it. It judged string LITERALS, which is silent about
    // `errorMessage = error.localizedDescription` — there is no literal in
    // that line to judge. Five shipped surfaces passed it while putting raw
    // failures on screen: This Week, the paywall, the keyboard strip, Share,
    // and Messages.
    //
    // What follows judges EXPRESSIONS, and derives the surface list from the
    // Xcode project instead of trusting the one written above.

    /// Files that put pixels in front of a user, plus the two that supply the
    /// copy those pixels show. Proved complete by
    /// `testEveryShippedSurfaceThatRendersUIIsUnderContract`.
    private static let renderingSurfaces = [
        // Build 115 — the shared adaptive-layout primitive. It declares a
        // `ViewModifier`, so the discovery test below sees it as a surface; it
        // renders no copy of its own, which is exactly what the contract
        // requires of it.
        "App/AdaptiveLayout.swift",
        "App/CoachView.swift",
        "App/DigestView.swift",
        "App/HomeView.swift",
        "App/MemoryView.swift",
        "App/OnboardingCalibrationView.swift",
        "App/OnboardingEntryPointsView.swift",
        // Build 117 — Read the Ask's own surfaces, under the same raw-error
        // contract as every other screen. `Shared/ReadTheAsk.swift` is
        // deliberately absent: it is pure Foundation and renders nothing, which
        // is why the discovery pass below does not see it as a surface.
        "App/ReadTheAskView.swift",
        "App/RecipientsManagerView.swift",
        "App/SettingsView.swift",
        "App/SetupDoctorView.swift",
        "App/TonoApp.swift",
        "KeyboardExtension/KeyboardRootView.swift",
        "KeyboardExtension/KeyboardViewController.swift",
        "KeyboardExtension/LiveToneIndicatorView.swift",
        "KeyboardExtension/TonoKeyboardVisualStyle.swift",
        "ShareExtension/ShareRootView.swift",
        "ShareExtension/ShareViewController.swift",
        "Shared/ContactsSync.swift",
        "Shared/ConsumerErrorCopy.swift",
        "Shared/StoreKitManager.swift",
        "TonoMessagesExtension/MessagesViewController.swift",
    ]

    /// How a source is recognised as a consumer surface. Deliberately
    /// generous: a false positive costs one line above, a false negative is
    /// the hole this contract exists to close.
    /// Matched as whole identifiers: `validatedCustomText(` contains "Text("
    /// and `normalizedLabel(` contains "Label(", and neither renders anything.
    private static let surfaceMarkers = [
        #":\s*View\s*\{"#,
        #":\s*(?:UIViewController|UIInputViewController|MSMessagesAppViewController"#
            + #"|UIView|UILabel|UIButton|UIStackView|ViewModifier)\b"#,
        #"\bUIHostingController\b"#,
        #"\bText\("#,
        #"\bLabel\("#,
    ]

    /// Expressions that turn a raw failure into something a user can read.
    /// None may appear anywhere in a consumer surface.
    private static let rawErrorExpressions: [(pattern: String, why: String)] = [
        (#"\.localizedDescription\b"#, "renders a failure's own description"),
        (#"\.errorDescription\b"#, "renders a failure's own description"),
        (#"\bString\(describing:"#, "renders a value's debug description"),
        (#"\bString\(reflecting:"#, "renders a value's debug description"),
        (#"\.debugDescription\b"#, "renders a debug description"),
        (#"\.userInfo\b"#, "renders a failure's underlying detail"),
        (
            #"\\\(\s*(?:error|err|e|failure|nsError|urlError|underlyingError)\b"#,
            "interpolates a raw failure into consumer copy"
        ),
        (#"\bstatusCode\b"#, "puts a status code on a consumer surface"),
        (#"\bresponseBody\b"#, "puts a response body on a consumer surface"),
        (#"\bhttpResponse\b"#, "puts response detail on a consumer surface"),
        // Build 113. `localizedDescription` is one of several ways a
        // Foundation error hands you its text, and the ban list knew only
        // that one. An independent probe rendered
        // `(error as NSError).localizedFailureReason` and another rendered
        // `ns.domain`; both passed the Build 112 contract untouched.
        (#"\.localizedFailureReason\b"#, "renders a failure's own description"),
        (#"\.localizedRecoverySuggestion\b"#, "renders a failure's own description"),
        (#"\.localizedRecoveryOptions\b"#, "renders a failure's own description"),
        (#"\.failureReason\b"#, "renders a failure's own description"),
        (#"\.recoverySuggestion\b"#, "renders a failure's own description"),
        (#"\bNSError\b"#, "reaches for a failure's Foundation representation"),
        (#"\.domain\b"#, "puts a failure's error domain on a consumer surface"),
    ]

    /// State rendered to the user when a request fails.
    private static let failureStateSinks = [
        #"\berrorMessage\s*=\s*(.+)"#,
        #"\bpurchaseError\s*=\s*(.+)"#,
        #"\bmode\s*=\s*\.error\((.*)\)"#,
        #"\bcompletion\((.*)\)"#,
    ]

    /// The only functions allowed to produce a failure sentence. Each maps a
    /// failure's CASE — never its message payload — onto an action.
    private static let approvedErrorMappers = [
        "ConsumerErrorCopy.message(", "prettyError(", "requestErrorMessage(",
        "verificationErrorMessage(", "userFacingMessage",
    ]

    private static let errorIdentifiers = [
        "error", "err", "e", "failure", "nsError", "urlError", "underlyingError",
    ]

    /// Build 113: the two surfaces that map an HTTP status onto a Coach
    /// sentence, and the declaration whose body owns that mapping. Everything
    /// else routes through `ConsumerErrorCopy`, which keeps them apart already.
    private static let rateLimitSurfaces = [
        ("App/CoachView.swift", "private func prettyError(_ e: TonoBackendError) -> String"),
        ("KeyboardExtension/TonoCoachClient.swift", "public var userFacingMessage: String"),
    ]

    /// Words that mean "you must pay". True for 402, false for 429.
    private static let paywallVocab = ["subscription", "subscribe", "trial"]

    /// The surfaces that consume `TonoBackend.analyzeStream` directly. Both
    /// take the streaming path in production, so both used to lose the status.
    private static let streamingConsumers = [
        "KeyboardExtension/KeyboardRootView.swift",
        "ShareExtension/ShareRootView.swift",
    ]

    private static let shippedTargets = ["Tono", "TonoKeyboard", "TonoShare", "TonoMessagesExtension"]

    /// The mapper is the one file allowed to author failure copy, so its copy
    /// is pinned exactly. A sentence not on this list is one nobody reviewed.
    private static let consumerErrorSentences: Set<String> = [
        " ",
        "This email is already on \\(current) devices (max \\(max)). Contact support if you need more.",
        "Couldn't coach this draft.",
        "Couldn't read this message.",
        "Couldn't load your weekly summary.",
        "Purchase couldn't be completed.",
        "Restore couldn't be completed.",
        "Couldn't add the rewrite to your message.",
        "Try again.",
        "Check your connection and try again.",
        "Open Tono and sign in again.",
        "Open Tono once to finish setting up, then try again.",
        "An active trial or subscription is required. Open Tono to continue.",
        "Wait a minute and try again.",
        "Sign in with your email first so your subscription follows you if you reinstall.",
        "Try again, and contact support@tonoit.com if it keeps happening.",
    ]

    /// The four sentences the repair brief names verbatim — proof the mapper
    /// keeps actions distinct instead of flattening every failure into one
    /// apology.
    private static let requiredActionSentences: [(action: String, headline: String, nextStep: String)] = [
        ("weeklySummary", "Couldn't load your weekly summary.", "Try again."),
        ("purchase", "Purchase couldn't be completed.", "Try again."),
        ("restore", "Restore couldn't be completed.", "Try again."),
        ("coachDraft", "Couldn't coach this draft.", "Check your connection and try again."),
    ]

    /// Calls whose string arguments a user reads.
    private static let renderCalls = [
        "Text(", "Label(", "Button(", "TextField(", "SecureField(", "Toggle(",
        "Picker(", "Section(", "NavigationLink(", "ProgressView(", "Stepper(",
        "Menu(", "Link(", "Alert(", "TextEditor(",
        ".navigationTitle(", ".accessibilityLabel(", ".accessibilityHint(",
        ".accessibilityValue(", ".alert(", ".confirmationDialog(", ".help(",
        ".searchable(", ".setTitle(",
        "mode = .error(", "ErrorView(", "completion(",
    ]

    private static let renderAssignments = [
        ".accessibilityLabel =", ".accessibilityHint =", ".accessibilityValue =",
        ".text =", ".title =", ".placeholder =",
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

    /// Build 113: 429 is the rate limit. 402 is the entitlement gate. Never
    /// one sentence.
    ///
    /// `TonoBackend` states the invariant in its own words — "Keep them
    /// distinct — 429 is NOT 'subscription required'" — and both Coach
    /// surfaces broke it anyway: the host app folded `402, 429` into a single
    /// branch and the keyboard answered 429 with the paywall sentence
    /// outright. A subscriber who trips the per-IP limit was told to buy the
    /// subscription they already pay for — a false statement on the surface
    /// people use most. 401 is judged alongside them because both surfaces
    /// used to drop it into a bare retry that names no next step.
    func testRateLimitedUsersAreNotToldToSubscribe() throws {
        for (relative, signature) in Self.rateLimitSurfaces {
            let body = try XCTUnwrap(
                SwiftSource.body(
                    ofDeclaration: signature,
                    in: SwiftSource.stripComments(try Self.source(relative))
                ),
                "\(relative) must still declare \(signature)"
            )

            XCTAssertEqual(
                SwiftSource.matches(#"case\s+(?:402\s*,\s*429|429\s*,\s*402)\s*:"#, in: body),
                [],
                "\(relative) answers 402 and 429 with one branch"
            )

            var answers: [Int: String] = [:]
            for code in [401, 402, 429] {
                let sentences = SwiftSource.captures(
                    #"case\s+\#(code)\s*:\s*return\s+"([^"]*)""#,
                    in: body
                )
                let sentence = try XCTUnwrap(
                    sentences.first,
                    "\(relative) must answer \(code) on its own"
                )
                answers[code] = sentence
            }

            XCTAssertEqual(
                Set(answers.values).count, 3,
                "\(relative) must give 401, 402 and 429 three different sentences"
            )

            // The truthfulness test runs in both directions: only the
            // entitlement gate may talk about paying, and the rate limit must
            // say what actually helps — wait.
            let rateLimited = (answers[429] ?? "").lowercased()
            for word in Self.paywallVocab {
                XCTAssertFalse(
                    rateLimited.contains(word),
                    "\(relative) tells a rate-limited user to subscribe: \(answers[429] ?? "")"
                )
            }
            XCTAssertTrue(
                Self.paywallVocab.contains(where: { (answers[402] ?? "").lowercased().contains($0) }),
                "\(relative) must still tell a gated user what they need: \(answers[402] ?? "")"
            )
            XCTAssertTrue(
                rateLimited.contains("wait"),
                "\(relative) must tell a rate-limited user to wait: \(answers[429] ?? "")"
            )
        }
    }

    /// Build 113: a streamed failure reaches the mapper as a status, never as
    /// a sentence.
    ///
    /// The non-streaming path throws `TonoBackendError.http(code, …)` and
    /// keeps 401, 402 and 429 apart. The streaming path — the one the keyboard
    /// strip and the Share sheet actually take — used to yield
    /// `.error("Server error (code)")`, which the consumers wrapped into
    /// `ToneEngineError.backend`, and the mapper can only answer that with
    /// "Try again." The status existed at the yield site and was destroyed a
    /// line later. Build 112 removed the leak here but did not recover the
    /// distinction; this keeps both — structure travels, prose does not.
    func testStreamedFailuresReachTheMapperAsAStatus() throws {
        let backend = SwiftSource.stripComments(try Self.source("Shared/TonoBackend.swift"))

        XCTAssertTrue(
            backend.contains("case failure(status: Int)"),
            "the analysis stream must be able to carry a status code"
        )
        XCTAssertEqual(
            SwiftSource.matches(#"yield\(\s*\.error\(\s*"Server error"#, in: backend), [],
            "the stream must not stringify a status into a sentence"
        )
        XCTAssertFalse(
            SwiftSource.matches(
                #"continuation\.yield\(\s*\.failure\(status:\s*code\s*\)\s*\)"#, in: backend
            ).isEmpty,
            "a non-2xx response must yield its status rather than a sentence about it"
        )

        let declaration = "public enum StreamedFailure: Error, Equatable"
        let payload = try XCTUnwrap(
            SwiftSource.body(ofDeclaration: declaration, in: backend),
            "the streamed failure must be a typed error"
        )
        // A body is where a host name or a stack trace would ride along. The
        // type is useless to a leak if it cannot hold text at all.
        XCTAssertFalse(
            payload.contains("String"),
            "the streamed failure must carry no message payload: \(payload)"
        )

        for relative in Self.streamingConsumers {
            let source = SwiftSource.stripComments(try Self.source(relative))
            // One stream loop per `.perception` arm. Every one of them has to
            // hand the status on, or the surface it feeds quietly loses the
            // distinction again.
            let loops = SwiftSource.matches(#"case\s+\.perception\("#, in: source).count
            let handled = SwiftSource.matches(#"case\s+\.failure\(let status\)"#, in: source).count
            let forwarded = SwiftSource.matches(
                #"StreamedFailure\.http\(status:\s*status\)"#, in: source
            ).count
            XCTAssertGreaterThan(loops, 0, "\(relative) must still consume the analysis stream")
            XCTAssertGreaterThanOrEqual(
                handled, loops,
                "\(relative) leaves \(loops - handled) stream loop(s) without a status arm"
            )
            XCTAssertGreaterThanOrEqual(
                forwarded, loops,
                "\(relative) must hand every streamed status to the mapper"
            )
        }
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

    // MARK: - Build 112 repair: no raw failure reaches a surface

    /// The surface list is derived from the project, not trusted. A new
    /// screen cannot ship unjudged.
    ///
    /// Membership is read as "appears in some target's Sources phase", which
    /// is a superset of the shipped targets — over-inclusion only ever adds
    /// files to the contract, so a shipped surface cannot slip through.
    func testEveryShippedSurfaceThatRendersUIIsUnderContract() throws {
        let root = Self.sourceRoot()
        let project = try Self.source("Tono.xcodeproj/project.pbxproj")
        let declared = Set(Self.renderingSurfaces)
        var unjudged: [String] = []

        for directory in Self.productionDirectories {
            for file in Self.swiftFiles(under: root.appendingPathComponent(directory)) {
                guard project.contains("/* \(file.lastPathComponent) in Sources */") else { continue }
                // `#filePath` and `FileManager` can disagree about symlinked
                // roots (`/tmp` vs `/private/tmp`), so both sides are resolved
                // before the prefix is stripped.
                let resolvedRoot = root.resolvingSymlinksInPath().path
                let relative = file.resolvingSymlinksInPath().path
                    .replacingOccurrences(of: resolvedRoot + "/", with: "")
                let source = SwiftSource.stripComments((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                guard Self.surfaceMarkers.contains(where: { !SwiftSource.matches($0, in: source).isEmpty })
                else { continue }
                if !declared.contains(relative) { unjudged.append(relative) }
            }
        }
        XCTAssertEqual(
            unjudged, [],
            "these shipped sources render UI but are not under the raw-error contract"
        )
        for relative in Self.renderingSurfaces {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                "\(relative) is under contract but missing from disk"
            )
        }
    }

    /// The assertion the first Build 112 contract lacked. It judges
    /// expressions, so `errorMessage = error.localizedDescription` fails with
    /// no string literal involved.
    func testNoConsumerSurfaceTurnsARawFailureIntoText() throws {
        for relative in Self.renderingSurfaces {
            let source = SwiftSource.stripComments(try Self.source(relative))
            for (pattern, why) in Self.rawErrorExpressions {
                let hits = SwiftSource.matches(pattern, in: source)
                XCTAssertEqual(
                    hits, [],
                    "\(relative) \(why): \(hits.prefix(4))"
                )
            }
        }
    }

    /// The raw-expression ban says a failure cannot be *formatted* onto a
    /// surface. This says it cannot be *assigned* to one either — together
    /// they leave no path from an `Error` to a screen that skips the mapper.
    func testRenderedFailureStateIsFixedCopyOrAMappedFailure() throws {
        for relative in Self.renderingSurfaces {
            let source = SwiftSource.stripComments(try Self.source(relative))
            // Build 113: the identifiers that hold a failure *in this file*,
            // not a fixed list. `let cause = error` is one line of laundering
            // and the old head-anchored rule could not see through it.
            let tainted = SwiftSource.taintedIdentifiers(seeds: Self.errorIdentifiers, in: source)
            var offenders: [String] = []
            for sink in Self.failureStateSinks {
                for assigned in SwiftSource.captures(sink, in: source) {
                    let rhs = assigned.trimmingCharacters(in: .whitespaces)
                    if rhs.isEmpty || rhs.hasPrefix("nil") { continue }
                    if Self.approvedErrorMappers.contains(where: { rhs.contains($0) }) { continue }
                    // Judge the whole right-hand side, not just its first
                    // token. A failure reached the screen through
                    // `(error as NSError)…` and through `{ let ns = error … }()`
                    // because both begin with punctuation, and through a
                    // string literal because the old rule skipped anything
                    // starting with a quote. Literal text drops out;
                    // interpolations do not, because an interpolation is code
                    // that gets rendered.
                    let split = SwiftSource.splitLiterals(rhs)
                    let named = SwiftSource.mentioned(
                        tainted,
                        in: split.code + " " + split.interpolations.joined(separator: " ")
                    )
                    if !named.isEmpty {
                        offenders.append("\(named) in \(rhs.prefix(70))")
                    }
                }
            }
            XCTAssertEqual(
                offenders, [],
                "\(relative) assigns a raw failure into rendered state"
            )
        }
    }

    /// The one file allowed to author failure copy is pinned exactly, must
    /// classify by case rather than by payload, and must ship everywhere.
    func testTheFailureMapperIsPinnedClassifiesByCaseAndShipsEverywhere() throws {
        let source = SwiftSource.stripComments(try Self.source("Shared/ConsumerErrorCopy.swift"))

        let unreviewed = Set(SwiftSource.rawStringLiterals(in: source))
            .subtracting(Self.consumerErrorSentences)
            .sorted()
        XCTAssertEqual(
            unreviewed, [],
            "the failure mapper may only author sentences this contract reviewed"
        )

        for (action, headline, nextStep) in Self.requiredActionSentences {
            XCTAssertTrue(
                source.contains(headline) && source.contains(nextStep),
                "the mapper must keep \(action) distinct: “\(headline) \(nextStep)”"
            )
        }

        let classify = try XCTUnwrap(
            SwiftSource.body(
                ofDeclaration: "private static func classify(_ error: Error) -> Recovery",
                in: source
            ),
            "the mapper must classify failures in one place"
        )
        XCTAssertFalse(
            classify.contains("localizedDescription") || classify.contains("String(describing:"),
            "the mapper must classify a failure by case, never by its message payload"
        )
        for family in [
            "TonoBackendError", "ToneEngineError", "StoreKitManager.StoreError", "URLError",
            "StreamedFailure",
        ] {
            XCTAssertTrue(classify.contains(family), "the mapper must classify \(family)")
        }

        let project = try Self.source("Tono.xcodeproj/project.pbxproj")
        XCTAssertEqual(
            project.components(separatedBy: "/* ConsumerErrorCopy.swift in Sources */").count - 1,
            Self.shippedTargets.count * 2,
            "the mapper needs one build file and one Sources entry per shipped target"
        )
        XCTAssertEqual(
            project.components(separatedBy: "/* ConsumerErrorCopy.swift */ = {isa = PBXFileReference;").count - 1,
            1,
            "the mapper must have exactly one file reference"
        )
    }

    /// Consumer vocabulary, judged on what is rendered rather than on a whole
    /// file. `testNoConsumerStringNamesImplementationDetail…` keeps judging
    /// every literal in `App/` and the copy files; this adds the surfaces
    /// that also build requests, where a host name is the request rather than
    /// something a user reads.
    func testRenderedCopyNamesNoImplementationDetail() throws {
        for relative in Self.renderingSurfaces {
            let raw = try Self.source(relative)
            for debug in [false, true] {
                let mode = debug ? "DEBUG" : "Release"
                let source = try SwiftSource.preprocess(raw, debug: debug)
                for literal in SwiftSource.renderedLiterals(in: source, calls: Self.renderCalls, assignments: Self.renderAssignments) {
                    let haystack = SwiftSource.withoutInterpolation(literal).lowercased()
                    for term in Self.forbiddenTerms {
                        XCTAssertFalse(
                            haystack.contains(term),
                            "\(mode) \(relative) renders “\(term)”: \(literal)"
                        )
                    }
                    for word in Self.forbiddenWords {
                        XCTAssertFalse(
                            SwiftSource.containsWord(word, in: haystack),
                            "\(mode) \(relative) renders the word “\(word)”: \(literal)"
                        )
                    }
                    for phrase in Self.forbiddenPhrases {
                        XCTAssertFalse(
                            haystack.contains(phrase),
                            "\(mode) \(relative) renders implementation rather than an action: \(literal)"
                        )
                    }
                }
            }
        }
    }

    /// Build 112's full test run trapped in `CFRelease` because the main
    /// queue re-read `pendingTimer` while the engine's serial queue was
    /// writing it. The fix is structural: the main queue only ever sees a
    /// captured instance, and the timer is invalidated on the run loop it was
    /// added to.
    func testLiveToneDebounceTimerLifecycleIsQueueConfined() throws {
        let engine = try Self.source("KeyboardExtension/LiveToneEngine.swift")
        let stripped = SwiftSource.stripComments(engine)
        let schedule = try XCTUnwrap(
            SwiftSource.body(
                ofDeclaration: "private func scheduleTimer(draft: String, boundHash: Int)",
                in: stripped
            ),
            "the engine must schedule the debounce in one place"
        )
        let cancel = try XCTUnwrap(
            SwiftSource.body(ofDeclaration: "private func cancelTimer()", in: stripped),
            "the engine must cancel the debounce in one place"
        )
        XCTAssertFalse(
            schedule.contains("self.pendingTimer"),
            "the main queue must never re-read the engine's queue-confined timer"
        )
        XCTAssertTrue(
            schedule.contains("RunLoop.main.add(timer, forMode: .common)"),
            "the debounce timer must stay installed on the main run loop"
        )
        XCTAssertTrue(
            cancel.contains("DispatchQueue.main.async") && cancel.contains("timer.invalidate()"),
            "a timer must be invalidated on the run loop it was added to"
        )
        XCTAssertFalse(
            stripped.contains("deinit"),
            "deinit runs on an arbitrary thread and must not touch queue-confined timer state"
        )
        XCTAssertTrue(
            engine.contains("public static let debounceInterval: TimeInterval = 0.500"),
            "the 500 ms debounce window must be unchanged"
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

    /// Every shipped bundle agrees with the ONE build authority, and the
    /// marketing version is unchanged.
    ///
    /// Build 114 asserts BOTH halves, deliberately; Build 115 keeps them.
    ///
    /// An intermediate version of this test derived the number from
    /// `Scripts/bump-build.sh` and stopped pinning a literal, to avoid keeping
    /// a fifth copy of the build number. That removed the only thing this test
    /// uniquely protects: with nothing but the derivation, all five places
    /// could drift together — an accidental bump to the guard script would
    /// propagate to every plist and the suite would still pass.
    ///
    /// So the shape is: the four bundles must agree with the guard script
    /// (that catches a partial bump, which is the common mistake), AND the
    /// guard script must pin the number a human actually reviewed (that
    /// catches a wholesale one). A real release edits the literal here on
    /// purpose, which is the point — release identity should not be able to
    /// change without somebody saying so.
    /// BUILD 117 UPDATE — the number moves because the build number is a
    /// reviewed release input and this is a new release object. The marketing
    /// version stays at 1.1: Read the Ask is a new capability inside the same
    /// product version, and nothing in this build is a new product version.
    func testAllFourShippedBundlesAreBuild117AtVersion11() throws {
        let root = Self.sourceRoot()
        let guardScript = try Self.source("Scripts/bump-build.sh")
        let expected = try XCTUnwrap(
            Self.value(ofAssignment: "EXPECTED_BUILD", in: guardScript),
            "Scripts/bump-build.sh must pin EXPECTED_BUILD — it is the release authority"
        )
        XCTAssertEqual(
            expected, "117",
            "the single build guard authority must pin the reviewed build number"
        )
        for relative in Self.shippedPlists {
            let data = try Data(contentsOf: root.appendingPathComponent(relative))
            let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
            XCTAssertEqual(
                plist?["CFBundleVersion"] as? String, expected,
                "\(relative) must declare build \(expected), the number Scripts/bump-build.sh pins"
            )
            XCTAssertEqual(
                plist?["CFBundleShortVersionString"] as? String, "1.1",
                "\(relative) must stay at marketing version 1.1"
            )
            XCTAssertTrue(guardScript.contains(relative), "the guard must still cover \(relative)")
        }
    }

    /// Read `NAME="value"` out of the guard script. Mirrors the parser in
    /// `BuildNumberGuardTests` so both read the authority the same way.
    private static func value(ofAssignment name: String, in script: String) -> String? {
        for rawLine in script.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(name)=") else { continue }
            return line.dropFirst(name.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return nil
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

    // MARK: - Build 112 repair: expression-level lexing

    /// Every match of `pattern`, as text. Used to judge expressions rather
    /// than literals — the leak this contract missed had no literal in it.
    static func matches(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        return regex
            .matches(in: source, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range) }
    }

    /// The first capture group of every match — the right-hand side of an
    /// assignment into rendered state.
    static func captures(_ pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = source as NSString
        return regex
            .matches(in: source, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
                return text.substring(with: match.range(at: 1))
            }
    }

    /// Separate Swift code from literal text, keeping interpolations as code.
    ///
    /// Build 113. The contract used to judge a right-hand side by its first
    /// token and to skip anything starting with a quote. Both were bypassable
    /// in one line: `"Couldn't load. \(cause)"` starts with a quote and every
    /// character that matters is inside it. Literal *text* is copy, and is
    /// judged as vocabulary elsewhere; an interpolation is executable code
    /// that gets rendered, so it belongs on the code side of this split.
    static func splitLiterals(_ source: String) -> (code: String, interpolations: [String]) {
        var code = ""
        var interpolations: [String] = []
        var index = source.startIndex
        var inString = false
        while index < source.endIndex {
            let character = source[index]
            if inString {
                let next = source.index(after: index)
                if character == "\\", next < source.endIndex {
                    if source[next] == "(" {
                        var depth = 0
                        var scan = next
                        while scan < source.endIndex {
                            if source[scan] == "(" { depth += 1 }
                            if source[scan] == ")" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            scan = source.index(after: scan)
                        }
                        let start = source.index(after: next)
                        if scan < source.endIndex, start <= scan {
                            interpolations.append(String(source[start..<scan]))
                            index = source.index(after: scan)
                        } else {
                            index = source.endIndex
                        }
                        continue
                    }
                    // An ordinary escape: \" \\ \n …
                    index = source.index(index, offsetBy: 2, limitedBy: source.endIndex)
                        ?? source.endIndex
                    continue
                }
                if character == "\"" { inString = false }
                index = source.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                index = source.index(after: index)
                continue
            }
            code.append(character)
            index = source.index(after: index)
        }
        return (code, interpolations)
    }

    /// Every name in `names` that appears in `expression` as a whole word.
    static func mentioned(_ names: Set<String>, in expression: String) -> [String] {
        names
            .filter { name in
                let escaped = NSRegularExpression.escapedPattern(for: name)
                return !matches(#"\b\#(escaped)\b"#, in: expression).isEmpty
            }
            .sorted()
    }

    /// Names that hold a failure — including ones laundered through a binding.
    ///
    /// Build 113. A fixed list of identifiers is defeated by one `let`:
    /// `let cause = error` renames the failure, and
    /// `{ let ns = error as NSError; … }()` renames it inside a closure the
    /// old head-anchored rule never looked into. Anything bound from
    /// something already tainted is tainted too, to a fixed point, so a chain
    /// of renames does not launder a failure either.
    static func taintedIdentifiers(seeds: [String], in source: String) -> Set<String> {
        var tainted = Set(seeds)
        let split = splitLiterals(source)
        let haystack = split.code + "\n" + split.interpolations.joined(separator: "\n")

        for name in captures(#"\bcatch\s+let\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: haystack) {
            tainted.insert(name)
        }

        let bindings = matches(
            #"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*(?::\s*[^=\n]+?)?=\s*[^\n]+"#,
            in: haystack
        )
        for _ in 0..<4 {  // a fixed point; four renames is past any real chain
            var grew = false
            for binding in bindings {
                guard
                    let name = captures(
                        #"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"#, in: binding
                    ).first,
                    !tainted.contains(name),
                    let equals = binding.firstIndex(of: "=")
                else { continue }
                let bound = String(binding[binding.index(after: equals)...])
                if !mentioned(tainted, in: bound).isEmpty || bound.contains("NSError") {
                    tainted.insert(name)
                    grew = true
                }
            }
            if !grew { break }
        }
        return tainted
    }

    /// True when `expression` begins with `word` as a whole identifier, so
    /// `error.localizedDescription` is caught and `errorCopy` is not.
    static func startsWithWord(_ word: String, _ expression: String) -> Bool {
        guard expression.hasPrefix(word) else { return false }
        let next = expression.dropFirst(word.count).first
        guard let next else { return true }
        return !next.isLetter && !next.isNumber && next != "_"
    }

    /// The argument list of the call whose `(` is at `open`.
    private static func balancedCall(in source: String, from open: String.Index) -> String {
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "(" { depth += 1 }
            if source[index] == ")" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return String(source[open...])
    }

    /// Like `stringLiterals`, but escapes keep their backslash so `\(…)` is
    /// still recognisable as an interpolation rather than a bare `(…)`.
    /// `stringLiterals` unescapes, which is right for judging prose and wrong
    /// for telling code apart from copy.
    static func rawStringLiterals(in source: String) -> [String] {
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
                    current.append(character)
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

    /// String literals a user actually reads. A keyboard legitimately names
    /// the request it builds; that is not copy. Only arguments of rendering
    /// calls and assignments to rendered UIKit properties are judged.
    static func renderedLiterals(in source: String, calls: [String], assignments: [String]) -> [String] {
        let stripped = stripComments(source)
        var literals: [String] = []
        for call in calls {
            var searchStart = stripped.startIndex
            while let found = stripped.range(of: call, range: searchStart..<stripped.endIndex) {
                let openParen = stripped.index(before: found.upperBound)
                literals += rawStringLiterals(in: balancedCall(in: stripped, from: openParen))
                searchStart = found.upperBound
            }
        }
        for assignment in assignments {
            var searchStart = stripped.startIndex
            while let found = stripped.range(of: assignment, range: searchStart..<stripped.endIndex) {
                let lineEnd = stripped.range(of: "\n", range: found.upperBound..<stripped.endIndex)?.lowerBound
                    ?? stripped.endIndex
                literals += rawStringLiterals(in: String(stripped[found.lowerBound..<lineEnd]))
                searchStart = found.upperBound
            }
        }
        return literals
    }

    /// Drops `\(…)` segments — those are code, not copy. Raw failures
    /// reaching copy through interpolation are caught structurally by
    /// `testNoConsumerSurfaceTurnsARawFailureIntoText`, which is strictly
    /// stronger than matching vocabulary against an expression.
    static func withoutInterpolation(_ literal: String) -> String {
        var output = ""
        var depth = 0
        var index = literal.startIndex
        while index < literal.endIndex {
            let next = literal.index(after: index)
            if depth == 0, literal[index] == "\\", next < literal.endIndex, literal[next] == "(" {
                depth = 1
                index = literal.index(index, offsetBy: 2)
                continue
            }
            if depth > 0 {
                if literal[index] == "(" { depth += 1 }
                if literal[index] == ")" { depth -= 1 }
                index = next
                continue
            }
            output.append(literal[index])
            index = next
        }
        return output
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
