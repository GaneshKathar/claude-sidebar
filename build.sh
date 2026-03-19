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
    "$DIR"/Sources/*.swift \
    "$DIR"/Sources/Services/*.swift \
    "$DIR"/Sources/Adapters/*.swift
codesign -fs - "$APP"
echo "Built: $APP"
echo "Run:   open $APP"

# ── Detect installed terminals ────────────────────────────────────────────────
echo ""
echo "Detecting installed terminals..."
FOUND=""
check_terminal() {
    local name="$1" bundle="$2" extra="$3"
    if [ -n "$bundle" ] && mdfind "kMDItemCFBundleIdentifier == '$bundle'" 2>/dev/null | head -1 | grep -q . 2>/dev/null; then
        echo "  ✓ $name detected"
        FOUND="$FOUND $name"
        [ -n "$extra" ] && echo "    $extra"
    fi
    return 0
}
check_terminal "iTerm2"    "com.googlecode.iterm2"
check_terminal "VS Code"   "com.microsoft.VSCode"   "Extension auto-installed below."
check_terminal "Cursor"    "com.todesktop.230313mzl4w4u92"
check_terminal "Kitty"     "net.kovidgoyal.kitty"    "Add 'allow_remote_control yes' to ~/.config/kitty/kitty.conf for full integration."
check_terminal "Ghostty"   "com.mitchellh.ghostty"
check_terminal "Alacritty" "org.alacritty"
check_terminal "Warp"      "dev.warp.Warp-Stable"
check_terminal "Terminal"  "com.apple.Terminal"
[ -z "$FOUND" ] && echo "  No known terminals detected (will use universal fallback)."

# ── Install VS Code extension ─────────────────────────────────────────────────
EXT_SRC="$DIR/vscode-extension"
EXT_DST="$HOME/.vscode/extensions/claude-sidebar-focus"

if [ -d "$EXT_SRC" ]; then
    echo ""
    echo "Installing VS Code extension..."
    mkdir -p "$EXT_DST"
    cp "$EXT_SRC/package.json" "$EXT_DST/"
    cp "$EXT_SRC/extension.js"  "$EXT_DST/"
    echo "Extension installed → $EXT_DST"
    echo "Restart VS Code (or run: Developer: Reload Window) to activate it."
fi

# ── Install Cursor extension (same as VS Code) ───────────────────────────────
CURSOR_DST="$HOME/.cursor/extensions/claude-sidebar-focus"
if [ -d "$EXT_SRC" ] && [ -d "$HOME/.cursor" ]; then
    echo "Installing Cursor extension..."
    mkdir -p "$CURSOR_DST"
    cp "$EXT_SRC/package.json" "$CURSOR_DST/"
    cp "$EXT_SRC/extension.js"  "$CURSOR_DST/"
    echo "Extension installed → $CURSOR_DST"
fi
