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

    /// iPhone LANDSCAPE widths, for the phones whose landscape width clears the
    /// 700pt reading measure — every current model does. These take the CAPPED
    /// branch, on purpose, and everything about that is asserted below rather
    /// than left to a comment.
    private static let phoneLandscapeWidths: [CGFloat] = [844, 852, 874, 896, 926, 932, 956]

    /// The small-SE landscape widths, which do NOT clear the reading measure.
    /// Kept separate because "landscape caps" is a claim about the widths where
    /// it is true, and stating it for all of them would be false.
    private static let smallPhoneLandscapeWidths: [CGFloat] = [568, 667]

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

    // MARK: - iPhone landscape: capped on purpose

    /// An iPhone in landscape is 844–956pt wide, which is WIDER than the 700pt
    /// reading measure, so it takes the capped branch: content stops at the
    /// measure and centres, and the peer-item grids below form two columns.
    ///
    /// That is a deliberate decision, not an accident of the arithmetic — it is
    /// the same readable-measure treatment iOS gives long-form content on a
    /// wide window, and it is what the runtime evidence shows. It is asserted
    /// here so that "the phone is unchanged" is never read as a claim about
    /// landscape: the phone claim is about PORTRAIT, and this is what landscape
    /// does instead.
    func testPhoneLandscapeTakesTheCappedBranchOnPurpose() {
        for measure in TonoContentMeasure.allCases {
            for width in Self.phoneLandscapeWidths {
                XCTAssertFalse(
                    TonoAdaptiveLayout.isIdentity(available: width, measure: measure, dynamicTypeSize: .large),
                    "\(measure) took the identity branch at \(width)pt of phone landscape — landscape is capped by design"
                )
                XCTAssertEqual(
                    TonoAdaptiveLayout.columnWidth(available: width, measure: measure, dynamicTypeSize: .large),
                    TonoAdaptiveLayout.cap(measure, dynamicTypeSize: .large), accuracy: 0.0001,
                    "\(measure) did not land on its measure at \(width)pt of phone landscape"
                )
            }
        }
        // The small-SE landscape widths are UNDER the reading measure, so they
        // legitimately stay on the identity branch — and the narrower form
        // measure still applies to them.
        for width in Self.smallPhoneLandscapeWidths {
            XCTAssertTrue(
                TonoAdaptiveLayout.isIdentity(available: width, measure: .reading, dynamicTypeSize: .large),
                "a \(width)pt landscape phone is inside the reading measure and must be left alone"
            )
            XCTAssertFalse(
                TonoAdaptiveLayout.isIdentity(available: width, measure: .form, dynamicTypeSize: .large),
                "a \(width)pt landscape phone is wider than the form measure and must be capped"
            )
        }
    }

    /// The consequence of "caps only ever grow": turning text all the way up on
    /// a landscape phone can put the window back INSIDE the measure, and the
    /// cap stops applying. Stated because it is surprising, and because it is
    /// the right behaviour — bigger text is exactly what wants a wider column.
    func testPhoneLandscapeCappingRelaxesAsTypeGrows() {
        let narrowest = Self.phoneLandscapeWidths[0]
        XCTAssertFalse(
            TonoAdaptiveLayout.isIdentity(available: narrowest, measure: .reading, dynamicTypeSize: .large),
            "an \(narrowest)pt landscape phone must be capped at the default content size"
        )
        XCTAssertTrue(
            TonoAdaptiveLayout.isIdentity(available: narrowest, measure: .reading, dynamicTypeSize: .accessibility5),
            "the grown reading measure must exceed \(narrowest)pt, so the cap stops applying at the largest size"
        )
        XCTAssertFalse(
            TonoAdaptiveLayout.isIdentity(
                available: Self.phoneLandscapeWidths.last ?? 956, measure: .reading,
                dynamicTypeSize: .accessibility5
            ),
            "the widest landscape phone must still be capped even at the largest size"
        )
    }

    func testTheColumnNeverExceedsTheWindowAtAnyDynamicTypeSize() {
        for measure in TonoContentMeasure.allCases {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths + Self.phoneLandscapeWidths
                    + Self.smallPhoneLandscapeWidths + Self.iPadWidths + Self.splitViewWidths {
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

    /// The specs the shipping surfaces lay their grids out with.
    ///
    /// Read from `TonoGridSpec.shipping`, which is what the call sites
    /// themselves pass, so this cannot describe a different app than the one
    /// that ships. It previously WAS a hand-copied table here, and it had
    /// already drifted — wrong spacing for all three real grids, plus a fourth
    /// entry for a grid that does not exist. The conclusions it reached still
    /// happened to hold; the guard did not.
    private static var shippingGrids: [TonoGridSpec] { TonoGridSpec.shipping }

    /// Non-vacuity for everything below: if the shipping list were empty, every
    /// `for spec in` loop would pass while proving nothing.
    func testTheShippingGridListIsNotEmptyAndCarriesNoPhantomGrid() {
        XCTAssertEqual(
            Self.shippingGrids.count, 3,
            "the shipping grid list changed size — add or remove the call site's spec deliberately, not by accident"
        )
        XCTAssertEqual(
            Set(Self.shippingGrids.map(\.label)).count, Self.shippingGrids.count,
            "two shipping grids share a label, so a failure message cannot say which one broke"
        )
    }

    /// Absolute, and no longer conditional on the minimum: EVERY shipping grid
    /// must be one column at every iPhone portrait width, padded or not. The
    /// previous version of this test excused any spec under 260pt into a
    /// tautology, so lowering a minimum could not fail it.
    func testEveryShippingGridCollapsesToOneColumnAtEveryPhonePortraitWidth() {
        for spec in Self.shippingGrids {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths {
                    // Both the raw window and the content width left after the
                    // padding each surface applies — the raw one is the
                    // stricter test, and both must collapse.
                    for available in [width, width - 40] {
                        let columns = TonoAdaptiveLayout.gridColumns(
                            available: available,
                            minimumItemWidth: spec.minimumItemWidth * TonoAdaptiveLayout.typeScale(size),
                            spacing: spec.spacing,
                            maximum: spec.maximumColumns
                        )
                        XCTAssertEqual(
                            columns, 1,
                            "\(spec.label) formed \(columns) columns in \(available)pt at \(width)pt / \(size) — the phone stack changed"
                        )
                    }
                }
            }
        }
    }

    func testEveryShippingGridFormsTwoColumnsInsideTheIPadReadingMeasure() {
        let content = TonoAdaptiveLayout.cap(.reading, dynamicTypeSize: .large) - 40
        for spec in Self.shippingGrids {
            let columns = TonoAdaptiveLayout.gridColumns(
                available: content, minimumItemWidth: spec.minimumItemWidth,
                spacing: spec.spacing, maximum: spec.maximumColumns
            )
            XCTAssertEqual(
                columns, 2,
                "\(spec.label) stayed one column inside a \(content)pt iPad reading measure"
            )
            XCTAssertGreaterThanOrEqual(
                TonoAdaptiveLayout.gridItemWidth(available: content, columns: columns, spacing: spec.spacing),
                spec.minimumItemWidth - 0.0001,
                "\(spec.label)'s two cells are under its own minimum inside the iPad reading measure"
            )
        }
    }

    /// The landscape-phone half of the same claim, started from a real phone
    /// landscape WINDOW rather than from the measure, so it is a statement
    /// about a device rather than about a number. Two-up on a landscape phone
    /// is the intended behaviour — see `AdaptiveLayout.swift`'s header.
    func testEveryShippingGridFormsTwoColumnsInsideAPhoneLandscapeReadingMeasure() {
        for window in Self.phoneLandscapeWidths {
            let column = TonoAdaptiveLayout.columnWidth(
                available: window, measure: .reading, dynamicTypeSize: .large
            )
            let content = column - 40
            for spec in Self.shippingGrids {
                let columns = TonoAdaptiveLayout.gridColumns(
                    available: content, minimumItemWidth: spec.minimumItemWidth,
                    spacing: spec.spacing, maximum: spec.maximumColumns
                )
                XCTAssertEqual(
                    columns, 2,
                    "\(spec.label) did not group two-up on a \(window)pt landscape phone, which is the intended composition"
                )
                let item = TonoAdaptiveLayout.gridItemWidth(
                    available: content, columns: columns, spacing: spec.spacing
                )
                XCTAssertGreaterThanOrEqual(
                    item, spec.minimumItemWidth - 0.0001,
                    "\(spec.label) formed \(item)pt cells on a \(window)pt landscape phone, under its own minimum"
                )
                XCTAssertLessThanOrEqual(
                    item * 2 + spec.spacing, content + 0.0001,
                    "\(spec.label) overflows the landscape column at \(window)pt"
                )
            }
        }
    }

    func testGridCellsNeverOverflowTheirRow() {
        for spec in Self.shippingGrids {
            for size in Self.allTypeSizes {
                for width in Self.phonePortraitWidths + Self.phoneLandscapeWidths + Self.iPadWidths {
                    let columns = TonoAdaptiveLayout.gridColumns(
                        available: width,
                        minimumItemWidth: spec.minimumItemWidth * TonoAdaptiveLayout.typeScale(size),
                        spacing: spec.spacing, maximum: spec.maximumColumns
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
        for spec in Self.shippingGrids {
            for width in stride(from: CGFloat(300), through: 1400, by: 7) {
                let columns = TonoAdaptiveLayout.gridColumns(
                    available: width, minimumItemWidth: spec.minimumItemWidth,
                    spacing: spec.spacing, maximum: spec.maximumColumns
                )
                guard columns > 1 else { continue }
                let item = TonoAdaptiveLayout.gridItemWidth(
                    available: width, columns: columns, spacing: spec.spacing
                )
                XCTAssertGreaterThanOrEqual(
                    item, spec.minimumItemWidth - 0.0001,
                    "\(spec.label) formed \(columns) sub-minimum columns at \(width)pt"
                )
            }
        }
    }

    /// Growing type must never gain columns — the grid may only ever collapse
    /// as the words get bigger.
    func testColumnCountNeverIncreasesAsTypeGrows() {
        for spec in Self.shippingGrids {
            for width in Self.iPadWidths {
                var previous = Int.max
                for size in Self.allTypeSizes {
                    let columns = TonoAdaptiveLayout.gridColumns(
                        available: width,
                        minimumItemWidth: spec.minimumItemWidth * TonoAdaptiveLayout.typeScale(size),
                        spacing: spec.spacing, maximum: spec.maximumColumns
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

    /// The gutter, bounded absolutely rather than against itself.
    ///
    /// Every assertion above compares a spec to its own numbers, so a spec that
    /// drifted would drag its expectations along with it. This one does not:
    /// the surfaces that group two-up have a 20pt vertical stack rhythm, and a
    /// horizontal gutter wider than that stops reading as one group of peers.
    /// `TonoGridSpec.maximumGutter` is the bound, and it is not derived from
    /// any spec.
    func testNoShippingGridUsesAGutterWiderThanTheSurfaceRhythm() {
        for spec in Self.shippingGrids {
            XCTAssertLessThanOrEqual(
                spec.spacing, TonoGridSpec.maximumGutter,
                "\(spec.label)'s \(spec.spacing)pt gutter is wider than the \(TonoGridSpec.maximumGutter)pt surface rhythm — two columns stop reading as one group"
            )
            XCTAssertGreaterThanOrEqual(spec.spacing, 0, "\(spec.label) has a negative gutter")
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

    /// The probe that actually distinguishes the two branches.
    ///
    /// `ProbeContent` above hosts a padded `VStack` containing a
    /// `.frame(maxWidth: .infinity)` child, so its direct child FILLS — and for
    /// a filling direct child the identity branch and the capped branch are
    /// arithmetically identical at any width at or under the cap. Comparing
    /// plain against adapted there can never fail, whichever branch runs. (The
    /// `probe.hug` guard inside it does not close that hole either: `probe.hug`
    /// is a grandchild inside the `VStack`, so its width is decided by the
    /// `VStack`, never by `ReadableColumnLayout`.)
    ///
    /// Here the layout's DIRECT child is the hugging `Text` itself, with no
    /// filling intermediary, and the probes measure the layout's own reported
    /// frame as well as the child's. Deleting the identity branch changes both.
    private struct HuggingColumnProbe: View {
        var body: some View {
            Text("Hug")
                .background(FrameProbe(name: "probe.child"))
                .tonoReadableColumn(.reading)
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

    /// The identity branch, on the only shape that can tell the two branches
    /// apart: a HUGGING direct child.
    ///
    /// The identity branch reports *exactly the size the child chose* and
    /// places it at *the layout's own origin*. The capped branch reports the
    /// full proposed width and centres the child inside it. So for a hugging
    /// child the two disagree about both numbers, and this is the assertion
    /// that goes red the moment the identity branch is removed.
    @MainActor
    func testTheColumnReportsExactlyWhatAHuggingDirectChildChose() {
        for width in [CGFloat(320), 375, 390, 393, 402, 430, 440] {
            let frames = measuredFrames(HuggingColumnProbe(), width: width, height: 400)
            guard let child = frames["probe.child"], let column = frames["probe.column"] else {
                return XCTFail("the hugging probe did not render at \(width)pt")
            }
            // Non-vacuity: if the child filled, the two branches would agree and
            // everything below would pass without testing anything.
            XCTAssertLessThan(
                child.width, width / 2,
                "the probe's DIRECT child filled at \(width)pt, so the identity branch is untested"
            )
            XCTAssertEqual(
                column.width, child.width, accuracy: 0.5,
                "the column reported \(column.width)pt for a child that chose \(child.width)pt at \(width)pt — that is the capped branch, not the identity"
            )
            XCTAssertEqual(
                column.minX, child.minX, accuracy: 0.5,
                "the column moved its hugging child at \(width)pt: column at \(column.minX), child at \(child.minX)"
            )
            // And against no layout at all, in the hosting view's own space.
            let plain = measuredFrames(
                Text("Hug").background(FrameProbe(name: "probe.child")), width: width, height: 400
            )
            XCTAssertEqual(
                plain["probe.child"]?.width ?? -1, child.width, accuracy: 0.5,
                "the column changed a hugging child's size at \(width)pt"
            )
        }
    }

    /// The converse, so the assertion above is not passing because the layout
    /// is inert: on an iPad the same hugging child IS taken over — the column
    /// reports the window and centres the child inside it.
    @MainActor
    func testTheColumnTakesOverAHuggingDirectChildOnAnIPad() {
        for width in [CGFloat(834), 1024, 1366] {
            let frames = measuredFrames(HuggingColumnProbe(), width: width, height: 400)
            guard let child = frames["probe.child"], let column = frames["probe.column"] else {
                return XCTFail("the hugging probe did not render at \(width)pt")
            }
            XCTAssertEqual(
                column.width, width, accuracy: 0.5,
                "the column did not take the capped branch at \(width)pt, so the phone assertion above is vacuous"
            )
            XCTAssertGreaterThan(
                column.width, child.width + 100,
                "the column and its hugging child are the same width at \(width)pt — the two branches are indistinguishable"
            )
            XCTAssertEqual(
                child.midX, width / 2, accuracy: 1.0,
                "the capped branch did not centre its hugging child at \(width)pt"
            )
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

    /// A grid laid out with a real shipping spec, so the numbers under test are
    /// the numbers a surface passes.
    private struct ShippingGridProbe: View {
        let spec: TonoGridSpec
        var body: some View {
            AdaptiveItemGrid(spec) {
                Color.purple.frame(height: 60).background(FrameProbe(name: "grid.a"))
                Color.green.frame(height: 60).background(FrameProbe(name: "grid.b"))
            }
        }
    }

    /// Each shipping spec is load-bearing, not decorative: the gutter it
    /// declares is the gutter the layout engine actually leaves between two
    /// cells, and the cells it produces clear the minimum it declares.
    ///
    /// This is what the old hand-copied table could not do. It listed a spacing
    /// of 16 for grids that ship 20 and 8, and nothing rendered anything, so the
    /// wrong numbers cost nothing. Here a wrong number is a wrong measurement.
    @MainActor
    func testEveryShippingGridSpecIsTheGeometryThatActuallyShips() {
        let width = TonoAdaptiveLayout.cap(.reading, dynamicTypeSize: .large)
        for spec in Self.shippingGrids {
            let frames = measuredFrames(ShippingGridProbe(spec: spec), width: width, height: 400)
            guard let a = frames["grid.a"], let b = frames["grid.b"] else {
                return XCTFail("\(spec.label) did not render at \(width)pt")
            }
            XCTAssertEqual(
                a.minY, b.minY, accuracy: 0.5,
                "\(spec.label) did not form two columns at \(width)pt"
            )
            XCTAssertEqual(
                b.minX - a.maxX, spec.spacing, accuracy: 0.5,
                "\(spec.label) declares a \(spec.spacing)pt gutter but lays out \(b.minX - a.maxX)pt"
            )
            XCTAssertLessThanOrEqual(
                b.minX - a.maxX, TonoGridSpec.maximumGutter + 0.5,
                "\(spec.label) lays out a \(b.minX - a.maxX)pt gutter, wider than the surface rhythm"
            )
            XCTAssertGreaterThanOrEqual(
                a.width, spec.minimumItemWidth - 0.5,
                "\(spec.label) laid out \(a.width)pt cells, under the \(spec.minimumItemWidth)pt minimum it declares"
            )
            XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(spec.label)'s two cells are not equal width")
        }
    }

    // MARK: - Typeface fidelity

    /// A string long enough that the two system faces set it to measurably
    /// different widths. SF Rounded and SF Pro differ by several points over
    /// this specimen, and two adjacent weights differ by more — which is what
    /// makes a laid-out size a usable probe for a FACE.
    private static let faceSpecimen = "Handgloves 0123 quick brown fox"

    /// The laid-out size a hosted `Text` chooses for itself.
    ///
    /// Hosting is the only way to see the face from outside: `Font` exposes
    /// neither its design nor its weight, and the shipping modifier's output is
    /// a `Font`. The rendered raster is no help either — `layer.render` does not
    /// capture a bare `Text` — so the laid-out size is the measurement that
    /// exists.
    @MainActor
    private func specimenSize<V: View>(_ view: V) -> CGSize {
        let controller = UIHostingController(rootView: AnyView(view.fixedSize()))
        // Without this the reported height carries the hosting controller's
        // safe-area inset — about 54pt on this destination — which would make
        // every height below a measurement of the window rather than of the
        // content.
        controller.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1400, height: 400))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let size = controller.sizeThatFits(
            in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        window.isHidden = true
        return CGSize(width: (size.width * 100).rounded() / 100, height: (size.height * 100).rounded() / 100)
    }

    /// The conversion is metric-for-metric the call it replaced — at the
    /// default content size, at every face, weight and size this app uses.
    ///
    /// This is the assertion the old
    /// `testEveryConvertedSizeIsUnchangedAtTheDefaultContentSize` could not
    /// make: that one compared a `CGFloat` point size and was therefore blind
    /// to the design and the weight entirely, which is how flipping the whole
    /// app from SF Rounded to SF Pro left 26 tests green.
    @MainActor
    func testTheModifierRendersTheSameMetricsAsTheSystemFontItReplaced() {
        for face in TonoFontFace.allCases {
            for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
                for size in [CGFloat(11), 13, 14, 17, 22, 28] {
                    let converted = specimenSize(
                        Text(Self.faceSpecimen)
                            .tonoFont(size: size, weight: weight, relativeTo: .body, face: face)
                    )
                    let original = specimenSize(
                        Text(Self.faceSpecimen).font(.system(size: size, weight: weight, design: face.design))
                    )
                    XCTAssertEqual(
                        converted.width, original.width, accuracy: 0.01,
                        "\(size)pt \(weight) \(face) set to \(converted.width)pt, not the \(original.width)pt of the system font it replaced"
                    )
                    XCTAssertEqual(
                        converted.height, original.height, accuracy: 0.01,
                        "\(size)pt \(weight) \(face) is \(converted.height)pt tall, not the \(original.height)pt of the system font it replaced"
                    )
                }
            }
        }
    }

    /// The two faces are actually distinguishable, and the modifiers hand back
    /// the one they claim.
    ///
    /// Non-vacuity comes first: if SF Rounded and SF Pro set the specimen to the
    /// same width, nothing below could tell a restyle from a no-op.
    @MainActor
    func testTheModifiersRenderTheFaceTheyClaim() {
        let rounded = specimenSize(
            Text(Self.faceSpecimen).font(.system(size: 17, weight: .semibold, design: .rounded))
        )
        let standard = specimenSize(
            Text(Self.faceSpecimen).font(.system(size: 17, weight: .semibold, design: .default))
        )
        XCTAssertGreaterThan(
            abs(rounded.width - standard.width), 1.0,
            "the two system faces set this specimen to the same width, so no assertion below can see a face change"
        )

        XCTAssertEqual(
            specimenSize(Text(Self.faceSpecimen).tonoFont(size: 17, weight: .semibold, relativeTo: .body)).width,
            rounded.width, accuracy: 0.01,
            "tonoFont's default face is not the app's rounded face"
        )
        XCTAssertEqual(
            specimenSize(Text(Self.faceSpecimen).tonoGlyphFont(size: 17, weight: .semibold, relativeTo: .body)).width,
            rounded.width, accuracy: 0.01,
            "tonoGlyphFont's default face is not the app's rounded face"
        )
        XCTAssertEqual(
            specimenSize(
                Text(Self.faceSpecimen).tonoFont(size: 17, weight: .semibold, relativeTo: .body, face: .standard)
            ).width,
            standard.width, accuracy: 0.01,
            "face: .standard did not render the standard face"
        )
    }

    /// Weight is pinned too, for the same reason: a point-size comparison
    /// cannot see it, and the restored call sites carry a weight that matters.
    @MainActor
    func testTheModifierRendersTheWeightItClaims() {
        var widths: [CGFloat] = []
        for weight in [Font.Weight.regular, .medium, .semibold, .bold] {
            let converted = specimenSize(
                Text(Self.faceSpecimen).tonoFont(size: 17, weight: weight, relativeTo: .body)
            ).width
            let reference = specimenSize(
                Text(Self.faceSpecimen).font(.system(size: 17, weight: weight, design: .rounded))
            ).width
            XCTAssertEqual(converted, reference, accuracy: 0.01, "\(weight) did not render as \(weight)")
            widths.append(converted)
        }
        // Non-vacuity: the four weights must be four different widths, or the
        // comparison above would hold for any weight at all.
        XCTAssertEqual(
            Set(widths).count, widths.count,
            "two weights set this specimen identically (\(widths)), so the weight assertions prove nothing"
        )
    }

    /// What the face-critical call sites MUST be, written out here rather than
    /// read off the declarations under test.
    ///
    /// This table is the one thing in the typeface section that is not derived
    /// from the code it checks. Everything else asks "does this call site
    /// render the face it declares", which a flipped declaration answers yes to
    /// by flipping its own expectation. This asks the question that matters:
    /// does it declare the face the APPROVED screen shipped. The two standard
    /// entries were authored `.font(.system(size: …))` with no `design:`
    /// argument; the rounded entry is the app's own face.
    private static let approvedCallSites:
        [(label: String, size: CGFloat, weight: Font.Weight, face: TonoFontFace)] = [
            ("Memory · Clear all", 14, .regular, .standard),
            ("Delete account · warning", 17, .semibold, .standard),
            ("Coach · How Coach works", 22, .bold, .rounded),
        ]

    func testTheFaceCriticalCallSitesAreDeclaredTheWayTheApprovedScreensShipped() {
        XCTAssertEqual(
            TonoTextStyle.faceCritical.map(\.label).sorted(),
            Self.approvedCallSites.map(\.label).sorted(),
            "the face-critical call sites are not the ones this test knows the approved values for"
        )
        for approved in Self.approvedCallSites {
            guard let declared = TonoTextStyle.faceCritical.first(where: { $0.label == approved.label }) else {
                XCTFail("\(approved.label) is no longer declared")
                continue
            }
            XCTAssertEqual(
                declared.face, approved.face,
                "\(approved.label) declares the \(declared.face) face; the approved screen shipped \(approved.face)"
            )
            XCTAssertEqual(
                declared.size, approved.size, accuracy: 0.0001,
                "\(approved.label) declares \(declared.size)pt; the approved screen shipped \(approved.size)pt"
            )
            XCTAssertEqual(
                declared.weight, approved.weight,
                "\(approved.label) declares \(declared.weight); the approved screen shipped \(approved.weight)"
            )
        }
    }

    /// The face-critical call sites, read from the shipping declarations they
    /// are applied with — descriptor, family and weight.
    ///
    /// The two restored ones were authored with no `design:` argument, so the
    /// approved screens ship SF Pro there; the rounded one is on the same screen
    /// family and is included so a blanket flip of `TonoFontFace` is caught from
    /// both directions.
    func testTheFaceCriticalCallSitesResolveToTheFamilyAndWeightTheyDeclare() {
        // Independent references, built straight from UIKit rather than from
        // anything under test.
        let standardFamily = UIFont.systemFont(ofSize: 17, weight: .regular).familyName
        let roundedFamily: String = {
            let base = UIFont.systemFont(ofSize: 17, weight: .regular)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base.familyName }
            return UIFont(descriptor: descriptor, size: 17).familyName
        }()
        XCTAssertNotEqual(
            roundedFamily, standardFamily,
            "SF Rounded and SF Pro report the same family here, so a family assertion cannot see a restyle"
        )

        XCTAssertFalse(TonoTextStyle.faceCritical.isEmpty, "no face-critical call site is under test")
        for style in TonoTextStyle.faceCritical {
            for size in Self.allTypeSizes {
                let font = style.resolvedUIFont(dynamicTypeSize: size)
                XCTAssertEqual(
                    font.familyName, style.face == .rounded ? roundedFamily : standardFamily,
                    "\(style.label) resolved to \(font.familyName) at \(size), not the \(style.face) face it declares"
                )
                let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
                let weight = traits?[.weight] as? CGFloat
                XCTAssertEqual(
                    weight ?? .nan, TonoTypography.uiWeight(style.weight).rawValue, accuracy: 0.001,
                    "\(style.label) resolved to weight \(String(describing: weight)) at \(size), not \(style.weight)"
                )
            }
            XCTAssertEqual(
                style.resolvedUIFont(dynamicTypeSize: .large).pointSize, style.size, accuracy: 0.0001,
                "\(style.label) does not render at its approved size at the default content size"
            )
        }
    }

    /// And the same call sites, measured through the shipping modifier rather
    /// than through the resolver — so the declaration is not just internally
    /// consistent, it is what the view lays out.
    @MainActor
    func testTheFaceCriticalCallSitesLayOutInTheFaceTheyDeclare() {
        for style in TonoTextStyle.faceCritical {
            let declared = specimenSize(Text(Self.faceSpecimen).tonoFont(style)).width
            let sameFace = specimenSize(
                Text(Self.faceSpecimen)
                    .font(.system(size: style.size, weight: style.weight, design: style.face.design))
            ).width
            let otherFace = specimenSize(
                Text(Self.faceSpecimen)
                    .font(
                        .system(
                            size: style.size, weight: style.weight,
                            design: style.face == .rounded ? .default : .rounded
                        )
                    )
            ).width
            XCTAssertEqual(
                declared, sameFace, accuracy: 0.01,
                "\(style.label) did not lay out in the \(style.face) face it declares"
            )
            XCTAssertGreaterThan(
                abs(declared - otherFace), 1.0,
                "\(style.label) is indistinguishable from the other face, so this assertion proves nothing"
            )
        }
    }

    // MARK: - The Coach explainer's step badge

    /// A digit inside a fixed frame with `.clipShape(Circle())` over it is CUT
    /// when it outgrows the frame — not wrapped, not shrunk, cut.
    ///
    /// Nothing else in either Build 115 suite can see this: `Extent` measures
    /// only `left` and `right`, and every accessibility-frame assertion is
    /// horizontal, so a digit overflowing a 22pt circle vertically is invisible
    /// to all of them. It is measured here directly, on the exact font the badge
    /// renders, at every Dynamic Type size — which is what the first Dynamic
    /// Type pass shipped without: the digit took the 2.2× text ceiling (28.6pt)
    /// inside a hard 22pt circle and clipped at all five accessibility sizes,
    /// on the app's first-run overlay.
    func testTheStepBadgeDigitFitsItsCircleAtEveryDynamicTypeSize() {
        for size in Self.allTypeSizes {
            let font = TonoStepBadge.font(dynamicTypeSize: size)
            let diameter = TonoStepBadge.diameter(dynamicTypeSize: size)
            for digit in ["1", "2", "3"] {
                let box = (digit as NSString).size(withAttributes: [.font: font])
                XCTAssertLessThanOrEqual(
                    box.height, diameter,
                    "the step badge's \(digit) needs \(box.height)pt of height in a \(diameter)pt circle at \(size) — it is clipped"
                )
                XCTAssertLessThanOrEqual(
                    box.width, diameter,
                    "the step badge's \(digit) needs \(box.width)pt of width in a \(diameter)pt circle at \(size) — it is clipped"
                )
                // Not a hairline fit: the badge must survive a metrics change,
                // and a digit filling its circle to the edge has already lost
                // the circle.
                XCTAssertLessThanOrEqual(
                    box.height, diameter * 0.85,
                    "the step badge's \(digit) fills \(box.height / diameter) of its circle at \(size) — no margin left"
                )
            }
        }
    }

    /// The approved appearance is untouched at the default content size: the
    /// same 13pt digit in the same 22pt circle that shipped.
    func testTheStepBadgeIsExactlyTheApprovedBadgeAtTheDefaultContentSize() {
        XCTAssertEqual(TonoStepBadge.diameter(dynamicTypeSize: .large), 22, accuracy: 0.0001)
        XCTAssertEqual(TonoStepBadge.fontSize(dynamicTypeSize: .large), 13, accuracy: 0.0001)
        XCTAssertEqual(TonoStepBadge.font(dynamicTypeSize: .large).pointSize, 13, accuracy: 0.0001)
        // And it must actually respond, or "fits at every size" would be true
        // of a badge that ignores Dynamic Type altogether.
        XCTAssertGreaterThan(
            TonoStepBadge.diameter(dynamicTypeSize: .accessibility5), 22 * 1.2,
            "the step badge's circle does not grow with Dynamic Type at all"
        )
        XCTAssertGreaterThan(
            TonoStepBadge.fontSize(dynamicTypeSize: .accessibility5), 13 * 1.2,
            "the step badge's digit does not grow with Dynamic Type at all"
        )
    }

    /// The shipping badge — the view Coach's explainer actually renders —
    /// adopts the scaled diameter rather than a hard 22.
    @MainActor
    func testTheShippingStepBadgeLaysOutAtTheScaledDiameter() {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility3, .accessibility5] {
            let laidOut = specimenSize(CoachView.StepBadge(number: "3").dynamicTypeSize(size))
            let expected = TonoStepBadge.diameter(dynamicTypeSize: size)
            XCTAssertEqual(
                laidOut.width, expected, accuracy: 0.5,
                "the shipping badge is \(laidOut.width)pt wide at \(size), not the \(expected)pt its metrics declare"
            )
            XCTAssertEqual(
                laidOut.height, expected, accuracy: 0.5,
                "the shipping badge is \(laidOut.height)pt tall at \(size), not the \(expected)pt its metrics declare"
            )
        }
        // Absolute, so this cannot pass by agreeing with a metric that stopped
        // scaling: the badge that shipped before was a hard 22pt at every size,
        // and that is what clipped.
        XCTAssertGreaterThan(
            specimenSize(CoachView.StepBadge(number: "3").dynamicTypeSize(.accessibility5)).width,
            TonoStepBadge.baseDiameter * 1.2,
            "the shipping badge is still the fixed \(TonoStepBadge.baseDiameter)pt circle at the largest accessibility size"
        )
    }
}
