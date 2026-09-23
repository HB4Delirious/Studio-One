#!/bin/bash
# Packages the built app into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Studio One.app"
VOL="Studio One"
DMG="build/StudioOne.dmg"

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./build.sh first" >&2; exit 1; }

STAGE=$(mktemp -d)
RW=$(mktemp -u).dmg
MOUNT=$(mktemp -d)
# Everything temporary goes, however the script ends.
trap 'hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; rm -rf "$STAGE" "$RW"; rmdir "$MOUNT" 2>/dev/null || true' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"    # drag-to-install target

# A volume icon needs both the file and the Finder "has custom icon" bit; the
# bit can only be set on a writable volume, so build read-write then compress.
if [[ -f Icon/StudioOne.icns ]]; then
    cp Icon/StudioOne.icns "$STAGE/.VolumeIcon.icns"
fi

rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW -quiet "$RW"

hdiutil attach -quiet -nobrowse -mountpoint "$MOUNT" "$RW"
[[ -f "$MOUNT/.VolumeIcon.icns" ]] && SetFile -a C "$MOUNT"
# Spotlight or Finder can hold a fresh volume for a moment; a plain detach
# then fails and, under set -e, took the whole package with it.
for attempt in 1 2 3; do
    hdiutil detach -quiet "$MOUNT" && break
    sleep 1
    [[ $attempt == 3 ]] && hdiutil detach -quiet -force "$MOUNT"
done

hdiutil convert "$RW" -format UDZO -quiet -o "$DMG"
rm -f "$RW"
echo "==> Built $DMG"
ls -lh "$DMG" | awk '{print "    size: " $5}'
