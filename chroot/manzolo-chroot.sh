#!/bin/bash
# PKG_NAME: manzolo-chroot
# PKG_VERSION: 3.0.1
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), dialog, qemu-utils, util-linux
# PKG_RECOMMENDS: cryptsetup, lvm2, kpartx
# PKG_SUGGESTS: xhost
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced chroot into physical and virtual disks
# PKG_LONG_DESCRIPTION: Interactive chroot tool for physical disks and virtual disk images.
#  .
#  Features:
#  - Chroot into physical disks and partitions
#  - Chroot into virtual disk images (qcow2, vdi, vmdk)
#  - Support for LUKS encrypted partitions
#  - Support for LVM volumes
#  - Automatic NBD (Network Block Device) mapping
#  - GUI/X11 support in chroot environment
#  - Custom shell and user selection
#  - Automatic bind mounting of /dev, /proc, /sys
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

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
# shellcheck disable=SC2034
readonly ORIGINAL_USER="${USER:-root}"
SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_NAME
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly SCRIPT_DIR
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.sh}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.sh}.lock"
# shellcheck disable=SC2034
readonly CONFIG_FILE="$SCRIPT_DIR/chroot.conf"
# shellcheck disable=SC2034
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
# shellcheck disable=SC2034
ADDITIONAL_MOUNTS=()
# shellcheck disable=SC2034
MOUNTED_POINTS=()
# shellcheck disable=SC2034
BIND_MOUNTS=()
ENABLE_GUI_SUPPORT=false
CHROOT_USER=""
# shellcheck disable=SC2034
CUSTOM_SHELL="/bin/bash"
# shellcheck disable=SC2034
PRESERVE_ENV=false

# Virtual disk specific variables
VIRTUAL_MODE=false
VIRTUAL_IMAGE=""
# shellcheck disable=SC2034
NBD_DEVICE=""
# shellcheck disable=SC2034
LUKS_MAPPINGS=()
# shellcheck disable=SC2034
ACTIVATED_VGS=()
# shellcheck disable=SC2034
OPEN_LUKS_PARTS=()

# Colors for output
# shellcheck disable=SC2034
RED='\033[0;31m'
# shellcheck disable=SC2034
GREEN='\033[0;32m'
# shellcheck disable=SC2034
YELLOW='\033[1;33m'
# shellcheck disable=SC2034
BLUE='\033[0;34m'
# shellcheck disable=SC2034
NC='\033[0m'

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/manzolo-chroot/"*.sh; do
    if [ -f "$script" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
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
                # shellcheck disable=SC2034
                CONFIG_FILE_PATH="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -d|--debug)
                # shellcheck disable=SC2034
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
    log "Starting Chroot v3.0.1"
    
    parse_args "$@"
    
    # Check for existing instance
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
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