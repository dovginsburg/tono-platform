#!/usr/bin/env python3
"""Static build-82 keyboard layout regression checks."""
from pathlib import Path
import plistlib, re, sys
root = Path(__file__).resolve().parents[1]
src = (root / "KeyboardExtension/KeyboardViewController.swift").read_text()
errors=[]
def check(ok,msg):
    if not ok: errors.append(msg)
check('static let row1: [String] = ["q","w","e","r","t","y","u","i","o","p"]' in src,"letters row1 is not 10 keys")
check('static let row2: [String] = ["a","s","d","f","g","h","j","k","l"]' in src,"letters row2 is not 9 keys")
check('static let row3: [String] = ["z","x","c","v","b","n","m"]' in src,"letters row3 is not 7 keys")
check(src.count('systemName: "delete.left"') == 1,"letters layout must construct exactly one delete control")
bottom=src[src.index('private func makeBottomRow()'):src.index('private func makeSymbolControlButton(')]
check('backspaceTapped' not in bottom,"bottom row duplicates delete")
check('if needsInputModeSwitchKey' in bottom and bottom.count('systemName: "globe"') == 1,"globe must be single and conditional")
check('title: "🌐"' not in src and 'title: "\\u{1F60A}"' not in src,"mode controls use colored emoji glyphs")
check('UIImage(systemName: shiftSymbolName)' in src and '"shift.fill"' in src,"shift is not an SF Symbol")
check('systemName: "face.smiling"' in src,"emoji mode control is not an SF Symbol")
check('preferredKeyboardHeight' in src and 'bar.heightAnchor.constraint(equalToConstant: 34)' in src,"compact height/header markers missing")
check('textDocumentProxy.insertText(emoji)' in src and 'list.insert(emoji, at: 0)' in src,"emoji insertion/recents markers missing")
for cat in ('recents','smileys','people','animals','food','activities','travel','objects','symbols','flags'):
    check(f'case .{cat}' in src or f'case {cat}' in src, f'emoji category missing: {cat}')
for rel in ('App/Info.plist','KeyboardExtension/Info.plist','ShareExtension/Info.plist','TonoMessagesExtension/Info.plist'):
    with open(root/rel,'rb') as f: p=plistlib.load(f)
    check(p.get('CFBundleVersion') == '82',f'{rel} is not build 82')
for p in root.rglob('*'):
    if p.is_file() and p.suffix in ('.plist','.entitlements','.swift','.pbxproj'):
        try: text=p.read_text()
        except UnicodeDecodeError: continue
        check('com.apple.developer.keyboard-extension' not in text,f'forbidden entitlement in {p.relative_to(root)}')
if errors:
    print('\n'.join('FAIL: '+e for e in errors)); sys.exit(1)
print('PASS: build 82 keyboard static/layout verification')
