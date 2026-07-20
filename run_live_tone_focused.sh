#!/usr/bin/env bash
# run_live_tone_focused.sh
# Smallest runnable Live Tone privacy harness on macOS — no Xcode, no
# iOS Simulator, no UIKit. Compiles and runs the production privacy
# + classifier + session sources directly against the standalone
# verifiers shipped under apps/ios/Scripts/.
#
# This is the executable counterpart to the privacy/focused coverage
# for t_2b5077ba. Run it from the candidate worktree root.
#
# Usage:
#   ./run_live_tone_focused.sh
#
# Exit codes:
#   0  — both verifiers passed; logs under /tmp/litone/
#   1  — privacy verifier compile/runtime failure
#   2  — focused verifier compile/runtime failure
#
# Artifacts (created on success):
#   /tmp/litone/lt_verify          — privacy verifier binary
#   /tmp/litone/lt_verify.log      — privacy verifier stdout/stderr
#   /tmp/litone/lt_focused         — focused verifier binary
#   /tmp/litone/lt_focused.log     — focused verifier stdout/stderr

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The script lives at the candidate worktree root when run from inside
# the worktree, and at the task workspace root (one level above the
# worktree) when copied alongside the other task artifacts.
if [ -d "$SCRIPT_DIR/apps/ios" ]; then
  REPO_ROOT="$SCRIPT_DIR"
elif [ -d "$SCRIPT_DIR/candidate/apps/ios" ]; then
  REPO_ROOT="$SCRIPT_DIR/candidate"
else
  echo "Could not locate candidate worktree from $SCRIPT_DIR" >&2
  exit 1
fi
IOS_DIR="$REPO_ROOT/apps/ios"
ART_DIR="${ART_DIR:-/tmp/litone}"

mkdir -p "$ART_DIR"

cd "$IOS_DIR"

echo "==> compile privacy verifier"
swiftc -o "$ART_DIR/lt_verify" \
  Shared/LiveToneClassifier.swift \
  Shared/LiveToneEligibility.swift \
  Shared/LiveTonePrivacy.swift \
  Shared/LiveToneKeys.swift \
  Shared/LiveToneMasterToggle.swift \
  Shared/LiveToneCounters.swift \
  Shared/LiveToneCopy.swift \
  Scripts/verify_live_tone_privacy.swift

echo "==> run privacy verifier"
"$ART_DIR/lt_verify" 2>&1 | tee "$ART_DIR/lt_verify.log"

echo "==> compile focused verifier"
swiftc -o "$ART_DIR/lt_focused" \
  Shared/LiveToneClassifier.swift \
  Shared/LiveToneSession.swift \
  Shared/LiveTonePrivacy.swift \
  Shared/LiveToneKeys.swift \
  Shared/LiveToneCopy.swift \
  Scripts/verify_live_tone_v1_focused.swift

echo "==> run focused verifier"
"$ART_DIR/lt_focused" 2>&1 | tee "$ART_DIR/lt_focused.log"

echo
echo "==> SHA-256 receipts"
shasum -a 256 "$ART_DIR/lt_verify.log"  "$ART_DIR/lt_focused.log"