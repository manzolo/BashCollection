#!/bin/bash

# Unified Advanced Interactive Chroot Script
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

# ============================================================================
# COMMON FUNCTIONS
# ============================================================================

log() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

debug() {
    if [[ "$DEBUG_MODE" == true ]]; then
        echo -e "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
    fi
}

error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

# ============================================================================
# HELP AND CONFIG
# ============================================================================

show_help() {
    cat << EOF
Unified Advanced Interactive Chroot Script

Usage: $SCRIPT_NAME [OPTIONS]

Options:
    -c, --config FILE    Use configuration file
    -q, --quiet          Quiet mode (no interactive dialogs)
    -d, --debug          Enable debug mode
    -v, --virtual FILE   Direct virtual image mode
    -h, --help           Show this help message

Configuration file format:
    # For physical disk mode:
    ROOT_DEVICE=/dev/sdaX
    ROOT_MOUNT=/mnt/chroot
    EFI_PART=/dev/sdaY
    BOOT_PART=/dev/sdaZ
    
    # For virtual disk mode:
    VIRTUAL_IMAGE=/path/to/image.vhd
    
    # Common options:
    ADDITIONAL_MOUNTS=(/dev/sda1:/home /dev/sda2:/var)
    CUSTOM_SHELL=/bin/zsh
    PRESERVE_ENV=true
    ENABLE_GUI_SUPPORT=true
    CHROOT_USER=username

Examples:
    $SCRIPT_NAME                           # Interactive mode
    $SCRIPT_NAME -v disk.vhd               # Virtual disk mode
    $SCRIPT_NAME -q -c config.conf         # Quiet mode with config
    $SCRIPT_NAME -d                        # Debug mode

EOF
}

load_config() {
    if [[ "$USE_CONFIG" == true ]]; then
        if [[ -f "$CONFIG_FILE_PATH" ]]; then
            debug "Loading configuration from $CONFIG_FILE_PATH"
            source "$CONFIG_FILE_PATH"
            
            # Check if virtual image is specified in config
            if [[ -n "${VIRTUAL_IMAGE:-}" ]]; then
                VIRTUAL_MODE=true
            fi
        else
            error "Configuration file not found: $CONFIG_FILE_PATH"
            exit 1
        fi
    elif [[ -f "$CONFIG_FILE" ]] && [[ "$QUIET_MODE" == false ]]; then
        if command -v dialog &> /dev/null && dialog --title "Configuration" --yesno "Found config file. Load it?" 8 40; then
            debug "Loading default configuration file"
            source "$CONFIG_FILE"
            
            # Check if virtual image is specified in config
            if [[ -n "${VIRTUAL_IMAGE:-}" ]]; then
                VIRTUAL_MODE=true
            fi
        fi
    fi
}

# ============================================================================
# PRIVILEGE MANAGEMENT
# ============================================================================

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
        debug "Failed to execute privileged command: $*"
        return 1
    fi
    return 0
}

# ============================================================================
# SYSTEM REQUIREMENTS
# ============================================================================

check_system_requirements() {
    log "Checking system requirements"
    
    local missing_tools=()
    local required_tools=(
        "lsblk"
        "mount" 
        "umount"
        "chroot"
        "mountpoint"
        "findmnt"
    )
    
    # Additional tools for virtual mode
    if [[ "$VIRTUAL_MODE" == true ]]; then
        required_tools+=("qemu-nbd" "fdisk" "cryptsetup" "pvs" "vgs" "lvs")
    fi
    
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
            run_with_privileges apt install -y util-linux coreutils qemu-utils cryptsetup lvm2
        elif command -v yum &> /dev/null; then
            log "Attempting to install missing tools via yum"
            run_with_privileges yum install -y util-linux coreutils qemu-img cryptsetup lvm2
        elif command -v pacman &> /dev/null; then
            log "Attempting to install missing tools via pacman"
            run_with_privileges pacman -S --noconfirm util-linux coreutils qemu cryptsetup lvm2
        fi
        
        # Recheck
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
    
    # Check for NBD module if virtual mode
    if [[ "$VIRTUAL_MODE" == true ]]; then
        if ! lsmod | grep -q nbd; then
            log "Loading nbd module..."
            run_with_privileges modprobe nbd max_part=16 || {
                error "Cannot load nbd module"
                exit 1
            }
        fi
    fi
    
    # Install dialog if needed for interactive mode
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        log "Installing dialog package for interactive mode"
        if command -v apt &> /dev/null; then
            run_with_privileges apt update && run_with_privileges apt install -y dialog
        elif command -v yum &> /dev/null; then
            run_with_privileges yum install -y dialog
        elif command -v pacman &> /dev/null; then
            run_with_privileges pacman -S --noconfirm dialog
        fi
    fi
    
    log "System requirements check completed"
}

# ============================================================================
# MOUNT MANAGEMENT
# ============================================================================

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
        warning "$target is already mounted"
        return 0
    fi
    
    for ((i=1; i<=retries; i++)); do
        debug "Mount attempt $i/$retries"
        
        local mount_result
        if [[ -n "$options" ]]; then
            if run_with_privileges mount $options "$source" "$target" 2>/dev/null; then
                mount_result=0
            else
                mount_result=1
            fi
        else
            if run_with_privileges mount "$source" "$target" 2>/dev/null; then
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
            if [[ $i -eq $retries ]]; then
                error "Failed to mount $source to $target after $retries attempts"
                return 1
            else
                debug "Mount attempt $i failed. Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done
}

safe_umount() {
    local target="$1"
    local retries=3
    local delay=2
    
    debug "Unmounting $target"
    
    for ((i=1; i<=retries; i++)); do
        debug "Unmount attempt $i/$retries for $target"
        
        if run_with_privileges umount "$target" 2>/dev/null; then
            log "Successfully unmounted $target"
            return 0
        else
            warning "Unmount attempt $i failed"
            sleep $delay
        fi
    done
    
    warning "All unmount attempts failed, trying lazy unmount for $target"
    if run_with_privileges umount -l "$target" 2>/dev/null; then
        log "Successfully lazy unmounted $target"
        return 0
    else
        error "Failed to unmount $target even with lazy"
        return 1
    fi
}

# ============================================================================
# VIRTUAL DISK FUNCTIONS
# ============================================================================

find_available_nbd() {
    debug "Looking for available NBD devices..."
    
    # Ensure NBD module is loaded with enough devices
    if ! lsmod | grep -q nbd; then
        log "Loading NBD module..."
        if ! run_with_privileges modprobe nbd max_part=16 nbds_max=16; then
            error "Failed to load NBD module"
            return 1
        fi
        sleep 1
    fi
    
    # Check if we have NBD devices
    if ! ls /dev/nbd* >/dev/null 2>&1; then
        error "No NBD devices found. NBD module may not be loaded correctly."
        return 1
    fi
    
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        debug "Checking NBD device: $nbd_dev"
        
        if [[ ! -e "$nbd_dev" ]]; then
            debug "Device $nbd_dev does not exist"
            continue
        fi
        
        # Check if device is in use by trying to read its status
        if sudo qemu-nbd -d "$nbd_dev" 2>/dev/null; then
            # Device was connected, we just freed it
            NBD_DEVICE="$nbd_dev"
            log "Found and freed NBD device: $NBD_DEVICE"
            return 0
        else
            # Check if device is truly free by looking at /proc/partitions
            if ! grep -q "$(basename $nbd_dev)" /proc/partitions 2>/dev/null; then
                # Device appears to be free
                NBD_DEVICE="$nbd_dev"
                log "Found available NBD device: $NBD_DEVICE"
                return 0
            else
                debug "Device $nbd_dev appears to be in use"
            fi
        fi
    done
    
    error "No available NBD device found. All devices may be in use."
    error "Try disconnecting unused NBD devices with: sudo qemu-nbd -d /dev/nbd0"
    return 1
}

connect_nbd() {
    local image_file="$1"
    
    log "Connecting $image_file to $NBD_DEVICE..."
    
    local file_type=$(file "$image_file")
    local format=""
    
    # Determine format
    if [[ "$image_file" == *.vtoy ]] || [[ "$image_file" == *.vhd ]]; then
        format="vpc"
    elif [[ "$file_type" == *"QEMU QCOW"* ]]; then
        format="qcow2"
    elif [[ "$file_type" == *"VDI disk image"* ]]; then
        format="vdi"
    elif [[ "$image_file" == *.vmdk ]]; then
        format="vmdk"
    else
        format="raw"
    fi
    
    log "Attempting to connect with format: $format"
    
    # Use sudo directly for qemu-nbd commands (not run_with_privileges)
    if ! sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file" 2>/dev/null; then
        if [[ "$format" == "vpc" ]]; then
            log "Falling back to raw format..."
            format="raw"
            if ! sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file"; then
                error "Failed to connect $image_file"
                exit 1
            fi
        else
            error "Failed to connect $image_file with format $format"
            exit 1
        fi
    fi
    
    log "Successfully connected with format: $format"
    
    sleep 2
    sudo partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 1
}

handle_luks_open() {
    local luks_parts="$1"
    IFS=',' read -ra parts <<< "$luks_parts"
    local idx=0
    
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        local name="luks$(date +%s)_$idx"
        log "Opening LUKS partition $part as /dev/mapper/$name"
        if run_with_privileges cryptsetup luksOpen "$part" "$name"; then
            LUKS_MAPPINGS+=("$name")
            OPEN_LUKS_PARTS+=("/dev/mapper/$name")
        else
            warning "Failed to open LUKS partition: $part"
        fi
        idx=$((idx+1))
    done
}

handle_lvm_activate() {
    log "Scanning for LVM physical volumes"
    sudo pvscan --cache >/dev/null 2>&1 || true
    
    local vgs
    vgs=$(sudo vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' || true)
    
    if [[ -n "$vgs" ]]; then
        while read -r vg; do
            [[ -z "$vg" ]] && continue
            log "Activating VG: $vg"
            if sudo vgchange -ay "$vg"; then
                ACTIVATED_VGS+=("$vg")
            fi
        done <<< "$vgs"
    fi
}

mount_partition_btrfs() {
    local partition="$1"
    local mount_point="$2"
    
    log "Probing Btrfs partition $partition for subvolumes..."
    mkdir -p "$mount_point"
    
    local probe=$(mktemp -d)
    run_with_privileges mount -o ro "$partition" "$probe" || {
        warning "Cannot mount $partition for probing"
        return 1
    }
    
    mapfile -t found_subs < <(
        run_with_privileges btrfs subvolume list "$probe" 2>/dev/null | \
        awk '{for(i=9;i<=NF;i++) printf "%s%s",$i,(i==NF?"":" "); print ""}' | \
        sed 's/^ *//; s/ *$//'
    )
    
    run_with_privileges umount "$probe"
    rmdir "$probe"
    
    local candidates_root=("@" "@root" "root")
    local mounted_root=0
    
    for s in "${found_subs[@]}"; do
        [[ -z "$s" ]] && continue
        candidates_root+=("$s")
    done
    
    for sub in "${candidates_root[@]}"; do
        [[ -z "$sub" ]] && continue
        log "Trying Btrfs subvolume candidate: $sub"
        if run_with_privileges mount -t btrfs -o subvol="$sub" "$partition" "$mount_point" 2>/dev/null; then
            if [[ -d "$mount_point/etc" ]] && { [[ -d "$mount_point/bin" ]] || [[ -d "$mount_point/usr/bin" ]]; }; then
                log "Using Btrfs subvolume for root: $sub"
                MOUNTED_POINTS+=("$mount_point")
                mounted_root=1
                break
            else
                run_with_privileges umount "$mount_point" 2>/dev/null || true
            fi
        fi
    done
    
    if [[ $mounted_root -eq 0 ]]; then
        log "No valid root subvolume found; mounting raw partition"
        run_with_privileges mount -t btrfs "$partition" "$mount_point" 2>/dev/null || warning "Cannot mount raw"
        MOUNTED_POINTS+=("$mount_point")
    fi
}

setup_virtual_disk() {
    local image_file="$1"
    
    if [[ ! -f "$image_file" ]]; then
        error "File not found: $image_file"
        return 1
    fi
    
    # Find available NBD device first
    if ! find_available_nbd; then
        error "Cannot find available NBD device"
        return 1
    fi
    
    # Validate that we have an NBD device
    if [[ -z "$NBD_DEVICE" ]]; then
        error "NBD device not set after find_available_nbd"
        return 1
    fi
    
    log "Using NBD device: $NBD_DEVICE"
    connect_nbd "$image_file"
    
    # Show partition information
    log "Partitions found:"
    sudo fdisk -l "$NBD_DEVICE" 2>/dev/null | grep "^$NBD_DEVICE" || true
    
    echo ""
    log "Filesystem details:"
    
    # Detect partitions properly
    local linux_part=""
    local efi_part=""
    local luks_parts=()
    local lvm_parts=()
    
    for part in ${NBD_DEVICE}p*; do
        if [[ -e "$part" ]]; then
            local fs_type=$(sudo blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local label=$(sudo blkid -o value -s LABEL "$part" 2>/dev/null || echo "")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "unknown")
            
            echo "  $part: $fs_type, Size: $size, Label: $label"
            
            # Detect partition types
            case "$fs_type" in
                ext4|ext3|ext2|xfs|btrfs)
                    local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                    if [[ -z "$linux_part" ]] || (( size_mb > 500 )); then
                        linux_part="$part"
                    fi
                    ;;
                vfat)
                    local size_mb=$(lsblk -bno SIZE "$part" 2>/dev/null | awk '{print int($1/1024/1024)}')
                    if (( size_mb < 1000 )); then
                        efi_part="$part"
                    fi
                    ;;
                crypto_LUKS|LUKS)
                    luks_parts+=("$part")
                    ;;
                LVM2_member)
                    lvm_parts+=("$part")
                    ;;
            esac
        fi
    done
    
    local luks_csv=$(IFS=,; echo "${luks_parts[*]}")
    local lvm_csv=$(IFS=,; echo "${lvm_parts[*]}")
    
    [[ -n "$efi_part" ]] && log "EFI partition found: $efi_part"
    [[ -n "$luks_csv" ]] && log "LUKS partitions found: $luks_csv"
    [[ -n "$lvm_csv" ]] && log "LVM physical volumes found: $lvm_csv"
    
    if [[ -n "$luks_csv" ]]; then
        handle_luks_open "$luks_csv"
    fi
    
    sudo partprobe 2>/dev/null || true
    sleep 1
    
    handle_lvm_activate
    
    if [[ -z "$linux_part" ]]; then
        # Try to find root LV
        local root_lv
        root_lv=$(sudo lvs --noheadings -o lv_path 2>/dev/null | head -1 || true)
        if [[ -n "$root_lv" ]]; then
            linux_part="$root_lv"
            log "Using logical volume as root: $linux_part"
        fi
    fi
    
    if [[ -z "$linux_part" ]]; then
        error "No Linux partition found in virtual disk"
        return 1
    fi
    
    ROOT_DEVICE="$linux_part"
    EFI_PART="$efi_part"
    
    log "Linux partition found: $ROOT_DEVICE"
    return 0
}

# ============================================================================
# PHYSICAL DISK FUNCTIONS  
# ============================================================================

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

# ============================================================================
# INTERACTIVE MODE
# ============================================================================

select_image_file() {
    local current_dir="$PWD"
    local selected=""
    local show_hidden=${SHOW_HIDDEN:-0}

    while true; do
        local menu_items=()

        if [[ "$current_dir" != "/" ]]; then
            menu_items+=(".." "Go to parent directory")
        fi

        # Find directories and image files
        while IFS= read -r -d '' item; do
            local name=$(basename "$item")
            if [[ -d "$item" ]]; then
                menu_items+=("📁 $name" "Directory")
            elif [[ "$name" == *.vhd || "$name" == *.vtoy || "$name" == *.qcow2 || \
                    "$name" == *.img || "$name" == *.raw || "$name" == *.vmdk ]]; then
                menu_items+=("💾 $name" "Disk image")
            fi
        done < <(find "$current_dir" -maxdepth 1 \( -type d -o -type f \) \
                 -not -path "$current_dir" \
                 $([ $show_hidden -eq 0 ] && echo '-not -name ".*"') \
                 -print0 2>/dev/null | sort -z)

        if [[ ${#menu_items[@]} -eq 0 ]]; then
            error "No image files or directories found in $current_dir"
            return 1
        fi

        selected=$(dialog --title "Select image file or directory" \
                         --menu "Current: $current_dir" 20 60 12 \
                         "${menu_items[@]}" 2>&1 >/dev/tty) || return 1

        local raw_name=$(echo "$selected" | sed 's/^[📁💾] //')

        if [[ "$selected" == ".." ]]; then
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$raw_name" ]]; then
            current_dir="$current_dir/$raw_name"
        elif [[ -f "$current_dir/$raw_name" ]]; then
            echo "$current_dir/$raw_name"
            return 0
        fi
    done
}

interactive_mode() {
    if [[ "$QUIET_MODE" == false ]] && ! command -v dialog &> /dev/null; then
        error "Dialog not available for interactive mode"
        exit 1
    fi
    
    # Ask the user what type of chroot they want
    local chroot_type
    if chroot_type=$(dialog --title "Chroot Type Selection" \
                           --menu "Select the type of chroot environment:" \
                           15 60 4 \
                           "physical" "Physical disk/partition chroot" \
                           "image" "Virtual disk image chroot" \
                           3>&1 1>&2 2>&3); then
        case "$chroot_type" in
            "image")
                VIRTUAL_MODE=true
                log "Virtual disk image mode selected"
                
                # Select virtual image file
                VIRTUAL_IMAGE=$(select_image_file)
                if [[ $? -ne 0 ]] || [[ -z "$VIRTUAL_IMAGE" ]]; then
                    error "No image file selected"
                    exit 1
                fi
                
                log "Selected virtual image: $VIRTUAL_IMAGE"
                ;;
            "physical")
                VIRTUAL_MODE=false
                log "Physical disk mode selected"
                
                # Select root device
                if ! ROOT_DEVICE=$(select_device "Root" false); then
                    error "No root device selected or operation cancelled"
                    exit 1
                fi
                ;;
            *)
                error "Unknown chroot type selected"
                exit 1
                ;;
        esac
    else
        error "No chroot type selected or operation cancelled"
        exit 1
    fi
    
    # Common options for both modes
    if dialog --title "Graphical Support" \
              --yesno "Do you need to run graphical applications (X11/Wayland) inside the chroot?\n\nThis will setup display variables and authentication files." 10 60; then
        ENABLE_GUI_SUPPORT=true
        local chroot_user
        chroot_user=$(dialog --title "Chroot User" \
                            --inputbox "Enter the user to run GUI apps as in chroot (default: root):" \
                            10 50 "$ORIGINAL_USER" 3>&1 1>&2 2>&3)
        if [[ $? -eq 0 ]]; then
            if [[ -n "$chroot_user" ]]; then
                CHROOT_USER="$chroot_user"
            else
                CHROOT_USER="root"
            fi
        else
            CHROOT_USER="root"
        fi
    else
        ENABLE_GUI_SUPPORT=false
    fi
    
    # Mount point selection
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
    
    # Additional options for physical mode only
    if [[ "$VIRTUAL_MODE" == false ]]; then
        if [[ -d "/sys/firmware/efi" ]]; then
            if dialog --title "UEFI Detected" --yesno "UEFI system detected. Mount EFI partition?" 8 50; then
                EFI_PART=$(select_device "EFI" true) || EFI_PART=""
            fi
        fi
        
        if dialog --title "Boot Partition" --yesno "Mount a separate boot partition?" 8 50; then
            BOOT_PART=$(select_device "Boot" true) || BOOT_PART=""
        fi
    fi
    
    return 0
}

# ============================================================================
# CHROOT SETUP
# ============================================================================

setup_chroot() {
    log "Setting up chroot environment at $ROOT_MOUNT"
    
    if [[ "$VIRTUAL_MODE" == true ]]; then
        # Virtual disk mode
        if ! setup_virtual_disk "$VIRTUAL_IMAGE"; then
            error "Failed to setup virtual disk"
            return 1
        fi
    fi
    
    # Validate and mount root filesystem
    local fs_type=$(run_with_privileges blkid -o value -s TYPE "$ROOT_DEVICE" 2>/dev/null || "")
    
    if [[ "$fs_type" == "btrfs" ]]; then
        mount_partition_btrfs "$ROOT_DEVICE" "$ROOT_MOUNT"
    else
        if ! safe_mount "$ROOT_DEVICE" "$ROOT_MOUNT"; then
            return 1
        fi
    fi
    
    # Handle boot partition mounting
    if [[ -n "$BOOT_PART" ]]; then
        if ! safe_mount "$BOOT_PART" "$ROOT_MOUNT/boot"; then
            return 1
        fi
    fi
    
    # Handle EFI partition
    if [[ -n "$EFI_PART" ]]; then
        local efi_target="$ROOT_MOUNT/boot/efi"
        if [[ -n "$BOOT_PART" ]]; then
            # EFI under separate /boot
            efi_target="$ROOT_MOUNT/boot/efi"
        else
            # EFI directly under root
            efi_target="$ROOT_MOUNT/boot/efi"
        fi
        
        run_with_privileges mkdir -p "$efi_target"
        if ! safe_mount "$EFI_PART" "$efi_target"; then
            warning "Failed to mount EFI partition"
        fi
    fi
    
    # Setup bind mounts for chroot
    setup_bind_mounts "$ROOT_MOUNT"
    
    # Copy network configuration
    if [[ -f /etc/resolv.conf ]]; then
        run_with_privileges cp --remove-destination /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf" 2>/dev/null || true
    fi
    
    if [[ -f /etc/hosts ]]; then
        run_with_privileges cp /etc/hosts "$ROOT_MOUNT/etc/hosts" 2>/dev/null || true
    fi
    
    log "Chroot environment setup complete"
    return 0
}

setup_bind_mounts() {
    local chroot_dir="$1"
    
    local bind_dirs=(
        "/proc:proc:proc"
        "/sys:sysfs:sys"  
        "/dev:--bind:dev"
        "/dev/pts:devpts:dev/pts:--options=ptmxmode=666,gid=5,mode=620"
        "/run:--bind:run"
        "/tmp:--bind:tmp"
    )
    
    for mount_spec in "${bind_dirs[@]}"; do
        IFS=':' read -r src fstype rel_target options <<< "$mount_spec"
        local target="$chroot_dir/$rel_target"
        
        run_with_privileges mkdir -p "$target"
        
        local mount_opts=""
        if [[ "$fstype" == "--bind" ]]; then
            mount_opts="--bind"
        elif [[ -n "$options" ]]; then
            mount_opts="-t $fstype $options"
        else
            mount_opts="-t $fstype"
        fi
        
        if safe_mount "$src" "$target" "$mount_opts"; then
            BIND_MOUNTS+=("$target")
            log "Bind mounted: $src -> $target"
        else
            warning "Failed to bind mount $src to $target"
        fi
    done
}

setup_gui_support() {
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Setting up graphical support (X11) - EXPERIMENTAL"
        
        if [[ -n "${DISPLAY:-}" ]]; then
            log "Configuring X11 display access"
            
            # Ensure /tmp/.X11-unix has correct permissions
            if [[ -d "/tmp/.X11-unix" ]]; then
                run_with_privileges chmod 1777 "/tmp/.X11-unix" || true
            fi
            
            # Copy Xauthority
            local chroot_user="${CHROOT_USER:-root}"
            local xauthority_path="/home/$ORIGINAL_USER/.Xauthority"
            local chroot_xauth_path
            
            if [[ "$chroot_user" == "root" ]]; then
                chroot_xauth_path="$ROOT_MOUNT/root/.Xauthority"
            else
                chroot_xauth_path="$ROOT_MOUNT/home/$chroot_user/.Xauthority"
            fi
            
            if [[ -f "$xauthority_path" ]]; then
                log "Copying Xauthority file"
                run_with_privileges cp "$xauthority_path" "$chroot_xauth_path" && \
                run_with_privileges chown "$chroot_user:$chroot_user" "$chroot_xauth_path" && \
                run_with_privileges chmod 600 "$chroot_xauth_path" || \
                    warning "Failed to setup X11 authentication"
            fi
            
            # Allow local connections
            if command -v xhost &> /dev/null; then
                xhost +local: || warning "Failed to configure xhost"
            fi
        else
            warning "DISPLAY not set, X11 support will not work"
            ENABLE_GUI_SUPPORT=false
        fi
    fi
}

# ============================================================================
# CHROOT ENTRY
# ============================================================================

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
        echo "Mode: $([ "$VIRTUAL_MODE" == true ] && echo "Virtual Disk" || echo "Physical Disk")"
        [[ "$VIRTUAL_MODE" == true ]] && echo "Image: $VIRTUAL_IMAGE"
        echo "Shell: $shell"
        echo "Chroot User: ${CHROOT_USER:-root}"
        echo "GUI Support: $([ "$ENABLE_GUI_SUPPORT" == true ] && echo "ENABLED" || echo "DISABLED")"
        echo
        echo "Tips:"
        echo "- Type 'exit' to return to host system"
        echo "- The cleanup process will handle everything automatically"
        echo "================================================="
        echo
        if [[ -t 0 ]]; then
            echo "Press Enter to continue into chroot environment..."
            read -r
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
    
    echo $ > "$CHROOT_PID_FILE"
    
    local chroot_env_vars=()
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then
            chroot_env_vars+=("DISPLAY=$DISPLAY")
        fi
        if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
            local original_uid=$(id -u "$ORIGINAL_USER")
            chroot_env_vars+=("XDG_RUNTIME_DIR=/run/user/$original_uid")
        fi
    fi
    
    if [[ -n "${CHROOT_USER:-}" ]] && [[ "$CHROOT_USER" != "root" ]]; then
        log "Entering chroot as user $CHROOT_USER"
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

# ============================================================================
# CLEANUP
# ============================================================================

cleanup() {
    local exit_code=$?
    
    debug "Starting cleanup process"
    
    rm -f "$LOCK_FILE" "$CHROOT_PID_FILE"
    
    # Cleanup GUI support
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Cleaning up GUI support"
        if command -v xhost &> /dev/null; then
            xhost -local: 2>/dev/null || true
        fi
    fi
    
    # Unmount bind mounts in reverse order
    for ((i=${#BIND_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${BIND_MOUNTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting bind mount: $mount_point"
            safe_umount "$mount_point" || warning "Error unmounting $mount_point"
        fi
    done
    
    # Unmount mount points in reverse order
    for ((i=${#MOUNTED_POINTS[@]}-1; i>=0; i--)); do
        local mount_point="${MOUNTED_POINTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting: $mount_point"
            safe_umount "$mount_point" || warning "Error unmounting $mount_point"
        fi
    done
    
    # Virtual disk specific cleanup
    if [[ "$VIRTUAL_MODE" == true ]]; then
        # Deactivate LVM VGs
        for vg in "${ACTIVATED_VGS[@]}"; do
            log "Deactivating VG: $vg"
            sudo vgchange -an "$vg" 2>/dev/null || warning "Error deactivating VG $vg"
        done
        
        # Close LUKS mappings
        for name in "${LUKS_MAPPINGS[@]}"; do
            log "Closing LUKS mapping: $name"
            sudo cryptsetup luksClose "$name" 2>/dev/null || warning "Error closing LUKS $name"
        done
        
        # Disconnect NBD
        if [[ -n "$NBD_DEVICE" ]]; then
            log "Disconnecting NBD device: $NBD_DEVICE"
            sudo qemu-nbd -d "$NBD_DEVICE" || warning "Error disconnecting $NBD_DEVICE"
        fi
    fi
    
    # Remove temporary directories
    for mount_point in "${MOUNTED_POINTS[@]}"; do
        if [[ "$mount_point" == /tmp/disk_mount_* ]]; then
            rmdir "$mount_point" 2>/dev/null || true
        fi
    done
    
    success "Cleanup complete"
    return $exit_code
}

# ============================================================================
# MAIN
# ============================================================================

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