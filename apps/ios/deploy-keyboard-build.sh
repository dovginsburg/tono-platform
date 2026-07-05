#!/usr/bin/env bash
# deploy-keyboard-build.sh — staged for Dov's Aqua session.
# Pre-conditions assumed:
#   - Working dir: /Users/Ezra/Projects/apps/tono/ios
#   - macOS keychain has the "Apple Distribution" certificate and the bound
#     ASC provisioning profiles:
#       "ASC AppStore com.tonoit.app"
#       "ASC AppStore com.tonoit.app.keyboard"
#   - /tmp/tono-export/working-api-key.json contains the App Store Connect
#     API key (PSS5YP9VS4) for fastlane pilot.
#   - The Tono backend (api.tonoit.com) is reachable.
#
# This script:
#   1. Archives the Release Tono build with manual code-signing pinned to
#      "ASC AppStore com.tonoit.app" + "ASC AppStore com.tonoit.app.keyboard".
#   2. Exports the archive as an .ipa with ExportOptions.plist (app-store).
#   3. Uploads to TestFlight via fastlane pilot using the API key in
#      /tmp/tono-export/working-api-key.json.
#
# Run from /Users/Ezra/Projects/apps/tono/ios with:
#   bash deploy-keyboard-build.sh

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Tono.xcodeproj"
SCHEME="Tono"
CONFIGURATION="Release"
DATE_STAMP="$(date -u +%Y-%m-%d)"
ARCHIVE_DIR="/Users/Ezra/Library/Developer/Xcode/Archives/${DATE_STAMP}"
ARCHIVE_PATH="${ARCHIVE_DIR}/Tono-keyboard-build.xcarchive"
EXPORT_DIR="/tmp/tono-export/out-keyboard"
EXPORT_OPTIONS="/tmp/tono-export/ExportOptions.plist"
PILOT_API_KEY_PATH="/tmp/tono-export/working-api-key.json"
ITC_TEAM_ID="4938S9TTBM"
LOG_FILE="/tmp/tono-export/deploy-keyboard-build.log"

mkdir -p "${ARCHIVE_DIR}"
mkdir -p "${EXPORT_DIR}"

echo "=== Tono keyboard-rewrite deploy ===" | tee -a "${LOG_FILE}"
echo "Date:    $(date -u +%FT%TZ)"               | tee -a "${LOG_FILE}"
echo "Project: ${PROJECT}"                        | tee -a "${LOG_FILE}"
echo "Scheme:  ${SCHEME} (${CONFIGURATION})"      | tee -a "${LOG_FILE}"
echo "Archive: ${ARCHIVE_PATH}"                   | tee -a "${LOG_FILE}"
echo "Export:  ${EXPORT_DIR}"                     | tee -a "${LOG_FILE}"
echo "Apple ID / Team: dov.ginsburg@gmail.com / ${ITC_TEAM_ID}" | tee -a "${LOG_FILE}"
echo ""                                           | tee -a "${LOG_FILE}"

# --- Step 1: archive ---------------------------------------------------------
echo "[1/3] xcodebuild archive …" | tee -a "${LOG_FILE}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -archivePath "${ARCHIVE_PATH}" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Distribution" \
  archive 2>&1 | tee -a "${LOG_FILE}"

# --- Step 2: exportArchive ---------------------------------------------------
echo "[2/3] xcodebuild -exportArchive …" | tee -a "${LOG_FILE}"
xcodebuild \
  -exportArchive \
  -archivePath "${ARCHIVE_PATH}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "${PILOT_API_KEY_PATH}" \
  -authenticationKeyID "PSS5YP9VS4" \
  -authenticationKeyIssuerID "93f12e0b-cd6e-4095-95a8-172311d722cd" \
  2>&1 | tee -a "${LOG_FILE}"

# --- Step 3: upload to TestFlight -------------------------------------------
echo "[3/3] fastlane pilot upload …" | tee -a "${LOG_FILE}"
PILOT_API_KEY_PATH="${PILOT_API_KEY_PATH}" \
FASTLANE_ITC_TEAM_ID="${ITC_TEAM_ID}" \
fastlane pilot upload \
  --ipa "${EXPORT_DIR}/Tono it.ipa" \
  --skip_waiting_for_build_processing \
  2>&1 | tee -a "${LOG_FILE}"

echo "" | tee -a "${LOG_FILE}"
echo "=== DONE ===" | tee -a "${LOG_FILE}"
ls -lah "${EXPORT_DIR}" | tee -a "${LOG_FILE}"
