#!/bin/zsh
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the app for the Simulator and captures each main screen into
# docs/screenshots/ using the demo launch arguments (seeded MockCore, no lock).
#
# Usage: scripts/screenshots.sh ["iPhone Air"]
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone Air}"
OUT=docs/screenshots
BUNDLE=nu.khensu.ptah
mkdir -p "$OUT"

xcodegen generate --quiet
xcodebuild -project Ptah.xcodeproj -scheme Ptah -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath build/dd build -quiet
APP=build/dd/Build/Products/Debug-iphonesimulator/khensu.nu.app

UDID=$(xcrun simctl list devices available | grep -E "^\s+$DEVICE \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl install "$UDID" "$APP"

shot() {
  local name=$1; shift
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE" -KhensuDemo YES "$@" >/dev/null
  sleep "${WAIT:-4}"
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null
  echo "captured $OUT/$name.png"
}

shot 01-onboarding     -KhensuScreen onboarding
shot 02-lock           -KhensuScreen lock
shot 03-chats          -KhensuTab chats
WAIT=8 shot 04-conversation -KhensuTab chats -KhensuScreen conversation
shot 05-add-contact    -KhensuTab chats -KhensuScreen addContact
WAIT=6 shot 06-safety-number -KhensuTab chats -KhensuScreen safety
shot 07-feed           -KhensuTab feed
shot 08-calls          -KhensuTab calls
shot 09-search         -KhensuTab search
shot 10-settings       -KhensuTab settings
shot 11-devnet         -KhensuTab settings -KhensuScreen devnet
shot 12-about          -KhensuTab settings -KhensuScreen about
WAIT=12 shot 13-network-test -KhensuTab settings -KhensuScreen networkTest

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear
