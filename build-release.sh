#!/bin/bash
# ============================================
#  Build release assets for GitHub Releases
#  Usage: ./build-release.sh <component>
#
#  Components:
#    core                    — menu bar app, TUI, updater
#    tool-screenshot-watcher — screenshot watcher tool
#
#  Output: ./release-output/<tag>/
# ============================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')

if [ $# -lt 1 ]; then
    echo "Usage: $0 <component>"
    echo ""
    echo "Components:"
    echo "  core                    — Core manager (v$VERSION)"
    echo "  tool-screenshot-watcher — Screenshot watcher (v$VERSION)"
    exit 1
fi

COMPONENT="$1"
TAG="${COMPONENT}-v${VERSION}"
OUTPUT_DIR="$SCRIPT_DIR/release-output/$TAG"

mkdir -p "$OUTPUT_DIR"

generate_manifest() {
    local dir="$1"
    local manifest_file="$dir/manifest.txt"
    > "$manifest_file"
    for file in "$dir"/*; do
        [ -f "$file" ] || continue
        local name
        name=$(basename "$file")
        [ "$name" = "manifest.txt" ] && continue
        local checksum
        checksum=$(shasum -a 256 "$file" | awk '{print $1}')
        echo "$checksum  $name" >> "$manifest_file"
    done
    echo "    Generated manifest.txt"
}

case "$COMPONENT" in
    core)
        echo "==> Building core release assets (v$VERSION)..."

        # Compile universal binary
        echo "==> Compiling ToolManager binary..."
        SWIFT_SRC="$SCRIPT_DIR/src/ToolManagerSource.swift"
        BUILDDIR=$(mktemp -d)
        trap 'rm -rf "$BUILDDIR"' EXIT

        swiftc "$SWIFT_SRC" -o "$BUILDDIR/ToolManager_arm64" -framework Cocoa -O \
            -target arm64-apple-macosx13.0 2>/dev/null
        swiftc "$SWIFT_SRC" -o "$BUILDDIR/ToolManager_x86_64" -framework Cocoa -O \
            -target x86_64-apple-macosx13.0 2>/dev/null
        lipo -create "$BUILDDIR/ToolManager_arm64" "$BUILDDIR/ToolManager_x86_64" \
            -output "$OUTPUT_DIR/ToolManager-universal"
        chmod +x "$OUTPUT_DIR/ToolManager-universal"
        echo "    Universal binary built ($(du -h "$OUTPUT_DIR/ToolManager-universal" | cut -f1 | xargs))"

        # Copy other core assets
        cp "$SCRIPT_DIR/src/tool-manager.sh" "$OUTPUT_DIR/"
        cp "$SCRIPT_DIR/resources/Info.plist" "$OUTPUT_DIR/"
        cp "$SCRIPT_DIR/src/sic-updater.sh" "$OUTPUT_DIR/"

        # Generate manifest with checksums
        generate_manifest "$OUTPUT_DIR"

        echo ""
        echo "============================================"
        echo "  Core release assets built: $TAG"
        echo "  Output: $OUTPUT_DIR/"
        echo "============================================"
        echo ""
        echo "  To create the GitHub Release:"
        echo "    gh release create $TAG $OUTPUT_DIR/* --title \"Core v$VERSION\" --notes \"Core manager update to v$VERSION\""
        echo ""
        ;;

    tool-screenshot-watcher)
        echo "==> Building screenshot-watcher release assets (v$VERSION)..."

        cp "$SCRIPT_DIR/src/screenshot-watcher.sh" "$OUTPUT_DIR/"
        cp "$SCRIPT_DIR/tools/screenshot-watcher.tool" "$OUTPUT_DIR/"

        # Generate manifest with checksums
        generate_manifest "$OUTPUT_DIR"

        echo ""
        echo "============================================"
        echo "  Tool release assets built: $TAG"
        echo "  Output: $OUTPUT_DIR/"
        echo "============================================"
        echo ""
        echo "  To create the GitHub Release:"
        echo "    gh release create $TAG $OUTPUT_DIR/* --title \"Screenshot Watcher v$VERSION\" --notes \"Screenshot watcher update to v$VERSION\""
        echo ""
        ;;

    *)
        echo "ERROR: Unknown component '$COMPONENT'"
        echo "Valid components: core, tool-screenshot-watcher"
        exit 1
        ;;
esac
