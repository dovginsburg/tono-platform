#!/usr/bin/env bash
# bump-build.sh — Verify the fixed release build number.
# Build numbers are release inputs, not mutable build output. An Archive must
# not silently change reviewed sources.
#
# EXPECTED_BUILD below is the SINGLE reviewed authority for the shipped build
# number. The Swift guards (Tests/BuildNumberGuardTests.swift,
# Tests/Build101RevenueTests.swift) and Scripts/verify_messages_extension.py all
# READ it from this file rather than hardcoding their own copy, so bumping a
# release means editing this constant and the four Info.plist values it checks —
# never a test. Keeping the pin here (instead of deriving it from the host
# plist) is deliberate: it still catches tooling that silently rewrites all four
# bundles to an unreviewed number.

set -eo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

EXPECTED_BUILD="112"
PLISTS=(
  "App/Info.plist"
  "KeyboardExtension/Info.plist"
  "ShareExtension/Info.plist"
  "TonoMessagesExtension/Info.plist"
)

for relative_path in "${PLISTS[@]}"; do
  plist="${SRCROOT}/${relative_path}"
  if [[ ! -f "$plist" ]]; then
    echo "build-number: missing ${relative_path}" >&2
    exit 1
  fi
  actual=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")
  if [[ "$actual" != "$EXPECTED_BUILD" ]]; then
    echo "build-number: ${relative_path} is ${actual}; expected ${EXPECTED_BUILD}" >&2
    exit 1
  fi
done

echo "build-number: all shipped bundles are build ${EXPECTED_BUILD}"

exit 0
