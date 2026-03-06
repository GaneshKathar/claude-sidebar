#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

# Build first
bash "$DIR/build.sh"

# Staging area
STAGE="$DIR/.dmg-staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/claude-sidebar"

# Copy app bundle and hooks
cp -R "$DIR/ClaudeSidebar.app" "$STAGE/claude-sidebar/"
cp -R "$DIR/hooks" "$STAGE/claude-sidebar/"

# Add a visible README
cat > "$STAGE/claude-sidebar/README.txt" << 'README'
Claude Sidebar — Setup
======================

1. Drag this "claude-sidebar" folder anywhere you like
   (e.g. ~/rubrik/, ~/Applications/, or wherever)

2. Open ClaudeSidebar.app inside the folder
   - If macOS blocks it: right-click → Open → Open

3. Click the sidebar icon in the menu bar → Settings
   - Add your repo paths
   - Click "Copy Install Prompt" → paste into a Claude Code session
     to set up the status hooks

Note: Keep ClaudeSidebar.app and the hooks/ folder together
in the same parent directory.
README

# Build DMG
DMG="$DIR/ClaudeSidebar.dmg"
rm -f "$DMG"
hdiutil create -volname "Claude Sidebar" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGE"

echo ""
echo "Packaged: $DMG"
echo "Share this file — drag claude-sidebar folder to ~/rubrik/"
