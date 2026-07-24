// Build97LayerNavigationTests.swift
// State + symbol coverage for the Apple three-layer keyboard navigation graph
// (`TonoKeyboardLayer`) and the canonical row contents (`TonoKeyRows`).
//
// Apple ships exactly three layers with one navigation rule each. These tests
// pin the full graph and the exact key rows so a stray relabel or reordering
// is caught before it ships.

import XCTest

final class Build97LayerNavigationTests: XCTestCase {

    // MARK: - Layer graph

    func testExactlyThreeLayers() {
        XCTAssertEqual(TonoKeyboardLayer.allCases, [.letters, .numbersAndPunctuation, .extendedSymbols])
    }

    func testBottomToggleLabelsMatchApple() {
        XCTAssertEqual(TonoKeyboardLayer.letters.bottomToggleLabel, "123")
        XCTAssertEqual(TonoKeyboardLayer.numbersAndPunctuation.bottomToggleLabel, "ABC")
        XCTAssertEqual(TonoKeyboardLayer.extendedSymbols.bottomToggleLabel, "ABC")
    }

    func testBottomToggleAlwaysReturnsToLettersFromNumericBranch() {
        // Apple rule: the bottom toggle from either numeric layer returns to
        // letters; from letters it enters the numbers layer.
        XCTAssertEqual(TonoKeyboardLayer.letters.bottomToggleTarget, .numbersAndPunctuation)
        XCTAssertEqual(TonoKeyboardLayer.numbersAndPunctuation.bottomToggleTarget, .letters)
        XCTAssertEqual(TonoKeyboardLayer.extendedSymbols.bottomToggleTarget, .letters)
    }

    func testLettersToNumbersAndBackIsReversible() {
        let there = TonoKeyboardLayer.letters.bottomToggleTarget
        XCTAssertEqual(there, .numbersAndPunctuation)
        XCTAssertEqual(there.bottomToggleTarget, .letters, "toggle must be reversible from the numbers layer")
    }

    func testRow3SwapOnlyExistsInNumericBranch() {
        XCTAssertNil(TonoKeyboardLayer.letters.row3SwapLabel, "letters layer has no #+= / 123 swap key")
        XCTAssertEqual(TonoKeyboardLayer.numbersAndPunctuation.row3SwapLabel, "#+=")
        XCTAssertEqual(TonoKeyboardLayer.extendedSymbols.row3SwapLabel, "123")
    }

    func testRow3SwapTogglesBetweenNumbersAndSymbols() {
        XCTAssertEqual(TonoKeyboardLayer.numbersAndPunctuation.row3SwapTarget, .extendedSymbols)
        XCTAssertEqual(TonoKeyboardLayer.extendedSymbols.row3SwapTarget, .numbersAndPunctuation)
        // The swap on the letters layer is a no-op (self), since it has no key.
        XCTAssertEqual(TonoKeyboardLayer.letters.row3SwapTarget, .letters)
    }

    func testFullNavigationWalkVisitsEveryLayerAndReturnsHome() {
        // letters -123-> numbers -#+=-> symbols -123-> numbers -ABC-> letters
        var layer = TonoKeyboardLayer.letters
        layer = layer.bottomToggleTarget
        XCTAssertEqual(layer, .numbersAndPunctuation)
        layer = layer.row3SwapTarget
        XCTAssertEqual(layer, .extendedSymbols)
        layer = layer.row3SwapTarget
        XCTAssertEqual(layer, .numbersAndPunctuation)
        layer = layer.bottomToggleTarget
        XCTAssertEqual(layer, .letters, "the full navigation walk must return home to letters")
    }

    // MARK: - Row contents

    func testLetterRowsAreTheQwertyLayout() {
        XCTAssertEqual(TonoKeyRows.lettersRow1, ["q","w","e","r","t","y","u","i","o","p"])
        XCTAssertEqual(TonoKeyRows.lettersRow2, ["a","s","d","f","g","h","j","k","l"])
        XCTAssertEqual(TonoKeyRows.lettersRow3, ["z","x","c","v","b","n","m"])
        XCTAssertEqual(TonoKeyRows.rows(for: .letters).map(\.count), [10, 9, 7])
    }

    func testNumbersLayerRows() {
        XCTAssertEqual(TonoKeyRows.numbersRow1, ["1","2","3","4","5","6","7","8","9","0"])
        XCTAssertEqual(TonoKeyRows.rows(for: .numbersAndPunctuation).map(\.count), [10, 10, 5])
    }

    func testSymbolLayerRowsCarryExtendedGlyphs() {
        // The extended symbols layer must expose the bracket/brace/math row and
        // the currency + bullet row that Apple's #+= plane ships.
        XCTAssertEqual(TonoKeyRows.symbolsRow1, ["[","]","{","}","#","%","^","*","+","="])
        XCTAssertTrue(TonoKeyRows.symbolsRow2.contains("€"))
        XCTAssertTrue(TonoKeyRows.symbolsRow2.contains("£"))
        XCTAssertTrue(TonoKeyRows.symbolsRow2.contains("¥"))
        XCTAssertTrue(TonoKeyRows.symbolsRow2.contains("•"))
        XCTAssertEqual(TonoKeyRows.rows(for: .extendedSymbols).map(\.count), [10, 10, 5])
    }

    func testPunctuationRow3IsSharedAcrossBothNumericLayers() {
        // Apple keeps the same . , ? ! ' row on both numeric planes.
        XCTAssertEqual(TonoKeyRows.numbersRow3, [".",",","?","!","'"])
        XCTAssertEqual(TonoKeyRows.symbolsRow3, TonoKeyRows.numbersRow3)
    }

    func testEveryLayerYieldsExactlyThreeRows() {
        for layer in TonoKeyboardLayer.allCases {
            XCTAssertEqual(TonoKeyRows.rows(for: layer).count, 3, "\(layer) must lay out three key rows")
        }
    }
}
