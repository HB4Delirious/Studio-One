#!/bin/zsh
# Builds the Studio One Stream Deck plug-in and packages it as an installer.
#   ./build.sh  ->  build/com.logan.studioone.streamDeckPlugin
set -euo pipefail
cd "${0:A:h}"

ID=com.logan.studioone
OUT=build
PLUGIN="$OUT/$ID.sdPlugin"
rm -rf "$OUT"
mkdir -p "$PLUGIN/bin"

echo "==> Compiling (arm64 + x86_64)"
for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13" -o "$OUT/StudioOneDeck-$arch" Sources/*.swift
done
lipo -create -output "$PLUGIN/bin/StudioOneDeck" "$OUT"/StudioOneDeck-arm64 "$OUT"/StudioOneDeck-x86_64
rm "$OUT"/StudioOneDeck-*
# Apple Silicon refuses to run an unsigned binary at all; ad-hoc is enough to run.
codesign --force --sign - "$PLUGIN/bin/StudioOneDeck"

echo "==> Images"
swift make-images.swift "$PLUGIN" ../Icon/icon-1024.png

cp manifest.json "$PLUGIN/"
mkdir -p "$PLUGIN/pi" && cp pi/*.html "$PLUGIN/pi/"

echo "==> Stream Deck + page"
# Beside the plug-in, not inside it: see make-profile.py.
python3 make-profile.py "$OUT/Studio One.streamDeckProfile" >/dev/null

echo "==> Packaging"
# A .streamDeckPlugin is a zip holding the .sdPlugin folder at its root.
# --norsrc keeps macOS resource forks and ._ files out of it.
(cd "$OUT" && ditto -c -k --norsrc --keepParent "$ID.sdPlugin" "$ID.streamDeckPlugin")
echo "==> Built $OUT/$ID.streamDeckPlugin ($(du -h "$OUT/$ID.streamDeckPlugin" | cut -f1))"
