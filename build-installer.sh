#!/bin/bash
# ============================================
#  Build Jeff's Sic Tools Manager .pkg installer
#  Output: ~/Desktop/Jeff's Sic Tools Manager.pkg
# ============================================
set -euo pipefail

# --- Config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
IDENTIFIER_BASE="com.custom-tools"
UPDATER_INTERVAL=120          # seconds between update checks (120=2min, 21600=6hrs)
OUTPUT="$HOME/Desktop/Jeff's Sic Tools Manager.pkg"
BUILDDIR=$(mktemp -d)

trap 'rm -rf "$BUILDDIR"' EXIT

echo "==> Build directory: $BUILDDIR"

# --- 1. Pre-flight checks ---
echo "==> Checking prerequisites..."

SOURCES=(
    "$SCRIPT_DIR/src/ToolManagerSource.swift"
    "$SCRIPT_DIR/src/tool-manager.sh"
    "$SCRIPT_DIR/src/screenshot-watcher.sh"
    "$SCRIPT_DIR/src/sic-updater.sh"
    "$SCRIPT_DIR/src/sic-watcher.c"
    "$SCRIPT_DIR/resources/Info.plist"
)
for src in "${SOURCES[@]}"; do
    if [ ! -f "$src" ]; then
        echo "ERROR: Missing source file: $src"
        exit 1
    fi
done

for cmd in pkgbuild productbuild; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Install Xcode Command Line Tools."
        exit 1
    fi
done

echo "    All checks passed."

# --- 2. Compile Swift binary (universal: arm64 + x86_64) ---
echo "==> Compiling ToolManager binary..."

SWIFT_SRC="$SCRIPT_DIR/src/ToolManagerSource.swift"
BIN_ARM64="$BUILDDIR/ToolManager_arm64"
BIN_X86="$BUILDDIR/ToolManager_x86_64"
BIN_UNIVERSAL="$BUILDDIR/ToolManager"

swiftc "$SWIFT_SRC" -o "$BIN_ARM64" -framework Cocoa -O \
    -target arm64-apple-macosx13.0 2>/dev/null
swiftc "$SWIFT_SRC" -o "$BIN_X86" -framework Cocoa -O \
    -target x86_64-apple-macosx13.0 2>/dev/null
lipo -create "$BIN_ARM64" "$BIN_X86" -output "$BIN_UNIVERSAL"

echo "    Universal binary built ($(du -h "$BIN_UNIVERSAL" | cut -f1 | xargs))."

# --- 2b. Compile sic-watcher binary (universal: arm64 + x86_64) ---
echo "==> Compiling sic-watcher binary..."

WATCHER_C_SRC="$SCRIPT_DIR/src/sic-watcher.c"
WATCHER_ARM64="$BUILDDIR/sic-watcher_arm64"
WATCHER_X86="$BUILDDIR/sic-watcher_x86_64"
WATCHER_UNIVERSAL="$BUILDDIR/sic-watcher"

cc "$WATCHER_C_SRC" -o "$WATCHER_ARM64" -O2 \
    -target arm64-apple-macosx13.0 2>/dev/null
cc "$WATCHER_C_SRC" -o "$WATCHER_X86" -O2 \
    -target x86_64-apple-macosx13.0 2>/dev/null
lipo -create "$WATCHER_ARM64" "$WATCHER_X86" -output "$WATCHER_UNIVERSAL"

echo "    Universal binary built ($(du -h "$WATCHER_UNIVERSAL" | cut -f1 | xargs))."

# --- 3. Base64-encode files ---
echo "==> Encoding files..."

BINARY_B64=$(base64 < "$BIN_UNIVERSAL")
SWIFT_B64=$(base64 < "$SWIFT_SRC")
BASH_B64=$(base64 < "$SCRIPT_DIR/src/tool-manager.sh")
WATCHER_B64=$(base64 < "$SCRIPT_DIR/src/screenshot-watcher.sh")
PLIST_B64=$(base64 < "$SCRIPT_DIR/resources/Info.plist")
UPDATER_B64=$(base64 < "$SCRIPT_DIR/src/sic-updater.sh")
WATCHER_BIN_B64=$(base64 < "$WATCHER_UNIVERSAL")

echo "    Done."

# ============================================================
#  Helper: generate a simple tool-manifest-only postinstall
#  Usage: make_manifest_pkg <dir-name> <manifest-content>
# ============================================================
make_manifest_pkg() {
    local dir="$1"
    local manifest="$2"

    mkdir -p "$BUILDDIR/$dir"
    cat > "$BUILDDIR/$dir/postinstall" << MANIFESTSCRIPT
#!/bin/bash
set -e
REAL_USER=\$(stat -f "%Su" /dev/console)
REAL_HOME=\$(dscl . -read /Users/"\$REAL_USER" NFSHomeDirectory | awk '{print \$2}')
mkdir -p "\$REAL_HOME/.local/tools"
cat > "\$REAL_HOME/.local/tools/${dir}.tool" << 'TOOL'
${manifest}
TOOL
chown -R "\$REAL_USER" "\$REAL_HOME/.local/tools"
exit 0
MANIFESTSCRIPT
    chmod +x "$BUILDDIR/$dir/postinstall"
}

# --- 4. Generate core postinstall script ---
echo "==> Generating core postinstall..."

mkdir -p "$BUILDDIR/core-scripts"
cat > "$BUILDDIR/core-scripts/postinstall" << 'CORE_HEADER'
#!/bin/bash
set -e

# Detect real user (installer runs as root)
REAL_USER=$(stat -f "%Su" /dev/console)
REAL_HOME=$(dscl . -read /Users/"$REAL_USER" NFSHomeDirectory | awk '{print $2}')

echo "Installing Jeff's Sic Tools Manager for user: $REAL_USER ($REAL_HOME)"

# --- Upgrade: stop existing installation ---
MANAGER_PLIST="$REAL_HOME/Library/LaunchAgents/com.custom-tools.manager.plist"
UPDATER_PLIST="$REAL_HOME/Library/LaunchAgents/com.custom-tools.updater.plist"
if [ -f "$MANAGER_PLIST" ]; then
    echo "Existing installation detected — upgrading..."
    su "$REAL_USER" -c "launchctl unload '$MANAGER_PLIST' 2>/dev/null || true"
    su "$REAL_USER" -c "launchctl unload '$UPDATER_PLIST' 2>/dev/null || true"
    killall ToolManager 2>/dev/null || true
    sleep 0.5
fi

# Create directory structure
mkdir -p "$REAL_HOME/.local/bin"
mkdir -p "$REAL_HOME/.local/tools"
mkdir -p "$REAL_HOME/.local/bin/ToolManager.app/Contents/MacOS"
mkdir -p "$REAL_HOME/Library/LaunchAgents"

CORE_HEADER

# Append base64 data and decode commands
cat >> "$BUILDDIR/core-scripts/postinstall" << CORE_DATA
# Decode pre-compiled universal binary
echo '$BINARY_B64' | base64 -d > "\$REAL_HOME/.local/bin/ToolManager.app/Contents/MacOS/ToolManager"
chmod +x "\$REAL_HOME/.local/bin/ToolManager.app/Contents/MacOS/ToolManager"

# Decode source (kept for reference/modification)
echo '$SWIFT_B64' | base64 -d > "\$REAL_HOME/.local/bin/ToolManagerSource.swift"

echo '$BASH_B64' | base64 -d > "\$REAL_HOME/.local/bin/tool-manager.sh"
chmod +x "\$REAL_HOME/.local/bin/tool-manager.sh"

echo '$PLIST_B64' | base64 -d > "\$REAL_HOME/.local/bin/ToolManager.app/Contents/Info.plist"

echo '$UPDATER_B64' | base64 -d > "\$REAL_HOME/.local/bin/sic-updater.sh"
chmod +x "\$REAL_HOME/.local/bin/sic-updater.sh"

CORE_DATA

cat >> "$BUILDDIR/core-scripts/postinstall" << 'CORE_UNINSTALLER'
# Install uninstall script
cat > "$REAL_HOME/.local/bin/uninstall-tool-manager.sh" << 'UNINSTALL'
#!/bin/bash
# ============================================
#  Uninstall Jeff's Sic Tools Manager
# ============================================
set -e

echo ""
echo "  Jeff's Sic Tools Manager — Uninstaller"
echo "  ========================================"
echo ""
echo "  This will remove:"
echo "    - Menu bar app (ToolManager.app)"
echo "    - CLI tool (tool-manager.sh)"
echo "    - All tool manifests (~/.local/tools/)"
echo "    - All related LaunchAgents"
echo "    - Source files and uninstaller"
echo ""
read -p "  Are you sure? (y/N) " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "  Cancelled."
    exit 0
fi

echo ""
echo "  Uninstalling..."

# Unload manager LaunchAgent
MANAGER_PLIST="$HOME/Library/LaunchAgents/com.custom-tools.manager.plist"
if [ -f "$MANAGER_PLIST" ]; then
    launchctl unload "$MANAGER_PLIST" 2>/dev/null || true
    rm "$MANAGER_PLIST"
    echo "    Removed manager LaunchAgent"
fi

# Kill the app
killall ToolManager 2>/dev/null || true

# Unload and remove updater LaunchAgent
UPDATER_PLIST="$HOME/Library/LaunchAgents/com.custom-tools.updater.plist"
if [ -f "$UPDATER_PLIST" ]; then
    launchctl unload "$UPDATER_PLIST" 2>/dev/null || true
    rm "$UPDATER_PLIST"
    echo "    Removed updater LaunchAgent"
fi

# Unload and remove all tool LaunchAgents referenced in manifests
for manifest in "$HOME/.local/tools/"*.tool; do
    [ -f "$manifest" ] || continue
    label="" plist_path="" script_path=""
    while IFS='=' read -r key val; do
        val="${val#"${val%%[![:space:]]*}"}"
        case "$key" in
            LABEL) label="$val" ;;
            PLIST) plist_path="$(eval echo "$val")" ;;
            SCRIPT) script_path="$(eval echo "$val")" ;;
        esac
    done < "$manifest"
    if [ -n "$label" ]; then
        launchctl unload "$plist_path" 2>/dev/null || true
    fi
    [ -f "$plist_path" ] && rm "$plist_path" && echo "    Removed $plist_path"
    [ -f "$script_path" ] && rm "$script_path" && echo "    Removed $script_path"
done

# Remove tool manifests
rm -f "$HOME/.local/tools/"*.tool
echo "    Removed tool manifests"

# Remove app bundle and source files
rm -rf "$HOME/.local/bin/ToolManager.app"
rm -f "$HOME/.local/bin/ToolManagerSource.swift"
rm -f "$HOME/.local/bin/tool-manager.sh"
rm -f "$HOME/.local/bin/sic-updater.sh"
rm -f "$HOME/.local/bin/sic-watcher"
echo "    Removed app and source files"

# Remove updater files
rm -f "$HOME/.local/sic-versions"
rm -f "$HOME/.local/.sic-updater.lock"
rm -f "$HOME/.local/.sic-github-token"
rm -rf "$HOME/.local/sic-backup"
echo "    Removed updater data"

# Remove log files
rm -f "$HOME/Library/Logs/screenshot-watcher.log"
rm -f "$HOME/Library/Logs/sic-updater.log"

# Forget installer receipts
sudo pkgutil --forget com.custom-tools.core 2>/dev/null || true
sudo pkgutil --forget com.custom-tools.screenshot-watcher 2>/dev/null || true
sudo pkgutil --forget com.custom-tools.cat-detector 2>/dev/null || true
sudo pkgutil --forget com.custom-tools.coffee-refiller 2>/dev/null || true
sudo pkgutil --forget com.custom-tools.snack-scheduler 2>/dev/null || true
sudo pkgutil --forget com.custom-tools.updater 2>/dev/null || true

# Remove empty directories (only if empty)
rmdir "$HOME/.local/tools" 2>/dev/null || true
rmdir "$HOME/.local/bin" 2>/dev/null || true
rmdir "$HOME/.local" 2>/dev/null || true

# Remove self
SELF="$HOME/.local/bin/uninstall-tool-manager.sh"
echo "    Removed uninstaller"
echo ""
echo "  Jeff's Sic Tools Manager has been uninstalled."
echo ""
rm -f "$SELF"
UNINSTALL
chmod +x "$REAL_HOME/.local/bin/uninstall-tool-manager.sh"

CORE_UNINSTALLER

cat >> "$BUILDDIR/core-scripts/postinstall" << CORE_VERSIONS
# Write initial version tracking file
cat > "\$REAL_HOME/.local/sic-versions" << 'SICVER'
# Jeff's Sic Tools Manager — installed versions
# Managed by sic-updater.sh
core=$VERSION
last-check=never
SICVER
chown "\$REAL_USER" "\$REAL_HOME/.local/sic-versions"

CORE_VERSIONS

cat >> "$BUILDDIR/core-scripts/postinstall" << 'CORE_LAUNCHAGENTS'
# Write LaunchAgent plist for manager
PLIST_PATH="$REAL_HOME/Library/LaunchAgents/com.custom-tools.manager.plist"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.custom-tools.manager</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REAL_HOME/.local/bin/ToolManager.app/Contents/MacOS/ToolManager</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLIST

CORE_LAUNCHAGENTS

# Updater plist — unquoted heredoc so $UPDATER_INTERVAL expands at build time
cat >> "$BUILDDIR/core-scripts/postinstall" << CORE_UPDATER_PLIST
# Write LaunchAgent plist for auto-updater
UPDATER_PLIST_PATH="\$REAL_HOME/Library/LaunchAgents/com.custom-tools.updater.plist"
cat > "\$UPDATER_PLIST_PATH" << UPDPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.custom-tools.updater</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>\$REAL_HOME/.local/bin/sic-updater.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>$UPDATER_INTERVAL</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>\$REAL_HOME/Library/Logs/sic-updater.log</string>
    <key>StandardErrorPath</key>
    <string>\$REAL_HOME/Library/Logs/sic-updater.log</string>
</dict>
</plist>
UPDPLIST

CORE_UPDATER_PLIST

cat >> "$BUILDDIR/core-scripts/postinstall" << 'CORE_FOOTER'
# Fix ownership
chown -R "$REAL_USER" "$REAL_HOME/.local"
chown "$REAL_USER" "$PLIST_PATH"
chown "$REAL_USER" "$UPDATER_PLIST_PATH"

# Load LaunchAgents
su "$REAL_USER" -c "launchctl load '$PLIST_PATH'"
su "$REAL_USER" -c "launchctl load '$UPDATER_PLIST_PATH'"

echo "Jeff's Sic Tools Manager installed successfully."
exit 0
CORE_FOOTER

chmod +x "$BUILDDIR/core-scripts/postinstall"

# --- 5. Generate screenshot-watcher postinstall script ---
echo "==> Generating screenshot-watcher postinstall..."

mkdir -p "$BUILDDIR/watcher-scripts"
cat > "$BUILDDIR/watcher-scripts/postinstall" << 'WATCHER_HEADER'
#!/bin/bash
set -e

# Detect real user
REAL_USER=$(stat -f "%Su" /dev/console)
REAL_HOME=$(dscl . -read /Users/"$REAL_USER" NFSHomeDirectory | awk '{print $2}')

echo "Installing Screenshot Watcher for user: $REAL_USER ($REAL_HOME)"

# Upgrade: stop existing service
WATCHER_PLIST="$REAL_HOME/Library/LaunchAgents/com.screenshot-watcher.plist"
if [ -f "$WATCHER_PLIST" ]; then
    echo "Existing Screenshot Watcher detected — upgrading..."
    su "$REAL_USER" -c "launchctl unload '$WATCHER_PLIST' 2>/dev/null || true"
fi

# Create directories
mkdir -p "$REAL_HOME/.local/bin"
mkdir -p "$REAL_HOME/.local/tools"
mkdir -p "$REAL_HOME/Desktop/Screenshots"
mkdir -p "$REAL_HOME/Library/LaunchAgents"
mkdir -p "$REAL_HOME/Library/Logs"

# Set macOS screenshot save location to ~/Desktop/Screenshots
su "$REAL_USER" -c "defaults write com.apple.screencapture location '$REAL_HOME/Desktop/Screenshots'"
chown -R "$REAL_USER" "$REAL_HOME/Desktop/Screenshots"

WATCHER_HEADER

cat >> "$BUILDDIR/watcher-scripts/postinstall" << WATCHER_DATA
# Decode screenshot-watcher script
echo '$WATCHER_B64' | base64 -d > "\$REAL_HOME/.local/bin/screenshot-watcher.sh"
chmod +x "\$REAL_HOME/.local/bin/screenshot-watcher.sh"

# Decode sic-watcher binary (native directory watcher)
echo '$WATCHER_BIN_B64' | base64 -d > "\$REAL_HOME/.local/bin/sic-watcher"
chmod +x "\$REAL_HOME/.local/bin/sic-watcher"

WATCHER_DATA

# Write manifest with build-time VERSION expansion
cat >> "$BUILDDIR/watcher-scripts/postinstall" << WATCHER_MANIFEST
# Write .tool manifest
cat > "\$REAL_HOME/.local/tools/screenshot-watcher.tool" << 'MANIFEST'
NAME=Screen-shot Manager
DESCRIPTION=Auto-opens Screenshots folder when you take a screenshot
LABEL=com.screenshot-watcher
SCRIPT=\$HOME/.local/bin/screenshot-watcher.sh
BINARY=\$HOME/.local/bin/sic-watcher
PLIST=\$HOME/Library/LaunchAgents/com.screenshot-watcher.plist
VERSION=$VERSION
UPDATE_TAG=tool-screenshot-watcher
MANIFEST

WATCHER_MANIFEST

cat >> "$BUILDDIR/watcher-scripts/postinstall" << 'WATCHER_FOOTER'
# Write LaunchAgent plist
PLIST_PATH="$REAL_HOME/Library/LaunchAgents/com.screenshot-watcher.plist"
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.screenshot-watcher</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REAL_HOME/.local/bin/screenshot-watcher.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$REAL_HOME/Library/Logs/screenshot-watcher.log</string>
    <key>StandardErrorPath</key>
    <string>$REAL_HOME/Library/Logs/screenshot-watcher.log</string>
</dict>
</plist>
PLIST

# Fix ownership
chown -R "$REAL_USER" "$REAL_HOME/.local"
chown "$REAL_USER" "$PLIST_PATH"

# Load LaunchAgent
su "$REAL_USER" -c "launchctl load '$PLIST_PATH'"

echo "Screenshot Watcher installed successfully."
WATCHER_FOOTER

# Append tool version tracking (needs build-time VERSION expansion)
cat >> "$BUILDDIR/watcher-scripts/postinstall" << WATCHER_VERSIONS
# Update version tracking
VERSIONS_FILE="\$REAL_HOME/.local/sic-versions"
if [ -f "\$VERSIONS_FILE" ]; then
    # Remove old entry if present, then add new
    grep -v "^tool-screenshot-watcher=" "\$VERSIONS_FILE" > "\$VERSIONS_FILE.tmp" || true
    mv "\$VERSIONS_FILE.tmp" "\$VERSIONS_FILE"
fi
echo "tool-screenshot-watcher=$VERSION" >> "\$VERSIONS_FILE"
chown "\$REAL_USER" "\$VERSIONS_FILE"

exit 0
WATCHER_VERSIONS

chmod +x "$BUILDDIR/watcher-scripts/postinstall"

# --- 6. Generate fake tool postinstall scripts ---
echo "==> Generating demo tool packages..."

make_manifest_pkg "cat-detector" "NAME=Cat-On-Keyboard Detector
DESCRIPTION=Alerts you when a cat is walking across your keyboard
LABEL=com.fake.cat-detector
PLIST=\$HOME/Library/LaunchAgents/com.fake.cat-detector.plist"

make_manifest_pkg "coffee-refiller" "NAME=Coffee Refiller 3000
DESCRIPTION=Detects empty mugs and summons fresh coffee
LABEL=com.fake.coffee-refiller
PLIST=\$HOME/Library/LaunchAgents/com.fake.coffee-refiller.plist"

make_manifest_pkg "snack-scheduler" "NAME=Snack Scheduler
DESCRIPTION=Reminds you to take a snack break every 47 minutes
LABEL=com.fake.snack-scheduler
PLIST=\$HOME/Library/LaunchAgents/com.fake.snack-scheduler.plist"

# --- 7. Build component packages ---
echo "==> Building component packages..."

mkdir -p "$BUILDDIR/packages"

pkgbuild --nopayload \
    --scripts "$BUILDDIR/core-scripts" \
    --identifier "${IDENTIFIER_BASE}.core" \
    --version "$VERSION" \
    "$BUILDDIR/packages/core.pkg"

pkgbuild --nopayload \
    --scripts "$BUILDDIR/watcher-scripts" \
    --identifier "${IDENTIFIER_BASE}.screenshot-watcher" \
    --version "$VERSION" \
    "$BUILDDIR/packages/screenshot-watcher.pkg"

pkgbuild --nopayload \
    --scripts "$BUILDDIR/cat-detector" \
    --identifier "${IDENTIFIER_BASE}.cat-detector" \
    --version "$VERSION" \
    "$BUILDDIR/packages/cat-detector.pkg"

pkgbuild --nopayload \
    --scripts "$BUILDDIR/coffee-refiller" \
    --identifier "${IDENTIFIER_BASE}.coffee-refiller" \
    --version "$VERSION" \
    "$BUILDDIR/packages/coffee-refiller.pkg"

pkgbuild --nopayload \
    --scripts "$BUILDDIR/snack-scheduler" \
    --identifier "${IDENTIFIER_BASE}.snack-scheduler" \
    --version "$VERSION" \
    "$BUILDDIR/packages/snack-scheduler.pkg"

echo "    Component packages built."

# --- 8. Write distribution XML ---
echo "==> Writing distribution XML..."

cat > "$BUILDDIR/distribution.xml" << DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Jeff's Sic Tools Manager</title>
    <welcome file="welcome.html" />
    <options customize="always" require-scripts="false" />

    <choices-outline>
        <line choice="core" />
        <line choice="screenshot-watcher" />
        <line choice="cat-detector" />
        <line choice="coffee-refiller" />
        <line choice="snack-scheduler" />
    </choices-outline>

    <choice id="core"
            title="Jeff's Sic Tools Manager (Core)"
            description="Menu bar control panel and bash TUI for managing tools. Required."
            enabled="false"
            selected="true">
        <pkg-ref id="com.custom-tools.core" />
    </choice>

    <choice id="screenshot-watcher"
            title="Screen-shot Manager"
            description="Auto-opens your Screenshots folder in Finder when you take a screenshot."
            selected="true">
        <pkg-ref id="com.custom-tools.screenshot-watcher" />
    </choice>

    <choice id="cat-detector"
            title="Cat-On-Keyboard Detector"
            description="Alerts you when a cat is walking across your keyboard."
            selected="true">
        <pkg-ref id="com.custom-tools.cat-detector" />
    </choice>

    <choice id="coffee-refiller"
            title="Coffee Refiller 3000"
            description="Detects empty mugs and summons fresh coffee."
            selected="true">
        <pkg-ref id="com.custom-tools.coffee-refiller" />
    </choice>

    <choice id="snack-scheduler"
            title="Snack Scheduler"
            description="Reminds you to take a snack break every 47 minutes."
            selected="true">
        <pkg-ref id="com.custom-tools.snack-scheduler" />
    </choice>

    <pkg-ref id="com.custom-tools.core" version="$VERSION">core.pkg</pkg-ref>
    <pkg-ref id="com.custom-tools.screenshot-watcher" version="$VERSION">screenshot-watcher.pkg</pkg-ref>
    <pkg-ref id="com.custom-tools.cat-detector" version="$VERSION">cat-detector.pkg</pkg-ref>
    <pkg-ref id="com.custom-tools.coffee-refiller" version="$VERSION">coffee-refiller.pkg</pkg-ref>
    <pkg-ref id="com.custom-tools.snack-scheduler" version="$VERSION">snack-scheduler.pkg</pkg-ref>
</installer-gui-script>
DISTXML

# --- 9. Write welcome.html ---
echo "==> Writing welcome page..."

mkdir -p "$BUILDDIR/resources"
cat > "$BUILDDIR/resources/welcome.html" << 'WELCOME'
<!DOCTYPE html>
<html>
<head>
<style>
    body { font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 13px; padding: 20px; color: #333; }
    @media (prefers-color-scheme: dark) { body { color: #eee; } }
    h1 { font-size: 20px; margin-bottom: 4px; }
    h2 { font-size: 14px; margin-top: 16px; margin-bottom: 4px; }
    ul { padding-left: 20px; }
    li { margin-bottom: 4px; }
    .note { background: rgba(128,128,128,0.15); border-radius: 6px; padding: 10px 12px; margin-top: 16px; font-size: 12px; }
</style>
</head>
<body>
    <h1>Jeff's Sic Tools Manager</h1>
    <p>A lightweight macOS menu bar app for managing custom background tools and services.</p>

    <h2>What's included</h2>
    <ul>
        <li><strong>Core</strong> &mdash; Menu bar control panel and bash TUI (required)</li>
        <li><strong>Screen-shot Manager</strong> &mdash; Auto-opens Screenshots folder on new screenshots</li>
        <li><strong>Cat-On-Keyboard Detector</strong> &mdash; Demo tool</li>
        <li><strong>Coffee Refiller 3000</strong> &mdash; Demo tool</li>
        <li><strong>Snack Scheduler</strong> &mdash; Demo tool</li>
    </ul>

    <p>On the next screen, select which tools to install.</p>

    <div class="note">
        <strong>Note:</strong> The menu bar app is pre-compiled as a universal binary (Apple Silicon + Intel). Everything is self-contained &mdash; no additional dependencies required.<br><br>
        <strong>To uninstall:</strong> Run <code>bash ~/.local/bin/uninstall-tool-manager.sh</code>
    </div>
</body>
</html>
WELCOME

# --- 10. Build final .pkg ---
echo "==> Building final installer..."

productbuild \
    --distribution "$BUILDDIR/distribution.xml" \
    --package-path "$BUILDDIR/packages" \
    --resources "$BUILDDIR/resources" \
    "$OUTPUT"

echo ""
echo "============================================"
echo "  Installer built successfully!"
echo "  $OUTPUT"
echo "============================================"
echo ""
echo "  To uninstall:"
echo "    bash ~/.local/bin/uninstall-tool-manager.sh"
echo ""
