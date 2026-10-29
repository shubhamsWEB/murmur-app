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
#
# On GitHub (the release workflow), notarization uses an App Store Connect API key instead of a keychain profile:
# APPLE_API_KEY (the .p8 file's path), APPLE_API_KEY_ID and APPLE_API_ISSUER. REQUIRE_NOTARIZATION=1 makes a DMG that
# isn't signed and notarized an error rather than a warning.
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

# Notary credentials: the API key on GitHub, else the keychain profile.
NOTARY=()
if [[ $SIGNED_FOR_RELEASE == 1 ]]; then
  if [[ -n "${APPLE_API_KEY:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
    NOTARY=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
  elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
    NOTARY=(--keychain-profile "$NOTARY_PROFILE")
  fi
fi

# Sends `$1` to Apple's notary service and waits; on a rejection, prints Apple's reasons (which file, what's wrong).
notarize() {
  local log="$DIST/notary-$(basename "$1").log"
  mkdir -p "$DIST"
  xcrun notarytool submit "$1" "${NOTARY[@]}" --wait --timeout 30m --output-format plist > "$log.plist" || true
  local status id
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$log.plist" 2>/dev/null || echo unknown)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$log.plist" 2>/dev/null || echo)"
  echo "  $(basename "$1"): $status${id:+ ($id)}"
  if [[ "$status" != Accepted ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY[@]}" "$log.json" > /dev/null 2>&1 && cat "$log.json" >&2
    echo "Apple didn't accept $(basename "$1") (its reasons above)" >&2
    exit 1
  fi
}

# The app itself is notarized and its ticket stapled first, so it opens without a warning once it's copied out of the
# DMG, even offline or where Apple's servers can't be reached (a DMG's ticket travels with the DMG, not the app).
if [[ ${#NOTARY[@]} -gt 0 ]]; then
  echo "› Notarizing the app (a few minutes)"
  ZIP="$(mktemp -d)/Murmur.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

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

NOTARIZED=0
if [[ $SIGNED_FOR_RELEASE == 1 ]]; then
  codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if [[ ${#NOTARY[@]} -gt 0 ]]; then
    echo "› Notarizing the DMG (a few minutes)"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    NOTARIZED=1
    echo "› Notarized and stapled, the app and the DMG: opens on any Mac without warnings"
  else
    echo "› Not notarized: no notary profile \"$NOTARY_PROFILE\" (see the top of this script)"
  fi
fi
if [[ "${REQUIRE_NOTARIZATION:-}" == 1 && $NOTARIZED != 1 ]]; then
  echo "The DMG isn't signed with a Developer ID and notarized: not a release" >&2
  exit 1
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "Done: $DMG ($SIZE)"
[[ -n "${CI:-}" ]] || open -R "$DMG"
