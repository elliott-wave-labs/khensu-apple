#!/usr/bin/env bash
# Archive nu.moments (nu.khensu.moments) for App Store Connect and optional IPA export.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${MOMENTS_ARCHIVE_DIR:-$HOME/Desktop/khensu-moments-submit}"
ARCHIVE="$OUT/Moments.xcarchive"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate
mkdir -p "$OUT"
echo "==> archiving Moments → $ARCHIVE"
xcodebuild -project Ptah.xcodeproj -scheme Moments -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=LHS49D8RYY
echo "==> export IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist Moments/Support/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates || {
  echo "export failed (open $ARCHIVE in Xcode Organizer to distribute manually)"
  exit 0
}
if [ -f "$OUT/export/nu.moments.ipa" ]; then
  cp -f "$OUT/export/nu.moments.ipa" "$OUT/nu.moments.ipa"
  echo "IPA: $OUT/nu.moments.ipa"
fi
echo "Archive: $ARCHIVE"
echo "Open Organizer or: open \"$ARCHIVE\""
