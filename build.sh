#!/bin/bash
# Builds Spot-a-oke.app.
#
# Works with Command Line Tools alone, or with Xcode. The catch is SwiftUI's
# @State, which is a macro in the macOS 27 SDK whose plugin ships only with
# Xcode — so when only CLT is present we build against the newest installed SDK
# that predates that change. With Xcode selected, its own SDK is used instead.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Spot-a-oke"
BUNDLE_ID="com.logan.SpotifyKaraoke"
DEPLOY_TARGET="14.0"
OUT="${1:-./build}"

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
if [[ -f Icon/Spot-a-oke.icns ]]; then
    cp Icon/Spot-a-oke.icns "$STAGE/Contents/Resources/Spot-a-oke.icns"
else
    echo "    warning: Icon/Spot-a-oke.icns missing — app will use the generic icon" >&2
fi

# A stable signing identity keeps macOS recognising each build as the same app.
# An ad-hoc signature is identified by cdhash — a hash of the binary — so every
# recompile looks like a different application, and the keychain asks for a
# password again. A self-signed certificate makes the designated requirement
# name the certificate instead, which survives rebuilds. See README.
SIGN_ID="${SPOTAOKE_SIGN_ID:-Spot-a-oke}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    IDENTITY="$SIGN_ID"
    echo "==> Signing as \"$SIGN_ID\" (stable identity, hardened runtime + Apple Events)"
else
    IDENTITY="-"
    echo "==> Signing ad-hoc (hardened runtime + Apple Events entitlement)"
    echo "    No \"$SIGN_ID\" certificate found — the keychain will prompt on every"
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
