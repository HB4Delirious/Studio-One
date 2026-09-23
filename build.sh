#!/bin/bash
# Builds Studio One.app.
#
# Works with Command Line Tools alone, or with Xcode. The catch is SwiftUI's
# @State, which is a macro in the macOS 27 SDK whose plugin ships only with
# Xcode — so when only CLT is present we build against the newest installed SDK
# that predates that change. With Xcode selected, its own SDK is used instead.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Studio One"
BUNDLE_ID="com.logan.SpotifyKaraoke"
DEPLOY_TARGET="14.0"

# --glass swaps the flat icon for the macOS 26 Liquid Glass one. Off by default:
# it needs Xcode for actool, and the flat icon is what every older macOS shows.
GLASS=0
OUT="./build"
for arg in "$@"; do
    case "$arg" in
        --glass) GLASS=1 ;;
        -*) echo "error: unknown option $arg (only --glass)" >&2; exit 1 ;;
        *) OUT="$arg" ;;
    esac
done

# With Xcode selected, let swiftc choose its own SDK: `xcrun --show-sdk-path`
# can return a stale Command Line Tools path that no longer exists, and forcing
# a mismatched SDK fails with "this SDK is not supported by the compiler".
#
# Without Xcode, fall back to a macOS 26.x SDK, whose SwiftUI still predates the
# @State macro that needs the Xcode-only plugin.
SDK_ARGS=()
if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    echo "==> SDK: Xcode default"
else
    SDK_ROOT="/Library/Developer/CommandLineTools/SDKs"
    SDK=""
    for candidate in MacOSX26.5.sdk MacOSX26.sdk; do
        if [[ -d "$SDK_ROOT/$candidate" ]]; then SDK="$SDK_ROOT/$candidate"; break; fi
    done
    if [[ -z "$SDK" ]]; then
        echo "error: no macOS 26.x SDK found under $SDK_ROOT" >&2
        echo "       Newer SDKs need Xcode for SwiftUI macro expansion." >&2
        exit 1
    fi
    SDK_ARGS=(-sdk "$SDK")
    echo "==> SDK: $(basename "$SDK")"
fi

# Build into a staging bundle and swap it in only once everything succeeds.
# Deleting the working app up front means a single failed compile leaves
# nothing to run.
APP="$OUT/$APP_NAME.app"
STAGE="$OUT/.$APP_NAME.building"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Compiling"
swiftc \
    -swift-version 5 \
    -target "arm64-apple-macosx$DEPLOY_TARGET" \
    ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} \
    -O \
    -o "$STAGE/Contents/MacOS/$APP_NAME" \
    ./*.swift

echo "==> Bundling"
cp Info.plist "$STAGE/Contents/Info.plist"
# Stamp the build so diagnostic logs identify exactly which one is running.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" \
    "$STAGE/Contents/Info.plist" >/dev/null 2>&1 || true
if [[ -f Icon/StudioOne.icns ]]; then
    cp Icon/StudioOne.icns "$STAGE/Contents/Resources/StudioOne.icns"
else
    echo "    warning: Icon/StudioOne.icns missing — app will use the generic icon" >&2
fi
# The dark artwork. macOS has no appearance-aware app icon, so this one is not
# named by Info.plist — DockIcon.swift swaps it in at runtime. See README.
if [[ -f Icon/StudioOneDark.icns ]]; then
    cp Icon/StudioOneDark.icns "$STAGE/Contents/Resources/StudioOneDark.icns"
fi
# The Stream Deck plug-in travels inside the app and is installed from
# Settings › Stream Deck, so there is no separate file to keep track of.
echo "==> Stream Deck plug-in"
./StreamDeck/build.sh >/dev/null
cp StreamDeck/build/com.logan.studioone.streamDeckPlugin "$STAGE/Contents/Resources/"
cp "StreamDeck/build/Studio One.streamDeckProfile" "$STAGE/Contents/Resources/"

if (( GLASS )); then
    if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
        echo "error: --glass needs Xcode selected — actool ships with it, not with" >&2
        echo "       the Command Line Tools. Run without --glass for the flat icon." >&2
        exit 1
    fi
    echo "==> Icon: Liquid Glass (macOS 26+; flat icns kept as the fallback)"
    # Compile elsewhere and take only Assets.car. actool emits its own .icns
    # alongside it holding just the 16 and 128 sizes — enough for its purposes,
    # but it would overwrite the full ten-size icns that older macOS falls back
    # to, and large icons would go blurry there.
    CAR=$(mktemp -d)
    xcrun actool --compile "$CAR" \
        --platform macosx --minimum-deployment-target 26.0 \
        --app-icon StudioOne \
        --output-partial-info-plist "$CAR/partial.plist" \
        Icon/StudioOne.icon >/dev/null
    cp "$CAR/Assets.car" "$STAGE/Contents/Resources/Assets.car"
    rm -rf "$CAR"
    # CFBundleIconName is what points macOS 26 at the catalog; without it the
    # Assets.car sits there unread and you get the flat icon anyway.
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string StudioOne" \
        "$STAGE/Contents/Info.plist" >/dev/null 2>&1 || true
else
    echo "==> Icon: flat"
fi

# A stable signing identity keeps macOS recognising each build as the same app.
# An ad-hoc signature is identified by cdhash — a hash of the binary — so every
# recompile looks like a different application, and the keychain asks for a
# password again. A self-signed certificate makes the designated requirement
# name the certificate instead, which survives rebuilds. See README.
# Whichever exists: an explicit choice, a "Studio One" certificate, or the
# Apple Development certificate a free Apple ID gives you — all of them are
# stable across rebuilds, which is the point. Ad-hoc only as a last resort.
SIGN_ID="${STUDIOONE_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]]; then
    AVAILABLE=$(security find-identity -v -p codesigning 2>/dev/null || true)
    SIGN_ID=$(printf '%s\n' "$AVAILABLE" | sed -n 's/.*"\(Studio One\)".*/\1/p' | head -1)
    [[ -z "$SIGN_ID" ]] && SIGN_ID=$(printf '%s\n' "$AVAILABLE" \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
fi
if [[ -n "$SIGN_ID" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    IDENTITY="$SIGN_ID"
    echo "==> Signing as \"$SIGN_ID\" (stable identity, hardened runtime + Apple Events)"
else
    IDENTITY="-"
    echo "==> Signing ad-hoc (hardened runtime + Apple Events entitlement)"
    echo "    No signing certificate found — the keychain will prompt on every"
    echo "    build until one exists. See README, \"Signing\"."
fi

codesign --force --sign "$IDENTITY" \
    --options runtime \
    --entitlements Karaoke.entitlements \
    --timestamp=none \
    "$STAGE"

# Everything worked; only now replace the previous build.
rm -rf "$APP"
mv "$STAGE" "$APP"
trap - EXIT

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | grep -E "flags|Signature" || true
