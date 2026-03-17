#!/bin/bash
# Dockwright Installer
# Usage: curl -fsSL https://dockwright.com/install.sh | bash
#
# What it does:
#   1. Downloads the latest Dockwright.app from GitHub Releases
#   2. Copies to /Applications
#   3. Optionally sets up auto-start via LaunchAgent
#   4. Opens the app

set -euo pipefail

APP_NAME="Dockwright"
BUNDLE_ID="com.Aatje.Dockwright.Dockwright"
GITHUB_REPO="AdelElo13/dockwright-macos-agent"
INSTALL_DIR="/Applications"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$BUNDLE_ID.plist"
DATA_DIR="$HOME/.dockwright"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✔${NC} $1"; }
fail()  { echo -e "${RED}✘${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}  ⚓  Dockwright Installer${NC}"
echo -e "  Your Mac. Your AI. No cloud required."
echo ""

# Check macOS version
SW_VER=$(sw_vers -productVersion | cut -d. -f1)
if [ "$SW_VER" -lt 14 ]; then
    fail "Dockwright requires macOS 14 Sonoma or later. You have $(sw_vers -productVersion)."
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
    fail "Unsupported architecture: $ARCH"
fi
info "Detected: macOS $(sw_vers -productVersion) ($ARCH)"

# Find latest release
info "Checking for latest release..."
LATEST_URL=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
    | grep "browser_download_url.*Dockwright.*\.zip" \
    | head -1 \
    | cut -d'"' -f4) || true

if [ -z "${LATEST_URL:-}" ]; then
    # No release found — try building from source
    info "No pre-built release found. Building from source..."

    if ! command -v xcodebuild &>/dev/null; then
        fail "Xcode not installed. Install from the App Store first."
    fi

    TMPDIR_BUILD=$(mktemp -d)
    info "Cloning repository..."
    git clone --depth 1 "https://github.com/$GITHUB_REPO.git" "$TMPDIR_BUILD/dockwright" 2>/dev/null || \
        fail "Failed to clone repository."

    info "Building (this may take a minute)..."
    cd "$TMPDIR_BUILD/dockwright"
    xcodebuild -project Dockwright.xcodeproj -scheme Dockwright -configuration Release \
        -derivedDataPath "$TMPDIR_BUILD/build" build 2>&1 | tail -5

    APP_PATH="$TMPDIR_BUILD/build/Build/Products/Release/Dockwright.app"
    if [ ! -d "$APP_PATH" ]; then
        fail "Build failed. Check Xcode and try again."
    fi

    ok "Built successfully"
else
    # Download pre-built release
    TMPDIR_DL=$(mktemp -d)
    info "Downloading from: $LATEST_URL"
    curl -fsSL "$LATEST_URL" -o "$TMPDIR_DL/Dockwright.zip" || fail "Download failed."
    info "Extracting..."
    unzip -qo "$TMPDIR_DL/Dockwright.zip" -d "$TMPDIR_DL" || fail "Extraction failed."
    APP_PATH="$TMPDIR_DL/Dockwright.app"
    if [ ! -d "$APP_PATH" ]; then
        # Try nested directory
        APP_PATH=$(find "$TMPDIR_DL" -name "Dockwright.app" -maxdepth 2 | head -1)
    fi
    if [ ! -d "$APP_PATH" ]; then
        fail "Dockwright.app not found in download."
    fi
    ok "Downloaded"
fi

# Remove old version if exists
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    info "Removing previous version..."
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi

# Install
info "Installing to $INSTALL_DIR..."
cp -R "$APP_PATH" "$INSTALL_DIR/" || fail "Failed to copy to /Applications. Try: sudo $0"
ok "Installed to $INSTALL_DIR/$APP_NAME.app"

# Create data directory
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/conversations"
mkdir -p "$DATA_DIR/skills"

# Remove quarantine attribute (app is unsigned from source build)
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

# Ask about auto-start
echo ""
read -p "  Start Dockwright on login? [y/N] " -n 1 -r AUTO_START
echo ""

if [[ $AUTO_START =~ ^[Yy]$ ]]; then
    mkdir -p "$LAUNCH_AGENT_DIR"
    cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>open</string>
        <string>-a</string>
        <string>Dockwright</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST
    launchctl load "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
    ok "Auto-start enabled"
fi

# Open the app
info "Launching Dockwright..."
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo -e "${GREEN}${BOLD}  ⚓  Dockwright installed successfully!${NC}"
echo ""
echo "  Tips:"
echo "  • Cmd+Shift+Space — toggle Dockwright from anywhere"
echo "  • Sign in with Claude or paste an API key to start"
echo "  • Grant Accessibility permission when prompted"
echo ""
echo "  Uninstall: rm -rf /Applications/Dockwright.app ~/.dockwright"
if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    echo "             launchctl unload $LAUNCH_AGENT_PLIST && rm $LAUNCH_AGENT_PLIST"
fi
echo ""

# Cleanup
rm -rf "${TMPDIR_BUILD:-/tmp/nonexistent}" "${TMPDIR_DL:-/tmp/nonexistent}" 2>/dev/null || true
