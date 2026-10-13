#!/bin/bash
# Builds Murmur and packs it into a shareable disk image: dist/Murmur-<version>.dmg (drag Murmur to Applications).
#
#   ./scripts/make-dmg.sh
#
# Signing, best available:
#   • A "Developer ID Application" certificate in your keychain → release build with a secure timestamp, and, if you
#     stored notary credentials once (xcrun notarytool store-credentials murmur-notary --apple-id … --team-id …),
#     notarized and stapled: it opens on any Mac with no warnings. NOTARY_PROFILE=<name> to use another profile.
#   • Otherwise your .sign-id identity (Apple Development) or ad-hoc: works, but other Macs show "Apple could not
#     verify Murmur"; they open it once from System Settings → Privacy & Security → Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build.noindex/Murmur.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-murmur-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DIST="dist"
DMG="$DIST/Murmur-$VERSION.dmg"

DEVELOPER_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
if [[ -n "$DEVELOPER_ID" ]]; then
  echo "› Building a release, signed with: $DEVELOPER_ID"
  RELEASE=1 SIGN_ID="$DEVELOPER_ID" ./build.sh
  SIGNED_FOR_RELEASE=1
else
  echo "› No Developer ID certificate found: building with $( [[ -f .sign-id ]] && head -1 .sign-id || echo 'ad-hoc signing' )"
  ./build.sh
  SIGNED_FOR_RELEASE=0
fi

echo "› Checking the app's signature"
codesign --verify --deep --strict "$APP"

echo "› Making $DMG"
STAGE="$(mktemp -d)/Murmur"
mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/Murmur.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<TXT
Murmur $VERSION — voice for your Mac

1. Drag Murmur onto Applications, then open it from Applications.
2. Setup walks you through the microphone, typing in other apps, and the folders to search.
   On first launch Murmur downloads its speech and search models once (about 1.4 GB).
3. Hold fn anywhere and talk.

Needs macOS 14 or later on an Apple silicon Mac.
$( [[ $SIGNED_FOR_RELEASE == 1 ]] && echo "" || echo "
If macOS says Apple could not verify Murmur: open System Settings → Privacy & Security, scroll down,
and click Open Anyway next to Murmur. You only do this once." )
TXT
rm -f "$DMG"
hdiutil create -volname "Murmur $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" > /dev/null
rm -rf "$(dirname "$STAGE")"

if [[ $SIGNED_FOR_RELEASE == 1 ]]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
    echo "› Notarizing (a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "› Notarized and stapled: opens on any Mac without warnings"
  else
    echo "› Not notarized: no notary profile \"$NOTARY_PROFILE\" (see the top of this script)"
  fi
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "Done: $DMG ($SIZE)"
open -R "$DMG"
