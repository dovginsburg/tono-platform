import XCTest
import SwiftUI
import UIKit
@testable import Tono

/// Build 115 — the eight product areas, measured as laid-out pixels.
///
/// `Build115AdaptiveLayoutTests` proves the PRIMITIVE. This file proves the
/// SURFACES: that each shipped screen actually adopted it, that a phone still
/// gets the screen that was approved, that an iPad gets a centred measure
/// rather than a stretched phone, and that neither one clips, reorders or
/// shrinks a control when a person turns text up.
///
/// Everything here renders the REAL shipping view through the REAL SwiftUI
/// layout engine and then reads numbers back out of the result — the ink
/// extent of the rendered raster, the accessibility tree of the laid-out
/// hierarchy. There is no string scan and no source regex in this file, so it
/// cannot pass by looking at the code that was supposed to do the work.
final class Build115IPadSurfaceLayoutTests: XCTestCase {

    // MARK: - The surfaces under contract

    /// Every product area the Build 115 iPad brief names, plus the sheets they
    /// present. `expectedMeasure` is the composition each one was given, and
    /// `phonePadding` is the horizontal padding it had BEFORE this work — so a
    /// phone assertion below is an assertion that the approved screen is intact.
    private struct Surface {
        let name: String
        let measure: TonoContentMeasure
        let phonePadding: CGFloat
        let make: () -> AnyView
    }

    @MainActor
    private static func surfaces() -> [Surface] {
        let holder = PreferencesHolder()
        let binding = Binding<TonePreferences>(get: { holder.value }, set: { holder.value = $0 })
        return [
            Surface(name: "coach", measure: .reading, phonePadding: 20) {
                AnyView(CoachView())
            },
            Surface(name: "digest", measure: .reading, phonePadding: 20) {
                AnyView(DigestView())
            },
            Surface(name: "memory", measure: .reading, phonePadding: 32) {
                AnyView(NavigationStack { MemoryView() })
            },
            Surface(name: "recipients", measure: .reading, phonePadding: 32) {
                AnyView(NavigationStack { RecipientsManagerView() })
            },
            Surface(name: "setupdoctor", measure: .reading, phonePadding: 20) {
                AnyView(NavigationStack { SetupDoctorView() })
            },
            Surface(name: "onboarding-entrypoints", measure: .reading, phonePadding: 24) {
                AnyView(OnboardingEntryPointsView(onDone: {}))
            },
            Surface(name: "onboarding-calibration", measure: .reading, phonePadding: 24) {
                AnyView(OnboardingCalibrationView(onDone: {}))
            },
            Surface(name: "settings", measure: .reading, phonePadding: 32) {
                AnyView(SettingsView(prefs: binding))
            },
            Surface(name: "paywall", measure: .form, phonePadding: 24) {
                AnyView(PaywallView(onDismiss: {}))
            },
            Surface(name: "account-deletion", measure: .form, phonePadding: 24) {
                AnyView(AccountDeletionView(onSuccess: {}, onCancel: {}))
            },
            Surface(name: "email-sign-in", measure: .form, phonePadding: 24) {
                AnyView(EmailSignInSheet(onSuccess: {}, onCancel: {}))
            },
        ]
    }

    private final class PreferencesHolder {
        var value = TonePreferences()
    }

    /// Real window sizes, points. Portrait and landscape for each family.
    private static let phonePortrait = CGSize(width: 393, height: 852)
    private static let phoneLandscape = CGSize(width: 852, height: 393)
    private static let iPadPortrait = CGSize(width: 1032, height: 1376)
    private static let iPadLandscape = CGSize(width: 1376, height: 1032)
    /// The 11-inch family, so the claim is not about one device.
    private static let iPadAirPortrait = CGSize(width: 820, height: 1180)
    private static let iPadAirLandscape = CGSize(width: 1180, height: 820)

    // MARK: - Measuring machinery

    /// The horizontal extent of a surface's CONTENT, in points, read off a
    /// raster of the laid-out hierarchy.
    ///
    /// Pixels rather than a view tree, because SwiftUI backs neither `Text` nor
    /// a card with a `UIView` — the rendered image is the only place the answer
    /// exists. Verified faithful against the independent full-app screenshots
    /// under /tmp/tono-build115-ipad-evidence: both put the adapted content
    /// column at 186…846 in a 1,032pt window.
    private struct Extent {
        let left: CGFloat
        let right: CGFloat
        var width: CGFloat { right - left }
        var isEmpty: Bool { right <= left }
    }

    /// The band at the top of a surface that belongs to NAVIGATION, not to
    /// content: the bar, the large title, a search field.
    ///
    /// Excluded on purpose. On iPadOS those are full-width by design — that is
    /// the platform's navigation architecture, which the Build 115 brief
    /// preserves — so including them would make every surface measure
    /// "full-bleed" and the measurement would prove nothing. `RootView`'s tab
    /// bar is likewise chrome and is not hosted here.
    private static let navigationBandHeight: CGFloat = 180

    @MainActor
    private func measureContent<V: View>(
        _ view: V, size: CGSize, typeSize: DynamicTypeSize = .large,
        style: UIUserInterfaceStyle = .dark
    ) -> (extent: Extent, controller: UIHostingController<AnyView>) {
        let controller = UIHostingController(rootView: AnyView(view.dynamicTypeSize(typeSize)))
        controller.overrideUserInterfaceStyle = style
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        window.isHidden = true
        return (Self.extent(in: image, size: size), controller)
    }

    private static func extent(in image: UIImage, size: CGSize) -> Extent {
        guard let cg = image.cgImage else { return Extent(left: 0, right: 0) }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Extent(left: 0, right: 0) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        func sample(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        // Background is read from the raster rather than assumed, so the same
        // measurement works on the black Coach field and the grouped Settings
        // background.
        let background = sample(2, height - 3)
        func differs(_ p: (Int, Int, Int)) -> Bool {
            abs(p.0 - background.0) + abs(p.1 - background.1) + abs(p.2 - background.2) > 24
        }
        let first = min(height - 1, Int(navigationBandHeight * CGFloat(height) / size.height))
        var left = -1, right = -1
        for x in 0..<width {
            var hit = false
            var y = first
            while y < height { if differs(sample(x, y)) { hit = true; break }; y += 2 }
            if hit { if left < 0 { left = x }; right = x }
        }
        guard left >= 0 else { return Extent(left: 0, right: 0) }
        let scale = size.width / CGFloat(width)
        return Extent(left: CGFloat(left) * scale, right: CGFloat(right + 1) * scale)
    }

    /// Every accessibility element in the laid-out hierarchy, in traversal
    /// order. `accessibilityElementCount()` is used rather than the
    /// `accessibilityElements` property because SwiftUI materialises its tree
    /// lazily and the property is nil until something asks.
    @MainActor
    private func accessibilityElements(
        of view: UIView
    ) -> [(label: String, traits: UIAccessibilityTraits, frame: CGRect)] {
        var found: [(String, UIAccessibilityTraits, CGRect)] = []
        var seen = 0
        func record(_ node: NSObject) {
            let label = node.accessibilityLabel ?? ""
            let value = node.accessibilityValue ?? ""
            found.append((label.isEmpty ? value : label, node.accessibilityTraits, node.accessibilityFrame))
        }
        func isChrome(_ object: NSObject) -> Bool {
            guard object is UIView else { return false }
            if object is UINavigationBar || object is UIToolbar || object is UISearchBar { return true }
            let name = String(describing: type(of: object))
            return name.contains("NavigationBar") || name.contains("SearchBar") || name.contains("Toolbar")
        }
        func walk(_ node: Any) {
            seen += 1
            guard seen < 4000 else { return }
            guard let object = node as? NSObject else { return }
            // Navigation chrome is excluded for the same reason the raster band
            // excludes it: a bar and a large title are the platform's, not this
            // surface's, and iPadOS renders them full width by design.
            if isChrome(object) { return }
            if object.isAccessibilityElement { record(object); return }
            let count = object.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) { walk(child) }
                }
                return
            }
            if let children = object.accessibilityElements {
                children.forEach(walk)
                return
            }
            (object as? UIView)?.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    // MARK: - Phone: the approved screen is intact

    /// Surfaces whose default state genuinely fills the width. This Week is
    /// excluded on purpose and with a reason: with no report loaded it renders
    /// a CENTRED failure card, so "fills the width" is false there regardless
    /// of this repair. Making it load would mean a second process-global
    /// URLProtocol in the shipped suite, which is precisely the Build 109
    /// attribution debt this repository already carries — so This Week's phone
    /// evidence is the pixel-identical runtime screenshot against the
    /// pre-change build instead.
    private static let fillsOnPhone: Set<String> = [
        "coach", "memory", "recipients", "setupdoctor", "onboarding-entrypoints",
        "settings", "paywall", "account-deletion", "email-sign-in",
    ]

    /// At phone widths nothing may be pulled in. If any measure were ever
    /// lowered under the widest phone, content would centre inside a cap and
    /// this goes red — which is the failure mode the whole primitive is built
    /// to make impossible.
    @MainActor
    func testNoSurfaceIsPulledInAtPhoneWidths() {
        for size in [CGSize(width: 320, height: 800), Self.phonePortrait] {
            for surface in Self.surfaces() where Self.fillsOnPhone.contains(surface.name) {
                let (extent, _) = measureContent(surface.make(), size: size)
                XCTAssertFalse(extent.isEmpty, "\(surface.name) rendered nothing at \(size.width)pt")
                XCTAssertGreaterThanOrEqual(
                    extent.width, size.width - 2 * surface.phonePadding - 1,
                    "\(surface.name) narrowed on a phone: \(extent.width)pt of \(size.width)pt"
                )
                XCTAssertLessThanOrEqual(
                    extent.left, surface.phonePadding + 1,
                    "\(surface.name) is inset from the left edge on a phone"
                )
            }
        }
    }

    /// The same claim with text turned all the way up, where a cap that scaled
    /// the wrong way would start pulling content in.
    @MainActor
    func testNoSurfaceIsPulledInOnAPhoneAtTheLargestAccessibilitySize() {
        for surface in Self.surfaces() where Self.fillsOnPhone.contains(surface.name) {
            let (extent, _) = measureContent(
                surface.make(), size: Self.phonePortrait, typeSize: .accessibility5
            )
            XCTAssertFalse(extent.isEmpty, "\(surface.name) rendered nothing at accessibility5")
            // At accessibility5 a wrapped paragraph legitimately stops short of
            // the right edge, so WIDTH is confounded here. A wrongly applied cap
            // CENTRES the column, which moves the LEFT edge — that is the
            // unconfounded signal, and it is what is asserted.
            XCTAssertLessThanOrEqual(
                extent.left, surface.phonePadding + 1,
                "\(surface.name) is inset from the left on a phone at accessibility5: \(extent.left)pt"
            )
            XCTAssertGreaterThan(
                extent.width, Self.phonePortrait.width * 0.6,
                "\(surface.name) collapsed to \(extent.width)pt on a phone at accessibility5"
            )
        }
    }

    // MARK: - iPad: composed, not stretched

    /// The defect this whole repair exists to remove: content running the full
    /// width of the tablet. Every surface must now stop at its measure, in both
    /// orientations, on both iPad families.
    @MainActor
    func testNoSurfaceRunsTheFullWidthOfAnIPadInEitherOrientation() {
        for size in [Self.iPadPortrait, Self.iPadLandscape, Self.iPadAirPortrait, Self.iPadAirLandscape] {
            for surface in Self.surfaces() {
                let (extent, _) = measureContent(surface.make(), size: size)
                XCTAssertFalse(extent.isEmpty, "\(surface.name) rendered nothing at \(size)")
                let cap = TonoAdaptiveLayout.cap(surface.measure, dynamicTypeSize: .large)
                XCTAssertLessThanOrEqual(
                    extent.width, cap + 2,
                    "\(surface.name) ran \(extent.width)pt of a \(size.width)pt window — that is the stretched phone"
                )
                XCTAssertLessThan(
                    extent.width, size.width - 100,
                    "\(surface.name) is still effectively full-bleed at \(size.width)pt"
                )
            }
        }
    }

    /// Capped is not enough — it has to be centred, or the tablet just gets a
    /// phone pinned to the left edge.
    @MainActor
    func testEverySurfaceIsCentredOnIPad() {
        for size in [Self.iPadPortrait, Self.iPadLandscape] {
            for surface in Self.surfaces() {
                let (extent, _) = measureContent(surface.make(), size: size)
                XCTAssertEqual(
                    extent.left, size.width - extent.right, accuracy: 4,
                    "\(surface.name) is not centred at \(size.width)pt: \(extent.left) left vs \(size.width - extent.right) right"
                )
            }
        }
    }

    /// Landscape must not simply take more width than portrait — the measure is
    /// a measure, not a fraction of the window.
    @MainActor
    func testLandscapeDoesNotWidenTheMeasure() {
        for surface in Self.surfaces() {
            let (portrait, _) = measureContent(surface.make(), size: Self.iPadPortrait)
            let (landscape, _) = measureContent(surface.make(), size: Self.iPadLandscape)
            XCTAssertEqual(
                landscape.width, portrait.width, accuracy: 6,
                "\(surface.name) grew from \(portrait.width)pt to \(landscape.width)pt in landscape"
            )
        }
    }

    // MARK: - Clipping

    /// Nothing may be laid out past either edge of the window, on any surface,
    /// at any size, at any Dynamic Type setting.
    @MainActor
    func testNothingIsLaidOutBeyondTheWindowOnAnySurface() {
        let sizes = [Self.phonePortrait, Self.phoneLandscape, Self.iPadPortrait, Self.iPadLandscape]
        for size in sizes {
            for typeSize in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                for surface in Self.surfaces() {
                    let (extent, controller) = measureContent(surface.make(), size: size, typeSize: typeSize)
                    XCTAssertGreaterThanOrEqual(
                        extent.left, -0.5,
                        "\(surface.name) draws left of the window at \(size.width)pt / \(typeSize)"
                    )
                    XCTAssertLessThanOrEqual(
                        extent.right, size.width + 0.5,
                        "\(surface.name) draws past the right edge at \(size.width)pt / \(typeSize)"
                    )
                    for element in accessibilityElements(of: controller.view) where !element.frame.isEmpty {
                        XCTAssertLessThanOrEqual(
                            element.frame.maxX, size.width + 1,
                            "\(surface.name): “\(element.label)” runs off the right at \(size.width)pt / \(typeSize)"
                        )
                        XCTAssertGreaterThanOrEqual(
                            element.frame.minX, -1,
                            "\(surface.name): “\(element.label)” runs off the left at \(size.width)pt / \(typeSize)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Touch targets

    /// Interactive elements that were ALREADY under the 44pt guideline before
    /// this work, measured identically at 393pt, 1032pt and 1376pt.
    ///
    /// Pinned rather than hidden. Every one is a plain `Button("…")` with no
    /// padding, or a `Form` toggle row, and every one is exactly as tall on a
    /// phone as on an iPad — so none of them is caused by this layout pass, and
    /// fixing them means changing spacing on screens that are already approved.
    /// They are reported as pre-existing debt in the Build 115 handoff. The
    /// list may not GROW: a new sub-44pt control fails the test below.
    private static let knownSubMinimumTargets: Set<String> = [
        "Skip for now", "Restore purchases", "Check again", "Sign in",
        "Why Coach needs Full Access", "Open Setup Doctor", "Verify Setup Manually",
        "Continue to Tono", "Send a new confirmation link", "Forgot your password?",
        "Create an account instead", "I already have an account", "Send a new link",
        "Thread context", "Risk change indicator", "Learn from my sessions",
        "Use memory in rewrites", "Weekly tone report", "Allow on-device Safer rewrites",
        "Help improve Tono", "Clear all", "Add something manually",
        "Open Settings", "Try again", "Sign in with email", "Show me how",
        "Open iOS Settings", "Got it",
    ]

    /// The regression this layout pass could actually cause: a control that
    /// shrinks because the column around it got narrower. Every interactive
    /// element must be at least as tall on an iPad as it is on a phone.
    @MainActor
    func testNoInteractiveElementShrinksBecauseOfTheIPadComposition() {
        for surface in Self.surfaces() {
            let (_, phone) = measureContent(surface.make(), size: Self.phonePortrait)
            let phoneHeights = Dictionary(
                accessibilityElements(of: phone.view)
                    .filter { $0.traits.contains(.button) && !$0.frame.isEmpty }
                    .map { ($0.label, $0.frame.height) },
                uniquingKeysWith: max
            )
            for size in [Self.iPadPortrait, Self.iPadLandscape] {
                let (_, pad) = measureContent(surface.make(), size: size)
                for element in accessibilityElements(of: pad.view)
                where element.traits.contains(.button) && !element.frame.isEmpty {
                    guard let onPhone = phoneHeights[element.label], onPhone >= 44 else { continue }
                    // A wider column wraps text to fewer lines, so a row that
                    // was 79pt on a phone legitimately becomes 66pt here. What
                    // may NOT happen is a control that cleared the guideline on
                    // a phone falling under it because of the composition.
                    XCTAssertGreaterThanOrEqual(
                        element.frame.height, 44,
                        "\(surface.name): “\(element.label)” went from \(onPhone)pt on a phone to \(element.frame.height)pt at \(size.width)pt, under the guideline"
                    )
                }
            }
        }
    }

    /// Every interactive element meets the 44pt guideline, except the pinned
    /// pre-existing set above — and that set may not grow.
    @MainActor
    func testNoNewControlFallsBelowTheTouchTargetGuideline() {
        var offenders: Set<String> = []
        var judged = 0
        for size in [Self.phonePortrait, Self.iPadPortrait, Self.iPadLandscape] {
            for surface in Self.surfaces() {
                let (_, controller) = measureContent(surface.make(), size: size)
                for element in accessibilityElements(of: controller.view)
                where element.traits.contains(.button) && !element.frame.isEmpty && element.frame.width > 1 {
                    judged += 1
                    if element.frame.height < 44 { offenders.insert(element.label) }
                }
            }
        }
        // Non-vacuity: if the traversal found no controls at all, everything
        // above would pass while proving nothing.
        XCTAssertGreaterThan(judged, 60, "the accessibility traversal found almost no controls to judge")
        XCTAssertEqual(
            offenders.subtracting(Self.knownSubMinimumTargets), [],
            "new controls fall below the 44pt touch target"
        )
    }

    // MARK: - Role and order invariants

    /// The surfaces whose composition CHANGES between one and two columns.
    /// They are the only ones where this work could reorder anything, and none
    /// of them is a lazy container, so their runs are directly comparable.
    ///
    /// This is the test that caught the real defect in the first draft of the
    /// grid: two tiles side by side sit on the same visual rows, and UIKit
    /// orders accessibility by geometry, so VoiceOver read "tile 1 title, tile
    /// 2 title, tile 1 detail, tile 2 detail" straight across. The fix was to
    /// contain each cell; this assertion is what holds it.
    private static let gridSurfaces: Set<String> = ["coach", "onboarding-entrypoints"]

    @MainActor
    func testTheGridSurfacesReadInTheSameOrderOnPhoneAndIPad() {
        for surface in Self.surfaces() where Self.gridSurfaces.contains(surface.name) {
            let (_, phone) = measureContent(surface.make(), size: Self.phonePortrait)
            let (_, pad) = measureContent(surface.make(), size: Self.iPadPortrait)
            let phoneLabels = accessibilityElements(of: phone.view).map(\.label).filter { !$0.isEmpty }
            let padLabels = accessibilityElements(of: pad.view).map(\.label).filter { !$0.isEmpty }
            XCTAssertGreaterThan(phoneLabels.count, 5, "\(surface.name): too few elements to compare")
            XCTAssertEqual(
                phoneLabels, padLabels,
                "\(surface.name): the two-column layout changed what VoiceOver reads, or the order it reads it in"
            )
        }
    }

    @MainActor
    func testTheGridSurfacesReadTheSameAfterRotation() {
        for surface in Self.surfaces() where Self.gridSurfaces.contains(surface.name) {
            let (_, portrait) = measureContent(surface.make(), size: Self.iPadPortrait)
            let (_, landscape) = measureContent(surface.make(), size: Self.iPadLandscape)
            let portraitLabels = accessibilityElements(of: portrait.view).map(\.label).filter { !$0.isEmpty }
            let landscapeLabels = accessibilityElements(of: landscape.view).map(\.label).filter { !$0.isEmpty }
            XCTAssertGreaterThan(portraitLabels.count, 5, "\(surface.name): too few elements to compare")
            XCTAssertEqual(
                portraitLabels, landscapeLabels,
                "\(surface.name): rotating the iPad changed the accessibility run"
            )
        }
    }

    /// Nothing may DISAPPEAR from a surface because the window got wider. Set
    /// comparison rather than sequence, so a lazy `Form` realising more rows in
    /// a taller window does not make this fail for the wrong reason.
    @MainActor
    func testNoSurfaceLosesContentOnAnIPad() {
        for surface in Self.surfaces() {
            let (_, phone) = measureContent(surface.make(), size: Self.phonePortrait)
            let (_, pad) = measureContent(surface.make(), size: Self.iPadPortrait)
            let phoneLabels = Set(accessibilityElements(of: phone.view).map(\.label).filter { !$0.isEmpty })
            let padLabels = Set(accessibilityElements(of: pad.view).map(\.label).filter { !$0.isEmpty })
            XCTAssertFalse(phoneLabels.isEmpty, "\(surface.name) exposed nothing on a phone")
            XCTAssertEqual(
                phoneLabels.subtracting(padLabels), [],
                "\(surface.name): content a phone shows is missing on an iPad"
            )
        }
    }

    // MARK: - The measures are actually distinct

    /// Proof that this is composition and not one blanket cap: the surfaces
    /// given the form measure must actually be narrower on an iPad than the
    /// ones given the reading measure.
    @MainActor
    func testFormSurfacesAreNarrowerThanReadingSurfacesOnIPad() {
        var readingWidths: [CGFloat] = []
        var formWidths: [CGFloat] = []
        for surface in Self.surfaces() {
            let (extent, _) = measureContent(surface.make(), size: Self.iPadPortrait)
            if surface.measure == .form { formWidths.append(extent.width) } else { readingWidths.append(extent.width) }
        }
        let widestForm = formWidths.max() ?? 0
        let widestReading = readingWidths.max() ?? 0
        XCTAssertGreaterThan(
            widestReading, widestForm + 80,
            "form surfaces (\(widestForm)pt) and reading surfaces (\(widestReading)pt) resolved to one blanket cap"
        )
    }
}
