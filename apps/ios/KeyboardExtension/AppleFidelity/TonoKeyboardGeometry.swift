// TonoKeyboardGeometry.swift
// Build 97 — SwiftUI Apple-fidelity keyboard metrics.
//
// All numeric constants in one place so the SwiftUI keys and the existing
// UIKit TonoKeyboardMetrics (KeyboardExtension/TonoKeyboardVisualStyle.swift)
// stay in lockstep. Anything that drives a key's frame, hit target, or row
// offset must come through here — never hard-coded in a SwiftUI layout.
//
// Apple values measured from the system keyboard on iOS 26.5:
//   * keyMinHeight        = 44pt       (Apple minimum comfortable hit target)
//   * letterKeyWidth      = (usable - rowSpacing*9) / 10 at portrait widths
//   * row2HorizontalInset = (letterKeyWidth + rowSpacing) / 2   — half keycap
//                          so row 2 sits visually centered under row 1
//   * row3InnerGap        = max(8, letterKeyWidth * 0.34)        — matches iOS
//   * cornerRadius        = 5pt
//   * fontSize            = 22pt        (Apple system keyboard)
//   * rowSpacing          = 8pt
//   * edgePadding         = 4pt
//   * preferredHeight     = 256/264pt depending on width + 36pt Coach headroom
//
// Three portrait buckets mirror `TonoKeyboardMetrics.portrait(...)`:
//   width < 390  → 252pt typing + 36pt Coach = 288pt total
//   width ≥ 430  → 264pt typing + 36pt Coach = 300pt total
//   otherwise    → 256pt typing + 36pt Coach = 292pt total
//
// The SwiftUI layer respects the exact same numbers; the existing
// `KeyboardControlGeometryTests.testExportedControlGeometryMeetsTouchTarget`
// already asserts these on the UIKit side, and the new SwiftUI
// `Build97KeyboardGeometryTests` does the same on the SwiftUI side.

import Foundation
import CoreGraphics

/// Width-bucketed SwiftUI keyboard metrics that mirror `TonoKeyboardMetrics`.
/// Apple's portrait keyboard has three stable heights at the iPhone widths
/// Tono targets: 320pt (SE-class), 375/402pt (regular), 440pt (Plus/Max).
public enum TonoKeyboardLayoutMetrics {

    // Apple minimum comfortable touch target. Every key control pads out to
    // at least this in both axes even when the visible glyph is smaller.
    public static let minimumTouchTarget: CGFloat = 44

    public static let keyCornerRadius: CGFloat = 5
    public static let keyFontSize: CGFloat = 22
    public static let rowSpacing: CGFloat = 8
    public static let edgePadding: CGFloat = 4

    // Typing-row geometry — values mirror UIKit TonoKeyboardMetrics exactly.
    public static func preferredContentHeight(availableWidth: CGFloat) -> CGFloat {
        preferredTypingHeight(availableWidth: availableWidth) + 36
    }

    public static func preferredTypingHeight(availableWidth: CGFloat) -> CGFloat {
        if availableWidth < 390 { return 252 }
        if availableWidth >= 430 { return 264 }
        return 256
    }

    public static func letterKeyWidth(availableWidth: CGFloat) -> CGFloat {
        let usable = max(availableWidth - edgePadding * 2, 320)
        return (usable - rowSpacing * 9) / 10
    }

    /// Row 2 inset that matches Apple's half-keycap centering. This is the
    /// exact Apple visual offset — without it the A-L row sits flush left of
    /// Q-P instead of visually centered.
    public static func row2HorizontalInset(availableWidth: CGFloat) -> CGFloat {
        (letterKeyWidth(availableWidth: availableWidth) + rowSpacing) / 2
    }

    /// Row 3 inner gap between the shift key and the Z key. Apple uses
    /// ~letterKeyWidth * 0.34; we floor at 8pt so very narrow widths still
    /// keep a tappable shift.
    public static func row3InnerGap(availableWidth: CGFloat) -> CGFloat {
        max(8, letterKeyWidth(availableWidth: availableWidth) * 0.34)
    }

    // Bottom-row widths — Apple's portrait proportions.
    public static let modeToggleWidth: CGFloat = 46
    public static let globeButtonWidth: CGFloat = minimumTouchTarget
    public static let historyButtonWidth: CGFloat = minimumTouchTarget
    public static let backspaceWidth: CGFloat = 54
    public static let returnWidth: CGFloat = 72
    public static let coachWidth: CGFloat = 76
    public static let emojiButtonWidth: CGFloat = minimumTouchTarget
}

/// Standard three-layer navigation matrix. Apple ships exactly three
/// distinct layers and one navigation rule per layer:
///
///   letters  bottom `123`  → symbols-123
///   123      bottom `ABC`  → letters,         row3 button `#+=` → symbols-extended
///   #+=      bottom `ABC`  → letters,         row3 button `123` → symbols-123
///
/// Anything that walks the layer graph must use this — never hard-code a
/// label like "123" anywhere but here.
public enum TonoKeyboardLayer: String, CaseIterable, Equatable {
    case letters
    case numbersAndPunctuation    // user-visible label `123`
    case extendedSymbols          // user-visible label `#+=`

    /// The bottom-row label shown to toggle to the next layer.
    public var bottomToggleLabel: String {
        switch self {
        case .letters:                  return "123"
        case .numbersAndPunctuation:    return "ABC"
        case .extendedSymbols:          return "ABC"
        }
    }

    /// Optional row-3 label that flips between 123 and #+= while in the
    /// numeric branch. Returns nil for the letters layer (no row-3 swap).
    public var row3SwapLabel: String? {
        switch self {
        case .letters:                  return nil
        case .numbersAndPunctuation:    return "#+="
        case .extendedSymbols:          return "123"
        }
    }

    /// Layer that the bottom-row toggle resolves to. Reversible: pressing the
    /// toggle from any layer always returns to letters (matches Apple).
    public var bottomToggleTarget: TonoKeyboardLayer {
        switch self {
        case .letters:                  return .numbersAndPunctuation
        case .numbersAndPunctuation:    return .letters
        case .extendedSymbols:          return .letters
        }
    }

    /// Layer that the row-3 swap key resolves to. Only meaningful when
    /// `row3SwapLabel != nil`.
    public var row3SwapTarget: TonoKeyboardLayer {
        switch self {
        case .numbersAndPunctuation:    return .extendedSymbols
        case .extendedSymbols:          return .numbersAndPunctuation
        default:                        return self
        }
    }
}

/// Apple's three rows of letter/symbol keys. These are the canonical row
/// contents; the SwiftUI keyboard must use them verbatim (or symbols-mode
/// variants below) — never inline a row of letters.
public enum TonoKeyRows {

    public static let lettersRow1: [String] = ["q","w","e","r","t","y","u","i","o","p"]
    public static let lettersRow2: [String] = ["a","s","d","f","g","h","j","k","l"]
    public static let lettersRow3: [String] = ["z","x","c","v","b","n","m"]

    public static let numbersRow1: [String] = ["1","2","3","4","5","6","7","8","9","0"]
    public static let numbersRow2: [String] = ["-","/",":",";","(",")","$","&","@","\""]
    public static let numbersRow3: [String] = [".",",","?","!","'"]

    public static let symbolsRow1: [String] = ["[","]","{","}","#","%","^","*","+","="]
    public static let symbolsRow2: [String] = ["_","\\","|","~","<",">","€","£","¥","•"]
    public static let symbolsRow3: [String] = [".",",","?","!","'"]

    public static func rows(for layer: TonoKeyboardLayer) -> [[String]] {
        switch layer {
        case .letters:
            return [lettersRow1, lettersRow2, lettersRow3]
        case .numbersAndPunctuation:
            return [numbersRow1, numbersRow2, numbersRow3]
        case .extendedSymbols:
            return [symbolsRow1, symbolsRow2, symbolsRow3]
        }
    }
}

/// Apple's `UIInputViewController.handleInputModeList(from:with:)`
/// glue lives in UIKit, so the SwiftUI globe key routes its long-press
/// through a closure provided by the host view controller. `TonoGlobeAction`
/// captures the two intents cleanly: short tap = advance, long press =
/// show menu (the host decides the menu UI).
///
/// Not `Equatable` — it wraps two closures, which have no identity Swift can
/// compare. Geometry/state tests exercise the values it drives, not the value
/// itself.
public struct TonoGlobeAction {
    public let advance: () -> Void
    public let showInputModeList: () -> Void
    public init(advance: @escaping () -> Void, showInputModeList: @escaping () -> Void) {
        self.advance = advance
        self.showInputModeList = showInputModeList
    }
}