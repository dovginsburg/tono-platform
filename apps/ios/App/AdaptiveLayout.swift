// AdaptiveLayout.swift
// Build 115 — the host app's one adaptive-layout primitive.
//
// Tono is a single universal binary (`TARGETED_DEVICE_FAMILY = "1,2"`). Before
// this file there was no size-class or width awareness anywhere in `App/` or
// `Shared/`: every screen was `NavigationStack { ScrollView { VStack(…).padding }}`
// with no maximum content width, so on an iPad the editor, the Coach button and
// every card ran the full 1,032pt of the window while the one hard-capped card
// (`.frame(maxWidth: 340)`) floated as a small island in a large empty field.
//
// WHAT THIS FILE IS AND IS NOT
//
// It is a *measure* primitive: it decides how wide a column of content may get
// and how many columns a set of peer items should occupy. It is deliberately
// NOT a navigation primitive — `RootView`'s `TabView` already renders as the
// iPadOS floating tab bar and reads correctly, so nothing here touches
// navigation architecture, and no separate iPad target exists or is implied.
//
// THE PHONE NO-OP, AND WHY IT IS A PROOF RATHER THAN A CLAIM
//
// Everything here is gated on *measured width*, never on
// `horizontalSizeClass`. That is the whole reason the phone behaviour can be
// proved rather than argued:
//
//   * an iPhone 17 Pro Max in LANDSCAPE reports a REGULAR horizontal size
//     class, so a size-class gate would silently restyle a phone;
//   * an iPad in a narrow Split View column reports COMPACT, so a size-class
//     gate would leave a 320pt column running the iPad composition.
//
// Width is the thing the layout actually depends on, so width is what is read.
//
// `ReadableColumnLayout` has an explicit identity branch: when the proposed
// width is at or below the cap it proposes *exactly the width it was proposed*,
// reports *exactly the size its child chose*, and places that child at *its own
// origin*. That is not "close to" a no-op — it is the identity function.
//
// What pins that, precisely (an earlier version of this comment claimed more
// than the tests delivered, so the claim is now spelled out):
//
//   * the ARITHMETIC identity — `isIdentity` and `columnWidth` — is pinned at
//     every iPhone portrait width from 320 to 440pt, one point at a time,
//     across every Dynamic Type size;
//   * the LAYOUT identity is pinned on real laid-out `UIView` frames for a
//     FILLING child (`testHostedPhoneGeometryIsByteForByteUnchangedByTheColumn`)
//     and — the case that actually distinguishes the two branches — for a
//     HUGGING direct child
//     (`testTheColumnReportsExactlyWhatAHuggingDirectChildChose`). For a
//     filling child the two branches are arithmetically identical at any width
//     at or under the cap, so only the hugging probe can tell them apart, and
//     deleting the identity branch turns that one red.
//
// Because every cap here is wider than the widest iPhone portrait width
// (440pt on the 17 Pro Max), the identity branch is the only branch a phone in
// portrait can ever take. In landscape a large iPhone is 844–956pt wide and
// DOES take the capped branch — content caps at the reading measure, centres,
// and the peer-item grids below form two columns. That is intentional and it
// is the same readable-measure treatment iOS gives long-form content on a wide
// window. It is pinned by its own tests
// (`testPhoneLandscapeTakesTheCappedBranchOnPurpose`,
// `testEveryShippingGridFormsTwoColumnsInsideAPhoneLandscapeReadingMeasure`,
// `testPhoneLandscapeIsCappedAndCentredOnPurpose`) rather than left as a
// surprise, so "the phone is untouched" is a claim about PORTRAIT only.
//
// DYNAMIC TYPE
//
// Caps GROW with Dynamic Type (bounded), never shrink: bigger glyphs need a
// wider column to keep a comfortable line, and growth can only ever make the
// identity branch more likely, never less. `min(available, cap)` then keeps the
// column inside the window at every size, so nothing can be pushed off-screen.

import SwiftUI
import UIKit

// MARK: - Measures

/// The named content measures this app composes with. Each one exists because
/// a specific KIND of content reads well at that width — there is deliberately
/// no single blanket cap, because "a column of prose", "a credential form" and
/// "a modal card" are not the same problem.
enum TonoContentMeasure: CaseIterable {

    /// Mixed reading + controls: Coach, This Week, Setup Doctor, onboarding.
    /// 700pt is a little over 90 characters at the app's body size, which is
    /// the upper end of a comfortable line and leaves room for the cards and
    /// the two-column groupings that sit inside it.
    case reading

    /// Data entry a person completes and leaves: the email sheet, the delete
    /// confirmation, the paywall's product list. Narrower on purpose — a text
    /// field or a capsule button stretched to a reading measure reads as a
    /// mistake, and this is the measure that stops the 1,000pt phone capsule.
    case form

    /// The base width at the default Dynamic Type size, before scaling.
    var baseWidth: CGFloat {
        switch self {
        case .reading: return 700
        case .form:    return 520
        }
    }

    /// How much wider the measure may get at the largest accessibility size.
    /// Bounded so a decorative measure cannot run away, and so the grown cap
    /// stays a *cap* rather than becoming "whatever the window is".
    var maximumGrowth: CGFloat {
        switch self {
        case .reading: return 1.30
        case .form:    return 1.45
        }
    }
}

// MARK: - The metric resolver

/// Every adaptive decision the app makes, as pure arithmetic.
///
/// Nothing here touches a view, so all of it is directly testable without a
/// hosting controller — and the view layer below is a thin shell over it, so a
/// test of these functions is a test of what actually ships.
enum TonoAdaptiveLayout {

    /// The widest width at which the column primitive is DEFINED to impose
    /// nothing.
    ///
    /// 500pt sits above the widest iPhone portrait width (440pt, 17 Pro Max)
    /// and below the narrowest iPad portrait width (744pt, iPad mini), so
    /// "phone portrait" and "iPad" fall on opposite sides of it with margin.
    /// It is an assertion target, not a branch: the code branches on the cap
    /// itself, and every cap is required to clear this.
    static let compactContentCeiling: CGFloat = 500

    /// The width at or below which a WINDOW is treated as compact for sizing a
    /// modal card. A separate number from the column ceiling because it answers
    /// a different question — not "is this column too wide to read" but "is
    /// there enough room around a card for it to be worth growing".
    ///
    /// 640pt keeps every iPad Split View column that iOS itself reports as
    /// compact (up to 507pt on a 1,024pt window) on the phone card, and puts
    /// every genuinely regular window above it.
    static let regularWindowThreshold: CGFloat = 640

    /// The widest iPhone portrait width Tono supports, used by the tests as the
    /// upper bound of the range the identity branch must cover.
    static let widestPhonePortraitWidth: CGFloat = 440

    // MARK: Column width

    /// The cap for `measure` at `dynamicTypeSize`, rounded to a whole point.
    static func cap(_ measure: TonoContentMeasure, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let scale = min(typeScale(dynamicTypeSize), measure.maximumGrowth)
        return (measure.baseWidth * scale).rounded()
    }

    /// The width a readable column actually receives inside `available`.
    ///
    /// Never wider than the window, never wider than the cap. Non-finite or
    /// non-positive proposals (SwiftUI proposes `nil`/`.infinity` while sizing)
    /// pass through untouched.
    static func columnWidth(
        available: CGFloat,
        measure: TonoContentMeasure,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        guard available.isFinite, available > 0 else { return available }
        return min(available, cap(measure, dynamicTypeSize: dynamicTypeSize))
    }

    /// True when the primitive imposes nothing at all at this width — i.e. the
    /// layout takes the identity branch and the result is byte-for-byte the
    /// unmodified view.
    static func isIdentity(
        available: CGFloat,
        measure: TonoContentMeasure,
        dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        guard available.isFinite, available > 0 else { return true }
        return available <= cap(measure, dynamicTypeSize: dynamicTypeSize)
    }

    // MARK: Modal cards

    /// The Coach explainer card's width.
    ///
    /// This is the one place the fix runs the OTHER way. The card shipped at a
    /// hard `.frame(maxWidth: 340)`, which is right on a phone and is the
    /// "tiny island" on an iPad. So the compact branch returns exactly 340 —
    /// the approved phone number, unchanged — and only a regular-width window
    /// gets a card sized to it.
    static let compactDialogWidth: CGFloat = 340

    static func dialogWidth(available: CGFloat, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        guard available.isFinite, available > 0 else { return compactDialogWidth }
        guard available > regularWindowThreshold else {
            // `min` reproduces the shipped `.frame(maxWidth: 340)` exactly,
            // including on a 320pt iPhone SE where 340 would have overflowed.
            return min(compactDialogWidth, available)
        }
        let grown = (compactDialogWidth * min(typeScale(dynamicTypeSize), 1.35) * 1.35).rounded()
        // Always leaves a margin, so the card can never touch the window edge.
        return max(compactDialogWidth, min(grown, available - 96))
    }

    // MARK: Grids

    /// How many columns a row of peer items should occupy.
    ///
    /// Returns 1 whenever a second column would not fit at `minimumItemWidth`,
    /// which is what makes the grid layout below collapse to exactly a `VStack`
    /// on a phone.
    static func gridColumns(
        available: CGFloat,
        minimumItemWidth: CGFloat,
        spacing: CGFloat,
        maximum: Int
    ) -> Int {
        guard maximum > 1, available.isFinite, available > 0,
              minimumItemWidth > 0, spacing >= 0
        else { return 1 }
        // n columns fit when n·min + (n−1)·spacing ≤ available.
        let fitting = Int(((available + spacing) / (minimumItemWidth + spacing)).rounded(.down))
        return max(1, min(maximum, fitting))
    }

    /// The width of one cell once `columns` share `available`.
    static func gridItemWidth(available: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
        guard columns > 1 else { return available }
        let count = CGFloat(columns)
        return max(0, (available - spacing * (count - 1)) / count)
    }

    // MARK: Dynamic Type

    /// The layout scale factor for a Dynamic Type size.
    ///
    /// A table rather than a formula so it is reviewable and testable line by
    /// line, and so it is monotonic by construction. Deliberately much flatter
    /// than the type scale itself: this widens a COLUMN, it does not resize
    /// text — SwiftUI already does that.
    static func typeScale(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: return 1.00
        case .xLarge:                          return 1.04
        case .xxLarge:                         return 1.08
        case .xxxLarge:                        return 1.12
        case .accessibility1:                  return 1.18
        case .accessibility2:                  return 1.24
        case .accessibility3:                  return 1.30
        case .accessibility4:                  return 1.36
        case .accessibility5:                  return 1.42
        @unknown default:                      return 1.42
        }
    }
}

// MARK: - The shipping grid specs

/// The parameters one peer-item grid is laid out with.
///
/// These are DECLARED HERE and consumed by both the shipping call sites and the
/// tests, so the two cannot drift. The previous arrangement — a hand-copied
/// table inside the test file — had already drifted: it carried the wrong
/// spacing for all three real grids and a fourth entry for a grid that does not
/// exist (the This Week top-line stats are a plain `HStack`). A test table that
/// describes a different app than the one that ships proves nothing about the
/// app that ships.
struct TonoGridSpec: Equatable {

    /// What this grid is, for test failure messages.
    let label: String

    /// The narrowest a cell may be before the grid collapses to one column.
    let minimumItemWidth: CGFloat

    /// The gutter between columns. Set to the spacing of the `VStack` each call
    /// site replaced, so the single-column result is frame-for-frame what
    /// shipped on a phone.
    let spacing: CGFloat

    let maximumColumns: Int
}

extension TonoGridSpec {

    /// This Week's two depth cards. Peers about the same week.
    static let digestDepthCards = TonoGridSpec(
        label: "This Week depth cards", minimumItemWidth: 300, spacing: 20, maximumColumns: 2
    )

    /// The onboarding entry-point tiles. Independent options, not a sequence.
    static let onboardingTiles = TonoGridSpec(
        label: "onboarding entry-point tiles", minimumItemWidth: 300, spacing: 20, maximumColumns: 2
    )

    /// Coach's "All rewrites" list. Four parallel answers to one draft.
    static let coachAlternateRewrites = TonoGridSpec(
        label: "Coach alternate rewrites", minimumItemWidth: 260, spacing: 8, maximumColumns: 2
    )

    /// Every grid the app actually ships. Adding a call site means adding it
    /// here, which is what puts it under test.
    static let shipping: [TonoGridSpec] = [digestDepthCards, onboardingTiles, coachAlternateRewrites]

    /// The widest gutter a two-column grouping may use.
    ///
    /// Absolute, not derived from the specs above, so it is a real bound rather
    /// than a restatement: the surfaces that group two-up have a 20pt vertical
    /// stack rhythm, and a horizontal gutter wider than that rhythm stops
    /// reading as one group of peers and starts reading as two unrelated
    /// columns. 24pt leaves the shipping 20pt a little room and still fails a
    /// gutter that has run away.
    static let maximumGutter: CGFloat = 24
}

// MARK: - Typography

/// Which system face a call site renders in.
///
/// A named type rather than a bare `Font.Design` because the FACE is the thing
/// that must not change silently: most of this app is SF Rounded, and a handful
/// of call sites were authored in the standard face and must stay there.
enum TonoFontFace: CaseIterable {

    /// SF Rounded — the app's face.
    case rounded

    /// SF Pro — the system default. Used where the original call site had no
    /// `design:` argument and the approved screen therefore shipped SF Pro.
    case standard

    var design: Font.Design {
        switch self {
        case .rounded:  return .rounded
        case .standard: return .default
        }
    }

    var systemDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .rounded:  return .rounded
        case .standard: return .default
        }
    }
}

/// Dynamic-Type-aware sizing for the app's faces.
///
/// `Font.system(size:weight:design:)` does not scale, and `Font.custom(_:size:
/// relativeTo:)` cannot express the rounded design, so neither one alone can
/// keep both the approved look and Dynamic Type. This resolves the point size
/// against `UIFontMetrics` instead, which gives exactly the `relativeTo:`
/// behaviour with the design preserved.
///
/// The property that makes this safe to apply to approved screens: at the
/// DEFAULT content size the scaled value is the input value, so every converted
/// call site renders at the size of the fixed-point one it replaced.
/// `testEveryConvertedSizeIsUnchangedAtTheDefaultContentSize` pins the size;
/// `testTheModifiersRenderTheFaceTheyClaim`,
/// `testTheModifierRendersTheWeightItClaims` and
/// `testTheModifierRendersTheSameMetricsAsTheSystemFontItReplaced` pin the FACE
/// and the WEIGHT, which a point-size comparison cannot see at all.
enum TonoTypography {

    /// Growth ceiling for text. Past this, a screen designed at 13–22pt starts
    /// to clip rather than to help, and SwiftUI's own line breaking has already
    /// had several sizes to work with.
    static let maximumTextGrowth: CGFloat = 2.2

    /// Growth ceiling for DECORATIVE metrics — glyph badges, circle diameters,
    /// icon sizes. Kept much tighter than text: these carry no words, so
    /// growing them only steals width from the words beside them.
    static let maximumDecorativeGrowth: CGFloat = 1.4

    static func scaledSize(
        _ size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        dynamicTypeSize: DynamicTypeSize,
        maximumGrowth: CGFloat = TonoTypography.maximumTextGrowth
    ) -> CGFloat {
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle(textStyle))
        let traits = UITraitCollection(preferredContentSizeCategory: contentSizeCategory(dynamicTypeSize))
        let scaled = metrics.scaledValue(for: size, compatibleWith: traits)
        return min(max(scaled, size), size * maximumGrowth)
    }

    static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle:  return .largeTitle
        case .title:       return .title1
        case .title2:      return .title2
        case .title3:      return .title3
        case .headline:    return .headline
        case .subheadline: return .subheadline
        case .body:        return .body
        case .callout:     return .callout
        case .footnote:    return .footnote
        case .caption:     return .caption1
        case .caption2:    return .caption2
        @unknown default:  return .body
        }
    }

    /// The actual `UIFont` a converted call site renders in.
    ///
    /// This is not a mirror of the view layer for the tests to inspect — it IS
    /// the view layer's resolution step. `ScaledSystemFontModifier` below wraps
    /// exactly this font, so a test that reads this descriptor reads the object
    /// that ships. `Font(_: UIFont)` and `Font.system(size:weight:design:)`
    /// produce identical laid-out metrics for a system font, which
    /// `testTheModifierRendersTheSameMetricsAsTheSystemFontItReplaced` measures
    /// rather than assumes.
    static func resolvedUIFont(
        size: CGFloat,
        weight: Font.Weight,
        face: TonoFontFace,
        relativeTo textStyle: Font.TextStyle,
        dynamicTypeSize: DynamicTypeSize,
        maximumGrowth: CGFloat = TonoTypography.maximumTextGrowth
    ) -> UIFont {
        let points = scaledSize(
            size, relativeTo: textStyle, dynamicTypeSize: dynamicTypeSize, maximumGrowth: maximumGrowth
        )
        let base = UIFont.systemFont(ofSize: points, weight: uiWeight(weight))
        guard let descriptor = base.fontDescriptor.withDesign(face.systemDesign) else { return base }
        return UIFont(descriptor: descriptor, size: points)
    }

    /// `Font.Weight` carries no public accessor, so the two scales are mapped
    /// case by case. They agree numerically — `.semibold` is 0.3 on both — and
    /// `testTheModifierRendersTheSameMetricsAsTheSystemFontItReplaced` measures
    /// that agreement at every weight this app uses.
    static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }

    static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall:          return .extraSmall
        case .small:           return .small
        case .medium:          return .medium
        case .large:           return .large
        case .xLarge:          return .extraLarge
        case .xxLarge:         return .extraExtraLarge
        case .xxxLarge:        return .extraExtraExtraLarge
        case .accessibility1:  return .accessibilityMedium
        case .accessibility2:  return .accessibilityLarge
        case .accessibility3:  return .accessibilityExtraLarge
        case .accessibility4:  return .accessibilityExtraExtraLarge
        case .accessibility5:  return .accessibilityExtraExtraExtraLarge
        @unknown default:      return .large
        }
    }
}

// MARK: - Face-critical call sites

/// A converted call site whose FACE is load-bearing, declared once and applied
/// by the view.
///
/// Only the face-critical sites are listed. The other conversions are either
/// the app's own rounded face — where a blanket flip is caught at the modifier
/// by `testTheModifiersRenderTheFaceTheyClaim` — or `Image(systemName:)`
/// glyphs, where `design` is inert. What this list exists for is the case that
/// slipped through: two call sites whose ORIGINAL had no `design:` argument,
/// and which a blanket `.rounded` conversion silently restyled.
struct TonoTextStyle {
    let label: String
    let size: CGFloat
    let weight: Font.Weight
    let textStyle: Font.TextStyle
    let face: TonoFontFace
    let maximumGrowth: CGFloat

    init(
        label: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle,
        face: TonoFontFace,
        maximumGrowth: CGFloat = TonoTypography.maximumTextGrowth
    ) {
        self.label = label
        self.size = size
        self.weight = weight
        self.textStyle = textStyle
        self.face = face
        self.maximumGrowth = maximumGrowth
    }

    /// The font this call site renders in — the same resolution the view layer
    /// performs, not a second copy of it.
    func resolvedUIFont(dynamicTypeSize: DynamicTypeSize) -> UIFont {
        TonoTypography.resolvedUIFont(
            size: size, weight: weight, face: face, relativeTo: textStyle,
            dynamicTypeSize: dynamicTypeSize, maximumGrowth: maximumGrowth
        )
    }
}

extension TonoTextStyle {

    /// Memory's `Clear all` toolbar button. Shipped `.font(.system(size: 14))`
    /// — no `design:` argument, therefore SF Pro.
    static let memoryClearAll = TonoTextStyle(
        label: "Memory · Clear all", size: 14, relativeTo: .subheadline, face: .standard
    )

    /// The account-deletion sheet's warning. Shipped `.font(.system(size: 17,
    /// weight: .semibold))` — no `design:` argument, therefore SF Pro. That
    /// sheet's Build 115 phase is layout only, so a typeface change here would
    /// have been outside its own declared scope.
    static let accountDeletionWarning = TonoTextStyle(
        label: "Delete account · warning", size: 17, weight: .semibold, relativeTo: .body, face: .standard
    )

    /// Coach's explainer heading — the app's own rounded face, on the same
    /// screen as the step badge, so a flip of the face is caught from the
    /// rounded direction too and not only from the standard one.
    static let coachExplainerTitle = TonoTextStyle(
        label: "Coach · How Coach works", size: 22, weight: .bold, relativeTo: .title2, face: .rounded
    )

    static let faceCritical: [TonoTextStyle] = [
        memoryClearAll, accountDeletionWarning, coachExplainerTitle,
    ]
}

// MARK: - The numbered step badge

/// The Coach explainer's numbered step badge: a digit inside a filled circle.
///
/// Declared here, and consumed by both `CoachView.StepBadge` and the tests,
/// for the same reason the grid specs are: a badge is a fixed frame with a
/// `clipShape(Circle())` over it, so if the digit grows and the circle does
/// not, the digit is silently CUT. That happened — the first Dynamic Type pass
/// gave the digit the text growth ceiling (2.2×, 28.6pt at the accessibility
/// sizes) while leaving the circle at a hard 22pt, and the app's first-run
/// overlay clipped for anyone with large text turned on.
///
/// The rule that makes it safe at every size: the digit and the circle scale
/// TOGETHER, both against the same text style and both held to the decorative
/// ceiling. Their ratio is therefore fixed at 13/22, so the digit's line box
/// occupies a constant ~0.71 of the circle at every Dynamic Type size — and at
/// the default size both resolve to exactly the approved 13pt and 22pt, so the
/// approved appearance is unchanged.
enum TonoStepBadge {

    /// The approved phone diameter, unchanged at the default content size.
    static let baseDiameter: CGFloat = 22

    /// The approved digit size, unchanged at the default content size.
    static let baseFontSize: CGFloat = 13

    static let textStyle: Font.TextStyle = .footnote
    static let weight: Font.Weight = .bold

    static func diameter(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        TonoTypography.scaledSize(
            baseDiameter, relativeTo: textStyle, dynamicTypeSize: dynamicTypeSize,
            maximumGrowth: TonoTypography.maximumDecorativeGrowth
        )
    }

    static func fontSize(dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        TonoTypography.scaledSize(
            baseFontSize, relativeTo: textStyle, dynamicTypeSize: dynamicTypeSize,
            maximumGrowth: TonoTypography.maximumDecorativeGrowth
        )
    }

    /// The resolved font of the digit — the object the badge actually renders.
    static func font(dynamicTypeSize: DynamicTypeSize) -> UIFont {
        TonoTypography.resolvedUIFont(
            size: baseFontSize, weight: weight, face: .rounded, relativeTo: textStyle,
            dynamicTypeSize: dynamicTypeSize,
            maximumGrowth: TonoTypography.maximumDecorativeGrowth
        )
    }
}

// MARK: - The readable-column layout

/// Centres its content and caps it at `cap`, and does *literally nothing* when
/// the proposed width already fits.
///
/// Written as a `Layout` rather than as `.frame(maxWidth:)` for one reason: a
/// frame modifier cannot express "leave this alone". `.frame(maxWidth: cap)`
/// changes how a hugging child sizes, and the `.frame(maxWidth: .infinity)`
/// needed to centre it forces a hugging child to fill. A `Layout` sees the
/// proposal and can return the child's own answer untouched.
struct ReadableColumnLayout: Layout {

    var cap: CGFloat

    /// The alignment used for the CAPPED branch only. The identity branch
    /// places at the layout's own origin, where there is nothing to align.
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let childProposal = childProposal(proposal)
        let sizes = subviews.map { $0.sizeThatFits(childProposal) }
        let childWidth = sizes.map(\.width).max() ?? 0
        let childHeight = sizes.map(\.height).max() ?? 0
        guard let available = proposal.width, available.isFinite, available > cap else {
            // ── IDENTITY BRANCH ──
            // The child was proposed exactly what we were proposed, and we
            // report exactly what it chose. Indistinguishable from having no
            // layout here at all.
            return CGSize(width: childWidth, height: childHeight)
        }
        return CGSize(width: available, height: childHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let childProposal = childProposal(proposal)
        guard let available = proposal.width, available.isFinite, available > cap else {
            // ── IDENTITY BRANCH ── placed at our own origin.
            for subview in subviews {
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: childProposal
                )
            }
            return
        }
        let width = min(available, cap)
        let x: CGFloat
        let anchor: UnitPoint
        switch alignment {
        case .leading:  x = bounds.midX - width / 2; anchor = .topLeading
        case .trailing: x = bounds.midX + width / 2; anchor = .topTrailing
        default:        x = bounds.midX;             anchor = .top
        }
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: anchor, proposal: childProposal)
        }
    }

    /// The proposal handed down to the content. On the identity branch this is
    /// the incoming proposal, unchanged.
    private func childProposal(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let width = proposal.width, width.isFinite else { return proposal }
        return ProposedViewSize(width: min(width, cap), height: proposal.height)
    }
}

// MARK: - The adaptive grid layout

/// Lays peer items out in as many columns as `minimumItemWidth` allows.
///
/// At one column it is exactly a `VStack(alignment:spacing:)`: same proposal,
/// same spacing, same alignment — which is what every phone width resolves to
/// for the minimums this app uses.
struct AdaptiveGridLayout: Layout {

    var minimumItemWidth: CGFloat
    var spacing: CGFloat
    var maximumColumns: Int
    /// Where an item that does not fill its cell sits inside it. Set to match
    /// the alignment of the `VStack` each call site replaced, so the
    /// single-column result is identical to what shipped.
    var itemAlignment: Alignment = .topLeading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let available = proposal.width ?? minimumItemWidth
        let columns = resolvedColumns(available: available)
        let itemWidth = TonoAdaptiveLayout.gridItemWidth(
            available: available, columns: columns, spacing: spacing
        )
        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columns > 1 ? itemWidth : proposal.width, height: nil))
        }
        let rows = rowHeights(sizes: sizes, columns: columns)
        let height = rows.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = columns > 1 ? available : (sizes.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard !subviews.isEmpty else { return }
        let available = proposal.width ?? bounds.width
        let columns = resolvedColumns(available: available)
        let itemWidth = TonoAdaptiveLayout.gridItemWidth(
            available: available, columns: columns, spacing: spacing
        )
        let cellProposal = ProposedViewSize(
            width: columns > 1 ? itemWidth : proposal.width, height: nil
        )
        let sizes = subviews.map { $0.sizeThatFits(cellProposal) }
        let rows = rowHeights(sizes: sizes, columns: columns)

        var y = bounds.minY
        for row in 0..<rows.count {
            let rowHeight = rows[row]
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                let cellX = bounds.minX + CGFloat(column) * (itemWidth + spacing)
                let cell = CGRect(x: cellX, y: y, width: columns > 1 ? itemWidth : bounds.width, height: rowHeight)
                subviews[index].place(
                    at: anchorPoint(in: cell),
                    anchor: unitPoint,
                    proposal: cellProposal
                )
            }
            y += rowHeight + spacing
        }
    }

    private func resolvedColumns(available: CGFloat) -> Int {
        TonoAdaptiveLayout.gridColumns(
            available: available,
            minimumItemWidth: minimumItemWidth,
            spacing: spacing,
            maximum: maximumColumns
        )
    }

    private func rowHeights(sizes: [CGSize], columns: Int) -> [CGFloat] {
        guard columns > 0 else { return [] }
        var heights: [CGFloat] = []
        var index = 0
        while index < sizes.count {
            let end = min(index + columns, sizes.count)
            heights.append(sizes[index..<end].map(\.height).max() ?? 0)
            index = end
        }
        return heights
    }

    private var unitPoint: UnitPoint {
        switch itemAlignment {
        case .top:        return .top
        case .topTrailing: return .topTrailing
        default:          return .topLeading
        }
    }

    private func anchorPoint(in cell: CGRect) -> CGPoint {
        switch itemAlignment {
        case .top:         return CGPoint(x: cell.midX, y: cell.minY)
        case .topTrailing: return CGPoint(x: cell.maxX, y: cell.minY)
        default:           return CGPoint(x: cell.minX, y: cell.minY)
        }
    }
}

// MARK: - View surface

private struct ReadableColumnModifier: ViewModifier {
    let measure: TonoContentMeasure
    let alignment: HorizontalAlignment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        ReadableColumnLayout(
            cap: TonoAdaptiveLayout.cap(measure, dynamicTypeSize: dynamicTypeSize),
            alignment: alignment
        ) {
            content
        }
    }
}

private struct ScaledSystemFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let face: TonoFontFace
    let textStyle: Font.TextStyle
    let maximumGrowth: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        // Resolved through `TonoTypography.resolvedUIFont` rather than through
        // `Font.system(size:weight:design:)` so that there is exactly ONE place
        // the face is decided, and a test can read the descriptor that actually
        // ships instead of a parallel re-derivation of it. The two produce
        // identical laid-out metrics; that is measured, not assumed.
        content.font(
            Font(
                TonoTypography.resolvedUIFont(
                    size: size,
                    weight: weight,
                    face: face,
                    relativeTo: textStyle,
                    dynamicTypeSize: dynamicTypeSize,
                    maximumGrowth: maximumGrowth
                )
            )
        )
    }
}

extension View {

    /// Centres this content and caps it at a readable measure on a wide window;
    /// does nothing at all on a narrow one.
    func tonoReadableColumn(
        _ measure: TonoContentMeasure = .reading,
        alignment: HorizontalAlignment = .center
    ) -> some View {
        modifier(ReadableColumnModifier(measure: measure, alignment: alignment))
    }

    /// The app's face at `size` points, scaling with Dynamic Type relative to
    /// `textStyle`. At the default content size this is exactly
    /// `.font(.system(size:weight:design:))` — the call it replaces.
    ///
    /// `face` defaults to `.rounded`, which is the app's face and what all but
    /// two converted call sites want. The two that pass `.standard` were
    /// authored with no `design:` argument, so the approved screen ships SF Pro
    /// there and this conversion must not quietly restyle them.
    func tonoFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle,
        face: TonoFontFace = .rounded,
        maximumGrowth: CGFloat = TonoTypography.maximumTextGrowth
    ) -> some View {
        modifier(
            ScaledSystemFontModifier(
                size: size, weight: weight, face: face,
                textStyle: textStyle, maximumGrowth: maximumGrowth
            )
        )
    }

    /// A call site whose face is declared once, in `TonoTextStyle`, and applied
    /// here — so a test that reads the declaration is reading what ships.
    func tonoFont(_ style: TonoTextStyle) -> some View {
        modifier(
            ScaledSystemFontModifier(
                size: style.size, weight: style.weight, face: style.face,
                textStyle: style.textStyle, maximumGrowth: style.maximumGrowth
            )
        )
    }

    /// A decorative glyph or badge: same scaling, tighter ceiling.
    func tonoGlyphFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle,
        face: TonoFontFace = .rounded
    ) -> some View {
        modifier(
            ScaledSystemFontModifier(
                size: size,
                weight: weight,
                face: face,
                textStyle: textStyle,
                maximumGrowth: TonoTypography.maximumDecorativeGrowth
            )
        )
    }
}

/// A row of peer items that becomes a grid on a wide window and stays a plain
/// vertical stack on a narrow one.
struct AdaptiveItemGrid<Content: View>: View {
    var minimumItemWidth: CGFloat
    var spacing: CGFloat
    var maximumColumns: Int
    var itemAlignment: Alignment = .topLeading
    @ViewBuilder var content: () -> Content

    /// The shipping call sites use this initialiser, so the numbers a surface
    /// lays out with are the numbers `TonoGridSpec` declares and the tests read.
    init(
        _ spec: TonoGridSpec,
        itemAlignment: Alignment = .topLeading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.minimumItemWidth = spec.minimumItemWidth
        self.spacing = spec.spacing
        self.maximumColumns = spec.maximumColumns
        self.itemAlignment = itemAlignment
        self.content = content
    }

    /// Kept for probes that need an arbitrary minimum rather than a shipping
    /// one. No shipping call site uses it.
    init(
        minimumItemWidth: CGFloat,
        spacing: CGFloat,
        maximumColumns: Int,
        itemAlignment: Alignment = .topLeading,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.minimumItemWidth = minimumItemWidth
        self.spacing = spacing
        self.maximumColumns = maximumColumns
        self.itemAlignment = itemAlignment
        self.content = content
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        AdaptiveGridLayout(
            // A bigger type size needs a wider cell before a second column is
            // worth having, so the same growth that widens a column also makes
            // the grid collapse EARLIER. That is what keeps two columns from
            // clipping at accessibility sizes.
            minimumItemWidth: minimumItemWidth * TonoAdaptiveLayout.typeScale(dynamicTypeSize),
            spacing: spacing,
            maximumColumns: maximumColumns,
            itemAlignment: itemAlignment
        ) {
            content()
        }
    }
}

/// Sizes a modal card: the approved 340pt on a phone, a card proportionate to
/// the window on an iPad.
struct AdaptiveDialogWidth: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        DialogWidthLayout(dynamicTypeSize: dynamicTypeSize) { content }
    }
}

private struct DialogWidthLayout: Layout {
    var dynamicTypeSize: DynamicTypeSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = resolved(proposal.width)
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let width = resolved(proposal.width)
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.minY),
                anchor: .top,
                proposal: ProposedViewSize(width: width, height: nil)
            )
        }
    }

    private func resolved(_ available: CGFloat?) -> CGFloat {
        TonoAdaptiveLayout.dialogWidth(
            available: available ?? TonoAdaptiveLayout.compactDialogWidth,
            dynamicTypeSize: dynamicTypeSize
        )
    }
}

extension View {
    /// The Coach explainer card's width rule.
    func tonoDialogWidth() -> some View { modifier(AdaptiveDialogWidth()) }
}
