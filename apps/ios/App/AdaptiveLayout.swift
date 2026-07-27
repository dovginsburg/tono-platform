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
// origin*. That is not "close to" a no-op — it is the identity function, and
// `Build115AdaptiveLayoutTests` pins it at every iPhone portrait width across
// every Dynamic Type size.
//
// Because every cap here is wider than the widest iPhone portrait width
// (440pt on the 17 Pro Max), the identity branch is the only branch a phone in
// portrait can ever take. In landscape a large iPhone is 956pt wide and DOES
// take the capped branch — that is intentional, it is the same readable-measure
// treatment iOS gives long-form content, and it is captured in the runtime
// evidence rather than left as a surprise.
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

// MARK: - Typography

/// Dynamic-Type-aware sizing for the app's rounded face.
///
/// `Font.system(size:weight:design:)` does not scale, and `Font.custom(_:size:
/// relativeTo:)` cannot express the rounded design, so neither one alone can
/// keep both the approved look and Dynamic Type. This resolves the point size
/// against `UIFontMetrics` instead, which gives exactly the `relativeTo:`
/// behaviour with the design preserved.
///
/// The property that makes this safe to apply to approved screens: at the
/// DEFAULT content size the scaled value is the input value, so every converted
/// call site renders identically to the fixed-point one it replaced.
/// `testEveryConvertedSizeIsUnchangedAtTheDefaultContentSize` pins that.
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

private struct ScaledRoundedFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let textStyle: Font.TextStyle
    let maximumGrowth: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: TonoTypography.scaledSize(
                    size,
                    relativeTo: textStyle,
                    dynamicTypeSize: dynamicTypeSize,
                    maximumGrowth: maximumGrowth
                ),
                weight: weight,
                design: .rounded
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

    /// The app's rounded face at `size` points, scaling with Dynamic Type
    /// relative to `textStyle`. At the default content size this is exactly
    /// `.font(.system(size:weight:design: .rounded))` — the call it replaces.
    func tonoFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle,
        maximumGrowth: CGFloat = TonoTypography.maximumTextGrowth
    ) -> some View {
        modifier(
            ScaledRoundedFontModifier(
                size: size, weight: weight, textStyle: textStyle, maximumGrowth: maximumGrowth
            )
        )
    }

    /// A decorative glyph or badge: same scaling, tighter ceiling, no rounded
    /// design assumption beyond what `.system` already gives symbols.
    func tonoGlyphFont(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle) -> some View {
        modifier(
            ScaledRoundedFontModifier(
                size: size,
                weight: weight,
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
