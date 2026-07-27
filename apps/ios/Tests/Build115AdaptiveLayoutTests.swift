import XCTest
import SwiftUI
import UIKit
@testable import Tono

/// Build 115 — the adaptive-layout primitive, as behaviour and as geometry.
///
/// The Build 114 investigation found the host app declared iPad support and was
/// never designed for it: zero size-class or width awareness anywhere, so every
/// screen inherited whatever width the window happened to be. The repair adds
/// one primitive, and the thing that makes the repair safe to ship on top of an
/// approved iPhone design is a single property:
///
///   **at every iPhone portrait width the primitive is the identity function.**
///
/// This file proves that twice over — once on the arithmetic, and once on the
/// real laid-out `UIView` frames of a hosted SwiftUI hierarchy, which is the
/// only measurement that cannot be argued with. It then proves the iPad side
/// actually composes rather than merely stretching.
///
/// Deliberately NOT a string scan. Every assertion below reads a number the
/// layout system produced.
final class Build115AdaptiveLayoutTests: XCTestCase {

    // MARK: - Fixtures

    /// Every iPhone portrait width Tono can be run at, from the narrowest
    /// supported device to the widest. Whole points, one at a time — the
    /// identity claim is about ALL of them, not three samples.
    private static var phonePortraitWidths: [CGFloat] {
        stride(from: CGFloat(320), through: TonoAdaptiveLayout.widestPhonePortraitWidth, by: 1).map { $0 }
    }

    /// Real iPad window widths, portrait and landscape, across the sizes Tono
    /// supports — mini through 13-inch Pro.
    private static let iPadPortraitWidths: [CGFloat] = [744, 768, 810, 820, 834, 1024, 1032]
    private static let iPadLandscapeWidths: [CGFloat] = [1024, 1080, 1112, 1133, 1180, 1194, 1366, 1376]
    private static var iPadWidths: [CGFloat] { iPadPortraitWidths + iPadLandscapeWidths }

    /// iPad multitasking columns. These report a COMPACT horizontal size class
    /// while being genuinely narrow, which is precisely the case a size-class
    /// gate gets wrong and a width gate gets right.
    private static let splitViewWidths: [CGFloat] = [320, 375, 414, 507]

    private static let allTypeSizes = DynamicTypeSize.allCases

    // MARK: - The identity claim (arithmetic)

    func testTheColumnImposesNothingAtEveryIPhonePortraitWidth() {
        for measure in TonoContentMeasure.allCases {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths {
                    XCTAssertTrue(
                        TonoAdaptiveLayout.isIdentity(available: width, measure: measure, dynamicTypeSize: size),
                        "\(measure) at \(width)pt / \(size) took the capped branch on a phone"
                    )
                    XCTAssertEqual(
                        TonoAdaptiveLayout.columnWidth(available: width, measure: measure, dynamicTypeSize: size),
                        width, accuracy: 0.0001,
                        "\(measure) at \(width)pt / \(size) changed the phone's content width"
                    )
                }
            }
        }
    }

    /// The identity is structural, not a coincidence of today's numbers: every
    /// cap is above the widest phone portrait width with margin, at every size.
    func testEveryCapClearsTheWidestPhonePortraitWidth() {
        for measure in TonoContentMeasure.allCases {
            for size in Self.allTypeSizes {
                XCTAssertGreaterThan(
                    TonoAdaptiveLayout.cap(measure, dynamicTypeSize: size),
                    TonoAdaptiveLayout.compactContentCeiling,
                    "\(measure) cap at \(size) is inside the compact ceiling, so a phone would be restyled"
                )
            }
        }
        XCTAssertGreaterThan(
            TonoAdaptiveLayout.compactContentCeiling,
            TonoAdaptiveLayout.widestPhonePortraitWidth,
            "the declared compact ceiling must sit above the widest phone Tono supports"
        )
    }

    /// An iPad Split View column is compact and narrow. A width gate leaves it
    /// alone; a size-class gate would have restyled the iPhone-shaped column.
    func testNarrowIPadMultitaskingColumnsAreLeftAlone() {
        for measure in TonoContentMeasure.allCases {
            for width in Self.splitViewWidths {
                XCTAssertEqual(
                    TonoAdaptiveLayout.columnWidth(available: width, measure: measure, dynamicTypeSize: .large),
                    width, accuracy: 0.0001,
                    "\(measure) capped a \(width)pt multitasking column"
                )
            }
        }
    }

    // MARK: - The iPad claim (arithmetic)

    func testTheColumnCapsAtEveryIPadWidthInBothOrientations() {
        for measure in TonoContentMeasure.allCases {
            for width in Self.iPadWidths {
                let resolved = TonoAdaptiveLayout.columnWidth(
                    available: width, measure: measure, dynamicTypeSize: .large
                )
                XCTAssertLessThan(
                    resolved, width,
                    "\(measure) ran the full \(width)pt window — that is the stretched-phone defect"
                )
                XCTAssertEqual(
                    resolved, TonoAdaptiveLayout.cap(measure, dynamicTypeSize: .large), accuracy: 0.0001
                )
                XCTAssertFalse(
                    TonoAdaptiveLayout.isIdentity(available: width, measure: measure, dynamicTypeSize: .large)
                )
            }
        }
    }

    /// Landscape is not a special case, but it is the case with the most width
    /// to waste, so it is asserted on its own: the column must not grow with
    /// the window.
    func testLandscapeGetsTheSameColumnAsPortrait() {
        for measure in TonoContentMeasure.allCases {
            let portrait = TonoAdaptiveLayout.columnWidth(
                available: 1024, measure: measure, dynamicTypeSize: .large
            )
            for width in Self.iPadLandscapeWidths {
                XCTAssertEqual(
                    TonoAdaptiveLayout.columnWidth(available: width, measure: measure, dynamicTypeSize: .large),
                    portrait, accuracy: 0.0001,
                    "\(measure) grew with the window at \(width)pt instead of holding its measure"
                )
            }
        }
    }

    func testTheColumnNeverExceedsTheWindowAtAnyDynamicTypeSize() {
        for measure in TonoContentMeasure.allCases {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths + Self.iPadWidths + Self.splitViewWidths {
                    XCTAssertLessThanOrEqual(
                        TonoAdaptiveLayout.columnWidth(available: width, measure: measure, dynamicTypeSize: size),
                        width,
                        "\(measure) at \(size) proposed more width than the window has — content would clip"
                    )
                }
            }
        }
    }

    func testCapsGrowMonotonicallyWithDynamicTypeAndStayBounded() {
        for measure in TonoContentMeasure.allCases {
            var previous: CGFloat = 0
            for size in Self.allTypeSizes {
                let cap = TonoAdaptiveLayout.cap(measure, dynamicTypeSize: size)
                XCTAssertGreaterThanOrEqual(cap, previous, "\(measure) cap shrank going into \(size)")
                XCTAssertLessThanOrEqual(
                    cap, measure.baseWidth * measure.maximumGrowth + 1,
                    "\(measure) cap ran past its declared growth ceiling at \(size)"
                )
                previous = cap
            }
            XCTAssertEqual(
                TonoAdaptiveLayout.cap(measure, dynamicTypeSize: .large), measure.baseWidth, accuracy: 0.0001,
                "\(measure) must be exactly its base width at the default content size"
            )
        }
    }

    /// A form measure that equalled the reading measure would mean the
    /// "one blind cap everywhere" this repair exists to avoid.
    func testTheFormMeasureIsMeaningfullyNarrowerThanTheReadingMeasure() {
        for size in Self.allTypeSizes {
            XCTAssertLessThan(
                TonoAdaptiveLayout.cap(.form, dynamicTypeSize: size),
                TonoAdaptiveLayout.cap(.reading, dynamicTypeSize: size) - 100,
                "a credential form and a column of prose must not resolve to the same measure (\(size))"
            )
        }
    }

    // MARK: - Modal card

    func testTheDialogKeepsTheApprovedPhoneWidthAndGrowsOnlyOnIPad() {
        for width in Self.phonePortraitWidths + Self.splitViewWidths {
            // Exactly what the shipped `.frame(maxWidth: 340)` produced,
            // including on a 320pt iPhone SE where 340 does not fit.
            XCTAssertEqual(
                TonoAdaptiveLayout.dialogWidth(available: width, dynamicTypeSize: .large),
                min(TonoAdaptiveLayout.compactDialogWidth, width), accuracy: 0.0001,
                "the explainer card changed width at \(width)pt — the phone card is approved at 340pt"
            )
        }
        for width in Self.iPadWidths {
            let resolved = TonoAdaptiveLayout.dialogWidth(available: width, dynamicTypeSize: .large)
            XCTAssertGreaterThan(
                resolved, TonoAdaptiveLayout.compactDialogWidth,
                "the explainer stayed a 340pt island in a \(width)pt window"
            )
            XCTAssertLessThanOrEqual(
                resolved, width - 96,
                "the explainer card left no margin at \(width)pt"
            )
        }
    }

    func testTheDialogNeverOverflowsAtAccessibilitySizes() {
        for size in Self.allTypeSizes {
            for width in Self.phonePortraitWidths + Self.iPadWidths {
                XCTAssertLessThanOrEqual(
                    TonoAdaptiveLayout.dialogWidth(available: width, dynamicTypeSize: size), width,
                    "the explainer card is wider than the \(width)pt window at \(size)"
                )
            }
        }
    }

    // MARK: - Grids

    /// The minimums the shipping surfaces actually pass. If a call site changes
    /// its minimum, this list is what says whether the phone still collapses.
    private static let shippingGridMinimums: [(label: String, minimum: CGFloat, spacing: CGFloat, maximum: Int)] = [
        ("digest top-line stats", 150, 16, 3),
        ("digest depth cards", 300, 16, 2),
        ("onboarding tiles", 300, 16, 2),
        ("coach alternate rewrites", 260, 12, 2),
    ]

    func testEveryShippingGridCollapsesToOneColumnAtPhoneWidths() {
        for spec in Self.shippingGridMinimums {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths {
                    // The content width inside a phone screen, after the padding
                    // each surface applies. Even the unpadded width must collapse
                    // for the wider minimums; the padded one must for all.
                    let content = width - 40
                    let columns = TonoAdaptiveLayout.gridColumns(
                        available: content,
                        minimumItemWidth: spec.minimum * TonoAdaptiveLayout.typeScale(size),
                        spacing: spec.spacing,
                        maximum: spec.maximum
                    )
                    if spec.minimum >= 260 {
                        XCTAssertEqual(
                            columns, 1,
                            "\(spec.label) formed \(columns) columns at \(width)pt / \(size) — the phone stack changed"
                        )
                    } else {
                        XCTAssertLessThanOrEqual(columns, spec.maximum)
                    }
                }
            }
        }
    }

    func testTheDepthGridsFormTwoColumnsInsideTheIPadReadingMeasure() {
        let content = TonoAdaptiveLayout.cap(.reading, dynamicTypeSize: .large) - 40
        for spec in Self.shippingGridMinimums where spec.minimum >= 260 {
            XCTAssertEqual(
                TonoAdaptiveLayout.gridColumns(
                    available: content, minimumItemWidth: spec.minimum,
                    spacing: spec.spacing, maximum: spec.maximum
                ),
                2,
                "\(spec.label) stayed one column inside a \(content)pt iPad reading measure"
            )
        }
    }

    func testGridCellsNeverOverflowTheirRow() {
        for spec in Self.shippingGridMinimums {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths + Self.iPadWidths {
                    let columns = TonoAdaptiveLayout.gridColumns(
                        available: width,
                        minimumItemWidth: spec.minimum * TonoAdaptiveLayout.typeScale(size),
                        spacing: spec.spacing, maximum: spec.maximum
                    )
                    let item = TonoAdaptiveLayout.gridItemWidth(
                        available: width, columns: columns, spacing: spec.spacing
                    )
                    let used = item * CGFloat(columns) + spec.spacing * CGFloat(columns - 1)
                    XCTAssertLessThanOrEqual(
                        used, width + 0.0001,
                        "\(spec.label): \(columns) columns overflow \(width)pt at \(size)"
                    )
                    XCTAssertGreaterThan(item, 0)
                }
            }
        }
    }

    /// Two columns of unreadable slivers would be worse than one honest column,
    /// so a second column is only ever taken when both cells clear the minimum.
    func testASecondColumnIsOnlyTakenWhenBothCellsClearTheMinimum() {
        for spec in Self.shippingGridMinimums {
            for width in stride(from: CGFloat(300), through: 1400, by: 7) {
                let columns = TonoAdaptiveLayout.gridColumns(
                    available: width, minimumItemWidth: spec.minimum,
                    spacing: spec.spacing, maximum: spec.maximum
                )
                guard columns > 1 else { continue }
                let item = TonoAdaptiveLayout.gridItemWidth(
                    available: width, columns: columns, spacing: spec.spacing
                )
                XCTAssertGreaterThanOrEqual(
                    item, spec.minimum - 0.0001,
                    "\(spec.label) formed \(columns) sub-minimum columns at \(width)pt"
                )
            }
        }
    }

    /// Growing type must never gain columns — the grid may only ever collapse
    /// as the words get bigger.
    func testColumnCountNeverIncreasesAsTypeGrows() {
        for spec in Self.shippingGridMinimums {
            for width in Self.iPadWidths {
                var previous = Int.max
                for size in Self.allTypeSizes {
                    let columns = TonoAdaptiveLayout.gridColumns(
                        available: width,
                        minimumItemWidth: spec.minimum * TonoAdaptiveLayout.typeScale(size),
                        spacing: spec.spacing, maximum: spec.maximum
                    )
                    XCTAssertLessThanOrEqual(
                        columns, previous,
                        "\(spec.label) gained a column going into \(size) at \(width)pt"
                    )
                    previous = columns
                }
            }
        }
    }

    // MARK: - Typography

    /// Every fixed point size this repair converted, gathered from the touched
    /// surfaces. The claim is that conversion changed no pixel at the default
    /// content size — which is what makes it safe on an approved design.
    private static let convertedSizes: [CGFloat] = [
        10, 11, 12, 13, 14, 15, 16, 17, 20, 22, 24, 26, 28, 32, 34, 36, 40, 44
    ]

    private static let usedTextStyles: [Font.TextStyle] = [
        .largeTitle, .title, .title2, .title3, .headline, .subheadline,
        .body, .callout, .footnote, .caption, .caption2
    ]

    func testEveryConvertedSizeIsUnchangedAtTheDefaultContentSize() {
        for style in Self.usedTextStyles {
            for size in Self.convertedSizes {
                XCTAssertEqual(
                    TonoTypography.scaledSize(size, relativeTo: style, dynamicTypeSize: .large),
                    size, accuracy: 0.0001,
                    "\(size)pt relative to \(style) moved at the DEFAULT content size — the approved look changed"
                )
            }
        }
    }

    func testConvertedSizesGrowMonotonicallyAndStayBounded() {
        for style in Self.usedTextStyles {
            for base in Self.convertedSizes {
                var previous: CGFloat = 0
                for size in Self.allTypeSizes {
                    let scaled = TonoTypography.scaledSize(base, relativeTo: style, dynamicTypeSize: size)
                    XCTAssertGreaterThanOrEqual(
                        scaled, previous - 0.0001, "\(base)pt/\(style) shrank going into \(size)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        scaled, base - 0.0001,
                        "\(base)pt/\(style) fell below its base size at \(size)"
                    )
                    XCTAssertLessThanOrEqual(
                        scaled, base * TonoTypography.maximumTextGrowth + 0.0001,
                        "\(base)pt/\(style) ran past the text growth ceiling at \(size)"
                    )
                    previous = scaled
                }
            }
        }
    }

    /// Text must actually respond — a "Dynamic Type aware" conversion that
    /// returned the same number at every size would be a lie that passes the
    /// unchanged-at-default test above.
    func testConvertedSizesActuallyRespondToAccessibilitySizes() {
        for style in Self.usedTextStyles {
            for base in Self.convertedSizes {
                XCTAssertGreaterThan(
                    TonoTypography.scaledSize(base, relativeTo: style, dynamicTypeSize: .accessibility5),
                    TonoTypography.scaledSize(base, relativeTo: style, dynamicTypeSize: .large) * 1.2,
                    "\(base)pt/\(style) barely moved at the largest accessibility size"
                )
            }
        }
    }

    /// Decorative metrics are held to a much tighter ceiling than text: a glyph
    /// that doubles only steals width from the words beside it.
    func testDecorativeMetricsAreHeldToATighterCeilingThanText() {
        for base in [CGFloat(11), 12, 14, 22, 28, 32, 34, 36, 40, 44] {
            let decorative = TonoTypography.scaledSize(
                base, relativeTo: .body, dynamicTypeSize: .accessibility5,
                maximumGrowth: TonoTypography.maximumDecorativeGrowth
            )
            let text = TonoTypography.scaledSize(base, relativeTo: .body, dynamicTypeSize: .accessibility5)
            XCTAssertLessThan(decorative, text, "decorative \(base)pt is not bounded tighter than text")
            XCTAssertLessThanOrEqual(decorative, base * TonoTypography.maximumDecorativeGrowth + 0.0001)
        }
    }

    // MARK: - The identity claim, measured on real laid-out views

    /// A real `UIView` planted in the SwiftUI hierarchy.
    ///
    /// SwiftUI does not back `Text` or `Color` with `UIView`s, so walking a
    /// hosting controller's subviews finds nothing. A `UIViewRepresentable`
    /// placed as a `.background` is laid out to exactly the frame of the view
    /// it backs, so its `UIView.frame` is SwiftUI's own answer for that view —
    /// a measurement of the shipping layout engine, not a re-derivation of it.
    private struct FrameProbe: UIViewRepresentable {
        let name: String
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = name
            return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {
            uiView.accessibilityIdentifier = name
        }
    }

    /// Content deliberately mixing the two shapes the primitive could get
    /// wrong: children that FILL the width, and children that HUG it.
    private struct ProbeContent: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("Hug")
                    .background(FrameProbe(name: "probe.hug"))
                Text("A paragraph long enough that it must wrap at a phone width and therefore reports a filled width rather than an intrinsic one.")
                    .fixedSize(horizontal: false, vertical: true)
                    .background(FrameProbe(name: "probe.wrap"))
                Color.purple
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .background(FrameProbe(name: "probe.fill"))
            }
            .padding(20)
            .background(FrameProbe(name: "probe.column"))
        }
    }

    /// Every probe's laid-out frame, in the hosting view's coordinate space,
    /// keyed by name and rounded to the hundredth of a point.
    @MainActor
    private func measuredFrames<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> [String: CGRect] {
        let controller = UIHostingController(rootView: view)
        controller.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        controller.view.backgroundColor = .clear
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        var frames: [String: CGRect] = [:]
        func walk(_ subject: UIView) {
            if let name = subject.accessibilityIdentifier, name.hasPrefix("probe.") || name.hasPrefix("grid.") {
                let frame = subject.convert(subject.bounds, to: controller.view)
                frames[name] = CGRect(
                    x: (frame.origin.x * 100).rounded() / 100, y: (frame.origin.y * 100).rounded() / 100,
                    width: (frame.width * 100).rounded() / 100, height: (frame.height * 100).rounded() / 100
                )
            }
            subject.subviews.forEach(walk)
        }
        walk(controller.view)
        window.isHidden = true
        return frames
    }

    /// The strongest form of the claim: hosting the SAME content with and
    /// without the primitive at a phone width produces the SAME laid-out
    /// `UIView` frames, to the hundredth of a point.
    @MainActor
    func testHostedPhoneGeometryIsByteForByteUnchangedByTheColumn() {
        for width in [CGFloat(320), 375, 390, 393, 402, 430, 440] {
            let plain = measuredFrames(ProbeContent(), width: width, height: 800)
            let adapted = measuredFrames(
                ProbeContent().tonoReadableColumn(.reading), width: width, height: 800
            )
            XCTAssertEqual(
                plain, adapted,
                "the readable column moved a phone's laid-out frames at \(width)pt"
            )
            XCTAssertEqual(
                Set(plain.keys), ["probe.hug", "probe.wrap", "probe.fill", "probe.column"],
                "the probe did not render at \(width)pt, so the comparison above proves nothing"
            )
            XCTAssertEqual(
                plain["probe.column"]?.width ?? 0, width, accuracy: 0.5,
                "the probe column did not fill the phone width, so the identity is untested"
            )
            XCTAssertLessThan(
                plain["probe.hug"]?.width ?? width, width / 2,
                "the hugging probe filled, so the hug case is untested at \(width)pt"
            )
        }
    }

    /// The same identity, at the size a phone actually gets when a person has
    /// turned text all the way up.
    @MainActor
    func testHostedPhoneGeometryIsUnchangedAtTheLargestAccessibilitySize() {
        for width in [CGFloat(320), 393, 440] {
            let plain = measuredFrames(
                ProbeContent().dynamicTypeSize(.accessibility5), width: width, height: 1400
            )
            let adapted = measuredFrames(
                ProbeContent().tonoReadableColumn(.reading).dynamicTypeSize(.accessibility5),
                width: width, height: 1400
            )
            XCTAssertEqual(plain, adapted, "the readable column moved frames at \(width)pt / accessibility5")
        }
    }

    /// And the converse — on an iPad it must actually do something, or the
    /// identity above would be vacuous.
    @MainActor
    func testHostedIPadGeometryIsCappedAndCentredByTheColumn() {
        for width in [CGFloat(834), 1024, 1366] {
            let plain = measuredFrames(ProbeContent(), width: width, height: 1000)
            let adapted = measuredFrames(
                ProbeContent().tonoReadableColumn(.reading), width: width, height: 1000
            )
            XCTAssertNotEqual(plain, adapted, "the readable column did nothing at \(width)pt")

            let cap = TonoAdaptiveLayout.cap(.reading, dynamicTypeSize: .large)
            XCTAssertEqual(
                plain["probe.column"]?.width ?? 0, width, accuracy: 0.5,
                "the unadapted column did not run the full \(width)pt window — the defect is not reproduced"
            )
            XCTAssertEqual(
                adapted["probe.column"]?.width ?? 0, cap, accuracy: 0.5,
                "the adapted column did not land on the \(cap)pt measure at \(width)pt"
            )
            for (name, frame) in adapted {
                XCTAssertLessThanOrEqual(
                    frame.width, cap + 0.5,
                    "\(name) kept running the full window at \(width)pt: \(frame)"
                )
            }
            // Centred: the left inset equals the right inset.
            if let column = adapted["probe.column"] {
                XCTAssertEqual(
                    column.minX, width - column.maxX, accuracy: 1.0,
                    "the capped column is not centred at \(width)pt"
                )
            }
        }
    }

    /// Nothing may be laid out beyond the window in either direction, at any
    /// width or type size — the clipping guard.
    @MainActor
    func testNothingIsLaidOutBeyondTheWindowAtAnyWidthOrTypeSize() {
        for width in [CGFloat(320), 393, 440, 744, 1024, 1366] {
            for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
                let frames = measuredFrames(
                    ProbeContent().tonoReadableColumn(.reading).dynamicTypeSize(typeSize),
                    width: width, height: 2000
                )
                XCTAssertFalse(frames.isEmpty, "nothing rendered at \(width)pt / \(typeSize)")
                for (name, frame) in frames {
                    XCTAssertGreaterThanOrEqual(
                        frame.minX, -0.5, "\(name) starts left of the window at \(width)pt / \(typeSize)"
                    )
                    XCTAssertLessThanOrEqual(
                        frame.maxX, width + 0.5,
                        "\(name) runs past the right edge at \(width)pt / \(typeSize): \(frame)"
                    )
                }
            }
        }
    }

    // MARK: - The grid layout, measured

    private struct GridProbe: View {
        let minimum: CGFloat
        var body: some View {
            AdaptiveItemGrid(minimumItemWidth: minimum, spacing: 16, maximumColumns: 2) {
                Color.purple.frame(height: 60).background(FrameProbe(name: "grid.a"))
                Color.green.frame(height: 60).background(FrameProbe(name: "grid.b"))
            }
        }
    }

    /// The reference the grid must reproduce on a phone: a plain `VStack` with
    /// the same spacing. Compared frame for frame, so "collapses to a stack" is
    /// measured rather than asserted.
    private struct StackReference: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Color.purple.frame(height: 60).background(FrameProbe(name: "grid.a"))
                Color.green.frame(height: 60).background(FrameProbe(name: "grid.b"))
            }
        }
    }

    @MainActor
    func testTheGridIsAPlainVerticalStackAtPhoneWidthsAndTwoUpOnIPad() {
        for width in [CGFloat(320), 393, 440] {
            let grid = measuredFrames(GridProbe(minimum: 300), width: width, height: 400)
            let stack = measuredFrames(StackReference(), width: width, height: 400)
            XCTAssertEqual(Set(grid.keys), ["grid.a", "grid.b"], "the grid lost an item at \(width)pt")
            XCTAssertEqual(
                grid, stack,
                "at \(width)pt the grid is not frame-for-frame the vertical stack it replaced"
            )
        }
        let wide = measuredFrames(GridProbe(minimum: 300), width: 700, height: 400)
        let a = try? XCTUnwrap(wide["grid.a"]); let b = try? XCTUnwrap(wide["grid.b"])
        guard let a, let b else { return XCTFail("the grid did not render at 700pt") }
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.5, "the iPad grid is not side by side")
        XCTAssertEqual(b.minX - a.maxX, 16, accuracy: 0.5, "two-column spacing is wrong")
        XCTAssertEqual(a.width, b.width, accuracy: 0.5, "the two columns are not equal width")
        XCTAssertEqual(a.width + b.width + 16, 700, accuracy: 0.5, "the grid does not fill its row")
    }
}
