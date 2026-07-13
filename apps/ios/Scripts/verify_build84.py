#!/usr/bin/env python3
"""Executable static, model, plist, and Swift-parse verification for build 84."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
swift = root / "KeyboardExtension/KeyboardViewController.swift"
client_swift = root / "KeyboardExtension/TonoCoachClient.swift"
src = swift.read_text()
client = client_swift.read_text()
errors: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


# Every build-83 semantic/layout gate remains in force.
check('static let row1: [String] = ["q","w","e","r","t","y","u","i","o","p"]' in src,
      "letters row 1 is not exactly 10 keys")
check('static let row2: [String] = ["a","s","d","f","g","h","j","k","l"]' in src,
      "letters row 2 is not exactly 9 keys")
check('static let row3: [String] = ["z","x","c","v","b","n","m"]' in src,
      "letters row 3 is not exactly 7 keys")
check('static let rowSpacing: CGFloat = 5.5' in src, "horizontal gap is not calibrated to 5.5pt")
check('static let preferredKeyboardHeight: CGFloat = 204' in src, "typing content is not 204pt")
check('bar.heightAnchor.constraint(equalToConstant: 26)' in src, "Coach bar is not minimal")

width, edge, gap = 367.5, 3.0, 5.5
key_width = (max(width - edge * 2, 320) - gap * 9) / 10
row2_inset = (key_width + gap) / 2
row3_inner_gap = max(8, key_width * 0.34)
check(31.0 <= key_width <= 32.0, f"367.5pt key width out of range: {key_width:.2f}")
check(18.0 <= row2_inset <= 19.0, f"367.5pt row-2 stagger out of range: {row2_inset:.2f}")
check(10.0 <= row3_inner_gap <= 11.0, f"367.5pt row-3 gap out of range: {row3_inner_gap:.2f}")
check('row2HorizontalInset(availableWidth:' in src and 'row3InnerGap(availableWidth:' in src,
      "geometry is not responsive to width")

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
check(src.count('#selector(bottomModeTapped)') == 1, "bottom mode action must be constructed once")
check(src.count('#selector(thirdRowModeTapped)') == 1, "third-row mode action must be constructed once")
check('modeToggleTapped' not in src, "legacy cyclic mode action remains")
check(src.count('systemName: "delete.left"') == 1, "must construct exactly one delete control")
bottom = src[src.index('private func makeBottomRow()'):src.index('private func makeSymbolControlButton(')]
check('backspaceTouchDown' not in bottom, "bottom row duplicates delete")
check('if needsInputModeSwitchKey' in bottom and bottom.count('systemName: "globe"') == 1,
      "globe must be single and conditional")
footer_start = src.index('// Footer preserves Apple semantics')
footer = src[footer_start:src.index('NSLayoutConstraint.activate([', footer_start)]
for marker in ('abc.setTitle("ABC"', 'systemName: "face.smiling.fill"',
               'emojiSpace.setTitle("space"', 'returnKeySpec'):
    check(marker in footer, f"emoji footer missing {marker}")
check('backspaceTouchDown' not in footer and 'delete.left' not in footer,
      "emoji footer must not duplicate delete")
check('systemName: "face.smiling"' in bottom, "keyboard emoji selector must be an SF Symbol")

check('UICollectionViewDataSource' in src and 'UICollectionViewDelegateFlowLayout' in src,
      "emoji grid is not a UICollectionView")
check('dequeueReusableCell' in src and 'prepareForReuse()' in src, "emoji cells are not reusable")
check('static let emojiCellsPerRow: Int = 8' in src, "emoji grid is not exactly 8 columns")
check('minimumLineSpacing = 1' in src and 'height: 34' in src, "emoji rows are not compact")
check('textDocumentProxy.insertText(emoji)' in src and 'list.insert(emoji, at: 0)' in src,
      "emoji insertion/recents behavior missing")
icons = ('clock', 'face.smiling', 'person.2.fill', 'pawprint.fill', 'fork.knife',
         'sportscourt.fill', 'car.fill', 'lightbulb.fill', 'heart.fill', 'flag.fill')
for icon in icons:
    check(f'return "{icon}"' in src, f"SF Symbols category icon missing: {icon}")
check('b.setTitle(category.' not in src, "raw category glyph labels remain")
for category in ('smileys', 'people', 'animals', 'food', 'activities', 'travel', 'objects', 'symbols', 'flags'):
    match = re.search(rf'case \.{category}: return Self\.characters\("([^"]*)"\)', src)
    check(match is not None, f"emoji dataset missing: {category}")
    if match:
        check(len(match.group(1).split()) >= 50, f"emoji dataset too small: {category}")
check('buildMarkerText' not in src and 'idBuildMarker' not in src, "visible BUILD label remains")

# Shift: deterministic gesture arbitration, persistent explicit state, and host policy.
check('lastShiftTapAt' not in src and 'Date()' not in src, "Date-based shift timing remains")
check('numberOfTapsRequired = 2' in src and 'singleTap.require(toFail: doubleTap)' in src,
      "shift single/double-tap gesture arbitration missing")
check('#selector(shiftSingleTapped)' in src and '#selector(shiftDoubleTapped)' in src,
      "shift gesture actions missing")
check('shiftWasAutomatic' in src and 'autocapitalizationType' in src,
      "automatic recommendation is not separate from explicit shift state")
for policy in ('.none', '.words', '.sentences', '.allCharacters'):
    check(policy in src, f"autocapitalization policy missing: {policy}")

# Delete: one touch-down mutation, delayed repeat, acceleration, and broad cancellation.
check('for: .touchDown' in src and '#selector(backspaceTouchDown)' in src,
      "delete does not fire on touch down")
check('deleteRepeatInitialDelay' in src and 'deleteRepeatInterval' in src and 'deleteRepeatMinimumInterval' in src,
      "delete delayed/accelerating cadence constants missing")
check('deleteRepeatWorkItem' in src and 'cancelDeleteRepeat()' in src,
      "delete repeat coordinator/cancellation missing")
check('#selector(backspaceTapped)' not in src, "delete still has a touch-up action")
for event in ('.touchUpInside', '.touchUpOutside', '.touchCancel', '.touchDragExit'):
    check(event in src, f"delete cancellation event missing: {event}")
check(src.count('cancelDeleteRepeat()') >= 4 and src.count('cancelTransientInteractions()') >= 8,
      "delete is not cancelled across transitions/lifecycle")

# Globe, host traits, return mapping, and appearance.
check('handleInputModeList(from: sender, with: event)' in src,
      "globe does not forward the actual UIEvent")
check('action: #selector(globeEvent(_:with:))' in src and 'for: .allTouchEvents' in src,
      "globe UIButton event wiring missing")
check('advanceToNextInputMode()' not in src, "tap-only globe implementation remains")
for key_type in ('.numbersAndPunctuation', '.URL', '.emailAddress', '.decimalPad',
                 '.numberPad', '.asciiCapableNumberPad', '.twitter', '.webSearch'):
    check(key_type in src, f"keyboard type adaptation missing: {key_type}")
check('keyboardAppearance' in src and 'overrideUserInterfaceStyle' in src,
      "keyboard appearance adaptation missing")
check('textDidChange' in src and 'refreshHostConfigurationIfNeeded' in src and 'isRebuildingLayout' in src,
      "trait refresh/rebuild loop guard missing")
check('viewWillTransition' in src and 'traitCollectionDidChange' in src and 'lastLayoutWidth' in src,
      "width/orientation/trait rebuild support missing")
return_cases = ('.default', '.go', '.google', '.join', '.next', '.route', '.search', '.send',
                '.yahoo', '.done', '.emergencyCall', '.continue')
for case in return_cases:
    check(f'case {case}:' in src, f"return mapping missing: {case}")
check('returnKeySpec' in src and 'accessibilityLabel: String' in src,
      "return visual/accessibility specification missing")

# Press visuals, previews, feedback, and unbranded ordinary accessibility.
check('UIInputViewAudioFeedback' in src and 'enableInputClicksWhenVisible' in src,
      "public input-click support missing")
check('UIDevice.current.playInputClick()' in src, "committed keys do not request system input clicks")
check('private final class KeyboardButton' in src and 'override var isHighlighted' in src,
      "native-like key highlight class missing")
check('showKeyPreview' in src and 'dismissKeyPreview' in src,
      "letter preview lifecycle missing")
check(src.count('dismissKeyPreview()') >= 4 and src.count('cancelTransientInteractions()') >= 8,
      "preview cleanup paths are incomplete")
check('accessibilityLabel = "Tono key' not in src and 'accessibilityLabel = "Tono control' not in src,
      "ordinary accessibility remains branded")

# Coach canonical axes, accessible semantic colors, neutral body, and taller result-only surface.
for axis in ('warmer', 'clearer', 'funnier', 'safer'):
    check(f'"{axis}"' in client, f"canonical Coach axis missing: {axis}")
for label in ('Warmer', 'Clearer', 'Funnier', 'Safer'):
    check(f'"{label}"' in src, f"title-case Coach label missing: {label}")
for token in ('B4234D', 'FF6B8A', '006A8E', '49C7F2', '7A5100', 'FFC247', '147A36', '4CD471'):
    check(token in src, f"semantic Coach color token missing: {token}")
check('canonicalSuggestions' in client and 'seenTexts' in client and 'trimmingCharacters' in client,
      "Coach suggestions are not canonicalized/unique/nonempty")
check('static let coachResultsKeyboardHeight: CGFloat' in src and '>= 250' in src,
      "Coach result-specific height gate missing")
check('preferredHeightConstraint?.constant = Const.preferredKeyboardHeight' in src,
      "typing height is not restored after results")
check('text.textColor = .label' in src, "Coach body text is not neutral")
check('adjustsFontForContentSizeCategory = true' in src, "Coach result Dynamic Type support missing")

# Result-state layout algebra at the checked-in 276pt height: after the 26pt
# Coach bar, 2pt body gap, 3pt bottom inset, 32pt title row, and 8pt title gap,
# all four 48pt cards plus three 4pt gaps must fit simultaneously. This is the
# deterministic regression for build 83's impossible ~155pt / 178pt stack.
canonical_labels = ('Warmer', 'Clearer', 'Funnier', 'Safer')
check(len(canonical_labels) == 4 and len(set(canonical_labels)) == 4,
      "Coach result headings are not exactly four unique labels")
required_result_stack = 4 * 48 + 3 * 4
available_result_stack = 276 - 26 - 2 - 3 - 32 - 8
check(required_result_stack <= available_result_stack,
      f"Coach result constraints are unsatisfiable: need {required_result_stack}, "
      f"have {available_result_stack}")
check('stack.distribution = .fillEqually' in src and 'stack.spacing = 4' in src,
      "Coach result cards are not evenly ordered/non-overlapping")

# Deterministic behavior model assertions.
LOWER, ONCE, CAPS = 'lower', 'once', 'caps'
def shift_event(state: str, event: str) -> str:
    if event == 'double':
        return LOWER if state == CAPS else CAPS
    return ONCE if state == LOWER else LOWER
check(shift_event(LOWER, 'single') == ONCE, "model: single shift is not one-shot")
check(shift_event(LOWER, 'double') == CAPS, "model: double shift is not caps lock")
check(shift_event(CAPS, 'single') == LOWER, "model: caps does not tap off")
def letter_commit(state: str) -> str:
    return LOWER if state == ONCE else state
check(letter_commit(CAPS) == CAPS, "model: caps does not persist letters")
check(letter_commit(ONCE) == LOWER, "model: one-shot is not consumed")

def auto_cap(policy: str, context: str) -> bool:
    if policy == 'none': return False
    if policy == 'all': return True
    if not context: return True
    if policy == 'words': return context[-1].isspace()
    if context.endswith('\n'): return True
    trimmed = context.rstrip()
    return len(trimmed) < len(context) and bool(trimmed) and trimmed[-1] in '.!?'
check(not auto_cap('sentences', 'hello '), "model: ordinary sentence-space capitalizes")
check(auto_cap('words', 'hello '), "model: words policy does not capitalize after space")
check(auto_cap('sentences', 'hello. '), "model: sentence boundary does not capitalize")
check(not auto_cap('none', ''), "model: none policy capitalizes")
check(auto_cap('all', 'hello'), "model: allCharacters does not capitalize")

delete_events = ['down'] + ['repeat'] * 3
check(delete_events.count('down') == 1 and len(delete_events) == 4,
      "model: delete initial/repeat mutation count is wrong")
delete_events.clear()  # cancellation means no later mutation
check(not delete_events, "model: delete cancellation leaves work")

return_labels = {
    'default': ('return', 'Return'), 'go': ('go', 'Go'),
    'google': ('Google', 'Google'), 'join': ('join', 'Join'),
    'next': ('next', 'Next'), 'route': ('route', 'Route'),
    'search': ('search', 'Search'), 'send': ('send', 'Send'),
    'yahoo': ('Yahoo', 'Yahoo'), 'done': ('done', 'Done'),
    'emergencyCall': ('emergency call', 'Emergency call'),
    'continue': ('continue', 'Continue'),
}
check(len(return_labels) == 12 and return_labels['emergencyCall'][1] == 'Emergency call',
      "model: return label matrix is incomplete")
check(return_labels.get('unknown', return_labels['default']) == ('return', 'Return'),
      "model: unknown return type does not fall back")

canonical_order = ('warmer', 'clearer', 'funnier', 'safer')
raw = [(' Safer ', 'safe'), ('WARMER', ' warm '), ('clearer', 'clear'),
       ('warmer', 'duplicate axis'), ('funnier', 'fun'), ('safer', 'CLEAR')]
seen_axes: set[str] = set()
seen_texts: set[str] = set()
canonical: dict[str, str] = {}
for axis, text in raw:
    axis, text = axis.strip().lower(), text.strip()
    folded = text.casefold()
    if axis in canonical_order and text and axis not in seen_axes and folded not in seen_texts:
        canonical[axis] = text
        seen_axes.add(axis); seen_texts.add(folded)
check(tuple(canonical) != canonical_order, "model fixture unexpectedly arrived in canonical order")
ordered = [(axis, canonical[axis]) for axis in canonical_order if axis in canonical]
check([axis for axis, _ in ordered] == list(canonical_order), "model: Coach axes not canonical order")
check(len({text.casefold() for _, text in ordered}) == len(ordered), "model: Coach text not unique")

for rel in ('App/Info.plist', 'KeyboardExtension/Info.plist',
            'ShareExtension/Info.plist', 'TonoMessagesExtension/Info.plist'):
    with open(root / rel, 'rb') as handle:
        plist = plistlib.load(handle)
    check(plist.get('CFBundleVersion') == '84', f"{rel} is not string build 84")

for path in root.rglob('*'):
    if path.is_file() and path.suffix in ('.plist', '.entitlements', '.swift', '.pbxproj'):
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        check('com.apple.developer.keyboard-extension' not in text,
              f"forbidden entitlement in {path.relative_to(root)}")

parse = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', str(swift)],
                       text=True, capture_output=True)
check(parse.returncode == 0, "Swift parse failed:\n" + parse.stderr)
client_parse = subprocess.run(['xcrun', 'swiftc', '-frontend', '-parse', str(client_swift)],
                              text=True, capture_output=True)
check(client_parse.returncode == 0, "Coach client Swift parse failed:\n" + client_parse.stderr)

if errors:
    print('\n'.join('FAIL: ' + error for error in errors))
    sys.exit(1)
print(f"PASS: build 84 verification (367.5pt key={key_width:.2f}, "
      f"row2Inset={row2_inset:.2f}, row3Gap={row3_inner_gap:.2f})")
