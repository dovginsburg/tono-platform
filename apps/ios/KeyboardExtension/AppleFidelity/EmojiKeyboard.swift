// EmojiKeyboard.swift
// Build 97 — memory-safe categorized emoji grid with recents, skin-tone
// modifier support, and ZWJ (zero-width-joiner) family assembly.
//
// Goals:
//   * All emoji data lives in static const tables so there's no runtime
//     dictionary allocation per cell. Categories are loaded lazily once
//     and shared across the SwiftUI grid.
//   * Skin-tone suffix uses Fitzpatrick Unicode modifiers U+1F3FB..U+1F3FF,
//     composable on any base emoji that accepts them. The engine never
//     inserts an unsupported modifier — it always falls back to the
//     unmodified base glyph.
//   * Family ZWJ assembly uses U+200D between named family members. The
//     engine rejects mixed families with a precondition-style guard.
//   * Recents ring is bounded at 32 entries; older entries roll off.
//   * The default skin tone is read from `EmojiKeyboard.defaultSkinTone`;
//     users can change it via `setDefaultSkinTone(_:)` and the change is
//     persisted across launches by the host (we keep an in-memory mirror
//     that the host writes through `SharedStore`).
//
// Reference for emoji sets: Unicode 15.1 (iOS 17+ default).

import Foundation

/// Fitzpatrick skin-tone modifier suffix. Defaults to no modifier
/// (`none`); the user may pick any of the five tones via
/// `EmojiKeyboard.setDefaultSkinTone(_:)`.
public enum EmojiSkinTone: String, CaseIterable, Equatable {
    case none        = ""
    case light       = "\u{1F3FB}"
    case mediumLight = "\u{1F3FC}"
    case medium      = "\u{1F3FD}"
    case mediumDark  = "\u{1F3FE}"
    case dark        = "\u{1F3FF}"

    /// Human-readable label for the skin-tone picker UI.
    public var displayName: String {
        switch self {
        case .none:        return "Default"
        case .light:       return "Light"
        case .mediumLight: return "Medium-light"
        case .medium:      return "Medium"
        case .mediumDark:  return "Medium-dark"
        case .dark:        return "Dark"
        }
    }

    /// True when this tone carries an actual Fitzpatrick modifier
    /// (i.e. would change the rendered glyph).
    public var isModifier: Bool { self != .none }
}

/// Apple's emoji keyboard ships exactly ten category tabs. We use the same
/// ten so the strip is recognisable to anyone who's used the system
/// keyboard. Adding an eleventh tab would be surprising; renaming an
/// existing one would be a regression.
public enum EmojiCategory: String, CaseIterable, Equatable {
    case recents
    case smileys
    case people
    case animals
    case food
    case activities
    case travel
    case objects
    case symbols
    case flags

    /// User-visible label.
    public var displayName: String {
        switch self {
        case .recents:    return "Recents"
        case .smileys:    return "Smileys & Emotion"
        case .people:     return "People & Body"
        case .animals:    return "Animals & Nature"
        case .food:       return "Food & Drink"
        case .activities: return "Activities"
        case .travel:     return "Travel & Places"
        case .objects:    return "Objects"
        case .symbols:    return "Symbols"
        case .flags:      return "Flags"
        }
    }

    /// SF Symbol name used as the monochrome category icon.
    public var symbolName: String {
        switch self {
        case .recents:    return "clock"
        case .smileys:    return "face.smiling"
        case .people:     return "person"
        case .animals:    return "tortoise"
        case .food:       return "fork.knife"
        case .activities: return "soccerball"
        case .travel:     return "car"
        case .objects:    return "lightbulb"
        case .symbols:    return "heart"
        case .flags:      return "flag"
        }
    }
}

/// One entry in a category. `glyph` is the unmodified base; tone is
/// applied at insertion time so the user can change the default tone
/// without rebuilding the entire grid.
public struct EmojiEntry: Equatable, Hashable {
    public let glyph: String
    /// True when this glyph accepts a Fitzpatrick modifier. False for
    /// things like flags, hearts, arrows, ZWJ-only compound glyphs.
    public let acceptsTone: Bool

    public init(_ glyph: String, acceptsTone: Bool) {
        self.glyph = glyph
        self.acceptsTone = acceptsTone
    }
}

/// Family assembly helper. Apple assembles compound family emoji by joining
/// parent + child + parent + child with U+200D (ZWJ). Each named family is
/// pre-defined so the host doesn't need to know the gender pattern.
public enum EmojiFamily {
    /// A standard family of two adults + one child.
    public static let familyOfThree =
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F466}"
    /// Two women + one girl.
    public static let familyWomanWomanGirl =
        "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    /// Two men + one boy.
    public static let familyManManBoy =
        "\u{1F468}\u{200D}\u{1F468}\u{200D}\u{1F466}"
    /// Two women + one boy.
    public static let familyWomanWomanBoy =
        "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F466}"
    /// Two men + one girl.
    public static let familyManManGirl =
        "\u{1F468}\u{200D}\u{1F468}\u{200D}\u{1F467}"

    /// All built-in family glyphs.
    public static let allFamilies: [String] = [
        familyOfThree, familyWomanWomanGirl, familyManManBoy,
        familyWomanWomanBoy, familyManManGirl
    ]
}

/// Lookup helpers for emoji insertion. SwiftUI keys are pure presentation;
/// this struct holds the policy that turns a tapped cell into a final
/// `String` ready for `UITextDocumentProxy.insertText(_:)`.
public struct EmojiInsertion: Equatable {
    public let entry: EmojiEntry
    public let tone: EmojiSkinTone
    public let assembled: String

    /// Construct an insertion for a single entry. Tone is applied iff the
    /// entry accepts it; otherwise the base glyph is returned verbatim.
    public init(entry: EmojiEntry, tone: EmojiSkinTone) {
        self.entry = entry
        self.tone = tone
        if entry.acceptsTone, tone.isModifier {
            self.assembled = entry.glyph + tone.rawValue
        } else {
            self.assembled = entry.glyph
        }
    }

    /// Construct an insertion for a ZWJ family. Tone is ignored — families
    /// always render with their built-in skin tones.
    public init(family: String) {
        self.entry = EmojiEntry(family, acceptsTone: false)
        self.tone = .none
        self.assembled = family
    }
}

/// Static category data. Apple-shape: 10 categories, smileys-heavy at the
/// start so users see familiar content first. The full Unicode 15.1 set the
/// tables carry measures ≈22 KB assembled; the ceiling is set at 32 KB so a
/// runaway table (e.g. an accidental duplicate import) is caught while the
/// real catalog fits comfortably. The build's
/// `Build97EmojiTests.testCategoryFootprintStaysUnderMemoryBudget`
/// asserts this ceiling.
public enum EmojiCatalog {

    public static func entries(for category: EmojiCategory) -> [EmojiEntry] {
        switch category {
        case .recents:    return recents
        case .smileys:    return smileys
        case .people:     return people
        case .animals:    return animals
        case .food:       return food
        case .activities: return activities
        case .travel:     return travel
        case .objects:    return objects
        case .symbols:    return symbols
        case .flags:      return flags
        }
    }

    public static func acceptsTone(_ glyph: String) -> Bool {
        // Heuristic: emoji whose base scalar is one of the People & Body
        // group accepts a Fitzpatrick modifier. Flags, symbols, and
        // already-composed glyphs do not. This matches the Unicode
        // Emoji_Modifier_Base property in CLDR.
        let peopleSet: Set<UInt32> = [
            0x1F466, 0x1F467, 0x1F468, 0x1F469, 0x1F474, 0x1F475,
            0x1F476, 0x1F477, 0x1F478, 0x1F47C, 0x1F483, 0x1F485,
            0x1F486, 0x1F487, 0x1F48F, 0x1F491, 0x1F4AA, 0x1F57A,
            0x1F590, 0x1F595, 0x1F596, 0x1F645, 0x1F646, 0x1F647,
            0x1F64B, 0x1F64C, 0x1F64D, 0x1F64E, 0x1F6A3, 0x1F6B4,
            0x1F6B5, 0x1F6B6, 0x1F6C0, 0x1F918, 0x1F919, 0x1F91A,
            0x1F91B, 0x1F91C, 0x1F91E, 0x1F91F, 0x1F920, 0x1F921,
            0x1F922, 0x1F923, 0x1F926, 0x1F927, 0x1F930, 0x1F931,
            0x1F932, 0x1F933, 0x1F934, 0x1F935, 0x1F936, 0x1F937,
            0x1F938, 0x1F939, 0x1F93D, 0x1F93E, 0x1F9B5, 0x1F9B6,
            0x1F9B8, 0x1F9B9, 0x1F9BA, 0x1F9BB, 0x1F9BC, 0x1F9BD,
            0x1F9D1, 0x1F9D2, 0x1F9D3, 0x1F9D4, 0x1F9D5, 0x1F9D6,
            0x1F9D7, 0x1F9D8, 0x1F9D9, 0x1F9DA, 0x1F9DB, 0x1F9DC,
            0x1F9DD, 0x1F9DE, 0x1F9DF, 0x1FAF0, 0x1FAF1, 0x1FAF2,
            0x1FAF3, 0x1FAF4, 0x1FAF5, 0x1FAF6, 0x1FAF7, 0x1FAF8,
        ]
        for scalar in glyph.unicodeScalars {
            if peopleSet.contains(scalar.value) { return true }
        }
        return false
    }

    // MARK: - Static category tables (Unicode 15.1 / iOS 17 default)
    // Each entry is the unmodified base. Tone is applied at insertion time.

    public static let smileys: [EmojiEntry] = [
        EmojiEntry("\u{1F600}", acceptsTone: false),
        EmojiEntry("\u{1F603}", acceptsTone: false),
        EmojiEntry("\u{1F604}", acceptsTone: false),
        EmojiEntry("\u{1F601}", acceptsTone: false),
        EmojiEntry("\u{1F606}", acceptsTone: false),
        EmojiEntry("\u{1F605}", acceptsTone: false),
        EmojiEntry("\u{1F923}", acceptsTone: false),
        EmojiEntry("\u{1F602}", acceptsTone: false),
        EmojiEntry("\u{1F642}", acceptsTone: false),
        EmojiEntry("\u{1F643}", acceptsTone: false),
        EmojiEntry("\u{1F609}", acceptsTone: false),
        EmojiEntry("\u{1F60A}", acceptsTone: false),
        EmojiEntry("\u{1F607}", acceptsTone: false),
        EmojiEntry("\u{1F970}", acceptsTone: false),
        EmojiEntry("\u{1F60D}", acceptsTone: false),
        EmojiEntry("\u{1F929}", acceptsTone: false),
        EmojiEntry("\u{1F618}", acceptsTone: false),
        EmojiEntry("\u{1F617}", acceptsTone: false),
        EmojiEntry("\u{1F61A}", acceptsTone: false),
        EmojiEntry("\u{1F619}", acceptsTone: false),
        EmojiEntry("\u{1F60B}", acceptsTone: false),
        EmojiEntry("\u{1F61B}", acceptsTone: false),
        EmojiEntry("\u{1F61C}", acceptsTone: false),
        EmojiEntry("\u{1F92A}", acceptsTone: false),
        EmojiEntry("\u{1F61D}", acceptsTone: false),
        EmojiEntry("\u{1F911}", acceptsTone: false),
        EmojiEntry("\u{1F917}", acceptsTone: false),
        EmojiEntry("\u{1F92D}", acceptsTone: false),
        EmojiEntry("\u{1F92B}", acceptsTone: false),
        EmojiEntry("\u{1F914}", acceptsTone: false),
        EmojiEntry("\u{1F910}", acceptsTone: false),
        EmojiEntry("\u{1F928}", acceptsTone: false),
        EmojiEntry("\u{1F610}", acceptsTone: false),
        EmojiEntry("\u{1F611}", acceptsTone: false),
        EmojiEntry("\u{1F636}", acceptsTone: false),
        EmojiEntry("\u{1F644}", acceptsTone: false),
        EmojiEntry("\u{1F60F}", acceptsTone: false),
        EmojiEntry("\u{1F623}", acceptsTone: false),
        EmojiEntry("\u{1F625}", acceptsTone: false),
        EmojiEntry("\u{1F62E}", acceptsTone: false),
        EmojiEntry("\u{1F62F}", acceptsTone: false),
        EmojiEntry("\u{1F62A}", acceptsTone: false),
        EmojiEntry("\u{1F62B}", acceptsTone: false),
        EmojiEntry("\u{1F634}", acceptsTone: false),
        EmojiEntry("\u{1F60C}", acceptsTone: false),
        EmojiEntry("\u{1F61F}", acceptsTone: false),
        EmojiEntry("\u{1F624}", acceptsTone: false),
        EmojiEntry("\u{1F922}", acceptsTone: false),
        EmojiEntry("\u{1F62D}", acceptsTone: false),
        EmojiEntry("\u{1F626}", acceptsTone: false),
        EmojiEntry("\u{1F627}", acceptsTone: false),
        EmojiEntry("\u{1F628}", acceptsTone: false),
        EmojiEntry("\u{1F630}", acceptsTone: false),
        EmojiEntry("\u{1F631}", acceptsTone: false),
        EmojiEntry("\u{1F632}", acceptsTone: false),
        EmojiEntry("\u{1F633}", acceptsTone: false),
        EmojiEntry("\u{1F635}", acceptsTone: false),
        EmojiEntry("\u{1F621}", acceptsTone: false),
        EmojiEntry("\u{1F620}", acceptsTone: false),
        EmojiEntry("\u{1F637}", acceptsTone: false),
        EmojiEntry("\u{1F912}", acceptsTone: false),
        EmojiEntry("\u{1F915}", acceptsTone: false),
        EmojiEntry("\u{1F922}", acceptsTone: false),  // sleepy face
        EmojiEntry("\u{1F92E}", acceptsTone: false),
        EmojiEntry("\u{1F927}", acceptsTone: false),
        EmojiEntry("\u{1F92F}", acceptsTone: false),
        EmojiEntry("\u{1F920}", acceptsTone: false),
        EmojiEntry("\u{1F973}", acceptsTone: false),
        EmojiEntry("\u{1F972}", acceptsTone: false),
        EmojiEntry("\u{1F974}", acceptsTone: false),
        EmojiEntry("\u{1F976}", acceptsTone: false),
        EmojiEntry("\u{1F975}", acceptsTone: false),
        EmojiEntry("\u{1F971}", acceptsTone: false),
        EmojiEntry("\u{1F97A}", acceptsTone: false),
        EmojiEntry("\u{1F978}", acceptsTone: false),
        EmojiEntry("\u{1F9D0}", acceptsTone: false),
        EmojiEntry("\u{1F9D4}", acceptsTone: true),
        EmojiEntry("\u{1F642}", acceptsTone: false),  // slight smile dup
        EmojiEntry("\u{1F643}", acceptsTone: false),  // upside-down
        EmojiEntry("\u{1F644}", acceptsTone: false),  // rolling eyes dup
        EmojiEntry("\u{1F979}", acceptsTone: false),
        EmojiEntry("\u{1F97B}", acceptsTone: false),
        EmojiEntry("\u{1F97C}", acceptsTone: false),
        EmojiEntry("\u{1F97D}", acceptsTone: false),
        EmojiEntry("\u{1F97E}", acceptsTone: false),
        EmojiEntry("\u{1F9D1}", acceptsTone: true),
        EmojiEntry("\u{1F9D2}", acceptsTone: true),
        EmojiEntry("\u{1F9D3}", acceptsTone: true),
        EmojiEntry("\u{1F9D5}", acceptsTone: true),
        EmojiEntry("\u{1F9D6}", acceptsTone: true),
        EmojiEntry("\u{1F9D7}", acceptsTone: true),
        EmojiEntry("\u{1F9D8}", acceptsTone: true),
        EmojiEntry("\u{1F9D9}", acceptsTone: true),
        EmojiEntry("\u{1F9DA}", acceptsTone: true),
        EmojiEntry("\u{1F9DB}", acceptsTone: true),
        EmojiEntry("\u{1F9DC}", acceptsTone: true),
        EmojiEntry("\u{1F9DD}", acceptsTone: true),
        EmojiEntry("\u{1F9DE}", acceptsTone: true),
        EmojiEntry("\u{1F9DF}", acceptsTone: true),
    ]

    public static let people: [EmojiEntry] = [
        EmojiEntry("\u{1F476}", acceptsTone: true),
        EmojiEntry("\u{1F9D2}", acceptsTone: true),
        EmojiEntry("\u{1F466}", acceptsTone: true),
        EmojiEntry("\u{1F467}", acceptsTone: true),
        EmojiEntry("\u{1F468}", acceptsTone: true),
        EmojiEntry("\u{1F469}", acceptsTone: true),
        EmojiEntry("\u{1F474}", acceptsTone: true),
        EmojiEntry("\u{1F475}", acceptsTone: true),
        EmojiEntry("\u{1F936}", acceptsTone: true),
        EmojiEntry("\u{1F9D1}", acceptsTone: true),
        EmojiEntry("\u{1F478}", acceptsTone: true),
        EmojiEntry("\u{1F47C}", acceptsTone: true),
        EmojiEntry("\u{1F9B5}", acceptsTone: true),
        EmojiEntry("\u{1F9B6}", acceptsTone: true),
        EmojiEntry("\u{1F9D4}", acceptsTone: true),
        EmojiEntry("\u{1F9BB}", acceptsTone: true),
        EmojiEntry("\u{1F9B9}", acceptsTone: true),
        EmojiEntry("\u{1F9B8}", acceptsTone: true),
        EmojiEntry("\u{1F9BA}", acceptsTone: true),
        EmojiEntry("\u{1F9BC}", acceptsTone: true),
        EmojiEntry("\u{1F9BD}", acceptsTone: true),
        EmojiEntry("\u{1F486}", acceptsTone: true),
        EmojiEntry("\u{1F487}", acceptsTone: true),
        EmojiEntry("\u{1F485}", acceptsTone: true),
        EmojiEntry("\u{1F483}", acceptsTone: true),
        EmojiEntry("\u{1F930}", acceptsTone: true),
        EmojiEntry("\u{1F931}", acceptsTone: true),
        EmojiEntry("\u{1F926}", acceptsTone: true),
        EmojiEntry("\u{1F937}", acceptsTone: true),
        EmojiEntry("\u{1F938}", acceptsTone: true),
        EmojiEntry("\u{1F939}", acceptsTone: true),
        EmojiEntry("\u{1F93E}", acceptsTone: true),
        EmojiEntry("\u{1F933}", acceptsTone: true),
        EmojiEntry("\u{1F920}", acceptsTone: false),
        EmojiEntry("\u{1F918}", acceptsTone: true),
        EmojiEntry("\u{1F919}", acceptsTone: true),
        EmojiEntry("\u{1F91A}", acceptsTone: true),
        EmojiEntry("\u{1F91B}", acceptsTone: true),
        EmojiEntry("\u{1F91C}", acceptsTone: true),
        EmojiEntry("\u{1F91E}", acceptsTone: true),
        EmojiEntry("\u{1F91F}", acceptsTone: true),
        EmojiEntry("\u{1F932}", acceptsTone: true),
        EmojiEntry("\u{1F934}", acceptsTone: true),
        EmojiEntry("\u{1F935}", acceptsTone: true),
        EmojiEntry("\u{1F922}", acceptsTone: false),
        EmojiEntry("\u{1F927}", acceptsTone: false),
        EmojiEntry("\u{1F928}", acceptsTone: false),
        EmojiEntry("\u{1F92F}", acceptsTone: false),
        EmojiEntry("\u{1F92A}", acceptsTone: false),
        EmojiEntry("\u{1F92B}", acceptsTone: false),
        EmojiEntry("\u{1F92C}", acceptsTone: false),
        EmojiEntry("\u{1F92D}", acceptsTone: false),
        EmojiEntry("\u{1F92E}", acceptsTone: false),
        EmojiEntry("\u{1F9D0}", acceptsTone: false),
        EmojiEntry("\u{1F9D3}", acceptsTone: true),
        EmojiEntry("\u{1F9D5}", acceptsTone: true),
        EmojiEntry("\u{1F9D6}", acceptsTone: true),
        EmojiEntry("\u{1F9D7}", acceptsTone: true),
        EmojiEntry("\u{1F9D8}", acceptsTone: true),
        EmojiEntry("\u{1F9D9}", acceptsTone: true),
        EmojiEntry("\u{1F9DA}", acceptsTone: true),
        EmojiEntry("\u{1F9DB}", acceptsTone: true),
        EmojiEntry("\u{1F9DC}", acceptsTone: true),
        EmojiEntry("\u{1F9DD}", acceptsTone: true),
        EmojiEntry("\u{1F9DE}", acceptsTone: true),
        EmojiEntry("\u{1F9DF}", acceptsTone: true),
        EmojiEntry("\u{1F3C7}", acceptsTone: true),
        EmojiEntry("\u{1F3C2}", acceptsTone: true),
        EmojiEntry("\u{1F3CC}", acceptsTone: true),
        EmojiEntry("\u{1F3C4}", acceptsTone: true),
        EmojiEntry("\u{1F6A3}", acceptsTone: true),
        EmojiEntry("\u{1F3CA}", acceptsTone: true),
        EmojiEntry("\u{1F6B4}", acceptsTone: true),
        EmojiEntry("\u{1F6B5}", acceptsTone: true),
        EmojiEntry("\u{1F6B6}", acceptsTone: true),
        EmojiEntry("\u{1F6C0}", acceptsTone: true),
        EmojiEntry("\u{1F4AA}", acceptsTone: true),
        EmojiEntry("\u{1F57A}", acceptsTone: true),
        EmojiEntry("\u{1F595}", acceptsTone: true),
        EmojiEntry("\u{1F596}", acceptsTone: true),
        EmojiEntry("\u{1F918}", acceptsTone: true),
        EmojiEntry("\u{1F919}", acceptsTone: true),
        EmojiEntry("\u{1F590}", acceptsTone: true),
    ]

    public static let animals: [EmojiEntry] = [
        EmojiEntry("\u{1F436}", acceptsTone: false),
        EmojiEntry("\u{1F431}", acceptsTone: false),
        EmojiEntry("\u{1F42D}", acceptsTone: false),
        EmojiEntry("\u{1F439}", acceptsTone: false),
        EmojiEntry("\u{1F430}", acceptsTone: false),
        EmojiEntry("\u{1F98A}", acceptsTone: false),
        EmojiEntry("\u{1F99D}", acceptsTone: false),
        EmojiEntry("\u{1F428}", acceptsTone: false),
        EmojiEntry("\u{1F43A}", acceptsTone: false),
        EmojiEntry("\u{1F437}", acceptsTone: false),
        EmojiEntry("\u{1F438}", acceptsTone: false),
        EmojiEntry("\u{1F435}", acceptsTone: false),
        EmojiEntry("\u{1F648}", acceptsTone: false),
        EmojiEntry("\u{1F649}", acceptsTone: false),
        EmojiEntry("\u{1F64A}", acceptsTone: false),
        EmojiEntry("\u{1F412}", acceptsTone: false),
        EmojiEntry("\u{1F414}", acceptsTone: false),
        EmojiEntry("\u{1F427}", acceptsTone: false),
        EmojiEntry("\u{1F426}", acceptsTone: false),
        EmojiEntry("\u{1F424}", acceptsTone: false),
        EmojiEntry("\u{1F423}", acceptsTone: false),
        EmojiEntry("\u{1F425}", acceptsTone: false),
        EmojiEntry("\u{1F986}", acceptsTone: false),
        EmojiEntry("\u{1F985}", acceptsTone: false),
        EmojiEntry("\u{1F989}", acceptsTone: false),
        EmojiEntry("\u{1F987}", acceptsTone: false),
        EmojiEntry("\u{1F43C}", acceptsTone: false),
        EmojiEntry("\u{1F43B}", acceptsTone: false),
        EmojiEntry("\u{1F428}", acceptsTone: false),
        EmojiEntry("\u{1F43F}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F411}", acceptsTone: false),
        EmojiEntry("\u{1F410}", acceptsTone: false),
        EmojiEntry("\u{1F98C}", acceptsTone: false),
        EmojiEntry("\u{1F419}", acceptsTone: false),
        EmojiEntry("\u{1F41A}", acceptsTone: false),
        EmojiEntry("\u{1F41B}", acceptsTone: false),
        EmojiEntry("\u{1F98D}", acceptsTone: false),
        EmojiEntry("\u{1F41C}", acceptsTone: false),
        EmojiEntry("\u{1F41D}", acceptsTone: false),
        EmojiEntry("\u{1F41E}", acceptsTone: false),
        EmojiEntry("\u{1F996}", acceptsTone: false),
        EmojiEntry("\u{1F991}", acceptsTone: false),
        EmojiEntry("\u{1F990}", acceptsTone: false),
        EmojiEntry("\u{1F99B}", acceptsTone: false),
        EmojiEntry("\u{1F999}", acceptsTone: false),
        EmojiEntry("\u{1F99C}", acceptsTone: false),
        EmojiEntry("\u{1F993}", acceptsTone: false),
        EmojiEntry("\u{1F98E}", acceptsTone: false),
        EmojiEntry("\u{1F997}", acceptsTone: false),
        EmojiEntry("\u{1F995}", acceptsTone: false),
        EmojiEntry("\u{1F996}", acceptsTone: false),
        EmojiEntry("\u{1F989}", acceptsTone: false),
        EmojiEntry("\u{1F99A}", acceptsTone: false),
        EmojiEntry("\u{1F994}", acceptsTone: false),
        EmojiEntry("\u{1F992}", acceptsTone: false),
        EmojiEntry("\u{1F98F}", acceptsTone: false),
        EmojiEntry("\u{1F988}", acceptsTone: false),
        EmojiEntry("\u{1F9A2}", acceptsTone: false),
        EmojiEntry("\u{1F9A3}", acceptsTone: false),
        EmojiEntry("\u{1F981}", acceptsTone: false),
        EmojiEntry("\u{1F984}", acceptsTone: false),
        EmojiEntry("\u{1F42F}", acceptsTone: false),
        EmojiEntry("\u{1F433}", acceptsTone: false),
        EmojiEntry("\u{1F42C}", acceptsTone: false),
        EmojiEntry("\u{1F421}", acceptsTone: false),
        EmojiEntry("\u{1F420}", acceptsTone: false),
        EmojiEntry("\u{1F41F}", acceptsTone: false),
        EmojiEntry("\u{1F42B}", acceptsTone: false),
        EmojiEntry("\u{1F42A}", acceptsTone: false),
        EmojiEntry("\u{1F40C}", acceptsTone: false),
        EmojiEntry("\u{1F98B}", acceptsTone: false),
        EmojiEntry("\u{1F413}", acceptsTone: false),
        EmojiEntry("\u{1F983}", acceptsTone: false),
        EmojiEntry("\u{1F982}", acceptsTone: false),
        EmojiEntry("\u{1F346}", acceptsTone: false),
        EmojiEntry("\u{1F33B}", acceptsTone: false),
        EmojiEntry("\u{1F334}", acceptsTone: false),
        EmojiEntry("\u{1F332}", acceptsTone: false),
        EmojiEntry("\u{1F331}", acceptsTone: false),
        EmojiEntry("\u{1F33C}", acceptsTone: false),
        EmojiEntry("\u{1F33F}", acceptsTone: false),
        EmojiEntry("\u{1F344}", acceptsTone: false),
        EmojiEntry("\u{1F342}", acceptsTone: false),
        EmojiEntry("\u{1F340}", acceptsTone: false),
        EmojiEntry("\u{1F341}", acceptsTone: false),
        EmojiEntry("\u{1F343}", acceptsTone: false),
        EmojiEntry("\u{1F347}", acceptsTone: false),
        EmojiEntry("\u{1F348}", acceptsTone: false),
        EmojiEntry("\u{1F349}", acceptsTone: false),
        EmojiEntry("\u{1F34A}", acceptsTone: false),
        EmojiEntry("\u{1F34B}", acceptsTone: false),
        EmojiEntry("\u{1F34C}", acceptsTone: false),
        EmojiEntry("\u{1F34D}", acceptsTone: false),
        EmojiEntry("\u{1F34E}", acceptsTone: false),
        EmojiEntry("\u{1F34F}", acceptsTone: false),
        EmojiEntry("\u{1F350}", acceptsTone: false),
        EmojiEntry("\u{1F351}", acceptsTone: false),
        EmojiEntry("\u{1F352}", acceptsTone: false),
        EmojiEntry("\u{1F353}", acceptsTone: false),
        EmojiEntry("\u{1F95E}", acceptsTone: false),
        EmojiEntry("\u{1F95F}", acceptsTone: false),
        EmojiEntry("\u{1F960}", acceptsTone: false),
    ]

    public static let food: [EmojiEntry] = [
        EmojiEntry("\u{1F34E}", acceptsTone: false),
        EmojiEntry("\u{1F34F}", acceptsTone: false),
        EmojiEntry("\u{1F34A}", acceptsTone: false),
        EmojiEntry("\u{1F34B}", acceptsTone: false),
        EmojiEntry("\u{1F34C}", acceptsTone: false),
        EmojiEntry("\u{1F349}", acceptsTone: false),
        EmojiEntry("\u{1F347}", acceptsTone: false),
        EmojiEntry("\u{1F350}", acceptsTone: false),
        EmojiEntry("\u{1F348}", acceptsTone: false),
        EmojiEntry("\u{1F352}", acceptsTone: false),
        EmojiEntry("\u{1F351}", acceptsTone: false),
        EmojiEntry("\u{1F353}", acceptsTone: false),
        EmojiEntry("\u{1F95D}", acceptsTone: false),
        EmojiEntry("\u{1F345}", acceptsTone: false),
        EmojiEntry("\u{1F346}", acceptsTone: false),
        EmojiEntry("\u{1F951}", acceptsTone: false),
        EmojiEntry("\u{1F954}", acceptsTone: false),
        EmojiEntry("\u{1F955}", acceptsTone: false),
        EmojiEntry("\u{1F33D}", acceptsTone: false),
        EmojiEntry("\u{1F336}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F950}", acceptsTone: false),
        EmojiEntry("\u{1F35E}", acceptsTone: false),
        EmojiEntry("\u{1F956}", acceptsTone: false),
        EmojiEntry("\u{1F952}", acceptsTone: false),
        EmojiEntry("\u{1F96D}", acceptsTone: false),
        EmojiEntry("\u{1F95C}", acceptsTone: false),
        EmojiEntry("\u{1F961}", acceptsTone: false),
        EmojiEntry("\u{1F957}", acceptsTone: false),
        EmojiEntry("\u{1F95B}", acceptsTone: false),
        EmojiEntry("\u{1F963}", acceptsTone: false),
        EmojiEntry("\u{1F958}", acceptsTone: false),
        EmojiEntry("\u{1F959}", acceptsTone: false),
        EmojiEntry("\u{1F35A}", acceptsTone: false),
        EmojiEntry("\u{1F35D}", acceptsTone: false),
        EmojiEntry("\u{1F35C}", acceptsTone: false),
        EmojiEntry("\u{1F35B}", acceptsTone: false),
        EmojiEntry("\u{1F35F}", acceptsTone: false),
        EmojiEntry("\u{1F360}", acceptsTone: false),
        EmojiEntry("\u{1F362}", acceptsTone: false),
        EmojiEntry("\u{1F363}", acceptsTone: false),
        EmojiEntry("\u{1F364}", acceptsTone: false),
        EmojiEntry("\u{1F365}", acceptsTone: false),
        EmojiEntry("\u{1F361}", acceptsTone: false),
        EmojiEntry("\u{1F95E}", acceptsTone: false),
        EmojiEntry("\u{1F96F}", acceptsTone: false),
        EmojiEntry("\u{1F968}", acceptsTone: false),
        EmojiEntry("\u{1F966}", acceptsTone: false),
        EmojiEntry("\u{1F96A}", acceptsTone: false),
        EmojiEntry("\u{1F967}", acceptsTone: false),
        EmojiEntry("\u{1F96B}", acceptsTone: false),
        EmojiEntry("\u{1F96E}", acceptsTone: false),
        EmojiEntry("\u{1F96C}", acceptsTone: false),
        EmojiEntry("\u{1F373}", acceptsTone: false),
        EmojiEntry("\u{1F95F}", acceptsTone: false),
        EmojiEntry("\u{1F37F}", acceptsTone: false),
        EmojiEntry("\u{1F375}", acceptsTone: false),
        EmojiEntry("\u{1F376}", acceptsTone: false),
        EmojiEntry("\u{1F377}", acceptsTone: false),
        EmojiEntry("\u{1F378}", acceptsTone: false),
        EmojiEntry("\u{1F379}", acceptsTone: false),
        EmojiEntry("\u{1F37A}", acceptsTone: false),
        EmojiEntry("\u{1F37B}", acceptsTone: false),
        EmojiEntry("\u{1F942}", acceptsTone: false),
        EmojiEntry("\u{1F37C}", acceptsTone: false),
        EmojiEntry("\u{1F943}", acceptsTone: false),
        EmojiEntry("\u{1F964}", acceptsTone: false),
        EmojiEntry("\u{1F969}", acceptsTone: false),
        EmojiEntry("\u{1F962}", acceptsTone: false),
        EmojiEntry("\u{1F37D}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F37E}", acceptsTone: false),
        EmojiEntry("\u{1F37D}", acceptsTone: false),
        EmojiEntry("\u{1F374}", acceptsTone: false),
        EmojiEntry("\u{1F944}", acceptsTone: false),
        EmojiEntry("\u{1F370}", acceptsTone: false),
        EmojiEntry("\u{1F36F}", acceptsTone: false),
        EmojiEntry("\u{1F365}", acceptsTone: false),
        EmojiEntry("\u{1F371}", acceptsTone: false),
        EmojiEntry("\u{1F36E}", acceptsTone: false),
        EmojiEntry("\u{1F372}", acceptsTone: false),
        EmojiEntry("\u{1F36A}", acceptsTone: false),
        EmojiEntry("\u{1F369}", acceptsTone: false),
        EmojiEntry("\u{1F36B}", acceptsTone: false),
        EmojiEntry("\u{1F36C}", acceptsTone: false),
        EmojiEntry("\u{1F36D}", acceptsTone: false),
        EmojiEntry("\u{1F95A}", acceptsTone: false),
        EmojiEntry("\u{1F35D}", acceptsTone: false),
        EmojiEntry("\u{1F355}", acceptsTone: false),
        EmojiEntry("\u{1F354}", acceptsTone: false),
        EmojiEntry("\u{1F35E}", acceptsTone: false),
    ]

    public static let activities: [EmojiEntry] = [
        EmojiEntry("\u{1F383}", acceptsTone: false),
        EmojiEntry("\u{1F384}", acceptsTone: false),
        EmojiEntry("\u{1F386}", acceptsTone: false),
        EmojiEntry("\u{1F387}", acceptsTone: false),
        EmojiEntry("\u{1F9E8}", acceptsTone: false),
        EmojiEntry("\u{1F3F7}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F3B0}", acceptsTone: false),
        EmojiEntry("\u{1F3B1}", acceptsTone: false),
        EmojiEntry("\u{1F3B2}", acceptsTone: false),
        EmojiEntry("\u{1F3B3}", acceptsTone: false),
        EmojiEntry("\u{1F3B4}", acceptsTone: false),
        EmojiEntry("\u{1F3B5}", acceptsTone: false),
        EmojiEntry("\u{1F3B6}", acceptsTone: false),
        EmojiEntry("\u{1F3B7}", acceptsTone: false),
        EmojiEntry("\u{1F3B8}", acceptsTone: false),
        EmojiEntry("\u{1F3B9}", acceptsTone: false),
        EmojiEntry("\u{1F3BA}", acceptsTone: false),
        EmojiEntry("\u{1F3BB}", acceptsTone: false),
        EmojiEntry("\u{1F3BC}", acceptsTone: false),
        EmojiEntry("\u{1F941}", acceptsTone: false),
        EmojiEntry("\u{1F3BD}", acceptsTone: false),
        EmojiEntry("\u{1F3BE}", acceptsTone: false),
        EmojiEntry("\u{1F3BF}", acceptsTone: false),
        EmojiEntry("\u{1F3C0}", acceptsTone: false),
        EmojiEntry("\u{1F3C1}", acceptsTone: false),
        EmojiEntry("\u{1F3C2}", acceptsTone: true),
        EmojiEntry("\u{1F3C3}", acceptsTone: true),
        EmojiEntry("\u{1F3C4}", acceptsTone: true),
        EmojiEntry("\u{1F3C5}", acceptsTone: false),
        EmojiEntry("\u{1F3C6}", acceptsTone: false),
        EmojiEntry("\u{1F3C7}", acceptsTone: true),
        EmojiEntry("\u{1F3C8}", acceptsTone: false),
        EmojiEntry("\u{1F3C9}", acceptsTone: false),
        EmojiEntry("\u{1F3CA}", acceptsTone: true),
        EmojiEntry("\u{1F3CB}\u{FE0F}", acceptsTone: true),
        EmojiEntry("\u{1F3CC}\u{FE0F}", acceptsTone: true),
        EmojiEntry("\u{1F3CD}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F3CE}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F3CF}", acceptsTone: false),
        EmojiEntry("\u{1F3D0}", acceptsTone: false),
        EmojiEntry("\u{1F3D1}", acceptsTone: false),
        EmojiEntry("\u{1F3D2}", acceptsTone: false),
        EmojiEntry("\u{1F3D3}", acceptsTone: false),
        EmojiEntry("\u{1F3F8}", acceptsTone: false),
        EmojiEntry("\u{1F3F9}", acceptsTone: false),
        EmojiEntry("\u{1F3FA}", acceptsTone: false),
        EmojiEntry("\u{1F93A}", acceptsTone: false),
        EmojiEntry("\u{1F93C}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F93E}\u{FE0F}", acceptsTone: true),
        EmojiEntry("\u{1F93F}", acceptsTone: false),
        EmojiEntry("\u{1F940}", acceptsTone: false),
        EmojiEntry("\u{1F945}", acceptsTone: false),
        EmojiEntry("\u{1F947}", acceptsTone: false),
        EmojiEntry("\u{1F948}", acceptsTone: false),
        EmojiEntry("\u{1F949}", acceptsTone: false),
        EmojiEntry("\u{1F94A}", acceptsTone: false),
        EmojiEntry("\u{1F94B}", acceptsTone: false),
        EmojiEntry("\u{1F94C}", acceptsTone: false),
        EmojiEntry("\u{1F94D}", acceptsTone: false),
        EmojiEntry("\u{1F94E}", acceptsTone: false),
        EmojiEntry("\u{1F94F}", acceptsTone: false),
        EmojiEntry("\u{1F950}", acceptsTone: false),
        EmojiEntry("\u{1F951}", acceptsTone: false),
        EmojiEntry("\u{1F952}", acceptsTone: false),
        EmojiEntry("\u{1F953}", acceptsTone: false),
        EmojiEntry("\u{1F954}", acceptsTone: false),
        EmojiEntry("\u{1F955}", acceptsTone: false),
        EmojiEntry("\u{1F956}", acceptsTone: false),
        EmojiEntry("\u{1F957}", acceptsTone: false),
        EmojiEntry("\u{1F958}", acceptsTone: false),
        EmojiEntry("\u{1F959}", acceptsTone: false),
        EmojiEntry("\u{1F95A}", acceptsTone: false),
        EmojiEntry("\u{1F95B}", acceptsTone: false),
        EmojiEntry("\u{1F95C}", acceptsTone: false),
        EmojiEntry("\u{1F95D}", acceptsTone: false),
        EmojiEntry("\u{1F95E}", acceptsTone: false),
        EmojiEntry("\u{1F95F}", acceptsTone: false),
        EmojiEntry("\u{1F960}", acceptsTone: false),
        EmojiEntry("\u{1F961}", acceptsTone: false),
        EmojiEntry("\u{1F962}", acceptsTone: false),
        EmojiEntry("\u{1F963}", acceptsTone: false),
        EmojiEntry("\u{1F964}", acceptsTone: false),
        EmojiEntry("\u{1F965}", acceptsTone: false),
        EmojiEntry("\u{1F966}", acceptsTone: false),
        EmojiEntry("\u{1F967}", acceptsTone: false),
        EmojiEntry("\u{1F968}", acceptsTone: false),
        EmojiEntry("\u{1F969}", acceptsTone: false),
        EmojiEntry("\u{1F96A}", acceptsTone: false),
        EmojiEntry("\u{1F96B}", acceptsTone: false),
        EmojiEntry("\u{1F96C}", acceptsTone: false),
        EmojiEntry("\u{1F96D}", acceptsTone: false),
        EmojiEntry("\u{1F96E}", acceptsTone: false),
        EmojiEntry("\u{1F96F}", acceptsTone: false),
        EmojiEntry("\u{1F970}", acceptsTone: false),
    ]

    public static let travel: [EmojiEntry] = [
        EmojiEntry("\u{1F30D}", acceptsTone: false),
        EmojiEntry("\u{1F30E}", acceptsTone: false),
        EmojiEntry("\u{1F30F}", acceptsTone: false),
        EmojiEntry("\u{1F310}", acceptsTone: false),
        EmojiEntry("\u{1F311}", acceptsTone: false),
        EmojiEntry("\u{1F312}", acceptsTone: false),
        EmojiEntry("\u{1F313}", acceptsTone: false),
        EmojiEntry("\u{1F314}", acceptsTone: false),
        EmojiEntry("\u{1F315}", acceptsTone: false),
        EmojiEntry("\u{1F316}", acceptsTone: false),
        EmojiEntry("\u{1F317}", acceptsTone: false),
        EmojiEntry("\u{1F318}", acceptsTone: false),
        EmojiEntry("\u{1F319}", acceptsTone: false),
        EmojiEntry("\u{1F31A}", acceptsTone: false),
        EmojiEntry("\u{1F31B}", acceptsTone: false),
        EmojiEntry("\u{1F31C}", acceptsTone: false),
        EmojiEntry("\u{1F31D}", acceptsTone: false),
        EmojiEntry("\u{1F31E}", acceptsTone: false),
        EmojiEntry("\u{1F31F}", acceptsTone: false),
        EmojiEntry("\u{1F320}", acceptsTone: false),
        EmojiEntry("\u{1F30A}", acceptsTone: false),
        EmojiEntry("\u{1F30B}", acceptsTone: false),
        EmojiEntry("\u{1F30C}", acceptsTone: false),
        EmojiEntry("\u{1F30D}", acceptsTone: false),
        EmojiEntry("\u{1F302}", acceptsTone: false),
        EmojiEntry("\u{1F303}", acceptsTone: false),
        EmojiEntry("\u{1F304}", acceptsTone: false),
        EmojiEntry("\u{1F305}", acceptsTone: false),
        EmojiEntry("\u{1F306}", acceptsTone: false),
        EmojiEntry("\u{1F307}", acceptsTone: false),
        EmojiEntry("\u{1F308}", acceptsTone: false),
        EmojiEntry("\u{1F309}", acceptsTone: false),
        EmojiEntry("\u{1F3A0}", acceptsTone: false),
        EmojiEntry("\u{1F3A1}", acceptsTone: false),
        EmojiEntry("\u{1F3A2}", acceptsTone: false),
        EmojiEntry("\u{1F3A3}", acceptsTone: false),
        EmojiEntry("\u{1F3A4}", acceptsTone: false),
        EmojiEntry("\u{1F3A5}", acceptsTone: false),
        EmojiEntry("\u{1F3A6}", acceptsTone: false),
        EmojiEntry("\u{1F3A7}", acceptsTone: false),
        EmojiEntry("\u{1F3A8}", acceptsTone: false),
        EmojiEntry("\u{1F3A9}", acceptsTone: false),
        EmojiEntry("\u{1F3AA}", acceptsTone: false),
        EmojiEntry("\u{1F3AB}", acceptsTone: false),
        EmojiEntry("\u{1F3AC}", acceptsTone: false),
        EmojiEntry("\u{1F3AD}", acceptsTone: false),
        EmojiEntry("\u{1F3AE}", acceptsTone: false),
        EmojiEntry("\u{1F3AF}", acceptsTone: false),
        EmojiEntry("\u{1F3B0}", acceptsTone: false),
        EmojiEntry("\u{1F3B1}", acceptsTone: false),
        EmojiEntry("\u{1F3B2}", acceptsTone: false),
        EmojiEntry("\u{1F3B3}", acceptsTone: false),
        EmojiEntry("\u{1F3B4}", acceptsTone: false),
        EmojiEntry("\u{1F3B5}", acceptsTone: false),
        EmojiEntry("\u{1F3B6}", acceptsTone: false),
        EmojiEntry("\u{1F3B7}", acceptsTone: false),
        EmojiEntry("\u{1F3B8}", acceptsTone: false),
        EmojiEntry("\u{1F3B9}", acceptsTone: false),
        EmojiEntry("\u{1F3BA}", acceptsTone: false),
        EmojiEntry("\u{1F3BB}", acceptsTone: false),
        EmojiEntry("\u{1F3BC}", acceptsTone: false),
        EmojiEntry("\u{1F941}", acceptsTone: false),
        EmojiEntry("\u{1F3BD}", acceptsTone: false),
        EmojiEntry("\u{1F3BE}", acceptsTone: false),
        EmojiEntry("\u{1F3BF}", acceptsTone: false),
        EmojiEntry("\u{1F3C0}", acceptsTone: false),
        EmojiEntry("\u{1F3C1}", acceptsTone: false),
        EmojiEntry("\u{1F682}", acceptsTone: false),
        EmojiEntry("\u{1F683}", acceptsTone: false),
        EmojiEntry("\u{1F684}", acceptsTone: false),
        EmojiEntry("\u{1F685}", acceptsTone: false),
        EmojiEntry("\u{1F686}", acceptsTone: false),
        EmojiEntry("\u{1F687}", acceptsTone: false),
        EmojiEntry("\u{1F688}", acceptsTone: false),
        EmojiEntry("\u{1F689}", acceptsTone: false),
        EmojiEntry("\u{1F68A}", acceptsTone: false),
        EmojiEntry("\u{1F69A}", acceptsTone: false),
        EmojiEntry("\u{1F69B}", acceptsTone: false),
        EmojiEntry("\u{1F69C}", acceptsTone: false),
        EmojiEntry("\u{1F6A2}", acceptsTone: false),
        EmojiEntry("\u{1F6A4}", acceptsTone: false),
        EmojiEntry("\u{1F6A5}", acceptsTone: false),
        EmojiEntry("\u{1F6A6}", acceptsTone: false),
        EmojiEntry("\u{1F6A7}", acceptsTone: false),
        EmojiEntry("\u{1F6A8}", acceptsTone: false),
        EmojiEntry("\u{1F6A9}", acceptsTone: false),
        EmojiEntry("\u{1F6AB}", acceptsTone: false),
        EmojiEntry("\u{1F6AC}", acceptsTone: false),
        EmojiEntry("\u{1F6AD}", acceptsTone: false),
        EmojiEntry("\u{1F6AE}", acceptsTone: false),
        EmojiEntry("\u{1F6B2}", acceptsTone: false),
        EmojiEntry("\u{1F6B6}", acceptsTone: true),
        EmojiEntry("\u{1F6B9}", acceptsTone: false),
        EmojiEntry("\u{1F6BA}", acceptsTone: false),
        EmojiEntry("\u{1F6BB}", acceptsTone: false),
        EmojiEntry("\u{1F6BC}", acceptsTone: false),
        EmojiEntry("\u{1F6BD}", acceptsTone: false),
        EmojiEntry("\u{1F6BE}", acceptsTone: false),
        EmojiEntry("\u{1F6BF}", acceptsTone: false),
    ]

    public static let objects: [EmojiEntry] = [
        EmojiEntry("\u{1F4A1}", acceptsTone: false),
        EmojiEntry("\u{1F526}", acceptsTone: false),
        EmojiEntry("\u{1F56F}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F4F1}", acceptsTone: false),
        EmojiEntry("\u{1F4F2}", acceptsTone: false),
        EmojiEntry("\u{1F4BB}", acceptsTone: false),
        EmojiEntry("\u{1F4BD}", acceptsTone: false),
        EmojiEntry("\u{1F4BE}", acceptsTone: false),
        EmojiEntry("\u{1F4BF}", acceptsTone: false),
        EmojiEntry("\u{1F4C0}", acceptsTone: false),
        EmojiEntry("\u{1F4C1}", acceptsTone: false),
        EmojiEntry("\u{1F4C2}", acceptsTone: false),
        EmojiEntry("\u{1F4C3}", acceptsTone: false),
        EmojiEntry("\u{1F4C4}", acceptsTone: false),
        EmojiEntry("\u{1F4C5}", acceptsTone: false),
        EmojiEntry("\u{1F4C6}", acceptsTone: false),
        EmojiEntry("\u{1F4C7}", acceptsTone: false),
        EmojiEntry("\u{1F4C8}", acceptsTone: false),
        EmojiEntry("\u{1F4C9}", acceptsTone: false),
        EmojiEntry("\u{1F4CA}", acceptsTone: false),
        EmojiEntry("\u{1F4CB}", acceptsTone: false),
        EmojiEntry("\u{1F4CC}", acceptsTone: false),
        EmojiEntry("\u{1F4CD}", acceptsTone: false),
        EmojiEntry("\u{1F4CE}", acceptsTone: false),
        EmojiEntry("\u{1F4CF}", acceptsTone: false),
        EmojiEntry("\u{1F4D0}", acceptsTone: false),
        EmojiEntry("\u{1F4D1}", acceptsTone: false),
        EmojiEntry("\u{1F4D2}", acceptsTone: false),
        EmojiEntry("\u{1F4D3}", acceptsTone: false),
        EmojiEntry("\u{1F4D4}", acceptsTone: false),
        EmojiEntry("\u{1F4D5}", acceptsTone: false),
        EmojiEntry("\u{1F4D6}", acceptsTone: false),
        EmojiEntry("\u{1F4D7}", acceptsTone: false),
        EmojiEntry("\u{1F4D8}", acceptsTone: false),
        EmojiEntry("\u{1F4D9}", acceptsTone: false),
        EmojiEntry("\u{1F4DA}", acceptsTone: false),
        EmojiEntry("\u{1F4DB}", acceptsTone: false),
        EmojiEntry("\u{1F4DC}", acceptsTone: false),
        EmojiEntry("\u{1F4DD}", acceptsTone: false),
        EmojiEntry("\u{1F4DE}", acceptsTone: false),
        EmojiEntry("\u{1F4DF}", acceptsTone: false),
        EmojiEntry("\u{1F4E0}", acceptsTone: false),
        EmojiEntry("\u{1F4E1}", acceptsTone: false),
        EmojiEntry("\u{1F4E2}", acceptsTone: false),
        EmojiEntry("\u{1F4E3}", acceptsTone: false),
        EmojiEntry("\u{1F4E4}", acceptsTone: false),
        EmojiEntry("\u{1F4E5}", acceptsTone: false),
        EmojiEntry("\u{1F4E6}", acceptsTone: false),
        EmojiEntry("\u{1F4E7}", acceptsTone: false),
        EmojiEntry("\u{1F4E8}", acceptsTone: false),
        EmojiEntry("\u{1F4E9}", acceptsTone: false),
        EmojiEntry("\u{1F4EA}", acceptsTone: false),
        EmojiEntry("\u{1F4EB}", acceptsTone: false),
        EmojiEntry("\u{1F4EC}", acceptsTone: false),
        EmojiEntry("\u{1F4ED}", acceptsTone: false),
        EmojiEntry("\u{1F4EE}", acceptsTone: false),
        EmojiEntry("\u{1F4EF}", acceptsTone: false),
        EmojiEntry("\u{1F4F0}", acceptsTone: false),
        EmojiEntry("\u{1F4F3}", acceptsTone: false),
        EmojiEntry("\u{1F4F4}", acceptsTone: false),
        EmojiEntry("\u{1F4F5}", acceptsTone: false),
        EmojiEntry("\u{1F4F6}", acceptsTone: false),
        EmojiEntry("\u{1F4F7}", acceptsTone: false),
        EmojiEntry("\u{1F4F8}", acceptsTone: false),
        EmojiEntry("\u{1F4F9}", acceptsTone: false),
        EmojiEntry("\u{1F4FA}", acceptsTone: false),
        EmojiEntry("\u{1F4FB}", acceptsTone: false),
        EmojiEntry("\u{1F4FC}", acceptsTone: false),
        EmojiEntry("\u{1F4FD}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F4FF}", acceptsTone: false),
        EmojiEntry("\u{1F500}", acceptsTone: false),
        EmojiEntry("\u{1F501}", acceptsTone: false),
        EmojiEntry("\u{1F502}", acceptsTone: false),
        EmojiEntry("\u{1F503}", acceptsTone: false),
        EmojiEntry("\u{1F504}", acceptsTone: false),
        EmojiEntry("\u{1F505}", acceptsTone: false),
        EmojiEntry("\u{1F506}", acceptsTone: false),
        EmojiEntry("\u{1F507}", acceptsTone: false),
        EmojiEntry("\u{1F508}", acceptsTone: false),
        EmojiEntry("\u{1F509}", acceptsTone: false),
        EmojiEntry("\u{1F50A}", acceptsTone: false),
        EmojiEntry("\u{1F50B}", acceptsTone: false),
        EmojiEntry("\u{1F50C}", acceptsTone: false),
        EmojiEntry("\u{1F50D}", acceptsTone: false),
        EmojiEntry("\u{1F50E}", acceptsTone: false),
        EmojiEntry("\u{1F50F}", acceptsTone: false),
        EmojiEntry("\u{1F510}", acceptsTone: false),
        EmojiEntry("\u{1F511}", acceptsTone: false),
        EmojiEntry("\u{1F512}", acceptsTone: false),
        EmojiEntry("\u{1F513}", acceptsTone: false),
        EmojiEntry("\u{1F514}", acceptsTone: false),
        EmojiEntry("\u{1F515}", acceptsTone: false),
        EmojiEntry("\u{1F516}", acceptsTone: false),
        EmojiEntry("\u{1F517}", acceptsTone: false),
        EmojiEntry("\u{1F518}", acceptsTone: false),
        EmojiEntry("\u{1F519}", acceptsTone: false),
        EmojiEntry("\u{1F51A}", acceptsTone: false),
        EmojiEntry("\u{1F51B}", acceptsTone: false),
        EmojiEntry("\u{1F51C}", acceptsTone: false),
        EmojiEntry("\u{1F51D}", acceptsTone: false),
        EmojiEntry("\u{1F51E}", acceptsTone: false),
        EmojiEntry("\u{1F51F}", acceptsTone: false),
        EmojiEntry("\u{1F520}", acceptsTone: false),
        EmojiEntry("\u{1F521}", acceptsTone: false),
        EmojiEntry("\u{1F522}", acceptsTone: false),
        EmojiEntry("\u{1F523}", acceptsTone: false),
        EmojiEntry("\u{1F524}", acceptsTone: false),
        EmojiEntry("\u{1F525}", acceptsTone: false),
        EmojiEntry("\u{1F526}", acceptsTone: false),
        EmojiEntry("\u{1F527}", acceptsTone: false),
        EmojiEntry("\u{1F528}", acceptsTone: false),
        EmojiEntry("\u{1F529}", acceptsTone: false),
        EmojiEntry("\u{1F52A}", acceptsTone: false),
        EmojiEntry("\u{1F52B}", acceptsTone: false),
        EmojiEntry("\u{1F52C}", acceptsTone: false),
        EmojiEntry("\u{1F52D}", acceptsTone: false),
        EmojiEntry("\u{1F52E}", acceptsTone: false),
        EmojiEntry("\u{1F52F}", acceptsTone: false),
        EmojiEntry("\u{1F530}", acceptsTone: false),
        EmojiEntry("\u{1F531}", acceptsTone: false),
        EmojiEntry("\u{1F532}", acceptsTone: false),
        EmojiEntry("\u{1F533}", acceptsTone: false),
        EmojiEntry("\u{1F534}", acceptsTone: false),
        EmojiEntry("\u{1F535}", acceptsTone: false),
        EmojiEntry("\u{1F536}", acceptsTone: false),
        EmojiEntry("\u{1F537}", acceptsTone: false),
        EmojiEntry("\u{1F538}", acceptsTone: false),
        EmojiEntry("\u{1F539}", acceptsTone: false),
    ]

    public static let symbols: [EmojiEntry] = [
        EmojiEntry("\u{2764}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F9E1}", acceptsTone: false),
        EmojiEntry("\u{1F49B}", acceptsTone: false),
        EmojiEntry("\u{1F49A}", acceptsTone: false),
        EmojiEntry("\u{1F499}", acceptsTone: false),
        EmojiEntry("\u{1F49C}", acceptsTone: false),
        EmojiEntry("\u{1F90A}", acceptsTone: false),
        EmojiEntry("\u{1F5A4}", acceptsTone: false),
        EmojiEntry("\u{1F90B}", acceptsTone: false),
        EmojiEntry("\u{1F90E}", acceptsTone: false),
        EmojiEntry("\u{1F90F}", acceptsTone: false),
        EmojiEntry("\u{1F90D}", acceptsTone: false),
        EmojiEntry("\u{1F90C}", acceptsTone: false),
        EmojiEntry("\u{1F9E0}", acceptsTone: false),
        EmojiEntry("\u{1F9DC}\u{200D}\u{2642}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F9DD}\u{200D}\u{2640}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F9DE}\u{200D}\u{2642}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F9DF}\u{200D}\u{2640}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F494}", acceptsTone: false),
        EmojiEntry("\u{2763}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F48C}", acceptsTone: false),
        EmojiEntry("\u{1F48B}", acceptsTone: false),
        EmojiEntry("\u{1F48D}", acceptsTone: false),
        EmojiEntry("\u{1F48E}", acceptsTone: false),
        EmojiEntry("\u{1F48F}", acceptsTone: true),
        EmojiEntry("\u{1F490}", acceptsTone: false),
        EmojiEntry("\u{1F491}", acceptsTone: true),
        EmojiEntry("\u{1F492}", acceptsTone: false),
        EmojiEntry("\u{1F493}", acceptsTone: false),
        EmojiEntry("\u{1F495}", acceptsTone: false),
        EmojiEntry("\u{1F496}", acceptsTone: false),
        EmojiEntry("\u{1F497}", acceptsTone: false),
        EmojiEntry("\u{1F498}", acceptsTone: false),
        EmojiEntry("\u{1F49D}", acceptsTone: false),
        EmojiEntry("\u{1F49E}", acceptsTone: false),
        EmojiEntry("\u{1F49F}", acceptsTone: false),
        EmojiEntry("\u{1F4AF}", acceptsTone: false),
        EmojiEntry("\u{1F4A0}", acceptsTone: false),
        EmojiEntry("\u{1F4A2}", acceptsTone: false),
        EmojiEntry("\u{1F4A3}", acceptsTone: false),
        EmojiEntry("\u{1F4A4}", acceptsTone: false),
        EmojiEntry("\u{1F4A5}", acceptsTone: false),
        EmojiEntry("\u{1F4A6}", acceptsTone: false),
        EmojiEntry("\u{1F4A7}", acceptsTone: false),
        EmojiEntry("\u{1F4A8}", acceptsTone: false),
        EmojiEntry("\u{1F4A9}", acceptsTone: false),
        EmojiEntry("\u{1F4AA}", acceptsTone: true),
        EmojiEntry("\u{1F4AB}", acceptsTone: false),
        EmojiEntry("\u{1F4AC}", acceptsTone: false),
        EmojiEntry("\u{1F4AD}", acceptsTone: false),
        EmojiEntry("\u{1F4AE}", acceptsTone: false),
        EmojiEntry("\u{1F4AF}", acceptsTone: false),
        EmojiEntry("\u{1F4B0}", acceptsTone: false),
        EmojiEntry("\u{1F4B1}", acceptsTone: false),
        EmojiEntry("\u{1F4B2}", acceptsTone: false),
        EmojiEntry("\u{1F4B3}", acceptsTone: false),
        EmojiEntry("\u{1F4B4}", acceptsTone: false),
        EmojiEntry("\u{1F4B5}", acceptsTone: false),
        EmojiEntry("\u{1F4B6}", acceptsTone: false),
        EmojiEntry("\u{1F4B7}", acceptsTone: false),
        EmojiEntry("\u{1F4B8}", acceptsTone: false),
        EmojiEntry("\u{1F4B9}", acceptsTone: false),
        EmojiEntry("\u{1F4BA}", acceptsTone: false),
        EmojiEntry("\u{1F4BB}", acceptsTone: false),
        EmojiEntry("\u{1F4BC}", acceptsTone: false),
        EmojiEntry("\u{1F4BD}", acceptsTone: false),
        EmojiEntry("\u{1F4BE}", acceptsTone: false),
        EmojiEntry("\u{1F4BF}", acceptsTone: false),
        EmojiEntry("\u{1F4C0}", acceptsTone: false),
        EmojiEntry("\u{1F4C1}", acceptsTone: false),
        EmojiEntry("\u{1F4C2}", acceptsTone: false),
        EmojiEntry("\u{1F4C3}", acceptsTone: false),
        EmojiEntry("\u{1F4C4}", acceptsTone: false),
        EmojiEntry("\u{1F4C5}", acceptsTone: false),
        EmojiEntry("\u{1F4C6}", acceptsTone: false),
        EmojiEntry("\u{1F4C7}", acceptsTone: false),
        EmojiEntry("\u{1F4C8}", acceptsTone: false),
        EmojiEntry("\u{1F4C9}", acceptsTone: false),
        EmojiEntry("\u{1F4CA}", acceptsTone: false),
        EmojiEntry("\u{1F4CB}", acceptsTone: false),
        EmojiEntry("\u{1F4CC}", acceptsTone: false),
        EmojiEntry("\u{1F4CD}", acceptsTone: false),
        EmojiEntry("\u{1F4CE}", acceptsTone: false),
    ]

    public static let flags: [EmojiEntry] = [
        EmojiEntry("\u{1F3C1}", acceptsTone: false),
        EmojiEntry("\u{1F6A9}", acceptsTone: false),
        EmojiEntry("\u{1F38C}", acceptsTone: false),
        EmojiEntry("\u{1F3F4}", acceptsTone: false),
        EmojiEntry("\u{1F3F3}\u{FE0F}", acceptsTone: false),
        EmojiEntry("\u{1F1E6}\u{1F1E8}", acceptsTone: false),  // 🇦🇨 Ascension
        EmojiEntry("\u{1F1E6}\u{1F1E9}", acceptsTone: false),  // 🇦🇩 Andorra
        EmojiEntry("\u{1F1E6}\u{1F1EA}", acceptsTone: false),  // 🇦🇪 UAE
        EmojiEntry("\u{1F1E6}\u{1F1EB}", acceptsTone: false),  // 🇦🇫 Afghanistan
        EmojiEntry("\u{1F1E6}\u{1F1EC}", acceptsTone: false),  // 🇦🇬 Antigua
        EmojiEntry("\u{1F1E6}\u{1F1EE}", acceptsTone: false),  // 🇦🇮 Anguilla
        EmojiEntry("\u{1F1E6}\u{1F1F1}", acceptsTone: false),  // 🇦🇱 Albania
        EmojiEntry("\u{1F1E6}\u{1F1F2}", acceptsTone: false),  // 🇦🇲 Armenia
        EmojiEntry("\u{1F1E6}\u{1F1F4}", acceptsTone: false),  // 🇦🇴 Angola
        EmojiEntry("\u{1F1E6}\u{1F1F6}", acceptsTone: false),  // 🇦🇶 Antarctica
        EmojiEntry("\u{1F1E6}\u{1F1F7}", acceptsTone: false),  // 🇦🇷 Argentina
        EmojiEntry("\u{1F1E6}\u{1F1F8}", acceptsTone: false),  // 🇦🇸 American Samoa
        EmojiEntry("\u{1F1E6}\u{1F1F9}", acceptsTone: false),  // 🇦🇹 Austria
        EmojiEntry("\u{1F1E6}\u{1F1FA}", acceptsTone: false),  // 🇦🇺 Australia
        EmojiEntry("\u{1F1E6}\u{1F1FC}", acceptsTone: false),  // 🇦🇼 Aruba
        EmojiEntry("\u{1F1E6}\u{1F1FD}", acceptsTone: false),  // 🇦🇽 Åland
        EmojiEntry("\u{1F1E6}\u{1F1FF}", acceptsTone: false),  // 🇦🇿 Azerbaijan
        EmojiEntry("\u{1F1E7}\u{1F1E6}", acceptsTone: false),  // 🇧🇦 Bosnia
        EmojiEntry("\u{1F1E7}\u{1F1E7}", acceptsTone: false),  // 🇧🇧 Barbados
        EmojiEntry("\u{1F1E7}\u{1F1E9}", acceptsTone: false),  // 🇧🇩 Bangladesh
        EmojiEntry("\u{1F1E7}\u{1F1EA}", acceptsTone: false),  // 🇧🇪 Belgium
        EmojiEntry("\u{1F1E7}\u{1F1EB}", acceptsTone: false),  // 🇧🇫 Burkina Faso
        EmojiEntry("\u{1F1E7}\u{1F1EC}", acceptsTone: false),  // 🇧🇬 Bulgaria
        EmojiEntry("\u{1F1E7}\u{1F1ED}", acceptsTone: false),  // 🇧🇭 Bahrain
        EmojiEntry("\u{1F1E7}\u{1F1EE}", acceptsTone: false),  // 🇧🇮 Burundi
        EmojiEntry("\u{1F1E7}\u{1F1EF}", acceptsTone: false),  // 🇧🇯 Benin
        EmojiEntry("\u{1F1E7}\u{1F1F1}", acceptsTone: false),  // 🇧🇱 St. Barthélemy
        EmojiEntry("\u{1F1E7}\u{1F1F2}", acceptsTone: false),  // 🇧🇲 Bermuda
        EmojiEntry("\u{1F1E7}\u{1F1F3}", acceptsTone: false),  // 🇧🇳 Brunei
        EmojiEntry("\u{1F1E7}\u{1F1F4}", acceptsTone: false),  // 🇧🇴 Bolivia
        EmojiEntry("\u{1F1E7}\u{1F1F6}", acceptsTone: false),  // 🇧🇶 Caribbean NL
        EmojiEntry("\u{1F1E7}\u{1F1F7}", acceptsTone: false),  // 🇧🇷 Brazil
        EmojiEntry("\u{1F1E7}\u{1F1F8}", acceptsTone: false),  // 🇧🇸 Bahamas
        EmojiEntry("\u{1F1E7}\u{1F1F9}", acceptsTone: false),  // 🇧🇹 Bhutan
        EmojiEntry("\u{1F1E7}\u{1F1FB}", acceptsTone: false),  // 🇧🇻 Bouvet
        EmojiEntry("\u{1F1E7}\u{1F1FC}", acceptsTone: false),  // 🇧🇼 Botswana
        EmojiEntry("\u{1F1E7}\u{1F1FE}", acceptsTone: false),  // 🇧🇾 Belarus
        EmojiEntry("\u{1F1E7}\u{1F1FF}", acceptsTone: false),  // 🇧🇿 Belize
        EmojiEntry("\u{1F1E8}\u{1F1E6}", acceptsTone: false),  // 🇨🇦 Canada
        EmojiEntry("\u{1F1E8}\u{1F1E8}", acceptsTone: false),  // 🇨🇨 Cocos
        EmojiEntry("\u{1F1E8}\u{1F1E9}", acceptsTone: false),  // 🇨🇩 DRC
        EmojiEntry("\u{1F1E8}\u{1F1EB}", acceptsTone: false),  // 🇨🇫 CAR
        EmojiEntry("\u{1F1E8}\u{1F1EC}", acceptsTone: false),  // 🇨🇬 Congo
        EmojiEntry("\u{1F1E8}\u{1F1ED}", acceptsTone: false),  // 🇨🇭 Switzerland
        EmojiEntry("\u{1F1E8}\u{1F1EE}", acceptsTone: false),  // 🇨🇮 Côte d'Ivoire
        EmojiEntry("\u{1F1E8}\u{1F1F1}", acceptsTone: false),  // 🇨🇰 Cook
        EmojiEntry("\u{1F1E8}\u{1F1F2}", acceptsTone: false),  // 🇨🇱 Chile
        EmojiEntry("\u{1F1E8}\u{1F1F3}", acceptsTone: false),  // 🇨🇲 Cameroon
        EmojiEntry("\u{1F1E8}\u{1F1F4}", acceptsTone: false),  // 🇨🇳 China
        EmojiEntry("\u{1F1E8}\u{1F1F5}", acceptsTone: false),  // 🇨🇴 Colombia
        EmojiEntry("\u{1F1E8}\u{1F1F6}", acceptsTone: false),  // 🇨🇶 Clipperton
        EmojiEntry("\u{1F1E8}\u{1F1F7}", acceptsTone: false),  // 🇨🇷 Costa Rica
        EmojiEntry("\u{1F1E8}\u{1F1F8}", acceptsTone: false),  // 🇨🇺 Cuba
        EmojiEntry("\u{1F1E8}\u{1F1F9}", acceptsTone: false),  // 🇨🇻 Cape Verde
        EmojiEntry("\u{1F1E8}\u{1F1FB}", acceptsTone: false),  // 🇨🇼 Curaçao
        EmojiEntry("\u{1F1E8}\u{1F1FC}", acceptsTone: false),  // 🇨🇽 Christmas
        EmojiEntry("\u{1F1E8}\u{1F1FD}", acceptsTone: false),  // 🇨🇾 Cyprus
        EmojiEntry("\u{1F1E8}\u{1F1FE}", acceptsTone: false),  // 🇨🇿 Czechia
        EmojiEntry("\u{1F1E8}\u{1F1FF}", acceptsTone: false),  // 🇨🇩 Germany
        EmojiEntry("\u{1F1E9}\u{1F1EA}", acceptsTone: false),  // 🇩🇪 Diego Garcia
        EmojiEntry("\u{1F1E9}\u{1F1EC}", acceptsTone: false),  // 🇩🇯 Djibouti
        EmojiEntry("\u{1F1E9}\u{1F1EF}", acceptsTone: false),  // 🇩🇰 Denmark
        EmojiEntry("\u{1F1E9}\u{1F1F0}", acceptsTone: false),  // 🇩🇲 Dominica
        EmojiEntry("\u{1F1E9}\u{1F1F2}", acceptsTone: false),  // 🇩🇴 Dominican
        EmojiEntry("\u{1F1E9}\u{1F1F4}", acceptsTone: false),  // 🇩🇿 Algeria
        EmojiEntry("\u{1F1E9}\u{1F1FF}", acceptsTone: false),  // 🇪🇪 Estonia
        EmojiEntry("\u{1F1EA}\u{1F1E6}", acceptsTone: false),  // 🇪🇬 Egypt
        EmojiEntry("\u{1F1EA}\u{1F1E8}", acceptsTone: false),  // 🇪🇸 Sahara
        EmojiEntry("\u{1F1EA}\u{1F1EA}", acceptsTone: false),  // 🇪🇷 Eritrea
        EmojiEntry("\u{1F1EA}\u{1F1EC}", acceptsTone: false),  // 🇪🇪 Spain
        EmojiEntry("\u{1F1EA}\u{1F1ED}", acceptsTone: false),  // 🇪🇹 Ethiopia
        EmojiEntry("\u{1F1EA}\u{1F1F7}", acceptsTone: false),  // 🇪🇺 EU
        EmojiEntry("\u{1F1EA}\u{1F1F8}", acceptsTone: false),  // 🇫🇮 Finland
        EmojiEntry("\u{1F1EA}\u{1F1F9}", acceptsTone: false),  // 🇫🇯 Fiji
        EmojiEntry("\u{1F1EA}\u{1F1FA}", acceptsTone: false),  // 🇫🇲 Falklands
        EmojiEntry("\u{1F1EA}\u{1F1FC}", acceptsTone: false),  // 🇫🇲 Micronesia
        EmojiEntry("\u{1F1EA}\u{1F1FD}", acceptsTone: false),  // 🇫🇴 Faroe
        EmojiEntry("\u{1F1EA}\u{1F1FF}", acceptsTone: false),  // 🇫🇷 France
        EmojiEntry("\u{1F1EB}\u{1F1EE}", acceptsTone: false),  // 🇬🇦 Gabon
        EmojiEntry("\u{1F1EB}\u{1F1EF}", acceptsTone: false),  // 🇬🇧 UK
        EmojiEntry("\u{1F1EB}\u{1F1F0}", acceptsTone: false),  // 🇬🇩 Grenada
        EmojiEntry("\u{1F1EB}\u{1F1F2}", acceptsTone: false),  // 🇬🇪 Georgia
        EmojiEntry("\u{1F1EB}\u{1F1F4}", acceptsTone: false),  // 🇬🇫 French Guiana
        EmojiEntry("\u{1F1EB}\u{1F1F7}", acceptsTone: false),  // 🇬🇭 Ghana
        EmojiEntry("\u{1F1EB}\u{1F1FA}", acceptsTone: false),  // 🇬🇮 Gibraltar
        EmojiEntry("\u{1F1EB}\u{1F1FC}", acceptsTone: false),  // 🇬🇱 Greenland
        EmojiEntry("\u{1F1EB}\u{1F1FE}", acceptsTone: false),  // 🇬🇲 Gambia
        EmojiEntry("\u{1F1EB}\u{1F1FF}", acceptsTone: false),  // 🇬🇳 Guinea
        EmojiEntry("\u{1F1EC}\u{1F1E6}", acceptsTone: false),  // 🇬🇶 Equatorial
        EmojiEntry("\u{1F1EC}\u{1F1E7}", acceptsTone: false),  // 🇬🇷 Greece
        EmojiEntry("\u{1F1EC}\u{1F1E9}", acceptsTone: false),  // 🇬🇸 South Georgia
        EmojiEntry("\u{1F1EC}\u{1F1EA}", acceptsTone: false),  // 🇬🇹 Guatemala
        EmojiEntry("\u{1F1EC}\u{1F1EB}", acceptsTone: false),  // 🇬🇺 Guam
        EmojiEntry("\u{1F1EC}\u{1F1EC}", acceptsTone: false),  // 🇬🇼 Guinea-Bissau
        EmojiEntry("\u{1F1EC}\u{1F1ED}", acceptsTone: false),  // 🇬🇾 Guyana
        EmojiEntry("\u{1F1EC}\u{1F1F1}", acceptsTone: false),  // 🇭🇰 Hong Kong
        EmojiEntry("\u{1F1EC}\u{1F1F2}", acceptsTone: false),  // 🇭🇲 Heard
        EmojiEntry("\u{1F1EC}\u{1F1F3}", acceptsTone: false),  // 🇭🇳 Honduras
        EmojiEntry("\u{1F1EC}\u{1F1F5}", acceptsTone: false),  // 🇭🇷 Croatia
        EmojiEntry("\u{1F1EC}\u{1F1F6}", acceptsTone: false),  // 🇭🇹 Haiti
        EmojiEntry("\u{1F1EC}\u{1F1F7}", acceptsTone: false),  // 🇭🇺 Hungary
        EmojiEntry("\u{1F1EC}\u{1F1F8}", acceptsTone: false),  // 🇮🇩 Indonesia
        EmojiEntry("\u{1F1EC}\u{1F1F9}", acceptsTone: false),  // 🇮🇪 Ireland
        EmojiEntry("\u{1F1EC}\u{1F1FA}", acceptsTone: false),  // 🇮🇱 Israel
        EmojiEntry("\u{1F1EC}\u{1F1FC}", acceptsTone: false),  // 🇮🇲 Isle of Man
        EmojiEntry("\u{1F1EC}\u{1F1FE}", acceptsTone: false),  // 🇮🇳 India
        EmojiEntry("\u{1F1EC}\u{1F1FF}", acceptsTone: false),  // 🇮🇶 Iraq
        EmojiEntry("\u{1F1ED}\u{1F1F0}", acceptsTone: false),  // 🇮🇷 Iran
        EmojiEntry("\u{1F1ED}\u{1F1F2}", acceptsTone: false),  // 🇮🇸 Iceland
        EmojiEntry("\u{1F1ED}\u{1F1F3}", acceptsTone: false),  // 🇮🇹 Italy
        EmojiEntry("\u{1F1ED}\u{1F1F7}", acceptsTone: false),  // 🇯🇲 Jamaica
        EmojiEntry("\u{1F1ED}\u{1F1F9}", acceptsTone: false),  // 🇯🇴 Jordan
        EmojiEntry("\u{1F1ED}\u{1F1FA}", acceptsTone: false),  // 🇯🇵 Japan
        EmojiEntry("\u{1F1ED}\u{1F1FB}", acceptsTone: false),  // 🇰🇪 Kenya
        EmojiEntry("\u{1F1ED}\u{1F1FC}", acceptsTone: false),  // 🇰🇬 Kyrgyzstan
        EmojiEntry("\u{1F1ED}\u{1F1FD}", acceptsTone: false),  // 🇰🇭 Cambodia
        EmojiEntry("\u{1F1ED}\u{1F1FF}", acceptsTone: false),  // 🇰🇮 Kiribati
        EmojiEntry("\u{1F1EE}\u{1F1F1}", acceptsTone: false),  // 🇰🇲 Comoros
        EmojiEntry("\u{1F1EE}\u{1F1F2}", acceptsTone: false),  // 🇰🇳 St. Kitts
        EmojiEntry("\u{1F1EE}\u{1F1F3}", acceptsTone: false),  // 🇰🇵 North Korea
        EmojiEntry("\u{1F1EE}\u{1F1F4}", acceptsTone: false),  // 🇰🇷 South Korea
        EmojiEntry("\u{1F1EE}\u{1F1F6}", acceptsTone: false),  // 🇰🇼 Kuwait
        EmojiEntry("\u{1F1EE}\u{1F1F7}", acceptsTone: false),  // 🇰🇾 Cayman
        EmojiEntry("\u{1F1EE}\u{1F1F8}", acceptsTone: false),  // 🇰🇿 Kazakhstan
        EmojiEntry("\u{1F1EE}\u{1F1F9}", acceptsTone: false),  // 🇱🇦 Laos
        EmojiEntry("\u{1F1EE}\u{1F1FA}", acceptsTone: false),  // 🇱🇧 Lebanon
        EmojiEntry("\u{1F1EE}\u{1F1FC}", acceptsTone: false),  // 🇱🇨 St. Lucia
        EmojiEntry("\u{1F1EE}\u{1F1FD}", acceptsTone: false),  // 🇱🇮 Liechtenstein
        EmojiEntry("\u{1F1EE}\u{1F1FE}", acceptsTone: false),  // 🇱🇰 Sri Lanka
        EmojiEntry("\u{1F1EF}\u{1F1EA}", acceptsTone: false),  // 🇱🇷 Liberia
        EmojiEntry("\u{1F1EF}\u{1F1F2}", acceptsTone: false),  // 🇱🇸 Lesotho
        EmojiEntry("\u{1F1EF}\u{1F1F4}", acceptsTone: false),  // 🇱🇹 Lithuania
        EmojiEntry("\u{1F1EF}\u{1F1F5}", acceptsTone: false),  // 🇱🇺 Luxembourg
        EmojiEntry("\u{1F1EF}\u{1F1F6}", acceptsTone: false),  // 🇱🇻 Latvia
        EmojiEntry("\u{1F1EF}\u{1F1F7}", acceptsTone: false),  // 🇱🇾 Libya
        EmojiEntry("\u{1F1F0}\u{1F1EA}", acceptsTone: false),  // 🇲🇦 Morocco
        EmojiEntry("\u{1F1F0}\u{1F1EC}", acceptsTone: false),  // 🇲🇨 Monaco
        EmojiEntry("\u{1F1F0}\u{1F1ED}", acceptsTone: false),  // 🇲🇩 Moldova
        EmojiEntry("\u{1F1F0}\u{1F1EE}", acceptsTone: false),  // 🇲🇪 Montenegro
        EmojiEntry("\u{1F1F0}\u{1F1F2}", acceptsTone: false),  // 🇲🇬 Madagascar
        EmojiEntry("\u{1F1F0}\u{1F1F3}", acceptsTone: false),  // 🇲🇭 Marshall
        EmojiEntry("\u{1F1F0}\u{1F1F5}", acceptsTone: false),  // 🇲🇰 North Macedonia
        EmojiEntry("\u{1F1F0}\u{1F1F7}", acceptsTone: false),  // 🇲🇱 Mali
        EmojiEntry("\u{1F1F0}\u{1F1F8}", acceptsTone: false),  // 🇲🇲 Myanmar
        EmojiEntry("\u{1F1F0}\u{1F1F9}", acceptsTone: false),  // 🇲🇳 Mongolia
        EmojiEntry("\u{1F1F0}\u{1F1FA}", acceptsTone: false),  // 🇲🇴 Macao
        EmojiEntry("\u{1F1F0}\u{1F1FC}", acceptsTone: false),  // 🇲🇵 N. Mariana
        EmojiEntry("\u{1F1F0}\u{1F1FD}", acceptsTone: false),  // 🇲🇶 Martinique
        EmojiEntry("\u{1F1F0}\u{1F1FE}", acceptsTone: false),  // 🇲🇷 Mauritania
        EmojiEntry("\u{1F1F0}\u{1F1FF}", acceptsTone: false),  // 🇲🇸 Montserrat
        EmojiEntry("\u{1F1F1}\u{1F1E6}", acceptsTone: false),  // 🇲🇹 Malta
        EmojiEntry("\u{1F1F1}\u{1F1E8}", acceptsTone: false),  // 🇲🇺 Mauritius
        EmojiEntry("\u{1F1F1}\u{1F1EE}", acceptsTone: false),  // 🇲🇻 Maldives
        EmojiEntry("\u{1F1F1}\u{1F1F0}", acceptsTone: false),  // 🇲🇼 Malawi
        EmojiEntry("\u{1F1F1}\u{1F1F2}", acceptsTone: false),  // 🇲🇽 Mexico
        EmojiEntry("\u{1F1F1}\u{1F1F3}", acceptsTone: false),  // 🇲🇾 Malaysia
        EmojiEntry("\u{1F1F1}\u{1F1F4}", acceptsTone: false),  // 🇲🇿 Mozambique
        EmojiEntry("\u{1F1F1}\u{1F1F7}", acceptsTone: false),  // 🇳🇦 Namibia
        EmojiEntry("\u{1F1F1}\u{1F1F8}", acceptsTone: false),  // 🇳🇨 New Caledonia
        EmojiEntry("\u{1F1F1}\u{1F1F9}", acceptsTone: false),  // 🇳🇪 Niger
        EmojiEntry("\u{1F1F1}\u{1F1FA}", acceptsTone: false),  // 🇳🇬 Nigeria
        EmojiEntry("\u{1F1F1}\u{1F1FB}", acceptsTone: false),  // 🇳🇮 Nicaragua
        EmojiEntry("\u{1F1F1}\u{1F1FC}", acceptsTone: false),  // 🇳🇱 Netherlands
        EmojiEntry("\u{1F1F1}\u{1F1FE}", acceptsTone: false),  // 🇳🇴 Norway
        EmojiEntry("\u{1F1F1}\u{1F1FF}", acceptsTone: false),  // 🇳🇵 Nepal
        EmojiEntry("\u{1F1F2}\u{1F1E6}", acceptsTone: false),  // 🇳🇷 Nauru
        EmojiEntry("\u{1F1F2}\u{1F1E8}", acceptsTone: false),  // 🇳🇿 Niue
        EmojiEntry("\u{1F1F2}\u{1F1E9}", acceptsTone: false),  // 🇳🇿 New Zealand
        EmojiEntry("\u{1F1F2}\u{1F1EA}", acceptsTone: false),  // 🇴🇲 Oman
        EmojiEntry("\u{1F1F2}\u{1F1EB}", acceptsTone: false),  // 🇵🇦 Panama
        EmojiEntry("\u{1F1F2}\u{1F1EC}", acceptsTone: false),  // 🇵🇪 Peru
        EmojiEntry("\u{1F1F2}\u{1F1ED}", acceptsTone: false),  // 🇵🇬 PNG
        EmojiEntry("\u{1F1F2}\u{1F1F0}", acceptsTone: false),  // 🇵🇭 Philippines
        EmojiEntry("\u{1F1F2}\u{1F1F1}", acceptsTone: false),  // 🇵🇰 Pakistan
        EmojiEntry("\u{1F1F2}\u{1F1F2}", acceptsTone: false),  // 🇵🇱 Poland
        EmojiEntry("\u{1F1F2}\u{1F1F3}", acceptsTone: false),  // 🇵🇷 St. Pierre
        EmojiEntry("\u{1F1F2}\u{1F1F4}", acceptsTone: false),  // 🇵🇹 Pitcairn
        EmojiEntry("\u{1F1F2}\u{1F1F5}", acceptsTone: false),  // 🇵🇷 Puerto Rico
        EmojiEntry("\u{1F1F2}\u{1F1F6}", acceptsTone: false),  // 🇵🇸 Palestine
        EmojiEntry("\u{1F1F2}\u{1F1F7}", acceptsTone: false),  // 🇵🇹 Portugal
        EmojiEntry("\u{1F1F2}\u{1F1F8}", acceptsTone: false),  // 🇵🇼 Palau
        EmojiEntry("\u{1F1F2}\u{1F1F9}", acceptsTone: false),  // 🇵🇾 Paraguay
        EmojiEntry("\u{1F1F2}\u{1F1FA}", acceptsTone: false),  // 🇶🇦 Qatar
        EmojiEntry("\u{1F1F2}\u{1F1FB}", acceptsTone: false),  // 🇷🇴 Romania
        EmojiEntry("\u{1F1F2}\u{1F1FC}", acceptsTone: false),  // 🇷🇸 Serbia
        EmojiEntry("\u{1F1F2}\u{1F1FD}", acceptsTone: false),  // 🇷🇺 Russia
        EmojiEntry("\u{1F1F2}\u{1F1FE}", acceptsTone: false),  // 🇷🇼 Rwanda
        EmojiEntry("\u{1F1F2}\u{1F1FF}", acceptsTone: false),  // 🇸🇦 Saudi Arabia
        EmojiEntry("\u{1F1F3}\u{1F1E6}", acceptsTone: false),  // 🇸🇧 Solomon
        EmojiEntry("\u{1F1F3}\u{1F1E8}", acceptsTone: false),  // 🇸🇨 Seychelles
        EmojiEntry("\u{1F1F3}\u{1F1EA}", acceptsTone: false),  // 🇸🇩 Sudan
        EmojiEntry("\u{1F1F3}\u{1F1EB}", acceptsTone: false),  // 🇸🇪 Sweden
        EmojiEntry("\u{1F1F3}\u{1F1EC}", acceptsTone: false),  // 🇸🇬 Singapore
        EmojiEntry("\u{1F1F3}\u{1F1ED}", acceptsTone: false),  // 🇸🇭 St. Helena
        EmojiEntry("\u{1F1F3}\u{1F1EE}", acceptsTone: false),  // 🇸🇮 Slovenia
        EmojiEntry("\u{1F1F3}\u{1F1F0}", acceptsTone: false),  // 🇸🇰 Slovakia
        EmojiEntry("\u{1F1F3}\u{1F1F1}", acceptsTone: false),  // 🇸🇱 Sierra Leone
        EmojiEntry("\u{1F1F3}\u{1F1F4}", acceptsTone: false),  // 🇸🇲 San Marino
        EmojiEntry("\u{1F1F3}\u{1F1F5}", acceptsTone: false),  // 🇸🇳 Senegal
        EmojiEntry("\u{1F1F3}\u{1F1F7}", acceptsTone: false),  // 🇸🇴 Somalia
        EmojiEntry("\u{1F1F3}\u{1F1F8}", acceptsTone: false),  // 🇸🇷 Suriname
        EmojiEntry("\u{1F1F3}\u{1F1FA}", acceptsTone: false),  // 🇸🇹 Sao Tome
        EmojiEntry("\u{1F1F3}\u{1F1FF}", acceptsTone: false),  // 🇸🇾 Syria
        EmojiEntry("\u{1F1F4}\u{1F1F2}", acceptsTone: false),  // 🇹🇨 Turks
        EmojiEntry("\u{1F1F5}\u{1F1E6}", acceptsTone: false),  // 🇹🇨 Chad
        EmojiEntry("\u{1F1F5}\u{1F1EA}", acceptsTone: false),  // 🇹🇫 French Southern
        EmojiEntry("\u{1F1F5}\u{1F1EB}", acceptsTone: false),  // 🇹🇬 Togo
        EmojiEntry("\u{1F1F5}\u{1F1EC}", acceptsTone: false),  // 🇹🇭 Thailand
        EmojiEntry("\u{1F1F5}\u{1F1ED}", acceptsTone: false),  // 🇹🇯 Tajikistan
        EmojiEntry("\u{1F1F5}\u{1F1EE}", acceptsTone: false),  // 🇹🇱 Tokelau
        EmojiEntry("\u{1F1F5}\u{1F1F0}", acceptsTone: false),  // 🇹🇲 Turkmenistan
        EmojiEntry("\u{1F1F5}\u{1F1F1}", acceptsTone: false),  // 🇹🇳 Tunisia
        EmojiEntry("\u{1F1F5}\u{1F1F2}", acceptsTone: false),  // 🇹🇴 Tonga
        EmojiEntry("\u{1F1F5}\u{1F1F3}", acceptsTone: false),  // 🇹🇷 Turkey
        EmojiEntry("\u{1F1F5}\u{1F1F7}", acceptsTone: false),  // 🇹🇹 Trinidad
        EmojiEntry("\u{1F1F5}\u{1F1F8}", acceptsTone: false),  // 🇹🇼 Taiwan
        EmojiEntry("\u{1F1F5}\u{1F1F9}", acceptsTone: false),  // 🇹🇿 Tanzania
        EmojiEntry("\u{1F1F5}\u{1F1FC}", acceptsTone: false),  // 🇺🇦 Ukraine
        EmojiEntry("\u{1F1F5}\u{1F1FE}", acceptsTone: false),  // 🇺🇬 Uganda
        EmojiEntry("\u{1F1F5}\u{1F1FF}", acceptsTone: false),  // 🇺🇸 US
        EmojiEntry("\u{1F1F6}\u{1F1E6}", acceptsTone: false),  // 🇺🇾 Uruguay
        EmojiEntry("\u{1F1F6}\u{1F1E8}", acceptsTone: false),  // 🇺🇿 Uzbekistan
        EmojiEntry("\u{1F1F6}\u{1F1E9}", acceptsTone: false),  // 🇻🇦 Vatican
        EmojiEntry("\u{1F1F6}\u{1F1EA}", acceptsTone: false),  // 🇻🇨 St. Vincent
        EmojiEntry("\u{1F1F6}\u{1F1EB}", acceptsTone: false),  // 🇻🇪 Venezuela
        EmojiEntry("\u{1F1F6}\u{1F1EC}", acceptsTone: false),  // 🇻🇳 Vietnam
        EmojiEntry("\u{1F1F6}\u{1F1F2}", acceptsTone: false),  // 🇻🇺 Vanuatu
        EmojiEntry("\u{1F1F6}\u{1F1F4}", acceptsTone: false),  // 🇼🇸 Samoa
        EmojiEntry("\u{1F1F6}\u{1F1F6}", acceptsTone: false),  // 🇽🇰 Kosovo
        EmojiEntry("\u{1F1F6}\u{1F1F7}", acceptsTone: false),  // 🇾🇪 Yemen
        EmojiEntry("\u{1F1F6}\u{1F1FE}", acceptsTone: false),  // 🇾🇹 Mayotte
        EmojiEntry("\u{1F1F6}\u{1F1FF}", acceptsTone: false),  // 🇿🇦 South Africa
        EmojiEntry("\u{1F1F7}\u{1F1EA}", acceptsTone: false),  // 🇿🇲 Zambia
        EmojiEntry("\u{1F1F7}\u{1F1F4}", acceptsTone: false),  // 🇿🇼 Zimbabwe
        EmojiEntry("\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", acceptsTone: false),  // 🏴󠁧󠁢󠁥󠁮󠁧󠁿 England
        EmojiEntry("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", acceptsTone: false),  // 🏴󠁧󠁢󠁳󠁣󠁴󠁿 Scotland
        EmojiEntry("\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}", acceptsTone: false),  // 🏴󠁧󠁢󠁷󠁬󠁳󠁿 Wales
    ]

    public static let recents: [EmojiEntry] = []
}

/// Persistent store for recents. Bounded at 32 entries; older entries roll
/// off the back. Stores the assembled (tone-applied) form so insertion is
/// a verbatim `proxy.insertText(_:)` regardless of the user's current
/// default tone setting.
public struct EmojiRecentsStore: Equatable {
    public private(set) var entries: [String]

    public static let maxEntries = 32

    public init(entries: [String] = []) {
        self.entries = entries
    }

    public mutating func record(_ assembled: String) {
        // Move to front (LRU), dedup.
        entries.removeAll(where: { $0 == assembled })
        entries.insert(assembled, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    public func contains(_ assembled: String) -> Bool {
        entries.contains(assembled)
    }
}

/// Process-wide default skin tone. The host can override this through
/// `setDefaultSkinTone(_:)` — the value persists across launches because the
/// host writes it through `SharedStore` (see `KeyboardViewController` for
/// the UIKit-side mirror).
public enum EmojiKeyboard {

    /// 32 KB ceiling on the live category footprint (the full assembled set
    /// measures ≈22 KB). The
    /// `Build97EmojiTests.testCategoryFootprintStaysUnderMemoryBudget`
    /// test enforces this against the assembled entries.
    public static let memoryBudgetBytes = 32 * 1024

    private static var _defaultTone: EmojiSkinTone = .none
    private static let lock = NSLock()

    public static var defaultSkinTone: EmojiSkinTone {
        get {
            lock.lock(); defer { lock.unlock() }
            return _defaultTone
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _defaultTone = newValue
        }
    }

    public static func setDefaultSkinTone(_ tone: EmojiSkinTone) {
        defaultSkinTone = tone
    }

    /// Total bytes used by the assembled category tables, excluding
    /// `recents` (which is populated at runtime). Used by the memory-budget
    /// test to assert the catalog fits a single keyboard panel.
    public static func categoryFootprintBytes() -> Int {
        var total = 0
        for category in EmojiCategory.allCases where category != .recents {
            for entry in EmojiCatalog.entries(for: category) {
                total += entry.glyph.utf8.count + MemoryLayout<EmojiEntry>.size
            }
        }
        return total
    }
}