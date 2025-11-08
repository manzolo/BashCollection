#!/bin/bash
# PKG_NAME: manzolo-disk-clone
# PKG_VERSION: 2.4.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), dialog, partclone, qemu-utils, parted
# PKG_RECOMMENDS: cryptsetup, lvm2
# PKG_SUGGESTS: pv
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Clone disks between physical and virtual formats
# PKG_LONG_DESCRIPTION: Advanced disk cloning tool with dry-run mode and smart cloning.
#  .
#  Features:
#  - Clone virtual to physical disks
#  - Clone physical to virtual images
#  - Virtual to virtual conversion with compression
#  - LUKS encryption support with UUID preservation
#  - GPT and MBR partition table support
#  - Dry-run mode for testing
#  - Uses partclone for efficient space usage
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection
set -euo pipefail

# ╔══════════════════════════════════════════════╗
# ║        Manzolo Disk Cloner v2.4              ║
# ║     With Dry Run & Enhanced Structure        ║
# ╚══════════════════════════════════════════════╝

SHOW_HIDDEN=false
SELECTED_FILE=""
SELECTED_TYPE="file"
GPT_SUPPORT=false
DRY_RUN=false

TEMP_PREFIX="/tmp/manzolo_clone_$$"

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# ───────────────────────────────
# Load helper scripts
# ───────────────────────────────
load_modules() {
    for script in "$SCRIPT_DIR/manzolo-disk-clone/"*.sh; do
        if [ -f "$script" ]; then
            source "$script"
        else
            echo "Error: missing module $script"
            exit 1
        fi
    done
}

load_modules

# ───────────────────────────────
# Main menu
# ───────────────────────────────
main_menu() {
    while true; do
        local menu_title="⚡ Manzolo Disk Cloner v2.4 ✨"
        [ "$DRY_RUN" = true ] && menu_title="🧪 $menu_title - DRY RUN"

        local choice
        choice=$(dialog --clear --title "$menu_title" \
            --menu "Select cloning type:" 18 85 7 \
            "1" "📦 → 📼 Virtual to Physical" \
            "2" "📼 → 📦 Physical to Virtual" \
            "3" "💿 → 📦 Virtual to Virtual (Compress)" \
            "4" "📼 → 📼 Physical to Physical (Simple)" \
            "5" "📼 → 📼 Physical to Physical (UUID Preservation)" \
            "6" "📚  About & Features" \
            "0" "🚪 Exit" \
            3>&1 1>&2 2>&3) || true

        clear
        case $choice in
            1) clone_virtual_to_physical ;;
            2) clone_physical_to_virtual ;;
            3) clone_virtual_to_virtual ;;
            4) clone_physical_to_physical_simple ;;
            5) clone_physical_to_physical_with_uuid ;;
            6) show_about ;;
            0|"") break ;;
        esac
    done
}

# ───────────────────────────────
# About
# ───────────────────────────────
show_about() {
    local text="🚀 FEATURES:\n\n✓ Smart Cloning: Copies only used space\n✓ Physical to Physical: Direct device cloning\n✓ UUID Preservation\n✓ Proportional Resize\n✓ LUKS Support\n✓ DRY RUN Mode\n..."
    [ "$DRY_RUN" = true ] && text="$text\n\n🧪 DRY RUN MODE ACTIVE"
    dialog --title "About Manzolo Disk Cloner v2.4" --msgbox "$text" 26 85
}

# ───────────────────────────────
# Main execution
# ───────────────────────────────
main() {
    trap cleanup EXIT INT TERM
    parse_args "$@"
    check_root
    check_dependencies
    check_partclone_tools
    check_uuid_tools
    check_optional_tools

    print_banner
    [ "$DRY_RUN" = true ] && log "🧪 All operations will be simulated"

    main_menu

    log "=============================="
    [ "$DRY_RUN" = true ] && log "✅ DRY RUN finished at $(date)" || log "✅ Finished at $(date)"
    log "=============================="
}

main "$@"
