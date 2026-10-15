#!/usr/bin/env bash
# Archive nu.waves (nu.khensu.waves) for App Store Connect and optional IPA export.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${WAVES_ARCHIVE_DIR:-$HOME/Desktop/khensu-waves-submit}"
ARCHIVE="$OUT/Waves.xcarchive"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate
mkdir -p "$OUT"
echo "==> archiving Waves → $ARCHIVE"
xcodebuild -project Ptah.xcodeproj -scheme Waves -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=LHS49D8RYY
echo "==> export IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist Waves/Support/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates || {
  echo "export failed (open $ARCHIVE in Xcode Organizer to distribute manually)"
  exit 0
}
if [ -f "$OUT/export/nu.waves.ipa" ]; then
  cp -f "$OUT/export/nu.waves.ipa" "$OUT/nu.waves.ipa"
  echo "IPA: $OUT/nu.waves.ipa"
fi
echo "Archive: $ARCHIVE"
echo "Open Organizer or: open \"$ARCHIVE\""
