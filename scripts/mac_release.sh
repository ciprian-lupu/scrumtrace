#!/usr/bin/env bash
# Developer ID archive + notary + staple + DMG. Fails clearly without Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mac_release.sh must run on macOS" >&2
  exit 2
fi

if [[ "${1:-}" == *Debug* ]]; then
  echo "mac_release.sh is Release-only. Do not sign a shipped binary with ScrumTrace Debug." >&2
  exit 2
fi

TEAM="${DEVELOPMENT_TEAM:-${SCRUMTRACE_DEVELOPMENT_TEAM:-}}"
if [[ -z "$TEAM" ]]; then
  echo "Set DEVELOPMENT_TEAM or SCRUMTRACE_DEVELOPMENT_TEAM to your Apple Team ID." >&2
  exit 2
fi

if [[ -z "${SCRUMTRACE_NOTARY_PROFILE:-}" && ( -z "${APPLE_ID:-}" || -z "${APP_SPECIFIC_PASSWORD:-}" || -z "${APPLE_TEAM_ID:-}" ) ]]; then
  echo "Set SCRUMTRACE_NOTARY_PROFILE or APPLE_ID + APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID." >&2
  exit 2
fi

DERIVED="${SCRUMTRACE_DERIVED:-$HOME/Library/Developer/Xcode/DerivedData/ScrumTraceRelease}"
ARCHIVE="$DERIVED/ScrumTrace.xcarchive"
EXPORT_DIR="$DERIVED/export"
DMG="${SCRUMTRACE_DMG:-$DERIVED/ScrumTrace.dmg}"

echo "archiving Release with Developer ID Application / team $TEAM"
xcodebuild \
  -project ScrumTrace.xcodeproj \
  -scheme ScrumTrace \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  ENABLE_HARDENED_RUNTIME=YES \
  archive

mkdir -p "$EXPORT_DIR"
APP="$ARCHIVE/Products/Applications/ScrumTrace.app"
if [[ ! -d "$APP" ]]; then
  echo "archive produced no ScrumTrace.app" >&2
  exit 1
fi

if [[ -n "${SCRUMTRACE_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$APP" --keychain-profile "$SCRUMTRACE_NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$APP" \
    --apple-id "$APPLE_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --team-id "${APPLE_TEAM_ID:-$TEAM}" \
    --wait
fi

xcrun stapler staple "$APP"
rm -f "$DMG"
hdiutil create -volname ScrumTrace -srcfolder "$APP" -ov -format UDZO "$DMG"
echo "dmg=$DMG"
echo "app=$APP"
