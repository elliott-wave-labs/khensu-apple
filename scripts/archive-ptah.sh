#!/usr/bin/env bash
# Archive khėnsu.ñü (nu.khensu.ptah) for App Store Connect and optional IPA export.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${PTAH_ARCHIVE_DIR:-$HOME/Desktop/khensu-ptah-submit}"
ARCHIVE="$OUT/Ptah.xcarchive"
cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate
mkdir -p "$OUT"
echo "==> archiving Ptah → $ARCHIVE"
xcodebuild -project Ptah.xcodeproj -scheme Ptah -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=LHS49D8RYY
echo "==> export IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$OUT/export" \
  -exportOptionsPlist App/Support/ExportOptions-AppStore.plist \
  -allowProvisioningUpdates || {
  echo "export failed (open $ARCHIVE in Xcode Organizer to distribute manually)"
  exit 0
}
# Export may name the IPA after the product or scheme.
for f in "$OUT"/export/*.ipa; do
  [ -f "$f" ] || continue
  cp -f "$f" "$OUT/khensu.nu.ipa"
  echo "IPA: $OUT/khensu.nu.ipa"
done
echo "Archive: $ARCHIVE"
echo "Open Organizer or: open \"$ARCHIVE\""
