#!/bin/bash

# Advanced interactive chroot with enhanced features
# Usage: ./manzolo_chroot.sh [OPTIONS]
# Options:
#   -c, --config FILE    Use configuration file
#   -q, --quiet          Quiet mode (no dialog)
#   -d, --debug          Debug mode
#   -h, --help           Show help

set -euo pipefail

# Constants
readonly ORIGINAL_USER="$USER"
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.sh}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.sh}.lock"
readonly CONFIG_FILE="$SCRIPT_DIR/chroot.conf"
readonly CHROOT_PID_FILE="/tmp/${SCRIPT_NAME%.sh}.chroot.pid"

# Global variables
QUIET_MODE=false
DEBUG_MODE=false
USE_CONFIG=false
CONFIG_FILE_PATH=""
ROOT_DEVICE=""
ROOT_MOUNT="/mnt/chroot"
EFI_PART=""
BOOT_PART=""
ADDITIONAL_MOUNTS=()
MOUNTED_POINTS=()
ENABLE_GUI_SUPPORT=false
CHROOT_USER=""
CHROOT_PROCESSES=()

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/manzolo_chroot/"*.sh; do
    if [ -f "$script" ]; then
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                USE_CONFIG=true
                CONFIG_FILE_PATH="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -d|--debug)
                DEBUG_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    : > "$LOG_FILE"
    log "Starting $SCRIPT_NAME v2.1"
    
    parse_args "$@"
    
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error "Another instance is already running (PID: $pid)"
            exit 1
        else
            debug "Removing stale lock file"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    
    check_system_requirements
    
    trap cleanup EXIT INT TERM
    
    load_config
    
    if [[ "$QUIET_MODE" == false ]] && [[ "$USE_CONFIG" == false ]]; then
        if ! interactive_mode; then
            error "Interactive mode failed"
            exit 1
        fi
    fi
    
    if [[ -z "$ROOT_DEVICE" ]]; then
        error "ROOT_DEVICE not specified"
        exit 1
    fi
    
    log "=== Configuration Summary ==="
    log "  ROOT_DEVICE: $ROOT_DEVICE"
    log "  ROOT_MOUNT: $ROOT_MOUNT"
    log "  EFI_PART: ${EFI_PART:-none}"
    log "  BOOT_PART: ${BOOT_PART:-none}"
    log "  GUI_SUPPORT: $ENABLE_GUI_SUPPORT"
    log "  CHROOT_USER: ${CHROOT_USER:-root}"
    log "  ADDITIONAL_MOUNTS: ${#ADDITIONAL_MOUNTS[@]} configured"
    log "========================="
    
    if setup_chroot; then
        setup_gui_support
        create_summary_report
        enter_chroot
    else
        error "Failed to setup chroot environment"
        exit 1
    fi
    
    if [[ "$QUIET_MODE" == false ]]; then
        dialog --title "Complete" --msgbox "Chroot session ended successfully.\n\nAll mount points have been cleaned up gracefully.\n\nSummary report: /tmp/${SCRIPT_NAME%.sh}_summary.log" 12 60
    fi
    
    log "Script completed successfully"
}

main "$@"