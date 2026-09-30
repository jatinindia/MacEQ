#!/bin/bash
# Packages build/MacEQ.app into build/MacEQ.dmg — the drag-to-Applications
# installer window users expect on macOS.
#
# Run scripts/build-app.sh first. Requires Finder automation permission, since
# icon positions and the window backdrop live in the volume's .DS_Store and
# only Finder can write them.
#
# The backdrop is generated, not hand-drawn. To change it, edit
# scripts/generate-dmg-background.swift and regenerate:
#
#   swiftc -O scripts/generate-dmg-background.swift -o /tmp/dmgbg
#   /tmp/dmgbg /tmp/bg-1x.png 1
#   /tmp/dmgbg /tmp/bg-2x.png 2
#   tiffutil -cathidpicheck /tmp/bg-1x.png /tmp/bg-2x.png \
#       -out Resources/dmg-background.tiff
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROJECT_DIR/build/MacEQ.app"
VOLUME_NAME="MacEQ"
TEMP_DMG="$PROJECT_DIR/build/MacEQ-temp.dmg"
FINAL_DMG="$PROJECT_DIR/build/MacEQ.dmg"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
# LZMA: the smallest format diskutil offers (about 15% under the old
# zlib-9 image). Opens on macOS 10.15+, well below MacEQ's own 14.4 floor.
COMPRESSED_FORMAT="ULMO"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/build-app.sh first" >&2
    exit 1
fi

# An ad-hoc signed release would cost every user their audio permission.
SIGNING_IDENTITY="MacEQ Self-Signed"
if ! codesign -dvv "$APP" 2>&1 | grep -qx "Authority=$SIGNING_IDENTITY"; then
    echo "error: $APP is not signed by '$SIGNING_IDENTITY':" >&2
    codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|Signature)=" >&2 || true
    echo "Run scripts/create-signing-identity.sh once, then scripts/build-app.sh." >&2
    exit 1
fi

# A stale mount from an interrupted run would silently poison the next build.
if [ -d "$MOUNT_POINT" ]; then
    diskutil eject force "$MOUNT_POINT" >/dev/null 2>&1 || true
fi

rm -rf "$TEMP_DMG" "$FINAL_DMG"

# Read-write image first: Finder has to be able to write the .DS_Store into it.
# diskutil (which replaces the deprecated hdiutil verbs) only makes APFS
# volumes; fine here, since MacEQ requires macOS 14.4 and APFS images open on
# 10.13+. It has no create-from-folder in a writable format, so a blank RAW
# image is sized from the content (plus room for Finder's .DS_Store and the
# volume icon) and filled after attaching.
CONTENT_KB=$(( $(du -sk "$APP" | cut -f1) + $(du -sk "$PROJECT_DIR/Resources/dmg-background.tiff" | cut -f1) \
    + $(du -sk "$PROJECT_DIR/Resources/AppIcon.icns" | cut -f1) ))
diskutil image create blank \
    --format RAW \
    --fs APFS \
    --volumeName "$VOLUME_NAME" \
    --size $(( (CONTENT_KB + 10240) * 1024 )) \
    "$TEMP_DMG" >/dev/null

diskutil image attach "$TEMP_DMG" >/dev/null
trap 'diskutil eject force "$MOUNT_POINT" >/dev/null 2>&1 || true' EXIT

# ditto keeps the app's code signature, extended attributes and permissions.
ditto "$APP" "$MOUNT_POINT/MacEQ.app"
ln -s /Applications "$MOUNT_POINT/Applications"
mkdir "$MOUNT_POINT/.background"
cp "$PROJECT_DIR/Resources/dmg-background.tiff" "$MOUNT_POINT/.background/background.tiff"

osascript <<APPLESCRIPT >/dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- 600x400 content area; the backdrop is drawn to match exactly.
        set the bounds of container window to {240, 140, 840, 540}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to 128
        set text size of options to 12
        set background picture of options to file ".background:background.tiff"
        set position of item "MacEQ.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        -- Close and reopen before updating: Finder only flushes window bounds
        -- to the volume's .DS_Store on close, so updating a still-open window
        -- persists the icon layout but silently loses the size.
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT

# A raw .dmg file can't carry a custom icon — that data is filesystem
# metadata (extended attributes) and gets stripped by any byte-stream
# transfer, including GitHub Releases. The mounted *volume* is different:
# its icon lives inside the DMG's own HFS+ filesystem, so it does survive
# distribution. Reuses the app icon so the drive matches the app once mounted.
#
# Written here, after the Finder styling above, not earlier: Finder's own
# "update" call deletes an unrecognized dotfile like .VolumeIcon.icns if
# it's present beforehand, so writing it any earlier is silently undone.
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$MOUNT_POINT/.VolumeIcon.icns"
SetFile -a C "$MOUNT_POINT"

sync
diskutil eject "$MOUNT_POINT" >/dev/null
trap - EXIT

# Compress to a read-only image for distribution.
diskutil image create from --format "$COMPRESSED_FORMAT" "$TEMP_DMG" "$FINAL_DMG" >/dev/null
rm -f "$TEMP_DMG"

echo "Built: $FINAL_DMG ($(du -h "$FINAL_DMG" | cut -f1))"
