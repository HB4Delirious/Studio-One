#!/bin/bash
# Regenerates the app icon from Icon/make-icon.swift.
#
# Produces both forms: Icon/StudioOne.icns (the flat icon, every macOS) and
# Icon/StudioOne.icon (the Liquid Glass source, compiled by build.sh --glass).
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc -O -o Icon/make-icon Icon/make-icon.swift
./Icon/make-icon --glass

icns() {   # $1 = source png, $2 = output basename
    rm -rf "Icon/$2.iconset" && mkdir -p "Icon/$2.iconset"
    while read -r px name; do
        sips -z "$px" "$px" "$1" --out "Icon/$2.iconset/$name.png" >/dev/null
    done <<'SIZES'
16 icon_16x16
32 icon_16x16@2x
32 icon_32x32
64 icon_32x32@2x
128 icon_128x128
256 icon_128x128@2x
256 icon_256x256
512 icon_256x256@2x
512 icon_512x512
1024 icon_512x512@2x
SIZES
    iconutil -c icns "Icon/$2.iconset" -o "Icon/$2.icns"
}
icns Icon/icon-1024.png      StudioOne
icns Icon/icon-1024-dark.png StudioOneDark
echo "==> Icon/StudioOne.icns, Icon/StudioOneDark.icns and Icon/StudioOne.icon are up to date"
