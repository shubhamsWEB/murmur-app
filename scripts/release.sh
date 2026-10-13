#!/bin/bash
# Publishes Murmur as a GitHub release: builds the DMG (scripts/make-dmg.sh), then uploads it to
# github.com/shubhamsWEB/murmur-app as release v<version>, under two names:
#
#   Murmur-<version>.dmg   this version, for anyone who wants a specific one
#   Murmur.dmg             always the newest; the website's Download buttons point here:
#                          https://github.com/shubhamsWEB/murmur-app/releases/latest/download/Murmur.dmg
#
#   ./scripts/release.sh               build and publish
#   ./scripts/release.sh --skip-build  publish the DMG already in dist/
#
# Needs the GitHub CLI, signed in once: brew install gh && gh auth login
# Bump CFBundleShortVersionString (and CFBundleVersion) in Resources/Info.plist before a new release.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${MURMUR_REPO:-shubhamsWEB/murmur-app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
DMG="dist/Murmur-$VERSION.dmg"
LATEST="dist/Murmur.dmg"

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }

if [[ "${1:-}" != "--skip-build" ]]; then
  ./scripts/make-dmg.sh
fi
[[ -f "$DMG" ]] || { echo "No $DMG. Run ./scripts/make-dmg.sh first."; exit 1; }
cp "$DMG" "$LATEST"

NOTES="$(mktemp)"
cat > "$NOTES" <<TXT
Download **Murmur.dmg** below, open it, and drag Murmur to Applications.

Needs a Mac with Apple silicon on macOS 14 or later. On first launch Murmur asks for the microphone and
Accessibility, then downloads its speech and search models.

If macOS says it can't verify the developer: open System Settings → Privacy & Security, scroll down and click
Open Anyway next to Murmur. You only need to do this once.
TXT

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "› Release $TAG exists: replacing its DMGs"
  gh release upload "$TAG" "$DMG" "$LATEST" --repo "$REPO" --clobber
else
  echo "› Creating release $TAG"
  git push origin HEAD
  gh release create "$TAG" "$DMG" "$LATEST" --repo "$REPO" --title "Murmur $VERSION" --notes-file "$NOTES" --target "$(git rev-parse HEAD)" --latest
fi
rm -f "$NOTES"

echo "✓ Published: https://github.com/$REPO/releases/tag/$TAG"
echo "  Download link: https://github.com/$REPO/releases/latest/download/Murmur.dmg"
