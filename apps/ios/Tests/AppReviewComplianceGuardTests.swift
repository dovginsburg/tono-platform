import XCTest

/// App Review compliance guards — red-capable, source-scanning.
///
/// These encode the four App Store rejection remediations for Tono 1.1 as
/// repository invariants so a regression cannot silently re-ship them. This
/// suite would have FAILED on Build 117 (which shipped a customer-visible
/// "Promo code" redemption field that called `/v1/coupon/redeem`) and passes
/// only once every custom-code unlock surface is gone from the shipped iOS
/// targets.
///
/// Scope note: comments are stripped before judgement (via `SwiftSource`,
/// defined in `Build112UISurfaceContractTests.swift`) so the explanatory
/// prose that documents WHY the coupon path was removed cannot itself trip the
/// guard. We match on the executable tokens a binary would actually carry.
final class AppReviewComplianceGuardTests: XCTestCase {

    // MARK: Guideline 3.1.1 — no custom promo/coupon unlock in the iOS binary

    /// Every shipped iOS target directory. The keyboard/share/iMessage
    /// extensions are included because 3.1.1 forbids the unlock path from ANY
    /// customer-visible entry point, not just the host app.
    private static let shippedTargetDirs = [
        "App", "Shared", "KeyboardExtension", "ShareExtension", "TonoMessagesExtension",
    ]

    /// Executable tokens that would indicate a custom-code unlock path survives.
    /// These are matched against comment-stripped source, so a token only fails
    /// the guard if it appears in live code or a user-facing string literal.
    private static let forbiddenUnlockTokens = [
        "/v1/coupon/redeem",   // the custom-code grant endpoint invocation
        "redeemCoupon",        // client method that reached it
        "redeemPromoCode",     // settings action that drove it
        "Promo code",          // the customer-visible redemption field label
        "CouponRedemption",    // the response model for the unlock
    ]

    func testNoCustomPromoCodeUnlockSurfaceInShippedTargets() throws {
        var offenders: [String] = []
        for dir in Self.shippedTargetDirs {
            let base = Self.sourceRoot().appendingPathComponent(dir)
            for file in Self.swiftFiles(under: base) {
                // Do not let this guard flag itself.
                if file.lastPathComponent == "AppReviewComplianceGuardTests.swift" { continue }
                let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                let code = SwiftSource.stripComments(raw)
                for token in Self.forbiddenUnlockTokens where code.contains(token) {
                    offenders.append("\(dir)/\(file.lastPathComponent): '\(token)'")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            """
            App Review 3.1.1 violation — a custom promo/coupon unlock surface is present \
            in a shipped iOS target. Free/discounted access must use App Store Offer Codes \
            and reviewer access the demo account; the iOS binary must carry no custom-code \
            unlock path. Offending sites:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    // MARK: - App Intents: aggregate metadata preflight + prohibited-brand guard

    /// The App Intent / Shortcuts / Spotlight surfaces that the successor (Build
    /// 127) must preserve from the Build-122+ lineage — no regression to the
    /// Build-117 feature scope.
    private static let requiredAppIntentSymbols = [
        "CoachDraftIntent",
        "TonoShortcutsProvider",
        "OpenKeyboardSetupIntent",
        "SetToneVariantEnabledIntent",
        "ToneVariantEntity",
        "AppIntentRouting",
    ]

    /// Brands that must never appear in Tono's shipped App Intent metadata — the
    /// consent/Shortcuts strings a user or the system surfaces. Includes the
    /// cross-branded "Potato App" OAuth client identity and the sibling apps.
    private static let prohibitedBrands = [
        "Potato", "parentscript", "tandempaws", "tandemskills",
    ]

    /// Shared detector — used by BOTH the real scan and the red negative control
    /// below, so a passing scan can never be vacuous.
    static func prohibitedBrandHits(in text: String) -> [String] {
        prohibitedBrands.filter { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Aggregate metadata preflight: every required App Intent symbol is present
    /// in the shipped source. Fails if the successor silently drops an intent.
    func testAppIntentAggregateMetadataIsPresent() throws {
        let root = Self.sourceRoot()
        var corpus = ""
        for dir in ["App", "Shared"] {
            for file in Self.swiftFiles(under: root.appendingPathComponent(dir)) {
                corpus += (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            }
        }
        let missing = Self.requiredAppIntentSymbols.filter { !corpus.contains($0) }
        XCTAssertTrue(
            missing.isEmpty,
            "App Intent aggregate metadata regressed — missing required intent surfaces: \(missing.joined(separator: ", "))"
        )
    }

    /// The shipped App Intent surfaces carry no prohibited (cross-brand) name.
    func testAppIntentSurfacesCarryNoProhibitedBrand() throws {
        let root = Self.sourceRoot()
        let intentFiles = [
            "Shared/AppIntentRouting.swift",
            "App/ToneVariantEntity.swift",
            "App/ShortcutsAppLink.swift",
            "App/CoachDraftIntent.swift",
            "App/AppleIntelligenceIntents.swift",
        ]
        var offenders: [String] = []
        for relative in intentFiles {
            let url = root.appendingPathComponent(relative)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let hits = Self.prohibitedBrandHits(in: SwiftSource.stripComments(raw))
            if !hits.isEmpty { offenders.append("\(relative): \(hits.joined(separator: ","))") }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "prohibited brand in App Intent metadata: \(offenders.joined(separator: " | "))"
        )
    }

    /// RED NEGATIVE CONTROL — proves the prohibited-brand guard actually fires.
    /// If this ever passes with the detector broken, the scan above is vacuous.
    func testProhibitedBrandGuardIsNotVacuous() {
        // A synthetic App Intent title carrying the cross-branded identity must
        // be caught…
        XCTAssertEqual(
            Self.prohibitedBrandHits(in: "AppShortcut title: Open Potato App"),
            ["Potato"],
            "the prohibited-brand detector failed to catch a known violation"
        )
        // …and a clean Tono title must not trip it.
        XCTAssertTrue(
            Self.prohibitedBrandHits(in: "Coach this draft with Tono").isEmpty,
            "the prohibited-brand detector produced a false positive on clean metadata"
        )
    }

    // MARK: - Helpers (self-contained; mirrors the Build112 contract's walker)

    /// `#filePath` is `<srcroot>/Tests/…`; SRCROOT is two directories up.
    private static func sourceRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
