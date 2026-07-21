#!/usr/bin/env bash
# bump-build.sh — Verify the fixed release build number for build 96.
# Build numbers are release inputs, not mutable build output. An Archive must
# not silently change reviewed build 96 sources.

set -eo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

EXPECTED_BUILD="96"
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
