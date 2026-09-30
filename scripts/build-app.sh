#!/bin/bash
# Builds the MacEQ SwiftPM executable and assembles a signed .app bundle.
#
# Usage: scripts/build-app.sh [debug|release]
#
# Signs with the "MacEQ Self-Signed" identity (scripts/create-signing-identity.sh)
# so the system-audio permission survives rebuilds and updates. Without it the
# app is ad-hoc signed: that signature changes on every rebuild, so macOS
# re-asks for the permission each time, and scripts/make-dmg.sh refuses to
# package it. Reset a stuck grant with:
# tccutil reset SystemAudioCaptureRequests com.jatingrewal.maceq
set -euo pipefail

CONFIGURATION="${1:-release}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/MacEQ.app"

cd "$PROJECT_DIR"
# Universal (Apple Silicon + Intel) binary: build each slice via its triple and
# merge with lipo. This works with the Command Line Tools and with Xcode.
#
# Each slice gets its own scratch path, and its output location is asked of
# SwiftPM rather than assumed. The paths are not stable: Xcode 27's SwiftPM
# writes to .build/out/Products/<Config> for every triple, so a second slice
# overwrites the first, and hard-coded .build/<triple>/<config> paths silently
# picked up months-old binaries from an earlier toolchain instead.
BINARIES=()
for ARCH in arm64 x86_64; do
    SCRATCH="$PROJECT_DIR/.build/app-$ARCH"
    swift build -c "$CONFIGURATION" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH"
    BINARY="$(swift build -c "$CONFIGURATION" --triple "$ARCH-apple-macosx" --scratch-path "$SCRATCH" --show-bin-path)/MacEQ"
    # Refuse a slice that isn't what it claims to be, rather than shipping it.
    if [ "$(lipo -archs "$BINARY")" != "$ARCH" ]; then
        echo "error: $BINARY is '$(lipo -archs "$BINARY")', expected '$ARCH'" >&2
        exit 1
    fi
    BINARIES+=("$BINARY")
done

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/MacEQ"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

SIGNING_IDENTITY="MacEQ Self-Signed"
if security find-identity -v -p codesigning | grep -q "\"$SIGNING_IDENTITY\""; then
    codesign --force --sign "$SIGNING_IDENTITY" "$APP_DIR"
    echo "Built and signed with '$SIGNING_IDENTITY': $APP_DIR"
else
    codesign --force --sign - "$APP_DIR"
    echo "warning: no '$SIGNING_IDENTITY' identity (see scripts/create-signing-identity.sh)," >&2
    echo "warning: so the app is ad-hoc signed and macOS will re-ask for the audio permission." >&2
    echo "Built and ad-hoc signed: $APP_DIR"
fi
echo "Run with: open '$APP_DIR'"
