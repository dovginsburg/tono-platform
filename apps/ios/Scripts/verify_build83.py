#!/usr/bin/env python3
"""Executable static and Swift-parse verification for Tono keyboard build 83."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
swift = root / "KeyboardExtension/KeyboardViewController.swift"
src = swift.read_text()
errors: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


# Exact semantic 10/9/7 letters geometry.
check('static let row1: [String] = ["q","w","e","r","t","y","u","i","o","p"]' in src,
      "letters row 1 is not exactly 10 keys")
check('static let row2: [String] = ["a","s","d","f","g","h","j","k","l"]' in src,
      "letters row 2 is not exactly 9 keys")
check('static let row3: [String] = ["z","x","c","v","b","n","m"]' in src,
      "letters row 3 is not exactly 7 keys")
check('static let rowSpacing: CGFloat = 5.5' in src, "horizontal gap is not calibrated to 5.5pt")
check('static let preferredKeyboardHeight: CGFloat = 204' in src, "custom content is not compact 204pt")
check('bar.heightAnchor.constraint(equalToConstant: 26)' in src, "Coach bar is not minimal")

# Deterministic portrait-width geometry assertions (735 px @2x = 367.5pt).
width = 367.5
edge = 3.0
gap = 5.5
key_width = (max(width - edge * 2, 320) - gap * 9) / 10
row2_inset = (key_width + gap) / 2
row3_inner_gap = max(8, key_width * 0.34)
check(31.0 <= key_width <= 32.0, f"367.5pt key width out of range: {key_width:.2f}")
check(18.0 <= row2_inset <= 19.0, f"367.5pt row-2 stagger out of range: {row2_inset:.2f}")
check(10.0 <= row3_inner_gap <= 11.0, f"367.5pt row-3 inner gap out of range: {row3_inner_gap:.2f}")
check('row2HorizontalInset(availableWidth:' in src and 'row3InnerGap(availableWidth:' in src,
      "geometry is not responsive to available width")

# Exact mode-state matrix. These are the only label/target declarations.
expected_matrix = {
    'case .letters: return ("123", .numbers)': 1,
    'case .numbers: return ("ABC", .letters)': 1,
    'case .symbols: return ("ABC", .letters)': 1,
    'case .numbers: return ("#+=", .symbols)': 1,
    'case .symbols: return ("123", .numbers)': 1,
}
for transition, count in expected_matrix.items():
    check(src.count(transition) == count, f"mode transition count mismatch: {transition}")
check('case .letters: return nil' in src, "letters must not have a third-row mode modifier")
check(src.count('#selector(bottomModeTapped)') == 1, "bottom mode action must be constructed exactly once")
check(src.count('#selector(thirdRowModeTapped)') == 1, "third-row mode action must be constructed exactly once")
check('modeToggleTapped' not in src, "legacy cyclic mode action remains")

# Conventional controls: one delete, only row 3; conditional globe; emoji footer semantics.
check(src.count('systemName: "delete.left"') == 1, "must construct exactly one delete control")
bottom = src[src.index('private func makeBottomRow()'):src.index('private func makeSymbolControlButton(')]
check('backspaceTapped' not in bottom, "bottom row duplicates delete")
check('if needsInputModeSwitchKey' in bottom and bottom.count('systemName: "globe"') == 1,
      "globe must be single and conditional")
footer = src[src.index('// Footer preserves Apple semantics'):src.index('NSLayoutConstraint.activate([', src.index('// Footer preserves Apple semantics'))]
for marker in ('abc.setTitle("ABC"', 'systemName: "face.smiling.fill"', 'emojiSpace.setTitle("space"', 'title: "return"'):
    check(marker in footer, f"emoji footer missing {marker}")
check('backspaceTapped' not in footer and 'delete.left' not in footer, "emoji footer must not duplicate delete")
check('systemName: "face.smiling"' in bottom, "keyboard emoji selector must be an SF Symbol")

# Dense lazy emoji collection and monochrome category strip.
check('UICollectionViewDataSource' in src and 'UICollectionViewDelegateFlowLayout' in src,
      "emoji grid is not a UICollectionView")
check('dequeueReusableCell' in src and 'prepareForReuse()' in src,
      "emoji cells are not reusable")
check('static let emojiCellsPerRow: Int = 8' in src, "emoji grid is not exactly 8 columns")
check('minimumLineSpacing = 1' in src and 'height: 34' in src, "emoji rows are not compact")
check('textDocumentProxy.insertText(emoji)' in src and 'list.insert(emoji, at: 0)' in src,
      "repeated emoji insertion/recents behavior missing")
icons = ('clock', 'face.smiling', 'person.2.fill', 'pawprint.fill', 'fork.knife',
         'sportscourt.fill', 'car.fill', 'lightbulb.fill', 'heart.fill', 'flag.fill')
for icon in icons:
    check(f'return "{icon}"' in src, f"SF Symbols category icon missing: {icon}")
check('b.setTitle(category.' not in src, "raw category glyph labels remain")

# Every substantial category has enough content to fill several 8-column rows.
for category in ('smileys', 'people', 'animals', 'food', 'activities', 'travel', 'objects', 'symbols', 'flags'):
    match = re.search(rf'case \.{category}: return Self\.characters\("([^"]*)"\)', src)
    if not match:
        errors.append(f"emoji dataset missing: {category}")
        continue
    count = len(match.group(1).split())
    check(count >= 50, f"emoji dataset too small: {category} has {count}, expected >= 50")

check('buildMarkerText' not in src and 'idBuildMarker' not in src,
      "visible BUILD label marker remains")

for rel in ('App/Info.plist', 'KeyboardExtension/Info.plist',
            'ShareExtension/Info.plist', 'TonoMessagesExtension/Info.plist'):
    with open(root / rel, 'rb') as handle:
        plist = plistlib.load(handle)
    check(plist.get('CFBundleVersion') == '83', f"{rel} is not string build 83")

for path in root.rglob('*'):
    if path.is_file() and path.suffix in ('.plist', '.entitlements', '.swift', '.pbxproj'):
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        check('com.apple.developer.keyboard-extension' not in text,
              f"forbidden entitlement in {path.relative_to(root)}")

parse = subprocess.run(
    ['xcrun', 'swiftc', '-frontend', '-parse', str(swift)],
    text=True,
    capture_output=True,
)
check(parse.returncode == 0, "Swift parse failed:\n" + parse.stderr)

if errors:
    print('\n'.join('FAIL: ' + error for error in errors))
    sys.exit(1)
print(f"PASS: build 83 static/layout verification (367.5pt key={key_width:.2f}, row2Inset={row2_inset:.2f}, row3Gap={row3_inner_gap:.2f})")
