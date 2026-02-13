#!/bin/bash
# ============================================
#  Dev build: compile → swap → relaunch
#  Instant local testing, no version bumps
#
#  Usage:
#    ./dev.sh            — build and hot-swap
#    ./dev.sh --restore  — reset version for auto-updater
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_SRC="$SCRIPT_DIR/src/ToolManagerSource.swift"
WATCHER_SRC="$SCRIPT_DIR/src/sic-watcher.c"
APP_BINARY="$HOME/.local/bin/ToolManager.app/Contents/MacOS/ToolManager"
VERSIONS_FILE="$HOME/.local/sic-versions"
VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')

# --- Restore mode ---
if [ "${1:-}" = "--restore" ]; then
    if [ -f "$VERSIONS_FILE" ]; then
        grep -v "^core=" "$VERSIONS_FILE" > "$VERSIONS_FILE.tmp" || true
        echo "core=$VERSION" >> "$VERSIONS_FILE.tmp"
        mv "$VERSIONS_FILE.tmp" "$VERSIONS_FILE"
        echo "  Restored core version to $VERSION"
        echo "  Auto-updater will resume normal operation."
    fi
    exit 0
fi

# --- Pre-flight ---
if [ ! -f "$SWIFT_SRC" ]; then
    echo "ERROR: Missing $SWIFT_SRC"
    exit 1
fi

if [ ! -d "$HOME/.local/bin/ToolManager.app" ]; then
    echo "ERROR: ToolManager.app not installed. Run the .pkg installer first."
    exit 1
fi

# --- Detect architecture ---
ARCH=$(uname -m)
case "$ARCH" in
    arm64)  TARGET="arm64-apple-macosx13.0" ;;
    x86_64) TARGET="x86_64-apple-macosx13.0" ;;
    *)      echo "ERROR: Unknown architecture $ARCH"; exit 1 ;;
esac

# --- Compile Swift app ---
echo "==> Compiling ToolManager ($ARCH)..."
TMPBIN=$(mktemp)
swiftc "$SWIFT_SRC" -o "$TMPBIN" -framework Cocoa -O -target "$TARGET" 2>&1
echo "    Done ($(du -h "$TMPBIN" | cut -f1 | xargs))"

# --- Compile sic-watcher ---
echo "==> Compiling sic-watcher ($ARCH)..."
TMPWATCHER=$(mktemp)
cc "$WATCHER_SRC" -o "$TMPWATCHER" -O2 -target "$TARGET" 2>&1
echo "    Done ($(du -h "$TMPWATCHER" | cut -f1 | xargs))"

# --- Kill existing ---
echo "==> Stopping ToolManager..."
killall ToolManager 2>/dev/null || true
sleep 0.5

# --- Swap binaries and scripts ---
echo "==> Swapping files..."
cp "$TMPBIN" "$APP_BINARY"
chmod +x "$APP_BINARY"
rm "$TMPBIN"

cp "$TMPWATCHER" "$HOME/.local/bin/sic-watcher"
chmod +x "$HOME/.local/bin/sic-watcher"
rm "$TMPWATCHER"

cp "$SCRIPT_DIR/src/screenshot-watcher.sh" "$HOME/.local/bin/screenshot-watcher.sh"
chmod +x "$HOME/.local/bin/screenshot-watcher.sh"

cp "$SCRIPT_DIR/src/sic-updater.sh" "$HOME/.local/bin/sic-updater.sh"
chmod +x "$HOME/.local/bin/sic-updater.sh"

# --- Protect from auto-updater ---
if [ -f "$VERSIONS_FILE" ]; then
    grep -v "^core=" "$VERSIONS_FILE" > "$VERSIONS_FILE.tmp" || true
    echo "core=99.99.99" >> "$VERSIONS_FILE.tmp"
    mv "$VERSIONS_FILE.tmp" "$VERSIONS_FILE"
fi

# --- Relaunch ---
echo "==> Launching..."
open "$HOME/.local/bin/ToolManager.app"

echo ""
echo "============================================"
echo "  Dev build deployed!"
echo "  Auto-updater paused (version set to 99.99.99)"
echo ""
echo "  When ready to deploy:"
echo "    1. Bump VERSION"
echo "    2. ./build-release.sh release"
echo "    3. gh release create ... (commands printed above)"
echo ""
echo "  To restore auto-updater:"
echo "    ./dev.sh --restore"
echo "============================================"
