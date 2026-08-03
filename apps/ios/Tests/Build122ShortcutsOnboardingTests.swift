import XCTest
import SwiftUI
import UIKit
@testable import Tono

/// Build 122 — the onboarding Shortcut correction, as a source-and-runtime
/// contract.
///
/// Root cause this suite pins: `App/OnboardingEntryPointsView.swift` shipped a
/// tile titled "Tono Rewrite Shortcut — Coming soon" whose copy claimed there
/// was "no verified public Tono Rewrite Shortcut install link yet" — while the
/// build's own Xcode Cloud source already contained `CoachDraftIntent`,
/// `TonoShortcutsProvider`, `OpenKeyboardSetupIntent` (Open Tono Keyboard
/// Setup) and `SetToneVariantEnabledIntent` (Set Tono Tone Variant), all with
/// App Intents target membership. The tile told the truth about a product that
/// no longer existed.
///
/// The assertions here fail on exactly the ways the correction could regress:
///
///   * the stale "Coming soon" shortcut tile or its "no install link" copy
///     coming back;
///   * the custom-rewrite steps (search Tono → Rewrite Draft, Ask Each Time,
///     Rewrite Style = Custom, a 1–120 character Custom Style) going missing;
///   * any wording that implies Tono sends the message for the person;
///   * the real "Open Shortcuts app" action disappearing, or the launcher
///     regressing into an unsafe force-unwrap or a fake import URL.
///
/// The source assertions are pure `String.contains` over the reviewed file, so
/// they fail on the copy a reviewer would read rather than on a simulator. The
/// launcher assertions drive the real `ShortcutsAppLink` through a fake opener.
/// The render section hosts the REAL shipping view and reads its accessibility
/// tree, and writes iPhone + iPad PNGs as runtime evidence.
final class Build122ShortcutsOnboardingTests: XCTestCase {

    // MARK: - Sources under contract

    private static let onboarding = "App/OnboardingEntryPointsView.swift"
    private static let launcher = "App/ShortcutsAppLink.swift"
    private static let provider = "App/CoachDraftIntent.swift"
    private static let localIntents = "App/AppleIntelligenceIntents.swift"

    // MARK: - Root cause: the stale tile is gone

    func testTheStaleComingSoonShortcutTileIsGone() throws {
        let source = try Self.source(Self.onboarding)
        for stale in [
            "Tono Rewrite Shortcut — Coming soon",
            "There is no verified public Tono Rewrite Shortcut install link yet",
            "no verified public Tono Rewrite Shortcut install link",
        ] {
            XCTAssertFalse(
                source.contains(stale),
                "the corrected onboarding must not carry the stale shortcut copy: “\(stale)”"
            )
        }
    }

    /// "Coming soon" may still describe the email tile when the email flag is
    /// off — but never the Shortcut. The shortcut detail must be truthful.
    func testTheShortcutTileNoLongerClaimsComingSoon() throws {
        let source = try Self.source(Self.onboarding)
        let detail = try XCTUnwrap(
            Self.value(of: "shortcutDetail", in: source),
            "onboarding must keep a shortcutDetail string"
        )
        XCTAssertFalse(
            detail.lowercased().contains("coming soon"),
            "the shortcut tile detail must not say “coming soon”: \(detail)"
        )
        XCTAssertTrue(
            source.contains("\"Set up the Tono Shortcut\""),
            "the shortcut tile title must be the truthful, actionable one"
        )
    }

    // MARK: - Discoverability copy (no import link, no auto-install)

    func testShortcutCopyDescribesRealDiscoverabilityWithoutClaimingImport() throws {
        let source = try Self.source(Self.onboarding)
        // Names the built-in actions a person will actually find.
        for actionName in ["Rewrite Draft", "Open Tono Keyboard Setup", "Set Tono Tone Variant"] {
            XCTAssertTrue(
                source.contains(actionName),
                "onboarding must name the discoverable action “\(actionName)”"
            )
        }
        XCTAssertTrue(
            source.contains("built into Apple's Shortcuts app"),
            "onboarding must say the actions are built into Apple's Shortcuts app"
        )
        XCTAssertTrue(
            source.contains("Nothing is imported and nothing installs on its own"),
            "onboarding must be explicit that nothing is imported or auto-installed"
        )
        // No import-link / auto-install claim in what a person READS. Judged
        // over comment-stripped source, so a doc comment that explains the tile
        // does NOT auto-install can't be mistaken for a claim that it does.
        let code = Self.stripComments(source).lowercased()
        for forbidden in ["import-workflow", "install link", "auto-install", "installs automatically", "one-tap install"] {
            XCTAssertFalse(
                code.contains(forbidden),
                "onboarding must not claim an import/auto-install path: “\(forbidden)”"
            )
        }
    }

    // MARK: - Custom-rewrite steps

    func testGuideCarriesEveryCustomRewriteStep() throws {
        let source = try Self.source(Self.onboarding)
        // The exact procedure the brief names, phrase by phrase.
        for step in [
            "Add Action",
            "search Tono",
            "Rewrite Draft",
            "Draft Message",
            "Ask Each Time",
            "Shortcut Input",
            "Rewrite Style to Custom",
            "Custom Style",
            "1–120 character",
            "warm, concise, and direct",
        ] {
            XCTAssertTrue(
                source.contains(step),
                "the custom-rewrite guide must include the step/detail “\(step)”"
            )
        }
    }

    /// The custom cap the guide states must equal the shared validator's cap, so
    /// the copy cannot drift from what the intent actually enforces.
    func testTheStatedCustomCapMatchesTheSharedValidator() throws {
        XCTAssertEqual(
            ShortcutRewrite.maxCustomLength, 120,
            "the shared Custom cap must be 120 — the number the guide copy states"
        )
        let source = try Self.source(Self.onboarding)
        XCTAssertTrue(
            source.contains("1–120 character"),
            "the guide must state the 1–120 character Custom Style range"
        )
    }

    // MARK: - No auto-send wording; run/review/copy is manual

    func testNoWordingImpliesTonoSendsTheMessage() throws {
        let code = Self.stripComments(try Self.source(Self.onboarding)).lowercased()
        // Affirmative auto-send phrasings the safe copy never uses. The negated
        // safety line ("Tono never sends your message for you") is handled
        // separately below, so it is not on this blunt list.
        for unsafe in [
            "auto-send",
            "automatically send",
            "automatically sends",
            "sends it for you",
            "sends automatically",
            "send it automatically",
        ] {
            XCTAssertFalse(
                code.contains(unsafe),
                "onboarding must never imply Tono sends for the user: “\(unsafe)”"
            )
        }
        // Every "sends your message for you" must be negated by "never" — a
        // dropped "never" would flip the safety claim into an auto-send promise.
        let sendsForYou = code.components(separatedBy: "sends your message for you").count - 1
        let neverSends = code.components(separatedBy: "never sends your message for you").count - 1
        XCTAssertEqual(
            sendsForYou, neverSends,
            "every 'sends your message for you' must be the negated, safe form"
        )
    }

    func testGuideStatesTheReviewThenCopyManuallyContract() throws {
        let source = try Self.source(Self.onboarding)
        XCTAssertTrue(
            source.contains("copy or share it yourself"),
            "the guide must tell the person to copy or share the rewrite themselves"
        )
        XCTAssertTrue(
            source.contains("Tono never sends your message for you"),
            "the guide must state plainly that Tono never sends the message"
        )
    }

    // MARK: - Requirements copy (no jargon)

    func testRequirementsCopyIsStatedPlainlyAndSeparatesLocalOnlyActions() throws {
        let source = try Self.source(Self.onboarding)
        XCTAssertTrue(
            source.contains("a signed-in Tono account, an active trial or subscription, and an internet connection"),
            "the guide must state the real network-rewrite requirements without jargon"
        )
        XCTAssertTrue(
            source.contains("work on your device only"),
            "the guide must mark Keyboard Setup and tone-setting actions as local-only"
        )
    }

    // MARK: - The real Open Shortcuts action

    func testOnboardingWiresTheBoundedOpenShortcutsAction() throws {
        let source = try Self.source(Self.onboarding)
        XCTAssertTrue(
            source.contains("\"Open Shortcuts app\""),
            "onboarding must offer an “Open Shortcuts app” action"
        )
        XCTAssertTrue(
            source.contains("ShortcutsAppLink.open"),
            "onboarding must open Shortcuts through the bounded ShortcutsAppLink launcher"
        )
    }

    /// The launcher itself: sanctioned public scheme, bare (no import path), no
    /// force-unwrap that could trap, and it lives OUTSIDE the intent the App
    /// Intent contract forbids URL side effects in.
    func testLauncherUsesTheSanctionedSchemeSafely() throws {
        // Judged over comment-stripped source: the file's doc comment explains
        // that the scheme is bare (no `import-workflow`), and that explanation
        // must not itself trip a "no fake import URL" assertion.
        let source = Self.stripComments(try Self.source(Self.launcher))
        XCTAssertTrue(
            source.contains("static let scheme = \"shortcuts\""),
            "the launcher must use Apple's public shortcuts scheme"
        )
        XCTAssertFalse(
            source.contains("import-workflow"),
            "the launcher must not build a fake import URL"
        )
        XCTAssertFalse(
            source.contains("\")!") || source.contains("appURL!"),
            "the launcher must not force-unwrap the URL — it fails honestly instead"
        )
        // The URL side effect must be here, not in CoachDraftIntent.
        let intent = Self.stripComments(try Self.source(Self.provider))
        for banned in ["shortcuts://", "openURL", "UIApplication"] {
            XCTAssertFalse(
                intent.contains(banned),
                "CoachDraftIntent must stay free of URL/app side effects (found “\(banned)”)"
            )
        }
    }

    func testTheThreeShippingActionsAreStillDeclared() throws {
        let provider = try Self.source(Self.provider)
        XCTAssertTrue(provider.contains("struct TonoShortcutsProvider: AppShortcutsProvider"))
        XCTAssertTrue(provider.contains("shortTitle: \"Rewrite Draft\""))
        XCTAssertTrue(provider.contains("struct CoachDraftIntent: AppIntent"))
        let local = try Self.source(Self.localIntents)
        XCTAssertTrue(local.contains("\"Open Tono Keyboard Setup\""))
        XCTAssertTrue(local.contains("\"Set Tono Tone Variant\""))
    }

    // MARK: - Launcher behavior (fail honest, never traps)

    func testLauncherURLIsBareAndNonNil() throws {
        let url = try XCTUnwrap(ShortcutsAppLink.appURL, "the Shortcuts URL must be constructible")
        XCTAssertEqual(url.scheme, "shortcuts")
        // Bare: no import-workflow host, no query, no path — it can only bring
        // the app forward, never import or run a workflow.
        XCTAssertTrue((url.query ?? "").isEmpty, "the Shortcuts URL must carry no query")
        XCTAssertTrue(url.path.isEmpty, "the Shortcuts URL must carry no path")
        XCTAssertNotEqual(url.host, "import-workflow")
    }

    func testLauncherReportsSuccessAndFailureHonestly() {
        let opened = FakeOpener(result: true)
        var reported: Bool?
        ShortcutsAppLink.open(using: opened) { reported = $0 }
        XCTAssertEqual(opened.openedURLs.map(\.absoluteString), ["shortcuts://"])
        XCTAssertEqual(reported, true, "a successful open must report success")

        let refused = FakeOpener(result: false)
        var refusedResult: Bool?
        ShortcutsAppLink.open(using: refused) { refusedResult = $0 }
        XCTAssertEqual(refusedResult, false, "a refused open must fail honestly, not crash")
    }

    /// Records what it was asked to open and answers with a fixed result — so
    /// both the success and the honest-failure paths are exercised without ever
    /// switching apps.
    private final class FakeOpener: URLOpening {
        let result: Bool
        private(set) var openedURLs: [URL] = []
        init(result: Bool) { self.result = result }
        func open(
            _ url: URL,
            options: [UIApplication.OpenExternalURLOptionsKey: Any],
            completionHandler completion: ((Bool) -> Void)?
        ) {
            openedURLs.append(url)
            completion?(result)
        }
    }

    // MARK: - Runtime render + screenshots (real shipping view)

    /// Hosts the REAL `OnboardingEntryPointsView`, asserts the Shortcut tile and
    /// its action are in the accessibility tree (and the stale copy is not), and
    /// writes iPhone + iPad PNGs to `Artifacts/` as runtime evidence.
    @MainActor
    func testRendersShortcutTileAndWritesScreenshots() throws {
        let devices: [(String, CGSize)] = [
            ("iphone-portrait", CGSize(width: 393, height: 852)),   // iPhone 17
            ("ipad-portrait", CGSize(width: 834, height: 1194)),    // iPad Pro 11
        ]
        let outDir = Self.sourceRoot().appendingPathComponent("Artifacts/onboarding-shortcut")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for (name, size) in devices {
            let labels = try renderAndCapture(
                OnboardingEntryPointsView(onDone: {}),
                size: size,
                writePNGTo: outDir.appendingPathComponent("\(name).png")
            )
            let joined = labels.joined(separator: " | ")
            XCTAssertTrue(
                joined.contains("Set up the Tono Shortcut"),
                "[\(name)] the Shortcut tile must be present: \(joined)"
            )
            XCTAssertTrue(
                joined.contains("Open Shortcuts app"),
                "[\(name)] the Open Shortcuts action must be present: \(joined)"
            )
            XCTAssertFalse(
                joined.lowercased().contains("rewrite shortcut — coming soon"),
                "[\(name)] the stale tile must not render: \(joined)"
            )
        }
    }

    /// Render `view` at `size`, write a PNG, and return the accessibility labels
    /// found in the laid-out hierarchy.
    @MainActor
    private func renderAndCapture<V: View>(
        _ view: V, size: CGSize, writePNGTo url: URL
    ) throws -> [String] {
        let controller = UIHostingController(rootView: AnyView(view))
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        // Give SwiftUI a moment to materialise its accessibility tree.
        let deadline = Date().addingTimeInterval(2.0)
        while accessibilityLabels(of: controller.view).isEmpty, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            controller.view.layer.render(in: ctx.cgContext)
        }
        if let data = image.pngData() {
            try? data.write(to: url)
        }
        let labels = accessibilityLabels(of: controller.view)
        window.isHidden = true
        return labels
    }

    /// Every accessibility label in the laid-out hierarchy, flattened.
    @MainActor
    private func accessibilityLabels(of root: UIView) -> [String] {
        var labels: [String] = []
        func walk(_ node: Any) {
            let object = node as AnyObject
            if let label = (object as? NSObject)?.accessibilityLabel, !label.isEmpty {
                labels.append(label)
            }
            if let element = object as? UIAccessibilityElement,
               let value = element.accessibilityValue, !value.isEmpty {
                labels.append(value)
            }
            if let children = (object as? NSObject)?.accessibilityElements {
                children.forEach(walk)
            }
            if let view = object as? UIView {
                view.subviews.forEach(walk)
            }
        }
        walk(root)
        return labels
    }

    // MARK: - Helpers

    private static func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: sourceRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// The string literal assigned to a `private var name: String { "…" }`
    /// computed property, so an assertion can target one tile's copy.
    private static func value(of property: String, in source: String) -> String? {
        guard let range = source.range(of: "var \(property): String {") else { return nil }
        let rest = source[range.upperBound...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        let afterOpen = rest.index(after: open)
        guard let close = rest[afterOpen...].firstIndex(of: "\"") else { return nil }
        return String(rest[afterOpen..<close])
    }

    /// Drop `//` and `/* */` comments so a doc comment about "auto-send" can't
    /// fail an assertion that judges what a person reads.
    private static func stripComments(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var inString = false, inLine = false, inBlock = false
        while i < source.endIndex {
            let c = source[i]
            let next = source.index(after: i)
            let two = next < source.endIndex ? String(source[i...next]) : String(c)
            if inLine {
                if c == "\n" { inLine = false; out.append(c) }
                i = next; continue
            }
            if inBlock {
                if two == "*/" { inBlock = false; i = source.index(i, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex; continue }
                i = next; continue
            }
            if inString {
                out.append(c)
                if c == "\\", next < source.endIndex { out.append(source[next]); i = source.index(after: next); continue }
                if c == "\"" { inString = false }
                i = next; continue
            }
            if two == "//" { inLine = true; i = next; continue }
            if two == "/*" { inBlock = true; i = source.index(i, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex; continue }
            out.append(c)
            if c == "\"" { inString = true }
            i = next
        }
        return out
    }
}
