#!/bin/bash

# Advanced Interactive Chroot Script
# Supports both physical disks/partitions and virtual disk images
# Usage: ./manzolo_unified_chroot.sh [OPTIONS]
# Options:
#   -c, --config FILE    Use configuration file
#   -q, --quiet          Quiet mode (no dialog)
#   -d, --debug          Debug mode
#   -v, --virtual FILE   Direct virtual image mode
#   -h, --help           Show help

set -euo pipefail

# Constants
readonly ORIGINAL_USER="${USER:-root}"
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
BIND_MOUNTS=()
ENABLE_GUI_SUPPORT=false
CHROOT_USER=""
CUSTOM_SHELL="/bin/bash"
PRESERVE_ENV=false

# Virtual disk specific variables
VIRTUAL_MODE=false
VIRTUAL_IMAGE=""
NBD_DEVICE=""
LUKS_MAPPINGS=()
ACTIVATED_VGS=()
OPEN_LUKS_PARTS=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/manzolo_chroot/"*.sh; do
    if [ -f "$script" ]; then
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

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
            -v|--virtual)
                VIRTUAL_MODE=true
                VIRTUAL_IMAGE="$2"
                shift 2
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

main() {
    : > "$LOG_FILE"
    log "Starting Unified Chroot Script v3.0"
    
    parse_args "$@"
    
    # Check for existing instance
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
    
    echo $ > "$LOCK_FILE"
    
    # Set trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Check system requirements
    check_system_requirements
    
    # Load config if specified
    load_config
    
    # Interactive mode if not quiet and no config
    if [[ "$QUIET_MODE" == false ]] && [[ "$USE_CONFIG" == false ]] && [[ -z "$VIRTUAL_IMAGE" ]]; then
        if ! interactive_mode; then
            error "Interactive mode failed"
            exit 1
        fi
    fi
    
    # Validate we have what we need
    if [[ "$VIRTUAL_MODE" == true ]]; then
        if [[ -z "$VIRTUAL_IMAGE" ]]; then
            error "Virtual mode selected but no image specified"
            exit 1
        fi
    else
        if [[ -z "$ROOT_DEVICE" ]]; then
            error "ROOT_DEVICE not specified"
            exit 1
        fi
    fi
    
    # Print configuration summary
    log "=== Configuration Summary ==="
    log "  Mode: $([ "$VIRTUAL_MODE" == true ] && echo "Virtual Disk" || echo "Physical Disk")"
    [[ "$VIRTUAL_MODE" == true ]] && log "  Image: $VIRTUAL_IMAGE"
    [[ -n "$ROOT_DEVICE" ]] && log "  ROOT_DEVICE: $ROOT_DEVICE"
    log "  ROOT_MOUNT: $ROOT_MOUNT"
    log "  EFI_PART: ${EFI_PART:-none}"
    log "  BOOT_PART: ${BOOT_PART:-none}"
    log "  GUI_SUPPORT: $ENABLE_GUI_SUPPORT"
    log "  CHROOT_USER: ${CHROOT_USER:-root}"
    log "========================="
    
    # Setup and enter chroot
    if setup_chroot; then
        setup_gui_support
        enter_chroot
    else
        error "Failed to setup chroot environment"
        exit 1
    fi
    
    if [[ "$QUIET_MODE" == false ]]; then
        success "Chroot session ended successfully"
        echo "All mount points have been cleaned up gracefully."
    fi
    
    log "Script completed successfully"
}

# Run main function
main "$@"