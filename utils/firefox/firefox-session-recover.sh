#!/bin/bash
# PKG_NAME: firefox-session-recover
# PKG_VERSION: 1.0.5
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), dialog
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Firefox session recovery tool
# PKG_LONG_DESCRIPTION: Interactive tool to restore corrupted or broken Firefox
#  sessions by selecting from available backups in sessionstore-backups/.
#  .
#  Supports Snap, APT, and Flatpak Firefox installations.
#  Creates a safety backup before restoring.
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

#===============================================================================
# FIREFOX SESSION RECOVER
# Restore Firefox sessions from sessionstore-backups/ files.
#
# Usage: firefox-session-recover [--help]
#===============================================================================

set -euo pipefail

# --- Colors ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

# --- Utility functions ---
msg_info()  { echo -e "  ${BLUE}[i]${NC} $*" >&2; }
msg_ok()    { echo -e "  ${GREEN}[+]${NC} $*" >&2; }
msg_warn()  { echo -e "  ${YELLOW}[!]${NC} $*" >&2; }
msg_err()   { echo -e "  ${RED}[x]${NC} $*" >&2; }

usage() {
    cat <<EOF

${BOLD}Firefox Session Recovery${NC}

Usage: $0 [--help|-h]

Interactively restore a Firefox session from available backups.
Creates a safety backup before any restore operation.

Supported installations: Snap, APT (native), Flatpak.
Requires: dialog, coreutils, procps.

EOF
    exit 0
}

# --- Parse arguments ---
case "${1:-}" in
    --help|-h) usage ;;
esac

# --- Dependency check ---
check_dependencies() {
    local missing=()
    for cmd in dialog numfmt stat pgrep; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_err "Missing dependencies: ${missing[*]}"
        msg_info "Install with: sudo apt install dialog coreutils procps"
        exit 1
    fi
}

# --- Detect Firefox installation type ---
detect_firefox_install() {
    local -a candidates=()

    # Snap
    local snap_dir="$HOME/snap/firefox/common/.mozilla/firefox"
    if [[ -f "$snap_dir/profiles.ini" ]]; then
        candidates+=("$snap_dir")
    fi

    # APT / native
    local apt_dir="$HOME/.mozilla/firefox"
    if [[ -f "$apt_dir/profiles.ini" ]]; then
        candidates+=("$apt_dir")
    fi

    # Flatpak
    local flatpak_dir="$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
    if [[ -f "$flatpak_dir/profiles.ini" ]]; then
        candidates+=("$flatpak_dir")
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        msg_err "No Firefox installation found."
        msg_info "Checked: Snap, APT, Flatpak paths."
        exit 1
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        FIREFOX_DIR="${candidates[0]}"
        return
    fi

    # Multiple installations: let user choose
    local items=()
    for dir in "${candidates[@]}"; do
        local label
        case "$dir" in
            *snap*)    label="Snap" ;;
            *flatpak*|*.var*) label="Flatpak" ;;
            *)         label="APT/Native" ;;
        esac
        items+=("$dir" "$label")
    done

    FIREFOX_DIR=$(dialog --title "Firefox Installation" \
        --menu "Multiple Firefox installations found. Select one:" 15 70 "${#candidates[@]}" \
        "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    clear
}

# --- Find profiles with sessionstore-backups ---
find_profiles() {
    PROFILES=()
    PROFILE_NAMES=()
    PROFILE_PATHS=()

    local current_name="" current_path="" current_is_relative=1

    _add_profile() {
        if [[ -n "${current_path:-}" ]]; then
            local full_path
            if [[ "${current_is_relative:-1}" == "1" ]]; then
                full_path="$FIREFOX_DIR/$current_path"
            else
                full_path="$current_path"
            fi
            if [[ -d "$full_path/sessionstore-backups" ]]; then
                PROFILES+=("$full_path")
                PROFILE_NAMES+=("${current_name:-$current_path}")
                PROFILE_PATHS+=("$current_path")
            fi
        fi
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Profile ]]; then
            _add_profile
            current_name=""
            current_path=""
            current_is_relative=1
        elif [[ "$line" =~ ^Name=(.+) ]]; then
            current_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Path=(.+) ]]; then
            current_path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^IsRelative=(.+) ]]; then
            current_is_relative="${BASH_REMATCH[1]}"
        fi
    done < "$FIREFOX_DIR/profiles.ini"

    # Handle last profile in file
    _add_profile
    unset -f _add_profile

    if [[ ${#PROFILES[@]} -eq 0 ]]; then
        msg_err "No profiles with sessionstore-backups/ found."
        exit 1
    fi
}

# --- Print profile summary ---
print_profiles_summary() {
    echo -e "${BOLD}Profiles found:${NC}"
    echo ""
    for i in "${!PROFILES[@]}"; do
        local prof_size
        prof_size=$(du -sh "${PROFILES[$i]}" 2>/dev/null | cut -f1)
        local prof_mod
        prof_mod=$(stat -c '%Y' "${PROFILES[$i]}" 2>/dev/null)
        local prof_mod_human
        prof_mod_human=$(date -d "@$prof_mod" '+%Y-%m-%d %H:%M:%S')
        local backup_count
        backup_count=$(find "${PROFILES[$i]}/sessionstore-backups" -maxdepth 1 -type f \( -name '*.jsonlz4' -o -name '*.jsonlz4-*' -o -name '*.baklz4' \) 2>/dev/null | wc -l)

        local backup_dir="${PROFILES[$i]}/sessionstore-backups"

        echo -e "  ${CYAN}${BOLD}${PROFILE_NAMES[$i]}${NC}"
        echo -e "    Path:       ${PROFILES[$i]}"
        echo -e "    Backups in: ${backup_dir}"
        echo -e "    Size:       ${prof_size}"
        echo -e "    Modified:   ${prof_mod_human}"
        echo -e "    Backups:    ${backup_count} file(s)"
        echo ""
    done

    echo -e "${BOLD}Quick help:${NC}"
    echo -e "  ${YELLOW}1.${NC} Select a Firefox profile"
    echo -e "  ${YELLOW}2.${NC} Choose a backup file to restore"
    echo -e "  ${YELLOW}3.${NC} A safety backup is created before restoring"
    echo -e "  ${YELLOW}4.${NC} The selected backup replaces ${BOLD}sessionstore.jsonlz4${NC}"
    echo ""
    read -rp "Press ENTER to continue..." _
    echo ""
}

# --- Select profile ---
select_profile() {
    print_profiles_summary

    if [[ ${#PROFILES[@]} -eq 1 ]]; then
        SELECTED_PROFILE="${PROFILES[0]}"
        SELECTED_PROFILE_NAME="${PROFILE_NAMES[0]}"
        msg_info "Using profile: $SELECTED_PROFILE_NAME"
        return
    fi

    local items=()
    for i in "${!PROFILES[@]}"; do
        local prof_size
        prof_size=$(du -sh "${PROFILES[$i]}" 2>/dev/null | cut -f1)
        local prof_mod
        prof_mod=$(stat -c '%Y' "${PROFILES[$i]}" 2>/dev/null)
        local prof_mod_human
        prof_mod_human=$(date -d "@$prof_mod" '+%Y-%m-%d %H:%M')
        items+=("${PROFILE_NAMES[$i]}" "${prof_mod_human}  ${prof_size}  ${PROFILE_PATHS[$i]}")
    done

    local choice
    choice=$(dialog --title "Firefox Profile" \
        --menu "Select profile to restore:" 18 78 "${#PROFILES[@]}" \
        "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    clear

    # Find selected profile by name
    for i in "${!PROFILE_NAMES[@]}"; do
        if [[ "${PROFILE_NAMES[$i]}" == "$choice" ]]; then
            SELECTED_PROFILE="${PROFILES[$i]}"
            SELECTED_PROFILE_NAME="${PROFILE_NAMES[$i]}"
            return
        fi
    done
}

# --- Check if Firefox is running ---
check_firefox_running() {
    if pgrep -x firefox &>/dev/null || pgrep -f "firefox-bin" &>/dev/null; then
        msg_err "Firefox is currently running."
        msg_info "Please close Firefox before restoring a session."
        exit 1
    fi
}

# --- Describe backup file type ---
describe_backup() {
    local filename="$1"
    case "$filename" in
        recovery.jsonlz4)    echo "Auto-save (most recent)" ;;
        recovery.baklz4)     echo "Auto-save (previous)" ;;
        previous.jsonlz4)    echo "Previous session" ;;
        upgrade.jsonlz4-*)   echo "Pre-upgrade backup" ;;
        sessionstore.jsonlz4) echo "Current session file" ;;
        *)                   echo "Backup file" ;;
    esac
}

# --- List and select backup ---
select_backup() {
    local backup_dir="$SELECTED_PROFILE/sessionstore-backups"
    local session_file="$SELECTED_PROFILE/sessionstore.jsonlz4"

    # Collect backup files sorted by modification time (newest first)
    local -a files=()
    local -a display=()

    # Include sessionstore.jsonlz4 from profile root if it exists
    if [[ -f "$session_file" ]]; then
        files+=("$session_file")
    fi

    # Add files from sessionstore-backups/
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$backup_dir" -maxdepth 1 -type f \( -name '*.jsonlz4' -o -name '*.jsonlz4-*' -o -name '*.baklz4' \) -print0 | xargs -0 ls -t 2>/dev/null | tr '\n' '\0')

    if [[ ${#files[@]} -eq 0 ]]; then
        msg_err "No backup files found in $backup_dir"
        exit 1
    fi

    # Build whiptail radiolist items
    local items=()
    local first=true
    # Map filename to full path (handle duplicates by appending index)
    declare -A file_map=()
    for f in "${files[@]}"; do
        local bname
        bname=$(basename "$f")
        local mod_date
        mod_date=$(stat -c '%Y' "$f")
        local mod_human
        mod_human=$(date -d "@$mod_date" '+%Y-%m-%d %H:%M:%S')
        local size
        size=$(stat -c '%s' "$f")
        local size_human
        size_human=$(numfmt --to=iec --suffix=B "$size")
        local desc
        desc=$(describe_backup "$bname")

        local label="$mod_human  ${size_human}  $desc"
        local state="OFF"
        if $first; then
            state="ON"
            first=false
        fi
        items+=("$bname" "$label" "$state")
        file_map["$bname"]="$f"
    done

    local selected_name
    selected_name=$(dialog --title "Session Backups - $SELECTED_PROFILE_NAME" \
        --radiolist "Select backup to restore (newest first):\n\nUse SPACE to select, ENTER to confirm." \
        20 78 "${#files[@]}" \
        "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    clear

    if [[ -z "$selected_name" ]]; then
        msg_warn "No backup selected."
        exit 0
    fi

    SELECTED_BACKUP="${file_map[$selected_name]}"
}

# --- Confirm and restore ---
confirm_and_restore() {
    local backup_basename
    backup_basename=$(basename "$SELECTED_BACKUP")
    local mod_date
    mod_date=$(stat -c '%Y' "$SELECTED_BACKUP")
    local mod_human
    mod_human=$(date -d "@$mod_date" '+%Y-%m-%d %H:%M:%S')
    local size_human
    size_human=$(numfmt --to=iec --suffix=B "$(stat -c '%s' "$SELECTED_BACKUP")")

    dialog --title "Confirm Restore" --yesno \
        "Restore this backup?\n\nFile: $backup_basename\nDate: $mod_human\nSize: $size_human\nProfile: $SELECTED_PROFILE_NAME\n\nA safety backup will be created before restoring." \
        15 60 3>&1 1>&2 2>&3 || exit 0
    clear

    # Create safety backup
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S')
    local safety_dir="$SELECTED_PROFILE/sessionstore-backups/pre-restore-${timestamp}"
    mkdir -p "$safety_dir"

    # Back up current session file if it exists
    local current_session="$SELECTED_PROFILE/sessionstore.jsonlz4"
    if [[ -f "$current_session" ]]; then
        cp -p "$current_session" "$safety_dir/"
        msg_ok "Current session backed up to: pre-restore-${timestamp}/"
    fi

    # Back up existing recovery files
    for f in "$SELECTED_PROFILE/sessionstore-backups"/*.{jsonlz4,baklz4} ; do
        [[ -f "$f" ]] || continue
        cp -p "$f" "$safety_dir/"
    done

    # Restore: copy selected backup as sessionstore.jsonlz4
    if [[ "$(realpath "$SELECTED_BACKUP")" == "$(realpath "$current_session")" ]]; then
        msg_info "Selected file is already sessionstore.jsonlz4, no copy needed."
    else
        cp -p "$SELECTED_BACKUP" "$current_session"
    fi
    msg_ok "Session restored from: $backup_basename"
    msg_info "Safety backup saved in: $safety_dir"
    msg_info "You can now start Firefox."
}

# --- Main ---
main() {
    echo ""
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  Firefox Session Recovery${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo ""

    check_dependencies
    detect_firefox_install
    find_profiles
    select_profile
    check_firefox_running
    select_backup
    confirm_and_restore
}

main
