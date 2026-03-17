#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/ClaudeSidebar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Building Claude Sidebar..."
swiftc -O -o "$APP/Contents/MacOS/ClaudeSidebar" \
    -framework AppKit \
    -target arm64-apple-macos13.0 \
    "$DIR/main.swift" \
    "$DIR"/Sources/*.swift
codesign -fs - "$APP"
echo "Built: $APP"
echo "Run:   open $APP"

# ── Install VS Code extension ─────────────────────────────────────────────────
EXT_SRC="$DIR/vscode-extension"
EXT_DST="$HOME/.vscode/extensions/claude-sidebar-focus"

if [ -d "$EXT_SRC" ]; then
    echo "Installing VS Code extension..."
    mkdir -p "$EXT_DST"
    cp "$EXT_SRC/package.json" "$EXT_DST/"
    cp "$EXT_SRC/extension.js"  "$EXT_DST/"
    echo "Extension installed → $EXT_DST"
    echo "Restart VS Code (or run: Developer: Reload Window) to activate it."
fi
