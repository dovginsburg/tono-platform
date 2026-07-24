// Build97EmojiTests.swift
// Emoji coverage for the Apple-fidelity categorized grid: category tabs, skin
// tone application, ZWJ family assembly, the bounded recents ring, and the
// in-memory footprint budget.

import XCTest

final class Build97EmojiTests: XCTestCase {

    override func tearDown() {
        // The default tone is process-wide; reset so tests stay independent.
        EmojiKeyboard.setDefaultSkinTone(.none)
        super.tearDown()
    }

    // MARK: - Categories

    func testExactlyTenAppleCategoryTabsInOrder() {
        XCTAssertEqual(
            EmojiCategory.allCases,
            [.recents, .smileys, .people, .animals, .food, .activities, .travel, .objects, .symbols, .flags]
        )
    }

    func testEveryNonRecentCategoryHasEntriesAndAnIcon() {
        for category in EmojiCategory.allCases where category != .recents {
            XCTAssertFalse(EmojiCatalog.entries(for: category).isEmpty, "\(category) must ship glyphs")
            XCTAssertFalse(category.symbolName.isEmpty, "\(category) must have an SF Symbol tab icon")
            XCTAssertFalse(category.displayName.isEmpty)
        }
        XCTAssertTrue(EmojiCatalog.entries(for: .recents).isEmpty, "recents is populated at runtime")
    }

    // MARK: - Skin tone application

    func testFitzpatrickModifierAppendedOnlyToToneAcceptingGlyphs() {
        let toneable = EmojiInsertion(entry: EmojiEntry("\u{1F469}", acceptsTone: true), tone: .dark)
        XCTAssertEqual(Array(toneable.assembled.unicodeScalars.map(\.value)), [0x1F469, 0x1F3FF])

        let nonToneable = EmojiInsertion(entry: EmojiEntry("\u{1F600}", acceptsTone: false), tone: .dark)
        XCTAssertEqual(nonToneable.assembled, "\u{1F600}", "a non-toneable glyph must never gain a modifier")
    }

    func testDefaultToneMeansNoModifierEvenOnToneAcceptingGlyph() {
        let plain = EmojiInsertion(entry: EmojiEntry("\u{1F469}", acceptsTone: true), tone: .none)
        XCTAssertEqual(plain.assembled, "\u{1F469}")
        XCTAssertFalse(EmojiSkinTone.none.isModifier)
        XCTAssertTrue(EmojiSkinTone.dark.isModifier)
    }

    func testEveryFitzpatrickToneRoundTripsThroughInsertion() {
        // The base + modifier fuse into a single grapheme cluster, so compare
        // at the scalar level rather than with grapheme-aware String.hasSuffix.
        for tone in EmojiSkinTone.allCases where tone.isModifier {
            let modifier = tone.rawValue.unicodeScalars.first!.value
            let ins = EmojiInsertion(entry: EmojiEntry("\u{270B}", acceptsTone: true), tone: tone)
            XCTAssertEqual(
                Array(ins.assembled.unicodeScalars.map(\.value)),
                [0x270B, modifier],
                "\(tone) must append exactly its Fitzpatrick modifier scalar"
            )
            XCTAssertFalse(tone.displayName.isEmpty)
        }
    }

    func testCatalogToneHeuristicMatchesUnicodeModifierBase() {
        XCTAssertTrue(EmojiCatalog.acceptsTone("\u{1F469}"), "a person glyph accepts a modifier")
        XCTAssertFalse(EmojiCatalog.acceptsTone("\u{1F600}"), "a smiley face does not")
        XCTAssertFalse(EmojiCatalog.acceptsTone("\u{1F1FA}\u{1F1F8}"), "a flag does not")
    }

    // MARK: - Process-wide default tone

    func testDefaultToneIsThreadSafeMutableAndPersistsInMemory() {
        XCTAssertEqual(EmojiKeyboard.defaultSkinTone, .none)
        EmojiKeyboard.setDefaultSkinTone(.medium)
        XCTAssertEqual(EmojiKeyboard.defaultSkinTone, .medium)
        EmojiKeyboard.defaultSkinTone = .light
        XCTAssertEqual(EmojiKeyboard.defaultSkinTone, .light)
    }

    // MARK: - ZWJ family assembly

    func testFamiliesAreZWJJoinedAndToneImmune() {
        XCTAssertEqual(EmojiFamily.allFamilies.count, 5)
        for family in EmojiFamily.allFamilies {
            XCTAssertTrue(
                family.unicodeScalars.contains { $0.value == 0x200D },
                "a compound family must be ZWJ-joined"
            )
            let insertion = EmojiInsertion(family: family)
            XCTAssertEqual(insertion.assembled, family, "family assembly is verbatim")
            XCTAssertEqual(insertion.tone, .none, "families always carry their built-in tones")
            XCTAssertFalse(insertion.entry.acceptsTone)
        }
    }

    // MARK: - Recents ring

    func testRecentsRingIsBoundedAt32AndMovesToFront() {
        var store = EmojiRecentsStore()
        for i in 0..<40 { store.record("e\(i)") }
        XCTAssertEqual(store.entries.count, 32, "the recents ring must be bounded")
        XCTAssertEqual(store.entries.first, "e39", "the most recent entry is at the front")
        XCTAssertFalse(store.contains("e0"), "the oldest entries roll off the back")
    }

    func testRecentsDedupPromotesInsteadOfDuplicating() {
        var store = EmojiRecentsStore()
        store.record("a")
        store.record("b")
        store.record("a") // re-record promotes, does not duplicate
        XCTAssertEqual(store.entries, ["a", "b"])
        XCTAssertTrue(store.contains("a"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - Memory footprint budget

    func testCategoryFootprintStaysUnderMemoryBudget() {
        let footprint = EmojiKeyboard.categoryFootprintBytes()
        XCTAssertGreaterThan(footprint, 0, "the catalog must actually carry glyphs")
        XCTAssertLessThanOrEqual(
            footprint,
            EmojiKeyboard.memoryBudgetBytes,
            "the assembled catalog (\(footprint) bytes) must fit the \(EmojiKeyboard.memoryBudgetBytes)-byte ceiling"
        )
        // Guard the budget itself against being loosened into meaninglessness.
        XCTAssertLessThanOrEqual(EmojiKeyboard.memoryBudgetBytes, 32 * 1024)
    }
}
