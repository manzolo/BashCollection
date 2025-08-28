#!/bin/bash

# Define global variables for disk and partition configuration
DISK_NAME=""
DISK_SIZE=""
DISK_FORMAT=""
PARTITION_TABLE="mbr" # Default to MBR
PREALLOCATION="off"   # Default to sparse allocation
declare -a PARTITIONS=()
VERBOSE=${VERBOSE:-0} # Verbosity flag (0 = silent, 1 = verbose)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check for required tools
check_dependencies() {
    local missing_tools=()
    
    command -v qemu-img >/dev/null || missing_tools+=("qemu-img")
    command -v fdisk >/dev/null || missing_tools+=("fdisk")
    command -v parted >/dev/null || missing_tools+=("parted")
    command -v mkfs.ext4 >/dev/null || missing_tools+=("e2fsprogs")
    command -v mkfs.xfs >/dev/null || missing_tools+=("xfsprogs")
    command -v mkfs.ntfs >/dev/null || missing_tools+=("ntfs-3g")
    command -v mkfs.vfat >/dev/null || missing_tools+=("dosfstools")
    command -v qemu-nbd >/dev/null || missing_tools+=("qemu-utils")
    command -v whiptail >/dev/null || missing_tools+=("whiptail")
    command -v awk >/dev/null || missing_tools+=("awk")
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        error "Please install them before running this script."
        exit 1
    fi
}

# Validate disk size format
validate_size() {
    local size=$1
    if [[ ! $size =~ ^[0-9]+[KMGT]?$ ]]; then
        return 1
    fi
    return 0
}

# Convert size to bytes for validation
size_to_bytes() {
    local size=$1
    local num=${size//[!0-9]/}
    local unit=${size//[0-9]/}
    
    case $unit in
        K|k) echo $((num * 1024)) ;;
        M|m) echo $((num * 1024 * 1024)) ;;
        G|g) echo $((num * 1024 * 1024 * 1024)) ;;
        T|t) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo $num ;;
    esac
}

# Function to get user input for disk configuration using whiptail
interactive_disk_config() {
    whiptail --title "Virtual Disk Creation" --msgbox "Welcome to the enhanced virtual disk creation tool.\n\nFeatures:\n- UEFI/MBR partition table support\n- Fixed/Sparse disk allocation\n- Multiple filesystem support\n- Swap partition support" 15 70
    
    while true; do
        DISK_NAME=$(whiptail --title "Disk Name" --inputbox "Enter the virtual disk file name:\n(e.g., 'my_disk.qcow2', 'system.raw')" 12 60 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then
            exit 0
        fi
        if [ -n "$DISK_NAME" ]; then
            break
        fi
        whiptail --title "Error" --msgbox "Disk name cannot be empty." 8 50
    done
    
    while true; do
        DISK_SIZE=$(whiptail --title "Disk Size" --inputbox "Enter the disk size:\n(e.g., '10G', '512M', '1T')" 12 60 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then
            exit 0
        fi
        if validate_size "$DISK_SIZE"; then
            break
        fi
        whiptail --title "Error" --msgbox "Invalid size format. Use format like: 10G, 512M, 1T" 8 60
    done
    
    DISK_FORMAT=$(whiptail --title "Disk Format" --menu "Choose the disk format:" 15 70 3 \
    "qcow2" "QEMU Copy-On-Write v2 (recommended)" \
    "raw" "Raw disk image (better performance)" \
    "vmdk" "VMware disk format" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        exit 0
    fi
    
    PARTITION_TABLE=$(whiptail --title "Partition Table" --menu "Choose partition table type:" 15 70 2 \
    "mbr" "Master Boot Record (Legacy BIOS)" \
    "gpt" "GUID Partition Table (UEFI)" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        exit 0
    fi
    
    if [ "$DISK_FORMAT" = "raw" ] || [ "$DISK_FORMAT" = "qcow2" ]; then
        PREALLOCATION=$(whiptail --title "Disk Allocation" --menu "Choose allocation method:" 15 70 2 \
        "full" "Pre-allocate disk space (better performance)" \
        "off" "Sparse allocation (grows as needed)" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            exit 0
        fi
    fi
}

# Function to get user input for partitions using whiptail
interactive_partition_config() {
    local total_bytes=$(size_to_bytes "$DISK_SIZE")
    local used_bytes=0
    
    while true; do
        local remaining_bytes=$((total_bytes - used_bytes))
        local remaining_readable=$(bytes_to_readable $remaining_bytes)
        
        if ! whiptail --title "Add Partition" --yesno "Do you want to add a new partition?\n\nDisk size: $DISK_SIZE\nRemaining space: $remaining_readable" 12 60; then
            break
        fi
        
        local PART_SIZE=""
        while true; do
            PART_SIZE=$(whiptail --title "Partition Size" --inputbox "Enter partition size:\n(e.g., '2G', '500M', or 'remaining' for all remaining space)\n\nRemaining: $remaining_readable" 14 60 3>&1 1>&2 2>&3)
            if [ $? -ne 0 ]; then
                break 2
            fi
            
            if [ "$PART_SIZE" = "remaining" ]; then
                PART_SIZE=$remaining_readable
                break
            elif validate_size "$PART_SIZE"; then
                local part_bytes=$(size_to_bytes "$PART_SIZE")
                if [ $part_bytes -le $remaining_bytes ]; then
                    used_bytes=$((used_bytes + part_bytes))
                    break
                else
                    whiptail --title "Error" --msgbox "Partition size exceeds remaining space ($remaining_readable)." 8 60
                fi
            else
                whiptail --title "Error" --msgbox "Invalid size format. Use format like: 2G, 500M, or 'remaining'" 8 60
            fi
        done
        
        local PART_FS=$(whiptail --title "Filesystem Type" --menu "Choose a filesystem:" 20 70 9 \
        "ext4" "Standard Linux filesystem (recommended)" \
        "ext3" "Older Linux filesystem" \
        "xfs" "High-performance Linux filesystem" \
        "btrfs" "Modern Linux filesystem with snapshots" \
        "ntfs" "Windows compatible filesystem" \
        "fat16" "FAT16 filesystem (legacy Windows/DOS)" \
        "vfat" "VFAT filesystem (FAT with long filename support)" \
        "fat32" "FAT32 filesystem (Windows compatible)" \
        "swap" "Linux swap partition" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            break
        fi
        
        PARTITIONS+=("${PART_SIZE}:${PART_FS}")
        
        if [ "$PART_SIZE" = "$remaining_readable" ] || [ $used_bytes -ge $total_bytes ]; then
            whiptail --title "Info" --msgbox "Disk is now fully allocated." 8 50
            break
        fi
    done
}

# Convert bytes to human readable format
bytes_to_readable() {
    local bytes=$1
    if [ $bytes -ge $((1024**4)) ]; then
        echo "$((bytes / (1024**4)))T"
    elif [ $bytes -ge $((1024**3)) ]; then
        echo "$((bytes / (1024**3)))G"
    elif [ $bytes -ge $((1024**2)) ]; then
        echo "$((bytes / (1024**2)))M"
    elif [ $bytes -ge 1024 ]; then
        echo "$((bytes / 1024))K"
    else
        echo "${bytes}B"
    fi
}

# Main function for interactive mode
interactive_mode() {
    interactive_disk_config
    interactive_partition_config

    if [ -z "$DISK_NAME" ] || [ -z "$DISK_SIZE" ] || [ -z "$DISK_FORMAT" ]; then
        whiptail --title "Error" --msgbox "Disk configuration incomplete. Exiting." 10 60
        exit 1
    fi
    
    local config_summary="Disk Configuration Summary:\n\n"
    config_summary+="Name: $DISK_NAME\n"
    config_summary+="Size: $DISK_SIZE\n"
    config_summary+="Format: $DISK_FORMAT\n"
    config_summary+="Partition Table: ${PARTITION_TABLE^^}\n"
    
    if [ "$DISK_FORMAT" = "raw" ] || [ "$DISK_FORMAT" = "qcow2" ]; then
        config_summary+="Allocation: $PREALLOCATION\n"
    fi
    
    if [ ${#PARTITIONS[@]} -gt 0 ]; then
        config_summary+="\nPartitions:\n"
        for i in "${!PARTITIONS[@]}"; do
            IFS=':' read -r size fs <<< "${PARTITIONS[$i]}"
            config_summary+="  $(($i + 1)). $size ($fs)\n"
        done
    else
        config_summary+="\nNo partitions will be created.\n"
    fi
    
    if whiptail --title "Confirm Configuration" --yesno "$config_summary\nProceed with disk creation?" 20 70; then
        create_and_format_disk
    else
        log "Operation cancelled by user."
        exit 0
    fi
}

# Main function for non-interactive mode
non_interactive_mode() {
    local CONFIG_FILE=$1
    if [ ! -f "${CONFIG_FILE}" ]; then
        error "Configuration file '${CONFIG_FILE}' not found."
        exit 1
    fi

    source "${CONFIG_FILE}"

    if [ -z "${DISK_NAME}" ] || [ -z "${DISK_SIZE}" ] || [ -z "${DISK_FORMAT}" ]; then
        error "Required variables (DISK_NAME, DISK_SIZE, DISK_FORMAT) are missing in the config file."
        exit 1
    fi

    PARTITION_TABLE=${PARTITION_TABLE:-"mbr"}
    PREALLOCATION=${PREALLOCATION:-"off"}

    log "Using configuration from: $CONFIG_FILE"
    create_and_format_disk
}

# Core function to create and format the disk
create_and_format_disk() {
    log "Starting disk creation process..."
    
    if [ -f "${DISK_NAME}" ]; then
        error "File '${DISK_NAME}' already exists."
        if command -v whiptail >/dev/null 2>&1; then
            if ! whiptail --title "File Exists" --yesno "File '${DISK_NAME}' already exists. Overwrite?" 8 60; then
                log "Operation cancelled."
                exit 0
            fi
        else
            read -p "File '${DISK_NAME}' already exists. Overwrite? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Operation cancelled."
                exit 0
            fi
        fi
        rm -f "${DISK_NAME}" 2>/dev/null || { error "Failed to remove existing file '${DISK_NAME}'"; exit 1; }
    fi
    
    log "Creating disk ${DISK_NAME} with size ${DISK_SIZE} and format ${DISK_FORMAT}..."
    
    local create_cmd="qemu-img create -f ${DISK_FORMAT}"
    
    if [ "$PREALLOCATION" = "full" ]; then
        case "$DISK_FORMAT" in
            "raw")
                create_cmd+=" -o preallocation=full"
                ;;
            "qcow2")
                create_cmd+=" -o preallocation=metadata"
                ;;
        esac
    fi
    
    create_cmd+=" ${DISK_NAME} ${DISK_SIZE}"
    
    if [ "$VERBOSE" -eq 1 ]; then
        if ! eval $create_cmd; then
            error "Failed to create virtual disk."
            exit 1
        fi
    else
        if ! eval $create_cmd >/dev/null 2>&1; then
            error "Failed to create virtual disk."
            exit 1
        fi
    fi
    
    success "Virtual disk created successfully."

    if [ "${#PARTITIONS[@]}" -gt 0 ]; then
        log "Setting up partitions..."
        create_partitions
        format_partitions
        log "Final partition table for ${DISK_NAME}:"
        if [ "$VERBOSE" -eq 1 ]; then
            log "Full parted output:"
            sudo parted -s "${DEVICE}" print
            log "Formatted table:"
        fi
        # Generate tabular output
        sudo parted -s "${DEVICE}" print | awk '
            BEGIN {
                printf "%-8s %-12s %-12s %-12s %-12s %s\n", "Number", "Start", "End", "Size", "File system", "Name"
                printf "%-8s %-12s %-12s %-12s %-12s %s\n", "------", "-------", "-------", "-------", "-----------", "----"
            }
            /^[ ]*[0-9]+/ {
                printf "%-8s %-12s %-12s %-12s %-12s %s\n", $1, $2, $3, $4, ($5 == "" ? "unknown" : $5), ($6 == "" ? "-" : $6)
            }' | while IFS= read -r line; do
                log "  $line"
            done
        cleanup_device "${DEVICE}"
    else
        success "Virtual disk created successfully (no partitions specified)."
    fi
}

# Convert size string to MiB
size_to_mib() {
    local size=$1
    local num=${size//[!0-9]/}
    local unit=${size//[0-9]/}
    
    case ${unit^^} in
        K) echo $((num / 1024)) ;;
        M) echo $num ;;
        G) echo $((num * 1024)) ;;
        T) echo $((num * 1024 * 1024)) ;;
        *) echo $((num / 1024 / 1024)) ;;
    esac
}

# Function to create partitions
create_partitions() {
    local DEVICE=""
    
    if [ "$DISK_FORMAT" = "qcow2" ]; then
        log "Loading qemu-nbd kernel module..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo modprobe nbd max_part=8
        else
            sudo modprobe nbd max_part=8 >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to load qemu-nbd kernel module."
            exit 1
        fi
        
        for i in {0..15}; do
            if [ ! -e "/sys/block/nbd$i/pid" ]; then
                DEVICE="/dev/nbd$i"
                break
            fi
        done
        
        if [ -z "$DEVICE" ]; then
            error "No available NBD devices"
            exit 1
        fi
        
        log "Connecting ${DISK_NAME} to ${DEVICE} via qemu-nbd..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --connect="$DEVICE" "$DISK_NAME"
        else
            sudo qemu-nbd --connect="$DEVICE" "$DISK_NAME" >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to connect qcow2 image via qemu-nbd"
            exit 1
        fi
        
        sleep 2
    else
        log "Setting up loop device for ${DISK_NAME}..."
        if [ "$VERBOSE" -eq 1 ]; then
            DEVICE=$(sudo losetup -f --show "${DISK_NAME}")
        else
            DEVICE=$(sudo losetup -f --show "${DISK_NAME}" 2>/dev/null)
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create loop device for ${DISK_NAME}"
            exit 1
        fi
    fi
    
    log "Using device: ${DEVICE}"
    
    if [ "$PARTITION_TABLE" = "gpt" ]; then
        log "Creating GPT partition table..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${DEVICE}" mklabel gpt
        else
            sudo parted -s "${DEVICE}" mklabel gpt >/dev/null 2>&1
        fi
    else
        log "Creating MBR partition table..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${DEVICE}" mklabel msdos
        else
            sudo parted -s "${DEVICE}" mklabel msdos >/dev/null 2>&1
        fi
    fi
    if [ $? -ne 0 ]; then
        error "Failed to create partition table"
        cleanup_device "$DEVICE"
        exit 1
    fi
    
    local start_mib=1
    local partition_number=1
    local total_disk_mib=$(size_to_mib "$DISK_SIZE")
    local used_mib=1
    
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs <<< "${part_info}"
        
        log "Creating partition ${partition_number}: ${part_size} (${part_fs})"
        
        local end_position
        local size_mib
        
        if [ "$part_size" = "remaining" ]; then
            end_position="100%"
            size_mib=$((total_disk_mib - used_mib))
        else
            size_mib=$(size_to_mib "$part_size")
            end_position=$((start_mib + size_mib))
            
            if [ $end_position -gt $total_disk_mib ]; then
                warning "Partition ${partition_number} size exceeds remaining disk space, adjusting to fit"
                end_position="100%"
            fi
        fi
        
        local part_name=""
        local part_type="primary"
        case "$part_fs" in
            "swap")
                part_name="Linux swap"
                ;;
            "ext4"|"ext3"|"xfs"|"btrfs")
                part_name="Linux filesystem"
                ;;
            "ntfs"|"fat16"|"vfat"|"fat32")
                part_name="Microsoft basic data"
                if [ "$PARTITION_TABLE" = "mbr" ]; then
                    case "$part_fs" in
                        "fat16")
                            if [ "$VERBOSE" -eq 1 ]; then
                                sudo parted -s "${DEVICE}" set $partition_number type 0x06
                            else
                                sudo parted -s "${DEVICE}" set $partition_number type 0x06 >/dev/null 2>&1
                            fi
                            ;;
                        "vfat"|"fat32")
                            if [ "$VERBOSE" -eq 1 ]; then
                                sudo parted -s "${DEVICE}" set $partition_number type 0x0b
                            else
                                sudo parted -s "${DEVICE}" set $partition_number type 0x0b >/dev/null 2>&1
                            fi
                            ;;
                    esac
                    if [ $? -ne 0 ]; then
                        error "Failed to set partition type for partition ${partition_number}"
                        cleanup_device "$DEVICE"
                        exit 1
                    fi
                fi
                ;;
            *)
                part_name="Linux filesystem"
                ;;
        esac
        
        if [ "$PARTITION_TABLE" = "gpt" ]; then
            if [ "$VERBOSE" -eq 1 ]; then
                sudo parted -s "${DEVICE}" mkpart "\"${part_name}\"" "${start_mib}MiB" "${end_position}"
            else
                sudo parted -s "${DEVICE}" mkpart "\"${part_name}\"" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
            fi
        else
            if [ "$end_position" = "100%" ]; then
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
            else
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}MiB"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}MiB" >/dev/null 2>&1
                fi
            fi
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create partition ${partition_number}"
            cleanup_device "$DEVICE"
            exit 1
        fi
        
        case "$part_fs" in
            "swap")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" set $partition_number swap on
                else
                    sudo parted -s "${DEVICE}" set $partition_number swap on >/dev/null 2>&1
                fi
                if [ $? -ne 0 ]; then
                    error "Failed to set swap flag for partition ${partition_number}"
                    cleanup_device "$DEVICE"
                    exit 1
                fi
                ;;
        esac
        
        if [ "$end_position" != "100%" ]; then
            start_mib=$end_position
            used_mib=$end_position
        else
            break
        fi
        
        ((partition_number++))
    done
    
    if [ "$VERBOSE" -eq 1 ]; then
        sudo partprobe "${DEVICE}"
    else
        sudo partprobe "${DEVICE}" >/dev/null 2>&1
    fi
    if [ $? -ne 0 ]; then
        error "Failed to inform kernel of partition table changes"
        cleanup_device "$DEVICE"
        exit 1
    fi
    sleep 2
    
    echo "${DEVICE}:${DISK_FORMAT}" > /tmp/disk_creator_device_info
}

# Function to cleanup device connections
cleanup_device() {
    local DEVICE=$1
    
    if [[ "$DEVICE" =~ /dev/nbd ]]; then
        log "Disconnecting ${DEVICE}..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --disconnect "$DEVICE"
        else
            sudo qemu-nbd --disconnect "$DEVICE" >/dev/null 2>&1
        fi
    else
        log "Releasing loop device ${DEVICE}..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo losetup -d "$DEVICE"
        else
            sudo losetup -d "$DEVICE" >/dev/null 2>&1
        fi
    fi
    if [ $? -ne 0 ]; then
        error "Failed to cleanup device ${DEVICE}"
        exit 1
    fi
}

# Function to format partitions
format_partitions() {
    local DEVICE_INFO=$(cat /tmp/disk_creator_device_info 2>/dev/null)
    
    if [ -z "$DEVICE_INFO" ]; then
        error "Device information not found"
        exit 1
    fi
    
    IFS=':' read -r DEVICE FORMAT <<< "$DEVICE_INFO"
    
    log "Formatting partitions on ${DEVICE}..."
    
    local counter=1
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs <<< "${part_info}"
        local part_device="${DEVICE}p${counter}"
        
        if [[ "$DEVICE" =~ /dev/nbd ]]; then
            part_device="${DEVICE}p${counter}"
        else
            part_device="${DEVICE}${counter}"
        fi
        
        local wait_count=0
        while [ ! -e "$part_device" ] && [ $wait_count -lt 10 ]; do
            sleep 1
            ((wait_count++))
        done
        
        if [ ! -e "$part_device" ]; then
            error "Partition device $part_device not found"
            continue
        fi
        
        log "Formatting ${part_device} as ${part_fs}..."
        
        case "$part_fs" in
            "ext4")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.ext4 -F "${part_device}"
                else
                    sudo mkfs.ext4 -F "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "ext3")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.ext3 -F "${part_device}"
                else
                    sudo mkfs.ext3 -F "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "xfs")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.xfs -f "${part_device}"
                else
                    sudo mkfs.xfs -f "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "btrfs")
                if command -v mkfs.btrfs >/dev/null; then
                    if [ "$VERBOSE" -eq 1 ]; then
                        sudo mkfs.btrfs -f "${part_device}"
                    else
                        sudo mkfs.btrfs -f "${part_device}" >/dev/null 2>&1
                    fi
                else
                    warning "btrfs-progs not found, skipping formatting of ${part_device}"
                    continue
                fi
                ;;
            "ntfs")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.ntfs -F "${part_device}"
                else
                    sudo mkfs.ntfs -F "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "fat16")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.vfat -F 16 "${part_device}"
                else
                    sudo mkfs.vfat -F 16 "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "vfat")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.vfat "${part_device}"
                else
                    sudo mkfs.vfat "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "fat32")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.vfat -F 32 "${part_device}"
                else
                    sudo mkfs.vfat -F 32 "${part_device}" >/dev/null 2>&1
                fi
                ;;
            "swap")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkswap "${part_device}"
                else
                    sudo mkswap "${part_device}" >/dev/null 2>&1
                fi
                ;;
            *)
                warning "Unknown filesystem type: ${part_fs}, skipping formatting"
                continue
                ;;
        esac
        
        if [ $? -eq 0 ]; then
            success "Partition ${counter} formatted successfully as ${part_fs}"
        else
            error "Failed to format partition ${counter} as ${part_fs}"
            continue
        fi
        
        ((counter++))
    done
    
    success "All partitions formatted successfully!"
}

# Show help
show_help() {
    cat << EOF
Virtual Disk Creator - Enhanced Edition

Usage:
  $0                      Start in interactive mode
  $0 <config_file>        Use configuration file
  $0 -h, --help           Show this help
  VERBOSE=1 $0            Enable verbose output for debugging

Features:
  - UEFI (GPT) and Legacy BIOS (MBR) support
  - Multiple disk formats (qcow2, raw, vmdk)
  - Fixed/sparse disk allocation
  - Multiple filesystem support (ext4, ext3, xfs, btrfs, ntfs, fat16, vfat, fat32)
  - Linux swap partition support
  - Interactive and configuration file modes
  - Verbose mode for detailed command output (set VERBOSE=1)
  - Displays final partition table in a tabular format after creation

Configuration file example:
  DISK_NAME="example.raw"
  DISK_SIZE="10G"
  DISK_FORMAT="raw"
  PARTITION_TABLE="gpt"      # "gpt" or "mbr"
  PREALLOCATION="full"       # "full" or "off" (for raw format)
  PARTITIONS=(
      "2G:ext4"
      "1G:swap"
      "500M:fat32"
      "remaining:vfat"
  )

EOF
}

# Main logic
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
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