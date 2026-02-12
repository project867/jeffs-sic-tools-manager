#!/bin/bash
# ============================================
#  Tool Manager for macOS
#  Manage custom background tools/services
# ============================================

TOOLS_DIR="$HOME/.local/tools"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Load tool manifests ---
load_tools() {
    TOOL_FILES=()
    TOOL_NAMES=()
    TOOL_DESCS=()
    TOOL_LABELS=()
    TOOL_SCRIPTS=()
    TOOL_PLISTS=()

    for f in "$TOOLS_DIR"/*.tool; do
        [ -f "$f" ] || continue
        TOOL_FILES+=("$f")

        local name="" desc="" label="" script="" plist=""
        while IFS='=' read -r key val; do
            val="${val#"${val%%[![:space:]]*}"}"
            case "$key" in
                NAME) name="$val" ;;
                DESCRIPTION) desc="$val" ;;
                LABEL) label="$val" ;;
                SCRIPT) script="$(eval echo "$val")" ;;
                PLIST) plist="$(eval echo "$val")" ;;
            esac
        done < "$f"

        TOOL_NAMES+=("$name")
        TOOL_DESCS+=("$desc")
        TOOL_LABELS+=("$label")
        TOOL_SCRIPTS+=("$script")
        TOOL_PLISTS+=("$plist")
    done
}

# --- Check if a tool is running ---
is_running() {
    launchctl list 2>/dev/null | grep -q "$1"
}

# --- Print header ---
header() {
    clear
    echo ""
    echo -e "${BOLD}  ========================================${RESET}"
    echo -e "${BOLD}            Tool Manager${RESET}"
    echo -e "${BOLD}  ========================================${RESET}"
    echo ""
}

# --- Main menu ---
main_menu() {
    while true; do
        load_tools
        header

        if [ ${#TOOL_FILES[@]} -eq 0 ]; then
            echo -e "  ${DIM}No tools installed.${RESET}"
            echo ""
            echo -e "  ${DIM}Q${RESET}  Quit"
            echo ""
            read -p "  > " choice
            case "$choice" in
                q|Q) clear; exit 0 ;;
            esac
            continue
        fi

        local all_running=true
        local any_running=false

        for i in "${!TOOL_FILES[@]}"; do
            local num=$((i + 1))
            if is_running "${TOOL_LABELS[$i]}"; then
                echo -e "  ${BOLD}$num.${RESET}  ${GREEN}RUNNING${RESET}  ${TOOL_NAMES[$i]}"
                echo -e "      ${DIM}${TOOL_DESCS[$i]}${RESET}"
                any_running=true
            else
                echo -e "  ${BOLD}$num.${RESET}  ${RED}STOPPED${RESET}  ${TOOL_NAMES[$i]}"
                echo -e "      ${DIM}${TOOL_DESCS[$i]}${RESET}"
                all_running=false
            fi
            echo ""
        done

        echo -e "  ────────────────────────────────────────"
        if $any_running; then
            echo -e "  ${BOLD}A${RESET}.  ${YELLOW}Stop all tools${RESET}"
        else
            echo -e "  ${BOLD}A${RESET}.  ${GREEN}Start all tools${RESET}"
        fi
        if ! $all_running && $any_running; then
            echo -e "  ${BOLD}S${RESET}.  ${GREEN}Start all tools${RESET}"
        fi
        echo -e "  ${BOLD}Q${RESET}.  Quit"
        echo ""
        read -p "  Enter choice: " choice

        case "$choice" in
            [0-9]*)
                local idx=$((choice - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#TOOL_FILES[@]}" ]; then
                    tool_menu "$idx"
                fi
                ;;
            a|A)
                if $any_running; then
                    stop_all
                else
                    start_all
                fi
                ;;
            s|S)
                start_all
                ;;
            q|Q)
                clear
                exit 0
                ;;
        esac
    done
}

# --- Tool detail menu ---
tool_menu() {
    local idx=$1
    while true; do
        header
        local running=false
        is_running "${TOOL_LABELS[$idx]}" && running=true

        if $running; then
            echo -e "  ${TOOL_NAMES[$idx]}  ${GREEN}[RUNNING]${RESET}"
        else
            echo -e "  ${TOOL_NAMES[$idx]}  ${RED}[STOPPED]${RESET}"
        fi
        echo -e "  ${DIM}${TOOL_DESCS[$idx]}${RESET}"
        echo ""
        echo -e "  ────────────────────────────────────────"

        if $running; then
            echo -e "  ${BOLD}1${RESET}.  Stop"
        else
            echo -e "  ${BOLD}1${RESET}.  Start"
        fi
        echo -e "  ${BOLD}2${RESET}.  ${RED}Uninstall${RESET}"
        echo -e "  ${BOLD}B${RESET}.  Back"
        echo ""
        read -p "  Enter choice: " choice

        case "$choice" in
            1)
                if $running; then
                    echo ""
                    echo -e "  Stopping ${TOOL_NAMES[$idx]}..."
                    launchctl unload "${TOOL_PLISTS[$idx]}" 2>/dev/null
                    sleep 0.5
                    echo -e "  ${RED}Stopped.${RESET}"
                    sleep 1
                else
                    echo ""
                    echo -e "  Starting ${TOOL_NAMES[$idx]}..."
                    launchctl load "${TOOL_PLISTS[$idx]}" 2>/dev/null
                    sleep 0.5
                    echo -e "  ${GREEN}Started.${RESET}"
                    sleep 1
                fi
                ;;
            2)
                echo ""
                read -p "  Are you sure you want to uninstall ${TOOL_NAMES[$idx]}? (y/N) " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    echo ""
                    echo "  Uninstalling..."
                    launchctl unload "${TOOL_PLISTS[$idx]}" 2>/dev/null
                    [ -f "${TOOL_SCRIPTS[$idx]}" ] && rm "${TOOL_SCRIPTS[$idx]}"
                    [ -f "${TOOL_PLISTS[$idx]}" ] && rm "${TOOL_PLISTS[$idx]}"
                    rm "${TOOL_FILES[$idx]}"
                    echo -e "  ${RED}Uninstalled.${RESET}"
                    sleep 1
                    return
                fi
                ;;
            b|B)
                return
                ;;
        esac
    done
}

# --- Stop all tools ---
stop_all() {
    echo ""
    for i in "${!TOOL_FILES[@]}"; do
        if is_running "${TOOL_LABELS[$i]}"; then
            echo -e "  Stopping ${TOOL_NAMES[$i]}..."
            launchctl unload "${TOOL_PLISTS[$i]}" 2>/dev/null
        fi
    done
    echo -e "  ${RED}All tools stopped.${RESET}"
    sleep 1
}

# --- Start all tools ---
start_all() {
    echo ""
    for i in "${!TOOL_FILES[@]}"; do
        if ! is_running "${TOOL_LABELS[$i]}"; then
            echo -e "  Starting ${TOOL_NAMES[$i]}..."
            launchctl load "${TOOL_PLISTS[$i]}" 2>/dev/null
        fi
    done
    echo -e "  ${GREEN}All tools started.${RESET}"
    sleep 1
}

main_menu
