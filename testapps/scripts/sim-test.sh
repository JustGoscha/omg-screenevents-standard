#!/bin/sh
# Builds both test apps, installs SE Recorder, and runs the two-app UI test in the simulator.
# Usage: scripts/sim-test.sh ["iPad Pro 11-inch (M4)"]
set -e
cd "$(dirname "$0")/.."
SIM="${1:-iPad Pro 11-inch (M4)}"
DEST="platform=iOS Simulator,name=$SIM"
DD=build/DerivedData
xcodegen generate -q
xcrun simctl boot "$SIM" 2>/dev/null || true
xcodebuild -project ScreenEventsTestApps.xcodeproj -scheme ScreenEventsTestApps -destination "$DEST" \
  -derivedDataPath $DD build-for-testing -quiet
xcrun simctl install "$SIM" $DD/Build/Products/Debug-iphonesimulator/SERecorder.app
xcodebuild -project ScreenEventsTestApps.xcodeproj -scheme ScreenEventsTestApps -destination "$DEST" \
  -derivedDataPath $DD -resultBundlePath build/sim-test-$(date +%s).xcresult test-without-building 2>&1 \
  | grep -E "SOURCE STATUS|RECORDER COUNTS|ROTATED COUNTS|^(listener|messages|samples|phases|display):|error:|Test Case|TEST (SUCCEEDED|FAILED)|\*\* TEST"
