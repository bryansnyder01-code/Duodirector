#!/usr/bin/env bash
# Phase 6: App Store screenshots from the UI tests (Demo Mode, synthetic cameras).
# Usage: scripts/capture-screenshots.sh ["Simulator name"] [output dir]
# Needs Xcode 16+ (xcresulttool export attachments) and XcodeGen.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone Duo}"
OUT="${2:-Screenshots}"
RESULT="build/Screenshots.xcresult"

xcodegen generate
xcrun simctl boot "$DEVICE" 2>/dev/null || true
# Clean status bar for the App Store.
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true

rm -rf "$RESULT"
xcodebuild test \
  -scheme DuoDirector \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:DuoDirectorUITests/ScreenshotTests \
  -resultBundlePath "$RESULT"

mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$OUT"
echo "Screenshots exported to $OUT (see manifest.json for which test made each file)."
