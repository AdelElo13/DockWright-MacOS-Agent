#!/bin/bash
# ─────────────────────────────────────────────────────────────
# create-dmg.sh — Create a Dockwright installer DMG
#
# Usage:
#   ./scripts/create-dmg.sh /path/to/Dockwright.app
#
# Output:
#   ~/Desktop/Dockwright-1.0.dmg
# ─────────────────────────────────────────────────────────────
set -euo pipefail

APP_PATH="${1:?Usage: $0 /path/to/Dockwright.app}"
VERSION="1.0"
DMG_NAME="Dockwright-${VERSION}"
DMG_OUTPUT="$HOME/Desktop/${DMG_NAME}.dmg"
STAGING="/tmp/dmg-staging-$$"

# Validate input
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Not found: $APP_PATH"
    exit 1
fi

echo "📦 Creating DMG for: $APP_PATH"

# Clean previous
rm -rf "$STAGING" "$DMG_OUTPUT" "/tmp/${DMG_NAME}-temp.dmg"

# Create staging directory
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/Dockwright.app"
ln -s /Applications "$STAGING/Applications"

# Create background image with arrow
python3 - << 'PYEOF'
import struct, zlib

WIDTH, HEIGHT = 600, 400

def make_png(pixels, w, h):
    raw = b''
    for y in range(h):
        raw += b'\x00'
        for x in range(w):
            r, g, b, a = pixels[y * w + x]
            raw += bytes([r, g, b, a])
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    return png

pixels = []
for y in range(HEIGHT):
    for x in range(WIDTH):
        # Dark background matching Dockwright theme
        pixels.append((30, 32, 36, 255))

# Draw arrow (teal color) pointing from left to right
cx, cy = 300, 200
for y in range(HEIGHT):
    for x in range(WIDTH):
        idx = y * WIDTH + x
        # Arrow shaft: horizontal line
        if 195 <= y <= 205 and 220 <= x <= 380:
            pixels[idx] = (72, 199, 190, 255)  # teal
        # Arrow head: triangle
        dx = x - 370
        dy = abs(y - 200)
        if 370 <= x <= 400 and dy <= (400 - x) * 0.8:
            pixels[idx] = (72, 199, 190, 255)

with open('/tmp/dmg-bg.png', 'wb') as f:
    f.write(make_png(pixels, WIDTH, HEIGHT))
print("✅ Background image created")
PYEOF

# Create temporary writable DMG
hdiutil create -size 200m -fs HFS+ -volname "$DMG_NAME" "/tmp/${DMG_NAME}-temp.dmg" -quiet

# Mount it
MOUNT_POINT=$(hdiutil attach "/tmp/${DMG_NAME}-temp.dmg" -readwrite -noverify -quiet | grep "/Volumes" | awk '{print $NF}')
echo "📁 Mounted at: $MOUNT_POINT"

# Copy contents
cp -R "$STAGING/Dockwright.app" "$MOUNT_POINT/"
ln -s /Applications "$MOUNT_POINT/Applications"

# Create .background directory and copy background image
mkdir -p "$MOUNT_POINT/.background"
cp /tmp/dmg-bg.png "$MOUNT_POINT/.background/background.png"

# Set DMG window appearance using AppleScript
echo "🎨 Configuring window layout..."
osascript << ASCRIPT
tell application "Finder"
    tell disk "$DMG_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set background picture of theViewOptions to file ".background:background.png"
        -- Position app icon on the left, Applications on the right
        set position of item "Dockwright.app" of container window to {150, 200}
        set position of item "Applications" of container window to {450, 200}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
ASCRIPT

# Wait for Finder to finish
sync
sleep 2

# Unmount
hdiutil detach "$MOUNT_POINT" -quiet -force 2>/dev/null || true

# Convert to compressed read-only DMG
hdiutil convert "/tmp/${DMG_NAME}-temp.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUTPUT" -quiet

# Cleanup
rm -rf "$STAGING" "/tmp/${DMG_NAME}-temp.dmg" "/tmp/dmg-bg.png"

echo ""
echo "✅ DMG created: $DMG_OUTPUT"
echo "📏 Size: $(du -h "$DMG_OUTPUT" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Open Xcode → Product → Archive"
echo "  2. Distribute App → Developer ID"
echo "  3. Notarize with: xcrun notarytool submit $DMG_OUTPUT --apple-id YOUR_APPLE_ID --team-id A3W973JZ49 --password APP_SPECIFIC_PASSWORD --wait"
echo "  4. Staple: xcrun stapler staple $DMG_OUTPUT"
echo "  5. Upload to GitHub releases"
