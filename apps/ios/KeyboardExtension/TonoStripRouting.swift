// TonoStripRouting.swift
// Build 106 — physical finding #3: "tapping an autocorrect suggestion ran Tono
// Coach instead of accepting the word."
//
// ── The Build-105 defect, exactly ───────────────────────────────────────────
// The top strip had ONE row of three buttons that was time-shared between two
// semantically opposite roles:
//
//   * spelling candidates  → `candidateTapped(_:)`  (local text replacement)
//   * Coach tone chips     → `toneChipTapped(_:)`   (network rewrite)
//
// `setToneChipsEnabled(true)` mutated the live target/action table:
//
//     button.removeTarget(self, action: #selector(candidateTapped(_:)), ...)
//     button.addTarget(self,    action: #selector(toneChipTapped(_:)),  ...)
//
// and `setToneChipsEnabled(false)` did NOT undo it — it only repainted titles
// via `refreshSpellingSuggestions()`. So after ONE toggle of the TONO button
// the three buttons were permanently welded to Coach: every subsequent
// spelling-suggestion tap called `beginCoachRewrite`, spent a network request,
// and replaced the whole draft instead of the misspelled word. The strip
// *looked* like spelling because the titles were repainted; only the dispatch
// was wrong, which is why it survived source-level review and only appeared
// on device.
//
// ── The Build-106 contract ──────────────────────────────────────────────────
// Roles are no longer time-shared. Each role owns its own dedicated,
// permanently-targeted buttons, and this file holds the two invariants that
// make the defect unrepresentable:
//
//   1. STATIC TARGETS. A `TonoStripButton` is constructed with its role and its
//      selector, and neither is ever mutated afterwards. There is no
//      `removeTarget` / `addTarget` call anywhere on the strip after
//      construction, so no toggle sequence can leave a suggestion button
//      pointing at Coach.
//   2. ROLE-GATED DISPATCH. Both action handlers re-check `sender.stripRole`
//      against the mode the controller believes it is in
//      (`TonoStripRoutingPolicy`). A dispatch that disagrees with either the
//      button's own identity or the active mode is refused, so even a future
//      re-introduction of dynamic targeting cannot reach Coach from a
//      suggestion.
//
// Everything here is UIKit-light and pure so the routing decision itself is
// unit-testable without a host document.

import UIKit

/// What a top-strip button means. Fixed at construction; never mutated.
public enum TonoStripRole: String, Equatable, CaseIterable {
    /// Local, on-device spelling/autocorrect candidate. Accepting one performs
    /// exactly one bounded text replacement and makes zero network calls.
    case suggestion
    /// Coach tone chip. Tapping one starts exactly one network rewrite.
    case toneChip

    /// Stable accessibility-identifier stem, so a physical inspector (Accessibility
    /// Inspector / XCUITest) can tell the two roles apart on the running device.
    public var accessibilityStem: String {
        switch self {
        case .suggestion: return "TonoKB.suggestion"
        case .toneChip:   return "TonoKB.toneChip"
        }
    }

    public func accessibilityIdentifier(index: Int) -> String {
        "\(accessibilityStem).\(index)"
    }
}

/// Which role the strip is currently presenting. Exactly one at a time — the
/// two roles are never simultaneously visible or simultaneously hit-testable.
public enum TonoStripMode: String, Equatable {
    case suggestions
    case toneChips

    public var activeRole: TonoStripRole {
        switch self {
        case .suggestions: return .suggestion
        case .toneChips:   return .toneChip
        }
    }
}

/// The pure decision the two `@objc` handlers delegate to.
///
/// Kept separate from the controller so the exact Build-105 failure — a
/// suggestion-role tap arriving while the strip is in suggestion mode but
/// dispatched down the Coach selector — is expressible as a unit test with no
/// UIKit host, no proxy and no network.
public enum TonoStripRoutingPolicy {

    public enum Decision: Equatable {
        /// Perform the role's own action for the button at `index`.
        case perform(role: TonoStripRole, index: Int)
        /// Refuse. Carries a privacy-safe reason for logging — never text.
        case refuse(reason: Reason)
    }

    public enum Reason: String, Equatable {
        /// The button's own fixed role is not the role of the handler it reached.
        /// This is the Build-105 signature and must never occur in Build 106.
        case roleMismatch
        /// The button's role is not the role the strip is currently presenting.
        case inactiveMode
        /// The index has no backing value (stale strip, shrunk candidate list).
        case indexOutOfRange
        /// Coach is mid-flight; a second start would violate the 1:1 contract.
        case busy
    }

    /// The single gate every strip tap passes through.
    ///
    /// - Parameters:
    ///   - senderRole: role baked into the tapped button at construction.
    ///   - handlerRole: role of the `@objc` handler that received the tap.
    ///   - mode: what the controller is currently presenting.
    ///   - index: the button's fixed index within its own row.
    ///   - valueCount: how many values that role currently has.
    ///   - isBusy: Coach in flight (only consulted for `.toneChip`).
    public static func decide(
        senderRole: TonoStripRole,
        handlerRole: TonoStripRole,
        mode: TonoStripMode,
        index: Int,
        valueCount: Int,
        isBusy: Bool
    ) -> Decision {
        guard senderRole == handlerRole else { return .refuse(reason: .roleMismatch) }
        guard mode.activeRole == senderRole else { return .refuse(reason: .inactiveMode) }
        guard index >= 0, index < valueCount else { return .refuse(reason: .indexOutOfRange) }
        if senderRole == .toneChip, isBusy { return .refuse(reason: .busy) }
        return .perform(role: senderRole, index: index)
    }
}

/// A top-strip button whose role and index are immutable identity, not state.
///
/// `role` is `let`: it cannot be repurposed by a repaint, a rerender, or a mode
/// toggle. `stripIndex` replaces the old `tag`-based indexing so an unrelated
/// `tag` assignment elsewhere in the view tree can never be read as a candidate
/// index. `tag` is still mirrored for compatibility with existing geometry
/// tests, but nothing in the dispatch path reads it.
final class TonoStripButton: TonoMinimumHitTargetButton {

    let stripRole: TonoStripRole
    let stripIndex: Int

    init(role: TonoStripRole, index: Int) {
        self.stripRole = role
        self.stripIndex = index
        super.init(frame: .zero)
        tag = index
        accessibilityIdentifier = role.accessibilityIdentifier(index: index)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TonoStripButton is code-only; a coder-instantiated button would have no role")
    }
}

/// Geometry contract for the strip.
///
/// `TonoMinimumHitTargetButton` expands its hit rect to a 44pt minimum, so two
/// controls that look separated on screen can still overlap where touches are
/// actually resolved. That expanded-hit-area overlap is one of the ways a
/// near-miss on a suggestion could land on TONO, so the separation is a
/// reviewed constant with a test that checks the *expanded* rects, not the
/// drawn ones.
public enum TonoStripGeometry {

    /// Minimum gap in points between the Coach control and the first strip
    /// button, chosen so their 44pt-expanded hit rects stay disjoint.
    public static let coachSeparation: CGFloat = 10

    /// The hit rect `TonoMinimumHitTargetButton` actually resolves touches in.
    public static func expandedHitRect(
        for frame: CGRect,
        minimumTouchTarget: CGFloat
    ) -> CGRect {
        let dx = max(0, (minimumTouchTarget - frame.width) / 2)
        let dy = max(0, (minimumTouchTarget - frame.height) / 2)
        return frame.insetBy(dx: -dx, dy: -dy)
    }

    /// True when no two of `frames` share any touch point once expanded.
    public static func hitRectsAreDisjoint(
        _ frames: [CGRect],
        minimumTouchTarget: CGFloat
    ) -> Bool {
        let expanded = frames.map { expandedHitRect(for: $0, minimumTouchTarget: minimumTouchTarget) }
        for i in expanded.indices {
            for j in expanded.indices where j > i {
                if expanded[i].intersects(expanded[j]) { return false }
            }
        }
        return true
    }
}
