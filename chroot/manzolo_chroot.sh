#!/bin/bash

# Advanced interactive chroot with enhanced features
# Usage: sudo ./advanced_chroot.sh [OPTIONS]
# Options:
#   -c, --config FILE    Use configuration file
#   -q, --quiet          Quiet mode (no dialog)
#   -d, --debug          Debug mode
#   -h, --help           Show help

set -euo pipefail

# Constants
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly LOG_FILE="/tmp/${SCRIPT_NAME%.sh}.log"
readonly LOCK_FILE="/tmp/${SCRIPT_NAME%.sh}.lock"
readonly CONFIG_FILE="$SCRIPT_DIR/chroot.conf"

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

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2
}

debug() {
    if [[ "$DEBUG_MODE" == true ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" | tee -a "$LOG_FILE" >&2
    fi
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# Help function
show_help() {
    cat << EOF
Advanced Interactive Chroot Script

Usage: sudo $SCRIPT_NAME [OPTIONS]

Options:
    -c, --config FILE    Use configuration file
    -q, --quiet          Quiet mode (no interactive dialogs)
    -d, --debug          Enable debug mode
    -h, --help           Show this help message

Configuration file format:
    ROOT_DEVICE=/dev/sdaX
    ROOT_MOUNT=/mnt/chroot
    EFI_PART=/dev/sdaY
    BOOT_PART=/dev/sdaZ
    ADDITIONAL_MOUNTS=(/dev/sda1:/home /dev/sda2:/var)
    CUSTOM_SHELL=/bin/zsh
    PRESERVE_ENV=true

Examples:
    sudo $SCRIPT_NAME                    # Interactive mode
    sudo $SCRIPT_NAME -q -c config.conf  # Quiet mode with config
    sudo $SCRIPT_NAME -d                 # Debug mode

EOF
}

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

# Check prerequisites
check_prerequisites() {
    debug "Checking prerequisites"
    
    # Check root privileges
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        if [[ "$QUIET_MODE" == false ]]; then
            dialog --title "Error" --msgbox "Run as root: sudo $0" 10 40 2>/dev/null || true
        fi
        exit 1
    fi

    # Check for existing lock file
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
    
    # Create lock file
    echo $$ > "$LOCK_FILE"
    
    # Install dialog if in interactive mode
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        log "Installing dialog package"
        if command -v apt &> /dev/null; then
            apt update && apt install -y dialog
        elif command -v yum &> /dev/null; then
            yum install -y dialog
        elif command -v pacman &> /dev/null; then
            pacman -S --noconfirm dialog
        elif command -v zypper &> /dev/null; then
            zypper install -y dialog
        else
            error "dialog not found and no supported package manager detected"
            exit 1
        fi
    fi

    # Check required tools
    local missing_tools=()
    for tool in lsblk mount umount chroot mountpoint; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
}

# Load configuration file
load_config() {
    if [[ "$USE_CONFIG" == true ]]; then
        if [[ -f "$CONFIG_FILE_PATH" ]]; then
            debug "Loading configuration from $CONFIG_FILE_PATH"
            # shellcheck source=/dev/null
            source "$CONFIG_FILE_PATH"
        else
            error "Configuration file not found: $CONFIG_FILE_PATH"
            exit 1
        fi
    elif [[ -f "$CONFIG_FILE" ]] && [[ "$QUIET_MODE" == false ]]; then
        if dialog --title "Configuration" --yesno "Found config file. Load it?" 8 40; then
            debug "Loading default configuration file"
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
        fi
    fi
}

# Enhanced device detection
get_devices() {
    debug "Detecting available devices"
    local devices
    devices=$(lsblk -rno NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | \
        awk '$2 == "part" && $4 != "swap" {
            fstype = ($4 == "") ? "unknown" : $4
            mp = ($5 == "" || $5 == "[SWAP]") ? "unmounted" : $5
            if (fstype != "swap") print "/dev/"$1" "$3" "fstype" "mp
        }')
    
    if [[ -z "$devices" ]]; then
        error "No suitable devices found"
        return 1
    fi
    
    echo "$devices"
}

# Interactive device selection
select_device() {
    local device_type="$1"
    local allow_skip="$2"
    
    if [[ "$QUIET_MODE" == true ]]; then
        return 0
    fi
    
    debug "Selecting $device_type device" >&2
    
    local devices
    devices=$(get_devices)
    
    if [[ -z "$devices" ]]; then
        error "No devices found for selection"
        return 1
    fi
    
    local options=()
    while IFS= read -r device; do
        if [[ -n "$device" ]]; then
            local dev_name size fstype mountpoint
            read -r dev_name size fstype mountpoint <<< "$device"
            options+=("$dev_name" "$size $fstype ($mountpoint)")
        fi
    done <<< "$devices"
    
    if [[ "$allow_skip" == true ]]; then
        options+=("None" "Skip this mount")
    fi
    
    if [[ ${#options[@]} -eq 0 ]]; then
        error "No devices available for selection"
        return 1
    fi
    
    local selected
    if selected=$(dialog --title "Select $device_type Device" \
                        --menu "Choose $device_type device:" \
                        20 80 10 \
                        "${options[@]}" \
                        3>&1 1>&2 2>&3); then
        if [[ -z "$selected" ]] || [[ "$selected" == "None" ]]; then
            debug "$device_type device selection: None/Skip" >&2
            return 1
        fi
        debug "$device_type device selected: $selected" >&2
        echo "$selected"
        return 0
    else
        error "Device selection cancelled"
        return 1
    fi
}

# Validate filesystem
validate_filesystem() {
    local device="$1"
    local fstype
    
    debug "Validating filesystem on $device"
    
    # Try multiple methods to detect filesystem
    fstype=$(lsblk -no FSTYPE "$device" 2>/dev/null || echo "")
    
    # If lsblk fails, try blkid
    if [[ -z "$fstype" ]] || [[ "$fstype" == "unknown" ]]; then
        debug "lsblk returned '$fstype', trying blkid"
        fstype=$(blkid -o value -s TYPE "$device" 2>/dev/null || echo "")
    fi
    
    # If still unknown, try file command
    if [[ -z "$fstype" ]] || [[ "$fstype" == "unknown" ]]; then
        debug "blkid failed, trying file command"
        local file_output
        file_output=$(file -s "$device" 2>/dev/null || echo "")
        
        case "$file_output" in
            *"ext2 filesystem"*) fstype="ext2" ;;
            *"ext3 filesystem"*) fstype="ext3" ;;
            *"ext4 filesystem"*) fstype="ext4" ;;
            *"XFS filesystem"*) fstype="xfs" ;;
            *"BTRFS filesystem"*) fstype="btrfs" ;;
            *"F2FS filesystem"*) fstype="f2fs" ;;
            *"FAT"*) fstype="vfat" ;;
        esac
    fi
    
    debug "Detected filesystem type: $fstype"
    
    case "$fstype" in
        ext2|ext3|ext4|xfs|btrfs|f2fs)
            debug "Valid Linux filesystem detected: $fstype"
            return 0
            ;;
        vfat|fat32|fat16)
            if [[ "$device" == "$EFI_PART" ]]; then
                debug "Valid EFI filesystem: $fstype"
                return 0
            else
                debug "FAT filesystem on non-EFI device: $fstype"
                # Ask user if they want to proceed with FAT filesystem for root
                if [[ "$QUIET_MODE" == false ]]; then
                    if dialog --title "Warning" --yesno "Device $device has FAT filesystem ($fstype).\nThis is unusual for a root filesystem.\nProceed anyway?" 10 60; then
                        return 0
                    else
                        return 1
                    fi
                fi
            fi
            ;;
        ntfs)
            error "NTFS filesystem detected. Cannot chroot into Windows partition."
            return 1
            ;;
        ""|unknown)
            # If we still can't detect, warn but allow user to proceed
            debug "Could not determine filesystem type for $device"
            if [[ "$QUIET_MODE" == false ]]; then
                if dialog --title "Warning" --yesno "Cannot determine filesystem type for $device.\nThis might indicate:\n- Encrypted partition\n- Corrupted filesystem\n- Unsupported filesystem\n\nProceed anyway? (Risk of mount failure)" 12 70; then
                    return 0
                else
                    return 1
                fi
            else
                # In quiet mode, proceed with warning
                log "Warning: Unknown filesystem type for $device, proceeding anyway"
                return 0
            fi
            ;;
        *)
            error "Unsupported filesystem: $fstype on $device"
            if [[ "$QUIET_MODE" == false ]]; then
                dialog --title "Error" --msgbox "Unsupported filesystem: $fstype\nDevice: $device\n\nSupported filesystems:\n- ext2/ext3/ext4\n- xfs, btrfs, f2fs\n- vfat (for EFI)" 12 60
            fi
            return 1
            ;;
    esac
}

# Safe mount function
safe_mount() {
    local source="$1"
    local target="$2"
    local options="${3:-}"
    local retries=3
    local delay=1
    
    debug "Mounting $source to $target with options: $options"
    
    # Create target directory
    if ! mkdir -p "$target"; then
        error "Failed to create mount point: $target"
        return 1
    fi
    
    # Check if already mounted
    if mountpoint -q "$target"; then
        log "Warning: $target is already mounted"
        if ! umount "$target" 2>/tmp/umount_error.log; then
            local error_msg
            error_msg=$(cat /tmp/umount_error.log 2>/dev/null || echo "Unknown error")
            error "Failed to unmount existing mount at $target: $error_msg"
            return 1
        fi
    fi
    
    # Attempt mounting with retries
    for ((i=1; i<=retries; i++)); do
        debug "Mount attempt $i/$retries"
        
        local mount_result
        if [[ -n "$options" ]]; then
            debug "Running: mount $options $source $target"
            if mount $options "$source" "$target" 2>/tmp/mount_error.log; then
                mount_result=0
            else
                mount_result=1
            fi
        else
            debug "Running: mount $source $target"
            if mount "$source" "$target" 2>/tmp/mount_error.log; then
                mount_result=0
            else
                mount_result=1
            fi
        fi
        
        if [[ $mount_result -eq 0 ]]; then
            MOUNTED_POINTS+=("$target")
            log "Successfully mounted $source to $target"
            return 0
        else
            local error_msg
            error_msg=$(cat /tmp/mount_error.log 2>/dev/null || echo "Unknown error")
            
            if [[ $i -eq $retries ]]; then
                error "Failed to mount $source to $target after $retries attempts: $error_msg"
                return 1
            else
                debug "Mount attempt $i failed: $error_msg. Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done
}

# Setup chroot environment
setup_chroot() {
    log "Setting up chroot environment at $ROOT_MOUNT"
    
    # Mount root device
    if ! validate_filesystem "$ROOT_DEVICE"; then
        return 1
    fi
    
    if ! safe_mount "$ROOT_DEVICE" "$ROOT_MOUNT"; then
        return 1
    fi

    # Caso 1: c'è una partizione /boot separata
    if [[ -n "$BOOT_PART" ]]; then
        if ! validate_filesystem "$BOOT_PART"; then
            return 1
        fi
        
        if ! safe_mount "$BOOT_PART" "$ROOT_MOUNT/boot"; then
            return 1
        fi

        if [[ -n "$EFI_PART" ]]; then
            if ! validate_filesystem "$EFI_PART"; then
                return 1
            fi

            if [[ -d "$ROOT_MOUNT/boot/efi" ]]; then
                if ! safe_mount "$EFI_PART" "$ROOT_MOUNT/boot/efi"; then
                    return 1
                fi
            else
                # fallback: monta EFI su /efi
                mkdir -p "$ROOT_MOUNT/efi"
                if ! safe_mount "$EFI_PART" "$ROOT_MOUNT/efi"; then
                    return 1
                fi
            fi
        fi

    else
        if [[ -n "$EFI_PART" ]]; then
            if ! validate_filesystem "$EFI_PART"; then
                return 1
            fi
            if ! safe_mount "$EFI_PART" "$ROOT_MOUNT/boot/efi"; then
                return 1
            fi
        fi
    fi
    
    # Mount additional partitions
    for mount_spec in "${ADDITIONAL_MOUNTS[@]}"; do
        if [[ "$mount_spec" =~ ^([^:]+):([^:]+)(:(.+))?$ ]]; then
            local src="${BASH_REMATCH[1]}"
            local dst="${BASH_REMATCH[2]}"
            local opts="${BASH_REMATCH[4]}"
            
            if ! safe_mount "$src" "$ROOT_MOUNT$dst" "$opts"; then
                return 1
            fi
        else
            error "Invalid mount specification: $mount_spec"
            return 1
        fi
    done
    
    # Mount virtual filesystems
    local virtual_mounts=(
        "/proc:proc:$ROOT_MOUNT/proc"
        "/sys:sysfs:$ROOT_MOUNT/sys"
        "/dev:--bind:$ROOT_MOUNT/dev"
        "/dev/pts:--bind:$ROOT_MOUNT/dev/pts"
        "/run:--bind:$ROOT_MOUNT/run"
        "/tmp:--bind:$ROOT_MOUNT/tmp"
    )
    
    for mount_spec in "${virtual_mounts[@]}"; do
        IFS=':' read -r src fstype target <<< "$mount_spec"
        
        local mount_opts=""
        if [[ "$fstype" == "--bind" ]]; then
            mount_opts="--bind"
        else
            mount_opts="-t $fstype"
        fi
        
        if ! safe_mount "$src" "$target" "$mount_opts"; then
            return 1
        fi
    done
    
    # Copy essential files
    local files_to_copy=(
        "/etc/resolv.conf"
        "/etc/hosts"
    )
    
    for file in "${files_to_copy[@]}"; do
        if [[ -f "$file" ]]; then
            debug "Copying $file to chroot"
            cp "$file" "$ROOT_MOUNT$file" 2>/dev/null || debug "Failed to copy $file"
        fi
    done
    
    # Ensure essential directories exist
    local dirs_to_create=(
        "/proc"
        "/sys"
        "/dev"
        "/dev/pts"
        "/run"
        "/tmp"
        "/var/tmp"
    )
    
    for dir in "${dirs_to_create[@]}"; do
        mkdir -p "$ROOT_MOUNT$dir"
    done
    
    log "Chroot environment setup complete"
}

# Enhanced cleanup function
cleanup() {
    local exit_code=$?
    
    debug "Starting cleanup process"
    
    # Remove lock file
    rm -f "$LOCK_FILE"
    
    if [[ ${#MOUNTED_POINTS[@]} -eq 0 ]]; then
        debug "No mount points to clean up"
        return $exit_code
    fi
    
    log "Cleaning up mount points"
    
    # Reverse the mount points array for proper unmounting order
    local reverse_mounts=()
    for ((i=${#MOUNTED_POINTS[@]}-1; i>=0; i--)); do
        reverse_mounts+=("${MOUNTED_POINTS[i]}")
    done
    
    local retries=5
    local delay=2
    local force_unmount=false
    
    for mount_point in "${reverse_mounts[@]}"; do
        if ! mountpoint -q "$mount_point"; then
            debug "$mount_point is not mounted, skipping"
            continue
        fi
        
        debug "Unmounting $mount_point"
        
        for ((i=1; i<=retries; i++)); do
            if umount "$mount_point" 2>/tmp/umount_error.log; then
                debug "Successfully unmounted $mount_point"
                break
            else
                local error_msg
                error_msg=$(cat /tmp/umount_error.log 2>/dev/null || echo "Unknown error")
                
                if [[ $i -eq $retries ]]; then
                    error "Failed to unmount $mount_point after $retries attempts: $error_msg"
                    
                    # Try force unmount as last resort
                    if command -v fuser &> /dev/null; then
                        debug "Attempting to kill processes using $mount_point"
                        fuser -km "$mount_point" 2>/dev/null || true
                        sleep 2
                        
                        if umount "$mount_point" 2>/dev/null; then
                            log "Force unmounted $mount_point"
                        elif umount -f "$mount_point" 2>/dev/null; then
                            log "Force unmounted $mount_point with -f flag"
                        elif umount -l "$mount_point" 2>/dev/null; then
                            log "Lazy unmounted $mount_point"
                        else
                            error "Could not unmount $mount_point even with force"
                        fi
                    fi
                else
                    debug "Unmount attempt $i failed: $error_msg. Retrying in ${delay}s..."
                    sleep $delay
                fi
            fi
        done
    done
    
    # Clean up temporary files
    rm -f /tmp/mount_error.log /tmp/umount_error.log
    
    debug "Cleanup complete"
    return $exit_code
}

# Enter chroot environment
enter_chroot() {
    local shell="${CUSTOM_SHELL:-/bin/bash}"
    local env_opts=""
    
    if [[ "${PRESERVE_ENV:-false}" == true ]]; then
        env_opts="env -"
    fi
    
    log "Entering chroot environment"
    
    if [[ "$QUIET_MODE" == false ]]; then
        dialog --title "Chroot Ready" \
               --msgbox "Entering chroot for $ROOT_DEVICE\nMount point: $ROOT_MOUNT\nShell: $shell\n\nType 'exit' to return" 12 60
    fi
    
    # Check if shell exists in chroot
    if [[ ! -x "$ROOT_MOUNT$shell" ]]; then
        error "Shell $shell not found in chroot, falling back to /bin/sh"
        shell="/bin/sh"
        
        if [[ ! -x "$ROOT_MOUNT$shell" ]]; then
            error "No suitable shell found in chroot"
            return 1
        fi
    fi
    
    # Enter chroot
    if [[ -n "$env_opts" ]]; then
        eval "$env_opts chroot \"$ROOT_MOUNT\" \"$shell\""
    else
        chroot "$ROOT_MOUNT" "$shell"
    fi
    
    log "Exited chroot environment"
}

# Interactive mode
interactive_mode() {
    # Check if we're in interactive mode (dialog available)
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        error "Dialog not available for interactive mode"
        exit 1
    fi
    
    # Select root device
    if ! ROOT_DEVICE=$(select_device "Root" false); then
        error "No root device selected or operation cancelled"
        exit 1
    fi
    
    # Get root mount point
    if ! ROOT_MOUNT=$(dialog --title "Root Mount Point" \
                            --inputbox "Enter root mount directory:" \
                            10 50 "/mnt/chroot" \
                            3>&1 1>&2 2>&3); then
        error "No mount point specified or operation cancelled"
        exit 1
    fi
    
    if [[ -z "$ROOT_MOUNT" ]]; then
        error "Empty mount point specified"
        exit 1
    fi
    
    # Check for UEFI and select EFI partition
    if [[ -d "/sys/firmware/efi" ]]; then
        if dialog --title "UEFI Detected" --yesno "UEFI system detected. Mount EFI partition?" 8 50; then
            EFI_PART=$(select_device "EFI" true) || EFI_PART=""
        fi
    fi
    
    # Select boot partition
    if dialog --title "Boot Partition" --yesno "Mount a separate boot partition?" 8 50; then
        BOOT_PART=$(select_device "Boot" true) || BOOT_PART=""
    fi
    
    # Additional mounts (simplified for this example)
    if dialog --title "Additional Mounts" --yesno "Configure additional mount points?" 8 40; then
        local additional_mount
        if additional_mount=$(dialog --title "Additional Mount" \
                                   --inputbox "Enter device:mountpoint (e.g., /dev/sda1:/home):" \
                                   10 60 \
                                   3>&1 1>&2 2>&3); then
            if [[ -n "$additional_mount" ]]; then
                ADDITIONAL_MOUNTS+=("$additional_mount")
            fi
        fi
    fi
}

# Main function
main() {
    # Initialize logging
    : > "$LOG_FILE"
    log "Starting $SCRIPT_NAME" >&2
    
    # Parse arguments
    parse_args "$@"
    
    # Check prerequisites
    check_prerequisites
    
    # Load configuration
    load_config
    
    # Setup signal handlers
    trap cleanup EXIT INT TERM
    
    # Run in appropriate mode
    if [[ "$QUIET_MODE" == false ]] && [[ "$USE_CONFIG" == false ]]; then
        if ! interactive_mode; then
            error "Interactive mode failed"
            exit 1
        fi
    fi
    
    # Validate required variables
    if [[ -z "$ROOT_DEVICE" ]]; then
        error "ROOT_DEVICE not specified"
        exit 1
    fi
    
    log "Configuration summary:" >&2
    log "  ROOT_DEVICE: $ROOT_DEVICE" >&2
    log "  ROOT_MOUNT: $ROOT_MOUNT" >&2
    log "  EFI_PART: ${EFI_PART:-none}" >&2
    log "  BOOT_PART: ${BOOT_PART:-none}" >&2
    
    # Setup and enter chroot
    if setup_chroot; then
        enter_chroot
    else
        error "Failed to setup chroot environment"
        exit 1
    fi
    
    # Success message
    if [[ "$QUIET_MODE" == false ]]; then
        dialog --title "Complete" --msgbox "Chroot session ended successfully" 8 40
    fi
    
    log "Script completed successfully" >&2
}

# Run main function with all arguments
main "$@"
