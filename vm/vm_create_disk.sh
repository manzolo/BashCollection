#!/bin/bash

# ==============================================================================
# IMPROVED CORE FUNCTIONS FOR VIRTUAL DISK CREATOR
# ==============================================================================

# Global cleanup variables
declare -g DEVICE=""
declare -g CLEANUP_REGISTERED=0

# ==============================================================================
# ERROR HANDLING & CLEANUP
# ==============================================================================

# Register cleanup trap handlers
register_cleanup() {
    if [ "$CLEANUP_REGISTERED" -eq 0 ]; then
        trap cleanup_on_exit EXIT INT TERM
        CLEANUP_REGISTERED=1
    fi
}

# Main cleanup function called on script exit
cleanup_on_exit() {
    local exit_code=$?
    
    if [ -n "$DEVICE" ]; then
        log "Cleaning up device $DEVICE..."
        cleanup_device "$DEVICE"
    fi
    
    # Clean up any temporary files
    rm -f /tmp/disk_creator_device_info 2>/dev/null
    
    exit $exit_code
}

# Define global variables for disk and partition configuration
DISK_NAME=""
DISK_SIZE=""
DISK_FORMAT=""
PARTITION_TABLE="mbr" # Default to MBR
PREALLOCATION="off"   # Default to sparse allocation
declare -a PARTITIONS=()
VERBOSE=${VERBOSE:-0} # Verbosity flag (0 = silent, 1 = verbose)

# Color codes for output
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r GRAY='\033[0;37m'
declare -r NC='\033[0m'

# Determine the directory where the script is located (resolving symlinks)
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

export LC_ALL=C

shopt -s globstar

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/vm_create_disk/"**/*.sh; do
    if [ -f "$script" ]; then
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

shopt -u globstar

#demo_logging

# Main logic
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    --reverse)
        if [ "$#" -ne 2 ]; then
            error "Usage: $0 --reverse <disk_image>"
            exit 1
        fi
        check_dependencies
        generate_config "$2"
        ;;
    --info)
        if [ "$#" -ne 2 ]; then
            error "Usage: $0 --info <disk_image>"
            exit 1
        fi
        check_dependencies
        info_disk "$2"
        ;;
    "")
        check_dependencies
        interactive_mode
        ;;
    *)
        if [ "$#" -eq 1 ]; then
            check_dependencies
            non_interactive_mode "$1"
        else
            error "Invalid arguments. Use -h for help."
            exit 1
        fi
        ;;
esac