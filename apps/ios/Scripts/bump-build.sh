#!/usr/bin/env bash
# bump-build.sh — Increment CFBundleVersion on every Release archive of Tono.
# Idempotent only in the loose sense: every invocation bumps by 1.
# Wired to the "Tono" target as a Run Script build phase (input file lists
# App/Info.plist + KeyboardExtension/Info.plist so Xcode reruns the phase
# when those files change).
#
# Why this exists:
#   Yesterday the build # froze at v1.0 #8 across 4 archive runs because
#   nothing was bumping CFBundleVersion between runs. TestFlight rejected
#   every duplicate-build archive. This script lives in a Run Script phase
#   so every Release archive bumps automatically — no human step, no
#   stalled pipeline.

set -eo pipefail

# When invoked from Xcode, SRCROOT points at the directory containing the
# target's source files (i.e. the ios/ folder). When invoked by hand for a
# dry run, fall back to the script's own parent directory so `bash
# bump-build.sh` still works.
SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# 1. Bump App/Info.plist CFBundleVersion and (lazily) CFBundleShortVersionString.
APP_PLIST="${SRCROOT}/App/Info.plist"
if [[ ! -f "$APP_PLIST" ]]; then
  echo "bump-build: App/Info.plist not found at $APP_PLIST" >&2
  exit 1
fi

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")
NEXT=$((CURRENT + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$APP_PLIST"
echo "bump-build: App/Info.plist CFBundleVersion $CURRENT -> $NEXT"

# 2. Mirror the same CFBundleVersion into KeyboardExtension/Info.plist so
#    the host .app and the embedded appex stay in lockstep (the host is the
#    only installable unit on TestFlight but mismatched numbers are still
#    confusing).
KB_PLIST="${SRCROOT}/KeyboardExtension/Info.plist"
if [[ -f "$KB_PLIST" ]]; then
  KB_CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$KB_PLIST")
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$KB_PLIST"
  echo "bump-build: KeyboardExtension/Info.plist CFBundleVersion $KB_CURRENT -> $NEXT"
fi

# 3. Mirror the same CFBundleVersion into ShareExtension/Info.plist too.
#    TonoShare ships in v1.0 alongside TonoKeyboard; iOS rejects
#    mismatched host/extension versions, so the bump has to apply to all
#    three plists in lockstep.
SHARE_PLIST="${SRCROOT}/ShareExtension/Info.plist"
if [[ -f "$SHARE_PLIST" ]]; then
  SHARE_CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$SHARE_PLIST")
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$SHARE_PLIST"
  echo "bump-build: ShareExtension/Info.plist CFBundleVersion $SHARE_CURRENT -> $NEXT"
fi

exit 0
