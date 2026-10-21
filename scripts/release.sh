#!/bin/bash
# Releases Murmur for Mac and Windows together: sets the version everywhere, tags it, and pushes. GitHub does the rest
# (.github/workflows/release.yml): builds the Mac app (signed, notarized) and the Windows installer in parallel, publishes
# both in one release (the newest, so the website's Download buttons and releases/latest/download/… get them), and
# writes the update feeds both apps check (updates/appcast.xml for the Mac, updates/windows-x86_64.json for Windows).
#
#   scripts/release.sh 1.4.0
#
# Before it: write what's new in scripts/release-notes/<version>.md (plain sentences or a list: it's the release's
# notes and the update window's text). Runs from a clean main branch, on a Mac, Windows (Git Bash) or Linux. Needs git
# and python3. Watch it at github.com/shubhamsWEB/murmur-app/actions; a failed build publishes nothing, and running
# this again with the same version after a fix moves the tag.
#
# Building a DMG on your own Mac is still scripts/make-dmg.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "usage: scripts/release.sh <version>, e.g. 1.4.0" >&2; exit 1; }
TAG="v$VERSION"
NOTES="scripts/release-notes/$VERSION.md"
python=python3
python3 -c '' 2> /dev/null || python=python   # Windows: python3 can be the Store's stub

[[ $(git rev-parse --abbrev-ref HEAD) == main ]] || { echo "release from main (git checkout main)" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "commit or stash your changes first" >&2; exit 1; }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main isn't the same as GitHub's: git pull (or push) first" >&2; exit 1; }
[[ -s $NOTES ]] || { echo "write what's new in $NOTES first" >&2; exit 1; }

# The version in all three places: the Mac app (its build number goes up by one each release, as Sparkle compares
# it), the Windows app, and the shell's crate.
"$python" scripts/set-version.py "$VERSION"
git add Resources/Info.plist shell/src-tauri/tauri.conf.json shell/src-tauri/Cargo.toml shell/src-tauri/Cargo.lock "$NOTES"
if ! git diff --cached --quiet; then
  git commit -q -m "Murmur $VERSION"
fi

# A tag that's there already (a release that failed and was fixed) moves to this commit.
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  git tag -d "$TAG" > /dev/null
  git push -q origin ":refs/tags/$TAG" 2> /dev/null || true
fi
git tag -a "$TAG" -m "Murmur $VERSION"
git push -q origin main "$TAG"
echo "Murmur $VERSION is on its way: https://github.com/shubhamsWEB/murmur-app/actions"
