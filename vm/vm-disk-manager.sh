#!/bin/bash
# PKG_NAME: vm-disk-manager
# PKG_VERSION: 4.0.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), qemu-utils, whiptail
# PKG_RECOMMENDS: qemu-system-x86, gparted, libguestfs-tools
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Comprehensive virtual disk management tool with TUI
# PKG_LONG_DESCRIPTION: Advanced tool for managing QEMU/KVM virtual disk images
#  with interactive text-based interface.
#  .
#  Features:
#  - Create, resize, and convert virtual disk images
#  - NBD mounting for direct filesystem access
#  - Partition management with GParted integration
#  - Snapshot management
#  - Format conversion (qcow2, raw, vdi, vmdk)
#  - Disk image optimization and compression
#  - Interactive file browser for image contents
#  - LUKS encryption support
#  - LVM management
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Main VM image management script
# Sources helper scripts from vm_disk_manager subdirectory relative to script location

# Determine the directory where the script is located (resolving symlinks)
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    whiptail --title "Root Privileges Required" --msgbox "This script must be run as root.\n\nRun with: sudo $0" 10 60
    exit 1
fi

# Global variables
SCRIPT_NAME="VM Image Manager Pro"
NBD_DEVICE=""
MOUNTED_PATHS=()
LUKS_MAPPED=()
LVM_ACTIVE=()
VG_DEACTIVATED=()
QEMU_PID=""
INSTALLED_PACKAGES=()
CLEANUP_DONE=false
LOG_FILE="/tmp/vm_image_manager_log_$$.txt"
LAST_DIR_FILE="/tmp/vm_disk_manager_last_dir"

echo "Script started at $(date)" > "$LOG_FILE"

shopt -s globstar

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/vm-disk-manager/"**/*.sh; do
    if [ -f "$script" ]; then
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

shopt -u globstar

configure_lsof_environment

# Trap for automatic cleanup on exit
trap cleanup EXIT INT TERM

whiptail --title "$SCRIPT_NAME" --msgbox "WARNING: This script performs advanced operations on disk images.\n\nThese operations carry the risk of data loss.\n\nYou are solely responsible for any damage or data loss that may occur.\n\nALWAYS BACK UP YOUR DISK IMAGES BEFORE USING THIS SCRIPT.\n\nUSE AT YOUR OWN RISK." 15 70

log "Checking dependencies..."
check_and_install_dependencies

echo "Starting interface..."
file=$(select_file)

if [ $? -ne 0 ] || [ ! -f "$file" ]; then
    whiptail --msgbox "No file selected or file not found. Exiting." 8 50
    exit 1
fi

main_menu "$file"

log "Script terminated."
