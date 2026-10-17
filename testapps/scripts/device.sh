#!/bin/sh
# Builds and installs SE Source + SE Recorder (with its broadcast extension) on a connected device.
# Usage: scripts/device.sh <TEAM_ID> [device name or id]
# The team needs App Groups; automatic signing registers the bundle ids and group.app.omg.screenevents.
set -e
cd "$(dirname "$0")/.."
TEAM="${1:?usage: scripts/device.sh <TEAM_ID> [device]}"
DEVICE="${2:-$(xcrun devicectl list devices 2>/dev/null | awk '/available/ && /iPad|iPhone/ {print $3; exit}')}"
[ -n "$DEVICE" ] || { echo "no connected device"; exit 1; }
DD=build/DerivedData
xcodegen generate -q
xcodebuild -project ScreenEventsTestApps.xcodeproj -scheme ScreenEventsTestApps -destination "generic/platform=iOS" \
  -derivedDataPath $DD DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build -quiet
for app in SESource SERecorder; do
  xcrun devicectl device install app --device "$DEVICE" $DD/Build/Products/Debug-iphoneos/$app.app
done
echo "installed on $DEVICE"
