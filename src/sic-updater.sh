#!/bin/bash
# ============================================
#  Jeff's Sic Tools Manager — Auto-Updater
#  Checks GitHub Releases for updates and
#  silently applies them.
#
#  Compatible with macOS default bash (3.2+).
# ============================================
set -euo pipefail

# --- Config ---
GITHUB_REPO="project867/jeffs-sic-tools-manager"
VERSIONS_FILE="$HOME/.local/sic-versions"
BACKUP_DIR="$HOME/.local/sic-backup"
BIN_DIR="$HOME/.local/bin"
TOOLS_DIR="$HOME/.local/tools"
LOG_FILE="$HOME/Library/Logs/sic-updater.log"
LOCK_FILE="$HOME/.local/.sic-updater.lock"
TOKEN_FILE="$HOME/.local/.sic-github-token"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=50"
MAX_LOG_SIZE=1048576  # 1MB

# --- Auth (for private repos) ---
AUTH_HEADER=""
if [ -f "$TOKEN_FILE" ]; then
    AUTH_HEADER="Authorization: Bearer $(cat "$TOKEN_FILE" | tr -d '[:space:]')"
fi

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG_FILE"
}

# --- Lock (prevent concurrent runs) ---
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "Another updater is running (PID $pid). Exiting."
            exit 0
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# --- Log rotation ---
rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_SIZE" ]; then
        tail -100 "$LOG_FILE" > "$LOG_FILE.tmp"
        mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# --- Version comparison ---
# Returns 0 (true) if $1 > $2 (semver)
version_gt() {
    local ver_a="$1"
    local ver_b="$2"

    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 << EOF
$ver_a
EOF
    IFS=. read -r b1 b2 b3 << EOF
$ver_b
EOF
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}

    if [ "$a1" -gt "$b1" ] 2>/dev/null; then return 0; fi
    if [ "$a1" -lt "$b1" ] 2>/dev/null; then return 1; fi
    if [ "$a2" -gt "$b2" ] 2>/dev/null; then return 0; fi
    if [ "$a2" -lt "$b2" ] 2>/dev/null; then return 1; fi
    if [ "$a3" -gt "$b3" ] 2>/dev/null; then return 0; fi
    return 1
}

# --- Read a version from sic-versions file ---
get_installed_version() {
    local component="$1"
    if [ -f "$VERSIONS_FILE" ]; then
        grep "^${component}=" "$VERSIONS_FILE" 2>/dev/null | head -1 | cut -d= -f2-
    fi
}

# --- Write/update a version in sic-versions file ---
set_installed_version() {
    local component="$1"
    local version="$2"

    if [ ! -f "$VERSIONS_FILE" ]; then
        echo "# Jeff's Sic Tools Manager — installed versions" > "$VERSIONS_FILE"
    fi

    # Remove existing entry, then append new one
    local tmp="${VERSIONS_FILE}.tmp"
    grep -v "^${component}=" "$VERSIONS_FILE" > "$tmp" 2>/dev/null || true
    echo "${component}=${version}" >> "$tmp"
    mv "$tmp" "$VERSIONS_FILE"
}

# --- Fetch releases from GitHub (single API call) ---
# Writes response to a temp file and prints the file path
fetch_releases() {
    local tmp_file="${TMPDIR:-/tmp}/sic-releases-$$.json"
    local curl_args=(-s --max-time 30 -H "Accept: application/vnd.github+json" -o "$tmp_file")
    if [ -n "$AUTH_HEADER" ]; then
        curl_args+=(-H "$AUTH_HEADER")
    fi
    curl "${curl_args[@]}" "$GITHUB_API" 2>/dev/null || {
        log "ERROR: Failed to fetch releases from GitHub"
        rm -f "$tmp_file"
        return 1
    }

    if ! grep -q '"tag_name"' "$tmp_file" 2>/dev/null; then
        log "ERROR: Invalid response from GitHub API"
        rm -f "$tmp_file"
        return 1
    fi

    echo "$tmp_file"
}

# --- Extract latest version for a component tag prefix ---
get_latest_version() {
    local tag_prefix="$1"
    local releases="$2"

    cat "$releases" | grep -o "\"tag_name\": *\"${tag_prefix}-v[^\"]*\"" \
        | head -1 \
        | sed "s/.*${tag_prefix}-v\([^\"]*\)\".*/\1/"
}

# --- Get asset download URLs for a specific tag ---
get_asset_urls() {
    local tag="$1"
    local releases="$2"

    cat "$releases" | awk -v tag="$tag" '
        /"tag_name"/ { found = ($0 ~ "\"" tag "\"") }
        found && /"browser_download_url"/ { print }
        found && /^\s*\]/ && !/^\s*\[/ { if (found) exit }
    ' | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/'
}

# --- Download a file ---
download_asset() {
    local url="$1"
    local dest="$2"
    local curl_args=(-sL --max-time 60 -o "$dest")
    if [ -n "$AUTH_HEADER" ]; then
        curl_args+=(-H "$AUTH_HEADER" -H "Accept: application/octet-stream")
    fi

    curl "${curl_args[@]}" "$url" 2>/dev/null || {
        log "ERROR: Failed to download $url"
        return 1
    }
}

# --- Verify sha256 checksum ---
verify_checksum() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

# --- Download release manifest ---
download_manifest() {
    local tag="$1"
    local releases="$2"
    local tmp_dir="$3"

    local manifest_url
    manifest_url=$(get_asset_urls "$tag" "$releases" | grep "manifest\.txt" || echo "")

    if [ -z "$manifest_url" ]; then
        log "WARNING: No manifest.txt found in release $tag"
        return 1
    fi

    download_asset "$manifest_url" "$tmp_dir/manifest.txt" || return 1
    echo "$tmp_dir/manifest.txt"
}

# --- Get expected checksum from manifest ---
get_checksum() {
    local manifest_file="$1"
    local filename="$2"
    grep "  ${filename}$" "$manifest_file" | awk '{print $1}'
}

# --- Download and verify a release asset ---
download_verified_asset() {
    local filename="$1"
    local tag="$2"
    local releases="$3"
    local tmp_dir="$4"
    local manifest_file="$5"

    local url
    url=$(get_asset_urls "$tag" "$releases" | grep "/${filename}$" || echo "")

    if [ -z "$url" ]; then
        log "ERROR: Asset $filename not found in release $tag"
        return 1
    fi

    download_asset "$url" "$tmp_dir/$filename" || return 1

    if [ -n "$manifest_file" ] && [ -f "$manifest_file" ]; then
        local expected
        expected=$(get_checksum "$manifest_file" "$filename")
        if [ -n "$expected" ]; then
            if ! verify_checksum "$tmp_dir/$filename" "$expected"; then
                log "ERROR: Checksum mismatch for $filename"
                return 1
            fi
        fi
    fi

    echo "$tmp_dir/$filename"
}

# ============================================================
#  Core Update
# ============================================================
apply_core_update() {
    local new_version="$1"
    local releases="$2"
    local tag="core-v${new_version}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local current_version
    current_version=$(get_installed_version "core")
    log "Updating core from $current_version to $new_version..."

    # Download manifest first
    local manifest_file=""
    manifest_file=$(download_manifest "$tag" "$releases" "$tmp_dir") || manifest_file=""

    # Download all core assets
    local binary_file tool_mgr_file plist_file updater_file

    binary_file=$(download_verified_asset "ToolManager-universal" "$tag" "$releases" "$tmp_dir" "$manifest_file") || {
        log "ERROR: Failed to download ToolManager binary"
        rm -rf "$tmp_dir"
        return 1
    }

    tool_mgr_file=$(download_verified_asset "tool-manager.sh" "$tag" "$releases" "$tmp_dir" "$manifest_file") || {
        log "ERROR: Failed to download tool-manager.sh"
        rm -rf "$tmp_dir"
        return 1
    }

    plist_file=$(download_verified_asset "Info.plist" "$tag" "$releases" "$tmp_dir" "$manifest_file") || {
        log "ERROR: Failed to download Info.plist"
        rm -rf "$tmp_dir"
        return 1
    }

    updater_file=$(download_verified_asset "sic-updater.sh" "$tag" "$releases" "$tmp_dir" "$manifest_file") || {
        log "WARNING: sic-updater.sh not in release, skipping self-update"
        updater_file=""
    }

    # Verify binary is a valid Mach-O
    if ! file "$binary_file" | grep -q "Mach-O"; then
        log "ERROR: Downloaded binary is not a valid Mach-O file"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Backup current files
    mkdir -p "$BACKUP_DIR/core"
    cp "$BIN_DIR/ToolManager.app/Contents/MacOS/ToolManager" "$BACKUP_DIR/core/" 2>/dev/null || true
    cp "$BIN_DIR/tool-manager.sh" "$BACKUP_DIR/core/" 2>/dev/null || true
    cp "$BIN_DIR/ToolManager.app/Contents/Info.plist" "$BACKUP_DIR/core/" 2>/dev/null || true

    # Stop the menu bar app
    killall ToolManager 2>/dev/null || true
    sleep 1

    # Replace files
    cp "$binary_file" "$BIN_DIR/ToolManager.app/Contents/MacOS/ToolManager"
    chmod +x "$BIN_DIR/ToolManager.app/Contents/MacOS/ToolManager"

    cp "$tool_mgr_file" "$BIN_DIR/tool-manager.sh"
    chmod +x "$BIN_DIR/tool-manager.sh"

    cp "$plist_file" "$BIN_DIR/ToolManager.app/Contents/Info.plist"

    # Self-update (takes effect next run)
    if [ -n "$updater_file" ]; then
        cp "$updater_file" "$BIN_DIR/sic-updater.sh"
        chmod +x "$BIN_DIR/sic-updater.sh"
    fi

    # Write version BEFORE relaunch so the new app reads the correct version
    set_installed_version "core" "$new_version"

    # Relaunch the menu bar app
    open "$BIN_DIR/ToolManager.app"

    # Verify it launched
    sleep 3
    if ! pgrep -x ToolManager >/dev/null; then
        log "WARNING: ToolManager failed to start after update — rolling back..."
        set_installed_version "core" "$current_version"
        cp "$BACKUP_DIR/core/ToolManager" "$BIN_DIR/ToolManager.app/Contents/MacOS/ToolManager" 2>/dev/null || true
        chmod +x "$BIN_DIR/ToolManager.app/Contents/MacOS/ToolManager"
        cp "$BACKUP_DIR/core/tool-manager.sh" "$BIN_DIR/tool-manager.sh" 2>/dev/null || true
        chmod +x "$BIN_DIR/tool-manager.sh"
        cp "$BACKUP_DIR/core/Info.plist" "$BIN_DIR/ToolManager.app/Contents/Info.plist" 2>/dev/null || true
        open "$BIN_DIR/ToolManager.app"
        rm -rf "$tmp_dir"
        return 1
    fi
    log "Core updated to $new_version successfully"
    rm -rf "$tmp_dir"
}

# ============================================================
#  Tool Update
# ============================================================
apply_tool_update() {
    local update_tag="$1"
    local new_version="$2"
    local manifest_file_path="$3"
    local releases="$4"
    local tag="${update_tag}-v${new_version}"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    log "Updating $update_tag to $new_version..."

    # Parse current manifest for SCRIPT, BINARY, LABEL, PLIST
    local script_path="" binary_path="" label="" plist_path=""
    while IFS='=' read -r key val; do
        val="${val#"${val%%[![:space:]]*}"}"
        case "$key" in
            SCRIPT) script_path="$(eval echo "$val")" ;;
            BINARY) binary_path="$(eval echo "$val")" ;;
            LABEL) label="$val" ;;
            PLIST) plist_path="$(eval echo "$val")" ;;
        esac
    done < "$manifest_file_path"

    # Derive tool name from UPDATE_TAG (strip "tool-" prefix)
    local tool_name="${update_tag#tool-}"

    # Download manifest
    local release_manifest=""
    release_manifest=$(download_manifest "$tag" "$releases" "$tmp_dir") || release_manifest=""

    # Download new script (if tool has one)
    local new_script=""
    if [ -n "$script_path" ]; then
        new_script=$(download_verified_asset "${tool_name}.sh" "$tag" "$releases" "$tmp_dir" "$release_manifest") || {
            log "ERROR: Failed to download ${tool_name}.sh"
            rm -rf "$tmp_dir"
            return 1
        }
    fi

    # Download new binary (if tool has one)
    local new_binary=""
    if [ -n "$binary_path" ]; then
        local binary_name
        binary_name=$(basename "$binary_path")
        new_binary=$(download_verified_asset "$binary_name" "$tag" "$releases" "$tmp_dir" "$release_manifest") || {
            log "ERROR: Failed to download $binary_name"
            rm -rf "$tmp_dir"
            return 1
        }
        # Verify it's a valid Mach-O
        if ! file "$new_binary" | grep -q "Mach-O"; then
            log "ERROR: Downloaded binary $binary_name is not a valid Mach-O file"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    # Download new tool manifest
    local new_manifest
    new_manifest=$(download_verified_asset "${tool_name}.tool" "$tag" "$releases" "$tmp_dir" "$release_manifest") || {
        log "ERROR: Failed to download ${tool_name}.tool"
        rm -rf "$tmp_dir"
        return 1
    }

    # Backup current files
    mkdir -p "$BACKUP_DIR/tools"
    [ -n "$script_path" ] && [ -f "$script_path" ] && cp "$script_path" "$BACKUP_DIR/tools/"
    [ -n "$binary_path" ] && [ -f "$binary_path" ] && cp "$binary_path" "$BACKUP_DIR/tools/"
    cp "$manifest_file_path" "$BACKUP_DIR/tools/"

    # Check if tool is running, stop if so
    local was_running=false
    if [ -n "$label" ] && launchctl list 2>/dev/null | grep -q "$label"; then
        was_running=true
        [ -n "$plist_path" ] && launchctl unload "$plist_path" 2>/dev/null || true
        sleep 1
    fi

    # Replace files
    if [ -n "$new_script" ] && [ -n "$script_path" ]; then
        cp "$new_script" "$script_path"
        chmod +x "$script_path"
    fi
    if [ -n "$new_binary" ] && [ -n "$binary_path" ]; then
        cp "$new_binary" "$binary_path"
        chmod +x "$binary_path"
    fi
    cp "$new_manifest" "$manifest_file_path"

    # Restart if it was running
    if $was_running && [ -n "$plist_path" ]; then
        launchctl load "$plist_path" 2>/dev/null || true
    fi

    set_installed_version "$update_tag" "$new_version"
    log "Tool $update_tag updated to $new_version successfully"
    rm -rf "$tmp_dir"
}

# ============================================================
#  Main
# ============================================================
main() {
    local check_only=false
    local force=false

    while [ $# -gt 0 ]; do
        case "$1" in
            --check) check_only=true ;;
            --force) force=true ;;
            *) echo "Usage: sic-updater.sh [--check] [--force]"; exit 1 ;;
        esac
        shift
    done

    mkdir -p "$(dirname "$LOG_FILE")"
    rotate_log
    acquire_lock
    trap release_lock EXIT

    log "--- Update check started ---"

    # Connectivity check
    if ! curl -s --max-time 5 "https://api.github.com" >/dev/null 2>&1; then
        log "No network connectivity. Exiting."
        exit 0
    fi

    # Fetch all releases (single API call)
    local releases
    releases=$(fetch_releases) || exit 0

    local updates_found=false

    # --- Check core ---
    local installed_core
    installed_core=$(get_installed_version "core")
    installed_core="${installed_core:-0.0.0}"

    local latest_core
    latest_core=$(get_latest_version "core" "$releases")

    if [ -n "$latest_core" ] && version_gt "$latest_core" "$installed_core"; then
        updates_found=true
        log "Core update available: $installed_core -> $latest_core"
        if $check_only; then
            echo "Core: $installed_core -> $latest_core"
        else
            apply_core_update "$latest_core" "$releases" || log "ERROR: Core update failed"
        fi
    else
        log "Core is up to date ($installed_core)"
    fi

    # --- Check each tool with UPDATE_TAG ---
    for manifest in "$TOOLS_DIR"/*.tool; do
        [ -f "$manifest" ] || continue

        local update_tag="" tool_version=""
        while IFS='=' read -r key val; do
            val="${val#"${val%%[![:space:]]*}"}"
            case "$key" in
                UPDATE_TAG) update_tag="$val" ;;
                VERSION) tool_version="$val" ;;
            esac
        done < "$manifest"

        # Skip tools without update configuration
        [ -z "$update_tag" ] && continue

        local installed_tool
        installed_tool=$(get_installed_version "$update_tag")
        installed_tool="${installed_tool:-${tool_version:-0.0.0}}"

        local latest_tool
        latest_tool=$(get_latest_version "$update_tag" "$releases")

        if [ -n "$latest_tool" ] && version_gt "$latest_tool" "$installed_tool"; then
            updates_found=true
            log "Tool update available ($update_tag): $installed_tool -> $latest_tool"
            if $check_only; then
                echo "$update_tag: $installed_tool -> $latest_tool"
            else
                apply_tool_update "$update_tag" "$latest_tool" "$manifest" "$releases" || \
                    log "ERROR: Tool update failed for $update_tag"
            fi
        else
            log "Tool $update_tag is up to date ($installed_tool)"
        fi
    done

    if ! $check_only; then
        set_installed_version "last-check" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi

    if ! $updates_found; then
        if $check_only; then
            echo "Everything is up to date."
        fi
        log "No updates available."
    fi

    # Clean up temp releases file
    rm -f "$releases"

    log "--- Update check finished ---"
}

main "$@"
