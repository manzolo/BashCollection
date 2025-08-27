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

warning() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $*" | tee -a "$LOG_FILE" >&2
}

# Help function
show_help() {
    cat << EOF
Advanced Interactive Chroot Script

Usage: ./$SCRIPT_NAME [OPTIONS]

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
    ENABLE_GUI_SUPPORT=true
    CHROOT_USER=manzolo

Examples:
    ./$SCRIPT_NAME                    # Interactive mode
    ./$SCRIPT_NAME -q -c config.conf  # Quiet mode with config
    ./$SCRIPT_NAME -d                 # Debug mode

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

# Function to run a command with sudo, preserving environment
run_with_privileges() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
        return $?
    fi
    
    if [[ "$QUIET_MODE" == false ]] && command -v dialog &> /dev/null; then
        clear
        echo "Administrative privileges required for: $*"
        echo "Please enter your password when prompted..."
        echo
    fi
    
    sudo -E "$@"
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        error "Failed to execute privileged command: $*"
        if [[ "$QUIET_MODE" == false ]]; then
            echo "Press Enter to continue..."
            read -r dummy_input || true
        fi
        return 1
    fi
    return 0
}

# Load configuration file
load_config() {
    if [[ "$USE_CONFIG" == true ]]; then
        if [[ -f "$CONFIG_FILE_PATH" ]]; then
            debug "Loading configuration from $CONFIG_FILE_PATH"
            source "$CONFIG_FILE_PATH"
        else
            error "Configuration file not found: $CONFIG_FILE_PATH"
            exit 1
        fi
    elif [[ -f "$CONFIG_FILE" ]] && [[ "$QUIET_MODE" == false ]]; then
        if dialog --title "Configuration" --yesno "Found config file. Load it?" 8 40; then
            debug "Loading default configuration file"
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

# Find processes using a mount point
find_processes_using_mount() {
    local mount_point="$1"
    local processes=()
    
    debug "Finding processes using $mount_point"
    
    if command -v fuser &> /dev/null; then
        local pids
        pids=$(fuser -m "$mount_point" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
        
        if [[ -n "$pids" ]]; then
            while IFS= read -r pid; do
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    local cmd
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    processes+=("$pid:$cmd")
                    debug "Found process using $mount_point: PID $pid ($cmd)"
                fi
            done <<< "$pids"
        fi
    fi
    
    if command -v lsof &> /dev/null; then
        local lsof_pids
        lsof_pids=$(lsof +D "$mount_point" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u || true)
        
        if [[ -n "$lsof_pids" ]]; then
            while IFS= read -r pid; do
                if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                    local cmd
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    if [[ ! " ${processes[*]} " =~ " $pid:$cmd " ]]; then
                        processes+=("$pid:$cmd")
                        debug "Found additional process using $mount_point: PID $pid ($cmd)"
                    fi
                fi
            done <<< "$lsof_pids"
        fi
    fi
    
    printf '%s\n' "${processes[@]}"
}

# Terminate processes gracefully
terminate_processes_gracefully() {
    local mount_point="$1"
    local processes
    local success=true
    
    processes=($(find_processes_using_mount "$mount_point"))
    
    if [[ ${#processes[@]} -eq 0 ]]; then
        debug "No processes found using $mount_point"
        return 0
    fi
    
    log "Found ${#processes[@]} processes using $mount_point"
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        
        if kill -0 "$pid" 2>/dev/null; then
            log "Sending SIGTERM to process $pid ($cmd)"
            if ! kill -TERM "$pid" 2>/dev/null; then
                warning "Failed to send SIGTERM to process $pid"
                success=false
            fi
        fi
    done
    
    sleep 3
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        
        if kill -0 "$pid" 2>/dev/null; then
            warning "Process $pid ($cmd) still running, sending SIGKILL"
            if ! kill -KILL "$pid" 2>/dev/null; then
                error "Failed to kill process $pid"
                success=false
            else
                log "Successfully killed process $pid ($cmd)"
            fi
        else
            debug "Process $pid ($cmd) terminated gracefully"
        fi
    done
    
    sleep 1
    
    if [[ "$success" == true ]]; then
        log "All processes using $mount_point have been terminated"
        return 0
    else
        error "Some processes could not be terminated"
        return 1
    fi
}

# Find all processes chrooted to ROOT_MOUNT
find_chroot_processes() {
    local chroot_path
    chroot_path=$(realpath "$ROOT_MOUNT" 2>/dev/null || echo "$ROOT_MOUNT")
    local processes=()
    
    debug "Finding processes chrooted to $chroot_path"
    
    for proc in /proc/[0-9]*; do
        if [[ -d "$proc" ]]; then
            local root_link="$proc/root"
            if [[ -L "$root_link" ]]; then
                local proc_root
                proc_root=$(readlink "$root_link" 2>/dev/null || continue)
                if [[ "$proc_root" == "$chroot_path" ]] || [[ "$proc_root" == "$chroot_path/"* ]]; then
                    local pid="${proc##/proc/}"
                    local cmd
                    cmd=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                    processes+=("$pid:$cmd")
                    debug "Found chroot process: PID $pid ($cmd)"
                fi
            fi
        fi
    done
    
    printf '%s\n' "${processes[@]}"
}

# Terminate all chroot processes gracefully
terminate_chroot_processes() {
    local processes
    processes=($(find_chroot_processes))
    
    if [[ ${#processes[@]} -eq 0 ]]; then
        debug "No chroot processes found"
        return 0
    fi
    
    log "Found ${#processes[@]} chroot processes to terminate"
    local success=true
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        if kill -0 "$pid" 2>/dev/null; then
            log "Sending SIGTERM to chroot process $pid ($cmd)"
            kill -TERM "$pid" 2>/dev/null || { warning "Failed to send SIGTERM to $pid"; success=false; }
        fi
    done
    
    sleep 3
    
    for process in "${processes[@]}"; do
        local pid="${process%%:*}"
        local cmd="${process#*:}"
        if kill -0 "$pid" 2>/dev/null; then
            warning "Chroot process $pid ($cmd) still running, sending SIGKILL"
            kill -KILL "$pid" 2>/dev/null || { error "Failed to kill $pid"; success=false; }
        else
            debug "Chroot process $pid ($cmd) terminated gracefully"
        fi
    done
    
    sleep 1
    
    if [[ "$success" == true ]]; then
        log "All chroot processes terminated"
        return 0
    else
        error "Some chroot processes could not be terminated"
        return 1
    fi
}

# Check and unmount a device if it's already mounted
check_and_unmount() {
    local device="$1"
    local mountpoint
    
    mountpoint=$(findmnt --noheadings --output TARGET --source "$device" 2>/dev/null || true)

    if [[ -n "$mountpoint" ]]; then
        log "Device $device is already mounted at $mountpoint"
        if [[ "$QUIET_MODE" == false ]]; then
            if dialog --title "Warning: Device Already Mounted" --yesno "The device $device is already mounted at $mountpoint.\nDo you want to unmount it before proceeding?" 10 60; then
                log "Attempting to unmount $device from $mountpoint"
                
                if ! run_with_privileges umount "$mountpoint" 2>/dev/null; then
                    warning "Normal unmount failed, checking for processes"
                    
                    if ! terminate_processes_gracefully "$mountpoint"; then
                        warning "Could not terminate all processes gracefully"
                    fi
                    
                    if ! run_with_privileges umount "$mountpoint" 2>/dev/null; then
                        error "Failed to unmount $device. Trying lazy unmount."
                        if dialog --title "Unmount Error" --yesno "Unmount failed. Try a lazy unmount?" 10 60; then
                            if run_with_privileges umount -l "$mountpoint" 2>/dev/null; then
                                log "Successfully lazy unmounted $device."
                                return 0
                            else
                                error "Failed to lazy unmount $device. Manual intervention may be required."
                                dialog --title "Critical Error" --msgbox "Could not unmount the device. Please unmount it manually and try again." 10 60
                                return 1
                            fi
                        else
                            log "Unmount cancelled by user. Exiting."
                            return 1
                        fi
                    fi
                fi
                log "Successfully unmounted $device"
                return 0
            else
                log "Unmount cancelled by user. Exiting."
                return 1
            fi
        fi
    fi
    return 0
}

# Validate filesystem
validate_filesystem() {
    local device="$1"
    local fstype
    
    debug "Validating filesystem on $device"
    
    fstype=$(lsblk -no FSTYPE "$device" 2>/dev/null || echo "")
    
    if [[ -z "$fstype" ]] || [[ "$fstype" == "unknown" ]]; then
        debug "lsblk returned '$fstype', trying blkid"
        fstype=$(blkid -o value -s TYPE "$device" 2>/dev/null || echo "")
    fi
    
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
            debug "Could not determine filesystem type for $device"
            if [[ "$QUIET_MODE" == false ]]; then
                if dialog --title "Warning" --yesno "Cannot determine filesystem type for $device.\nThis might indicate:\n- Encrypted partition\n- Corrupted filesystem\n- Unsupported filesystem\n\nProceed anyway? (Risk of mount failure)" 12 70; then
                    return 0
                else
                    return 1
                fi
            else
                warning "Unknown filesystem type for $device, proceeding anyway"
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
    
    if ! mkdir -p "$target"; then
        error "Failed to create mount point: $target"
        return 1
    fi
    
    if mountpoint -q "$target"; then
        warning "$target is already mounted, attempting unmount"
        if ! terminate_processes_gracefully "$target"; then
            warning "Could not terminate all processes using $target"
        fi
        
        if ! run_with_privileges umount "$target" 2>/tmp/mount_error.log; then
            local error_msg
            error_msg=$(cat /tmp/mount_error.log 2>/dev/null || echo "Unknown error")
            error "Failed to unmount existing mount at $target: $error_msg"
            return 1
        fi
    fi
    
    for ((i=1; i<=retries; i++)); do
        debug "Mount attempt $i/$retries"
        
        local mount_result
        if [[ -n "$options" ]]; then
            debug "Running: sudo mount $options $source $target"
            if run_with_privileges mount $options "$source" "$target" 2>/tmp/mount_error.log; then
                mount_result=0
            else
                mount_result=1
            fi
        else
            debug "Running: sudo mount $source $target"
            if run_with_privileges mount "$source" "$target" 2>/tmp/mount_error.log; then
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

# Safe unmount function with retries
safe_umount() {
    local target="$1"
    local retries=3
    local delay=2
    
    debug "Unmounting $target"
    
    for ((i=1; i<=retries; i++)); do
        debug "Unmount attempt $i/$retries for $target"
        
        if run_with_privileges umount "$target" 2>/tmp/umount_error.log; then
            log "Successfully unmounted $target"
            return 0
        else
            local error_msg
            error_msg=$(cat /tmp/umount_error.log 2>/dev/null || echo "Unknown error")
            warning "Unmount attempt $i failed: $error_msg"
            
            terminate_processes_gracefully "$target"
            
            sleep $delay
        fi
    done
    
    warning "All unmount attempts failed, trying lazy unmount for $target"
    if run_with_privileges umount -l "$target" 2>/tmp/umount_error.log; then
        log "Successfully lazy unmounted $target"
        return 0
    else
        local error_msg
        error_msg=$(cat /tmp/umount_error.log 2>/dev/null || echo "Unknown error")
        error "Failed to unmount $target even with lazy: $error_msg"
        return 1
    fi
}

# Setup chroot environment
setup_chroot() {
    log "Setting up chroot environment at $ROOT_MOUNT"
    
    if ! validate_filesystem "$ROOT_DEVICE"; then
        return 1
    fi
    
    if ! safe_mount "$ROOT_DEVICE" "$ROOT_MOUNT"; then
        return 1
    fi

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
                run_with_privileges mkdir -p "$ROOT_MOUNT/efi"
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
    
    local virtual_mounts=(
        "/proc:proc:$ROOT_MOUNT/proc"
        "/sys:sysfs:$ROOT_MOUNT/sys"
        "/dev:--bind:$ROOT_MOUNT/dev"
        "/dev/pts:devpts:$ROOT_MOUNT/dev/pts:--options=ptmxmode=666,gid=5,mode=620"
        "/run:--bind:$ROOT_MOUNT/run"
        "/tmp:--bind:$ROOT_MOUNT/tmp"
    )
    
    for mount_spec in "${virtual_mounts[@]}"; do
        IFS=':' read -r src fstype target options <<< "$mount_spec"
        
        local mount_opts=""
        if [[ "$fstype" == "--bind" ]]; then
            mount_opts="--bind"
        elif [[ -n "$options" ]]; then
            mount_opts="-t $fstype $options"
        else
            mount_opts="-t $fstype"
        fi
        
        if ! safe_mount "$src" "$target" "$mount_opts"; then
            return 1
        fi
    done
    
    # Debug checks for /dev/pts
    debug "Checking /dev/pts in chroot: $(ls -ld "$ROOT_MOUNT/dev/pts")"
    if [[ -n "$(ls $ROOT_MOUNT/dev/pts)" ]]; then
        debug "PTY devices in chroot: $(ls $ROOT_MOUNT/dev/pts)"
    else
        warning "No PTY devices found in $ROOT_MOUNT/dev/pts"
    fi
    
    local files_to_copy=(
        "/etc/resolv.conf"
        "/etc/hosts"
    )
    
    for file in "${files_to_copy[@]}"; do
        if [[ -f "$file" ]]; then
            debug "Copying $file to chroot"
            run_with_privileges cp "$file" "$ROOT_MOUNT$file" 2>/dev/null || debug "Failed to copy $file"
        fi
    done
    
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
        run_with_privileges mkdir -p "$ROOT_MOUNT$dir"
        run_with_privileges chmod 1777 "$ROOT_MOUNT$dir" || debug "Failed to set permissions on $ROOT_MOUNT$dir"
    done
    
    log "Chroot environment setup complete"
}

# Helper function to ensure user exists in chroot and create home dir if needed
ensure_chroot_user() {
    local chroot_user="${CHROOT_USER:-root}"
    local chroot_passwd="$ROOT_MOUNT/etc/passwd"
    
    if [[ "$chroot_user" != "root" ]]; then
        if ! grep -q "^$chroot_user:" "$chroot_passwd" 2>/dev/null; then
            error "User $chroot_user does not exist in chroot's /etc/passwd"
            return 1
        fi
        local home_dir
        home_dir=$(grep "^$chroot_user:" "$chroot_passwd" | cut -d: -f6)
        if [[ -z "$home_dir" ]]; then
            error "No home directory found for $chroot_user in chroot"
            return 1
        fi
        run_with_privileges mkdir -p "$ROOT_MOUNT$home_dir" || {
            error "Failed to create home directory $home_dir for $chroot_user"
            return 1
        }
        run_with_privileges chown "$chroot_user:$chroot_user" "$ROOT_MOUNT$home_dir" || {
            warning "Failed to set ownership for $home_dir"
        }
    fi
    return 0
}

setup_gui_support() {
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Setting up graphical support (X11) - EXPERIMENTAL"
        warning "GUI support is experimental and may cause host system instability"

        if ! ensure_chroot_user; then
            error "Failed to ensure chroot user setup, GUI support may fail"
            ENABLE_GUI_SUPPORT=false
            return 1
        fi

        if [[ -n "${DISPLAY:-}" ]]; then
            log "Configuring X11 display access (using shared /tmp/.X11-unix)"
            
            # Ensure /tmp/.X11-unix has correct permissions
            if [[ -d "/tmp/.X11-unix" ]]; then
                run_with_privileges chmod 1777 "/tmp/.X11-unix" || \
                    warning "Failed to set permissions on /tmp/.X11-unix"
                debug "Permissions on /tmp/.X11-unix: $(ls -ld /tmp/.X11-unix)"
            else
                warning "/tmp/.X11-unix does not exist on host"
            fi
            
            # Copy Xauthority to appropriate user's home in chroot
            local chroot_user="${CHROOT_USER:-root}"
            local xauthority_path="/home/$ORIGINAL_USER/.Xauthority"
            local chroot_xauth_path
            if [[ "$chroot_user" == "root" ]]; then
                chroot_xauth_path="$ROOT_MOUNT/root/.Xauthority"
            else
                chroot_xauth_path="$ROOT_MOUNT/home/$chroot_user/.Xauthority"
            fi
            if [[ -f "$xauthority_path" ]]; then
                log "Copying Xauthority file to $chroot_xauth_path"
                run_with_privileges cp "$xauthority_path" "$chroot_xauth_path" && \
                run_with_privileges chown "$chroot_user:$chroot_user" "$chroot_xauth_path" && \
                run_with_privileges chmod 600 "$chroot_xauth_path" || \
                    warning "Failed to setup X11 authentication for $chroot_user"
                debug "Xauthority in chroot: $(ls -l $chroot_xauth_path 2>/dev/null || echo 'not found')"
            else
                warning "Xauthority file not found at $xauthority_path - X11 authentication may fail"
            fi

            # Allow local connections for the chroot user
            if command -v xhost &> /dev/null; then
                log "Configuring xhost for local access"
                xhost +local: || warning "Failed to configure xhost"
                debug "xhost settings: $(xhost)"
            else
                warning "xhost not found, X11 authentication may fail"
            fi
        else
            warning "DISPLAY not set, X11 support will not work"
            ENABLE_GUI_SUPPORT=false
            return 1
        fi

        # Temporarily disable Wayland support to isolate X11 issues
        # if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        #     log "Configuring Wayland display access (using shared /run/user)"
        #     local original_uid=$(id -u "$ORIGINAL_USER")
        #     run_with_privileges mkdir -p "$ROOT_MOUNT/run/user/$original_uid" || \
        #         warning "Failed to ensure Wayland runtime dir in chroot"
        #     run_with_privileges chmod 700 "$ROOT_MOUNT/run/user/$original_uid" || \
        #         warning "Failed to set permissions on Wayland runtime dir"
        #     run_with_privileges chown "$original_uid:$original_uid" "$ROOT_MOUNT/run/user/$original_uid" || \
        #         warning "Failed to set ownership on Wayland runtime dir"
        #     debug "Permissions on /run/user/$original_uid: $(ls -ld $ROOT_MOUNT/run/user/$original_uid)"
        # fi

        # Ensure /dev/pts permissions
        run_with_privileges chmod 1777 "$ROOT_MOUNT/dev/pts" || \
            warning "Failed to set permissions on /dev/pts in chroot"
        debug "Permissions on /dev/pts: $(ls -ld $ROOT_MOUNT/dev/pts)"

        log "Graphical support setup complete (experimental mode)"
        warning "Monitor your host system for stability issues"
    fi
}

cleanup() {
    local exit_code=$?
    
    debug "Starting cleanup process"
    
    rm -f "$LOCK_FILE" "$CHROOT_PID_FILE"
    
    if [[ ${#MOUNTED_POINTS[@]} -eq 0 ]]; then
        debug "No mount points to clean up"
        return $exit_code
    fi
    
    log "Cleaning up mount points gracefully"
    
    log "Terminating any lingering chroot processes"
    if ! terminate_chroot_processes; then
        warning "Some chroot processes may persist, proceeding with caution."
    fi
    sleep 2

    # Then, proceed with unmounting
    local reverse_mounts=()
    for ((i=${#MOUNTED_POINTS[@]}-1; i>=0; i--)); do
        reverse_mounts+=("${MOUNTED_POINTS[i]}")
    done

    for mount_point in "${reverse_mounts[@]}"; do
        if ! mountpoint -q "$mount_point"; then
            debug "$mount_point is not mounted, skipping"
            continue
        fi
        
        # Do NOT call terminate_processes_gracefully for bind-mounts of host directories
        case "$mount_point" in
            */proc|*/sys|*/dev|*/run|*/tmp|*/dev/pts)
                log "Unmounting virtual filesystem: $mount_point"
                ;;
            *)
                log "Unmounting physical filesystem: $mount_point"
                terminate_processes_gracefully "$mount_point" || warning "Could not terminate all processes for $mount_point"
                ;;
        esac
        
        safe_umount "$mount_point" || error "Failed to unmount $mount_point - check manually"
    done    

    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Cleaning up GUI support remnants"
        local chroot_user="${CHROOT_USER:-root}"
        if [[ "$chroot_user" == "root" ]]; then
            rm -f "$ROOT_MOUNT/root/.Xauthority" 2>/dev/null || true
        else
            rm -f "$ROOT_MOUNT/home/$chroot_user/.Xauthority" 2>/dev/null || true
        fi
        # Reset xhost settings
        if command -v xhost &> /dev/null; then
            xhost -local: || warning "Failed to reset xhost settings"
            debug "xhost settings after cleanup: $(xhost)"
        fi
        log "GUI cleanup complete"
    fi
    
    rm -f /tmp/mount_error.log /tmp/umount_error.log
    
    log "Cleanup complete"
    return $exit_code
}

# Enter chroot environment with better process tracking
enter_chroot() {
    local shell="${CUSTOM_SHELL:-/bin/bash}"
    
    log "Entering chroot environment"
    
    if [[ "$QUIET_MODE" == false ]]; then
        clear
        echo "================================================="
        echo "           CHROOT SESSION READY"
        echo "================================================="
        echo "Chroot Environment: $ROOT_DEVICE"
        echo "Mount Point: $ROOT_MOUNT"
        echo "Shell: $shell"
        echo "Chroot User: ${CHROOT_USER:-root}"
        if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
            echo "GUI Support: ENABLED (experimental)"
            echo
            echo "WARNING: GUI support is experimental!"
            echo "If you experience host system issues, exit immediately."
        else
            echo "GUI Support: DISABLED (recommended)"
        fi
        echo
        echo "Tips:"
        echo "- Type 'exit' to return to host system"
        echo "- The cleanup process will handle mount points automatically"
        echo "- Monitor system resources if GUI support is enabled"
        echo "================================================="
        echo
        if [[ -t 0 ]]; then
            echo "Press Enter to continue into chroot environment..."
            local dummy_input
            read -r dummy_input || {
                warning "Failed to read input, continuing anyway"
            }
        else
            debug "Non-interactive session, skipping Enter prompt"
        fi
    fi
    
    if [[ ! -x "$ROOT_MOUNT$shell" ]]; then
        warning "Shell $shell not found in chroot, falling back to /bin/sh"
        shell="/bin/sh"
        
        if [[ ! -x "$ROOT_MOUNT$shell" ]]; then
            error "No suitable shell found in chroot"
            return 1
        fi
    fi
    
    echo $$ > "$CHROOT_PID_FILE"
    
    local chroot_env_vars=()
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then
            chroot_env_vars+=("DISPLAY=$DISPLAY")
            debug "Setting DISPLAY=$DISPLAY for chroot"
        fi
        # Temporarily disable Wayland
        # if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        #     chroot_env_vars+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
        #     debug "Setting WAYLAND_DISPLAY=$WAYLAND_DISPLAY for chroot"
        # fi
        if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
            local original_uid=$(id -u "$ORIGINAL_USER")
            chroot_env_vars+=("XDG_RUNTIME_DIR=/run/user/$original_uid")
            debug "Setting XDG_RUNTIME_DIR=/run/user/$original_uid for chroot"
        fi
    fi
    
    debug "Environment variables for chroot: ${chroot_env_vars[*]}"
    
    if [[ -n "${CHROOT_USER:-}" ]] && [[ "$CHROOT_USER" != "root" ]]; then
        log "Entering chroot as user $CHROOT_USER"
        debug "Chroot user home: $(grep "^$CHROOT_USER:" $ROOT_MOUNT/etc/passwd | cut -d: -f6)"
        if [[ ${#chroot_env_vars[@]} -gt 0 ]]; then
            run_with_privileges chroot "$ROOT_MOUNT" su - "$CHROOT_USER" -c "env ${chroot_env_vars[*]} $shell"
        else
            run_with_privileges chroot "$ROOT_MOUNT" su - "$CHROOT_USER" -c "$shell"
        fi
    else
        log "Entering chroot as root"
        if [[ ${#chroot_env_vars[@]} -gt 0 ]]; then
            run_with_privileges env "${chroot_env_vars[@]}" chroot "$ROOT_MOUNT" "$shell"
        else
            run_with_privileges chroot "$ROOT_MOUNT" "$shell"
        fi
    fi
    
    log "Exited chroot environment"
}

interactive_mode() {
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        error "Dialog not available for interactive mode"
        exit 1
    fi
    
    if ! ROOT_DEVICE=$(select_device "Root" false); then
        error "No root device selected or operation cancelled"
        exit 1
    fi
    
    if ! check_and_unmount "$ROOT_DEVICE"; then
        exit 1
    fi

    if dialog --title "Graphical Support" --yesno "Do you need to run graphical applications (X11/Wayland) inside the chroot?\n\nThis will setup display variables and authentication files." 10 60; then
        ENABLE_GUI_SUPPORT=true
        local chroot_user
        chroot_user=$(dialog --title "Chroot User" --inputbox "Enter the user to run GUI apps as in chroot (default: root):" 10 50 "$ORIGINAL_USER" 3>&1 1>&2 2>&3)
        if [[ $? -eq 0 ]]; then
            if [[ -n "$chroot_user" ]]; then
                CHROOT_USER="$chroot_user"
            else
                warning "No user specified, defaulting to root"
                CHROOT_USER="root"
            fi
        else
            debug "Chroot user selection cancelled, defaulting to root"
            CHROOT_USER="root"
        fi
    else
        ENABLE_GUI_SUPPORT=false
    fi    

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
    
    if [[ -d "/sys/firmware/efi" ]]; then
        if dialog --title "UEFI Detected" --yesno "UEFI system detected. Mount EFI partition?" 8 50; then
            EFI_PART=$(select_device "EFI" true) || EFI_PART=""
        fi
    fi
    
    if dialog --title "Boot Partition" --yesno "Mount a separate boot partition?" 8 50; then
        BOOT_PART=$(select_device "Boot" true) || BOOT_PART=""
    fi
    
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

# Function to check system requirements and install missing tools
check_system_requirements() {
    log "Checking system requirements"
    
    local missing_tools=()
    local optional_tools=()
    
    local required_tools=(
        "lsblk"
        "mount" 
        "umount"
        "chroot"
        "mountpoint"
        "findmnt"
    )
    
    local recommended_tools=(
        "fuser"
        "lsof"
        "blkid"
        "file"
        "xhost"
    )
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        
        if command -v apt &> /dev/null; then
            log "Attempting to install missing tools via apt"
            run_with_privileges apt update
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "lsblk"|"mount"|"umount"|"mountpoint"|"findmnt") 
                        run_with_privileges apt install -y util-linux ;;
                    "chroot") 
                        run_with_privileges apt install -y coreutils ;;
                esac
            done
        elif command -v yum &> /dev/null; then
            log "Attempting to install missing tools via yum"
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "lsblk"|"mount"|"umount"|"mountpoint"|"findmnt") 
                        run_with_privileges yum install -y util-linux ;;
                    "chroot") 
                        run_with_privileges yum install -y coreutils ;;
                esac
            done
        elif command -v pacman &> /dev/null; then
            log "Attempting to install missing tools via pacman"
            for tool in "${missing_tools[@]}"; do
                case "$tool" in
                    "lsblk"|"mount"|"umount"|"mountpoint"|"findmnt") 
                        run_with_privileges pacman -S --noconfirm util-linux ;;
                    "chroot") 
                        run_with_privileges pacman -S --noconfirm coreutils ;;
                esac
            done
        fi
        
        missing_tools=()
        for tool in "${required_tools[@]}"; do
            if ! command -v "$tool" &> /dev/null; then
                missing_tools+=("$tool")
            fi
        done
        
        if [[ ${#missing_tools[@]} -gt 0 ]]; then
            error "Still missing required tools after installation attempt: ${missing_tools[*]}"
            exit 1
        fi
    fi
    
    for tool in "${recommended_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            optional_tools+=("$tool")
        fi
    done
    
    if [[ ${#optional_tools[@]} -gt 0 ]]; then
        warning "Missing optional tools (some features may be limited): ${optional_tools[*]}"
    fi
    
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        log "Installing dialog package for interactive mode"
        if command -v apt &> /dev/null; then
            run_with_privileges apt update && run_with_privileges apt install -y dialog
        elif command -v yum &> /dev/null; then
            run_with_privileges yum install -y dialog
        elif command -v pacman &> /dev/null; then
            run_with_privileges pacman -S --noconfirm dialog
        elif command -v zypper &> /dev/null; then
            run_with_privileges zypper install -y dialog
        else
            error "dialog not found and no supported package manager detected"
            exit 1
        fi
    fi
    
    log "System requirements check completed"
}

# Function to create a summary report
create_summary_report() {
    local report_file="/tmp/${SCRIPT_NAME%.sh}_summary.log"
    
    {
        echo "=== Chroot Session Summary ==="
        echo "Date: $(date)"
        echo "User: $ORIGINAL_USER"
        echo ""
        echo "Configuration:"
        echo "  ROOT_DEVICE: $ROOT_DEVICE"
        echo "  ROOT_MOUNT: $ROOT_MOUNT"
        echo "  EFI_PART: ${EFI_PART:-none}"
        echo "  BOOT_PART: ${BOOT_PART:-none}"
        echo "  GUI_SUPPORT: $ENABLE_GUI_SUPPORT"
        echo "  CHROOT_USER: ${CHROOT_USER:-root}"
        echo ""
        echo "Mount Points Created:"
        for mount_point in "${MOUNTED_POINTS[@]}"; do
            echo "  $mount_point"
        done
        echo ""
        echo "Additional Mounts:"
        for mount_spec in "${ADDITIONAL_MOUNTS[@]}"; do
            echo "  $mount_spec"
        done
        echo ""
        echo "Log File: $LOG_FILE"
        echo "=== End of Summary ==="
    } > "$report_file"
    
    debug "Summary report created at $report_file"
}

# Main function
main() {
    : > "$LOG_FILE"
    log "Starting $SCRIPT_NAME v2.1 (Enhanced Edition)"
    
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