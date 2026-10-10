#!/bin/bash
# Makes a release: sets the version, builds, packages, commits and tags it,
# then says what to upload. It publishes nothing itself.
#
#   ./release.sh 2.0.1                 # the repository already in Info.plist
#   ./release.sh 2.0.1 owner/name      # and set it, for the app's updater
#
# The app's updater reads api.github.com/repos/<owner/name>/releases/latest
# and installs the first .dmg attached to it — only if it's signed with the
# same certificate as the copy that's running, so build with the same one.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "usage: ./release.sh <version, like 2.0.1> [owner/name]" >&2
    exit 1
fi
REPO="${2:-$(/usr/libexec/PlistBuddy -c 'Print :StudioOneUpdateRepo' Info.plist 2>/dev/null || true)}"
if [[ -n "$REPO" && ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "error: the repository should look like owner/name, not \"$REPO\"" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: commit or stash your changes first, so the tag is exactly what's built" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "error: v$VERSION is already tagged" >&2
    exit 1
fi

echo "==> Version $VERSION${REPO:+, updates from $REPO}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
if [[ -n "$REPO" ]]; then
    /usr/libexec/PlistBuddy -c "Set :StudioOneUpdateRepo $REPO" Info.plist 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :StudioOneUpdateRepo string $REPO" Info.plist
fi

./build.sh
if codesign -dv "build/Studio One.app" 2>&1 | grep -q "^Signature=adhoc"; then
    echo "warning: this build is signed ad hoc, so installed copies can't update to it" >&2
    echo "         by themselves — see README, \"Signing\"." >&2
fi
./package.sh
DMG="build/Studio-One-$VERSION.dmg"
cp build/StudioOne.dmg "$DMG"

if [[ -n "$(git status --porcelain Info.plist)" ]]; then
    git commit -q -m "Version $VERSION" Info.plist
fi
git tag -a "v$VERSION" -m "Studio One $VERSION"

echo
echo "==> Ready: $DMG, tagged v$VERSION. To publish:"
if [[ -z "$REPO" ]]; then
    echo "    (No repository set: installed copies won't look for this release."
    echo "     Run again with owner/name, or set StudioOneUpdateRepo in Info.plist.)"
fi
echo "    1. Push the branch and the tag:  git push <remote> HEAD v$VERSION"
echo "    2. Make the release and attach the DMG:"
echo "       https://github.com/${REPO:-<owner>/<name>}/releases/new?tag=v$VERSION"
echo "       (or: gh release create v$VERSION \"$DMG\" --title \"Studio One $VERSION\")"
