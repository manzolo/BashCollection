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
    
    case ${unit^^} in
        K) echo $((num * 1024)) ;;
        M) echo $((num * 1024 * 1024)) ;;
        G) echo $((num * 1024 * 1024 * 1024)) ;;
        T) echo $((num * 1024 * 1024 * 1024 * 1024)) ;;
        *) echo $num ;;
    esac
}

# Convert bytes to human-readable format
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

# Convert size to MiB (mebibytes, 1024*1024 bytes) for parted
size_to_mib() {
    local size=$1
    if [ "$size" = "remaining" ]; then
        echo "remaining"
        return
    fi
    local num=${size//[!0-9]/}
    local unit=${size//[0-9]/}
    
    # Convert to bytes first for precise calculation
    local bytes
    case ${unit^^} in
        K) bytes=$((num * 1024)) ;;
        M) bytes=$((num * 1024 * 1024)) ;;
        G) bytes=$((num * 1024 * 1024 * 1024)) ;;
        T) bytes=$((num * 1024 * 1024 * 1024 * 1024)) ;;
        *) bytes=$num ;;
    esac
    # Convert bytes to MiB (ceiling to ensure no loss)
    echo $(( (bytes + 1024*1024 - 1) / (1024*1024) ))
}

# Function to get user input for disk configuration using whiptail
interactive_disk_config() {
    whiptail --title "Virtual Disk Creation" --msgbox "Welcome to the enhanced virtual disk creation tool.\n\nFeatures:\n- UEFI/MBR partition table support\n- Fixed/Sparse disk allocation\n- Multiple filesystem support\n- Swap partition support\n- Generate config from existing disk\n- Display disk info" 15 70
    
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
    "raw" "Raw disk image (better performance)"  3>&1 1>&2 2>&3)
    
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
        
        local PART_FS=$(whiptail --title "Filesystem Type" --menu "Choose a filesystem (or none for unformatted):" 20 70 11 \
        "none" "No filesystem (unformatted)" \
        "ext4" "Standard Linux filesystem (recommended)" \
        "ext3" "Older Linux filesystem" \
        "xfs" "High-performance Linux filesystem" \
        "btrfs" "Modern Linux filesystem with snapshots" \
        "ntfs" "Windows compatible filesystem" \
        "fat16" "FAT16 filesystem (legacy Windows/DOS)" \
        "vfat" "VFAT filesystem (FAT with long filename support)" \
        "fat32" "FAT32 filesystem (Windows compatible)" \
        "swap" "Linux swap partition" \
        "msr" "Microsoft Reserved Partition (GPT only)" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            break
        fi
        
        local PART_TYPE=""
        if [ "$PARTITION_TABLE" = "mbr" ]; then
            PART_TYPE=$(whiptail --title "Partition Type" --menu "Choose partition type:" 15 70 3 \
            "primary" "Primary partition" \
            "extended" "Extended partition (for logical partitions)" \
            "logical" "Logical partition (requires an extended partition)" 3>&1 1>&2 2>&3)
            if [ $? -ne 0 ]; then
                break
            fi
            PARTITIONS+=("${PART_SIZE}:${PART_FS}:${PART_TYPE}")
        else
            PARTITIONS+=("${PART_SIZE}:${PART_FS}")
        fi
        
        if [ "$PART_SIZE" = "$remaining_readable" ] || [ $used_bytes -ge $total_bytes ]; then
            whiptail --title "Info" --msgbox "Disk is now fully allocated." 8 50
            break
        fi
    done
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
            IFS=':' read -r size fs type <<< "${PARTITIONS[$i]}"
            if [ "$PARTITION_TABLE" = "mbr" ]; then
                config_summary+="  $(($i + 1)). $size ($fs, $type)\n"
            else
                config_summary+="  $(($i + 1)). $size ($fs)\n"
            fi
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

    # Validate PARTITIONS array format
    for part in "${PARTITIONS[@]}"; do
        if [[ ! "$part" =~ ^[^:]+:[^:]*(:[^:]+)?$ ]]; then
            error "Invalid partition format in config: $part"
            exit 1
        fi
    done

    log "Using configuration from: $CONFIG_FILE"
    create_and_format_disk
}

# Updated create_partitions function
create_partitions() {
    # Declare DEVICE as global
    declare -g DEVICE

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
    
    # Wait for partition devices to be created
    log "Waiting for partition devices to be created..."
    sudo partprobe "${DEVICE}"
    udevadm settle
    sleep 2
    
    # Debug: Print the partition array before processing
    log "DEBUG: Processing partitions: ${PARTITIONS[*]}"
    
    local start_mib=1
    local partition_number=1
    local total_disk_mib=$(size_to_mib "$DISK_SIZE")
    local used_mib=1
    local extended_start_mib=0
    local extended_end_mib=0
    local logical_start_mib=0
    
    # Calculate total logical partition size for validation
    local logical_total_mib=0
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ "$part_type" = "logical" ] && [ "$part_size" != "remaining" ]; then
            logical_total_mib=$((logical_total_mib + $(size_to_mib "$part_size")))
        fi
    done
    local overhead_per_logical=32 # MiB per logical partition for EBR and alignment
    local logical_overhead_mib=$((overhead_per_logical * $(echo "${PARTITIONS[*]}" | grep -c ":logical")))
    
    # First pass: create primary and extended partitions
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ -z "$part_type" ] && [ "$PARTITION_TABLE" = "mbr" ]; then
            part_type="primary"
        fi

        # Skip logical partitions in the first pass
        if [ "$part_type" = "logical" ]; then
            continue
        fi

        log "Creating partition ${partition_number}: ${part_size} (${part_fs:-none}, ${part_type:-none})"
        
        local size_mib
        if [ "$part_size" = "remaining" ]; then
            size_mib=$((total_disk_mib - used_mib))
            if [ $size_mib -le 0 ]; then
                error "No remaining space for partition ${partition_number}"
                cleanup_device "$DEVICE"
                exit 1
            fi
            end_position="100%"
        else
            size_mib=$(size_to_mib "$part_size")
            end_position=$((start_mib + size_mib))
            if [ $end_position -gt $total_disk_mib ]; then
                warning "Partition ${partition_number} size exceeds remaining disk space, adjusting to fit"
                size_mib=$((total_disk_mib - used_mib))
                end_position="100%"
            fi
        fi
        
        # For extended partition, ensure it can hold all logical partitions plus overhead
        if [ "$part_type" = "extended" ] && [ "$part_size" != "remaining" ]; then
            local extended_size_mib=$(size_to_mib "$part_size")
            if [ $((logical_total_mib + logical_overhead_mib)) -gt $extended_size_mib ]; then
                error "Extended partition size ($part_size) is too small to hold logical partitions ($logical_total_mib MiB + $logical_overhead_mib MiB overhead)"
                cleanup_device "$DEVICE"
                exit 1
            fi
        fi
        
        local part_name=""
        case "${part_fs:-unknown}" in
            "swap") part_name="Linux_swap" ;;
            "ext4"|"ext3"|"xfs"|"btrfs") part_name="Linux_filesystem" ;;
            "ntfs"|"fat16"|"vfat"|"fat32") part_name="Microsoft_basic_data" ;;
            "msr") part_name="Microsoft_reserved_partition" ;;
            *) part_name="Unformatted" ;;
        esac

        local parted_fs_type
        case "${part_fs:-unknown}" in
            "swap") parted_fs_type="linux-swap" ;;
            "vfat"|"fat32") parted_fs_type="fat32" ;;
            "fat16") parted_fs_type="fat16" ;;
            "ntfs") parted_fs_type="ntfs" ;;
            "ext4") parted_fs_type="ext4" ;;
            "ext3") parted_fs_type="ext3" ;;
            "xfs") parted_fs_type="xfs" ;;
            "btrfs") parted_fs_type="btrfs" ;;
            "msr") parted_fs_type="" ;;
            *) parted_fs_type="" ;;
        esac
        
        if [ "$PARTITION_TABLE" = "gpt" ]; then
            if [ "$part_fs" = "msr" ]; then
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_name}" "" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_name}" "" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
            else
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_name}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_name}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
            fi
        else
            if [ "$part_type" = "extended" ]; then
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
                extended_start_mib=$(sudo parted -s "${DEVICE}" print | awk '/extended/ {print int($2)}')
                extended_end_mib=$(sudo parted -s "${DEVICE}" print | awk '/extended/ {print int($3)}')
                logical_start_mib=$((extended_start_mib + 1)) # Start logical partitions after EBR
            else
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
            fi
        fi
        
        local parted_exit_code=$?
        if [ $parted_exit_code -ne 0 ]; then
            error "Failed to create partition ${partition_number} (exit code: $parted_exit_code)"
            cleanup_device "$DEVICE"
            exit 1
        fi
        
        # Update start position for next partition (only for non-logical partitions)
        if [ "$part_type" != "logical" ]; then
            start_mib=$(sudo parted -s "${DEVICE}" print | awk -v num="$partition_number" '$1 == num {print int($3)}')
            used_mib=$start_mib
        fi
        ((partition_number++))
    done

    # Now handle the logical partitions
    log "Creating logical partitions..."
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ "$part_type" != "logical" ]; then
            continue
        fi

        log "Creating logical partition: ${part_size} (${part_fs})"
        
        local parted_fs_type
        case "${part_fs:-unknown}" in
            "swap") parted_fs_type="linux-swap" ;;
            "vfat"|"fat32") parted_fs_type="fat32" ;;
            "fat16") parted_fs_type="fat16" ;;
            "ntfs") parted_fs_type="ntfs" ;;
            "ext4") parted_fs_type="ext4" ;;
            "ext3") parted_fs_type="ext3" ;;
            "xfs") parted_fs_type="xfs" ;;
            "btrfs") parted_fs_type="btrfs" ;;
            *) parted_fs_type="" ;;
        esac

        local part_end_position
        if [ "$part_size" = "remaining" ]; then
            part_end_position=$((extended_end_mib - 1)) # Leave 1 MiB for EBR
        else
            local size_mib=$(size_to_mib "$part_size")
            part_end_position=$((logical_start_mib + size_mib))
            
            if [ $part_end_position -gt $((extended_end_mib - 1)) ]; then
                error "Logical partition size ($part_size) exceeds remaining space in extended partition ($((extended_end_mib - logical_start_mib)) MiB available)"
                cleanup_device "$DEVICE"
                exit 1
            fi
        fi
        
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${DEVICE}" mkpart logical "${parted_fs_type}" "${logical_start_mib}MiB" "${part_end_position}MiB"
        else
            sudo parted -s "${DEVICE}" mkpart logical "${parted_fs_type}" "${logical_start_mib}MiB" "${part_end_position}MiB" >/dev/null 2>&1
        fi
        
        local parted_exit_code=$?
        if [ $parted_exit_code -ne 0 ]; then
            error "Failed to create logical partition (exit code: $parted_exit_code)"
            cleanup_device "$DEVICE"
            exit 1
        fi

        local actual_end_mib=$(sudo parted -s "${DEVICE}" print | awk '/logical/ {print int($3)}' | tail -1)
        if [[ ! -z "$actual_end_mib" ]]; then
            logical_start_mib=$((actual_end_mib + 1)) # Add 1 MiB for next EBR
        fi
        
        sleep 2
        sudo partprobe "${DEVICE}" >/dev/null 2>&1
        sleep 1

        ((partition_number++))
    done
    
    # Final check: wait for all partitions to appear
    log "Waiting for all partitions to be recognized..."
    sleep 3
    sudo partprobe "${DEVICE}" >/dev/null 2>&1
    sleep 2
    
    # Debug: List what partitions actually exist
    log "DEBUG: Checking partition devices:"
    ls -la "${DEVICE}"* 2>/dev/null | while IFS= read -r line; do log "DEBUG: $line"; done
    
    # Write device info to a temporary file for cleanup function
    echo "${DEVICE}:${DISK_FORMAT}" > /tmp/disk_creator_device_info
}

# Updated create_and_format_disk function
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

    validate_mbr_partitions
    
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

        # Ensure DEVICE is set
        if [ -z "$DEVICE" ]; then
            error "DEVICE not set after create_partitions"
            exit 1
        fi

        # Passa il device alla funzione
        format_partitions "$DEVICE"
        log "Final partition table for ${DISK_NAME}:"
        if [ "$VERBOSE" -eq 1 ]; then
            log "Full parted output:"
            sudo parted -s "${DEVICE}" print
            log "Formatted table:"
        fi
        # Generate tabular output
        sudo parted -s "${DEVICE}" print | awk -v part_table="$PARTITION_TABLE" '
            BEGIN {
                if (part_table == "mbr") {
                    printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", "Number", "Start", "End", "Size", "File system", "Type", "Name"
                    printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", "------", "-------", "-------", "-------", "-----------", "-------", "----"
                } else {
                    printf "%-8s %-12s %-12s %-12s %-12s %s\n", "Number", "Start", "End", "Size", "File system", "Name"
                    printf "%-8s %-12s %-12s %-12s %-12s %s\n", "------", "-------", "-------", "-------", "-----------", "----"
                }
            }
            /^[ ]*[0-9]+/ {
                fs=$5
                if (fs == "" || fs == "unknown") fs="none"
                if (fs == "linux-swap(v1)" || fs == "linux-swap") fs="swap"
                name=$6
                if (fs == "fat16" || fs == "fat32" || fs == "vfat") name="Microsoft basic data"
                else if (fs == "swap") name="Linux swap"
                else if (fs == "ext4" || fs == "ext3" || fs == "xfs" || fs == "btrfs") name="Linux filesystem"
                else if (name == "" || name == "unknown") name="Unformatted"
                type=""
                if (part_table == "mbr") {
                    if ($7 ~ /logical/) type="logical"
                    else if ($7 ~ /extended/) type="extended"
                    else type="primary"
                    printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", $1, $2, $3, $4, fs, type, name
                } else {
                    printf "%-8s %-12s %-12s %-12s %-12s %s\n", $1, $2, $3, $4, fs, name
                }
            }' | while IFS= read -r line; do
                log "  $line"
            done
        cleanup_device "${DEVICE}"
    else
        success "Virtual disk created successfully (no partitions specified)."
    fi
}

validate_mbr_partitions() {
    if [ "$PARTITION_TABLE" != "mbr" ]; then
        return 0
    fi
    
    local primary_count=0
    local extended_count=0
    local logical_count=0
    local logical_partitions=()
    local other_partitions=()
    
    # Prima passata: conteggio tipi di partizione
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        case "$part_type" in
            "primary")  primary_count=$((primary_count + 1)); other_partitions+=("$part_info") ;;
            "extended") extended_count=$((extended_count + 1)); other_partitions+=("$part_info") ;;
            "logical")  logical_count=$((logical_count + 1)); logical_partitions+=("$part_info") ;;
            *)          other_partitions+=("$part_info") ;; # default = primary
        esac
    done
    
    # Se ci sono logiche senza estesa → aggiungila
    if [ $logical_count -gt 0 ] && [ $extended_count -eq 0 ]; then
        log "Logical partitions detected without an extended partition. Adding an extended partition."
        
        local has_remaining_logical=false
        local logical_total_bytes=0
        
        for part_info in "${logical_partitions[@]}"; do
            IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
            if [ "$part_size" = "remaining" ]; then
                has_remaining_logical=true
                break
            fi
            logical_total_bytes=$((logical_total_bytes + $(size_to_bytes "$part_size")))
        done
        
        local extended_size
        if [ "$has_remaining_logical" = true ]; then
            extended_size="remaining"
        else
            # Overhead di 32 MiB per logica
            local overhead_per_logical=$((32 * 1024 * 1024))
            local overhead_bytes=$((overhead_per_logical * logical_count))
            local extended_total_bytes=$((logical_total_bytes + overhead_bytes + 64*1024*1024)) # +64 MiB margine
            
            # Arrotonda al GiB superiore
            local gib=$((1024 * 1024 * 1024))
            local rounded=$(( (extended_total_bytes + gib - 1) / gib * gib ))
            extended_size=$(bytes_to_readable "$rounded")
            
            log "DEBUG: Logical partitions total: $(bytes_to_readable $logical_total_bytes)"
            log "DEBUG: Extended partition size with overhead ($logical_count logical partitions): $extended_size"
        fi
        
        PARTITIONS=()
        for part in "${other_partitions[@]}"; do
            PARTITIONS+=("$part")
        done
        PARTITIONS+=("${extended_size}:none:extended")
        for part in "${logical_partitions[@]}"; do
            PARTITIONS+=("$part")
        done
        
        extended_count=1
        log "Added extended partition of size $extended_size containing $logical_count logical partition(s)"
    fi
    
    # Vincoli MBR
    local total_primary_extended=$((primary_count + extended_count))
    if [ $total_primary_extended -gt 4 ]; then
        error "MBR partition table can have max 4 primary+extended partitions (found: $total_primary_extended)"
        return 1
    fi
    if [ $extended_count -gt 1 ]; then
        error "MBR can have only 1 extended partition (found: $extended_count)"
        return 1
    fi
    
    return 0
}

# Function to format partitions
format_partitions() {
    local DEVICE="$1"
    local partition_number=1
    local logical_number=5

    log "Formatting partitions on $DEVICE..."

    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        local part_dev=""

        if [ "$part_type" = "logical" ]; then
            part_dev="${DEVICE}p${logical_number}"
            ((logical_number++))
        else
            part_dev="${DEVICE}p${partition_number}"
            ((partition_number++))
        fi

        if [ ! -b "$part_dev" ]; then
            error "Partition device $part_dev does not exist"
            continue
        fi

        log "Formatting $part_dev as $part_fs..."
        case "$part_fs" in
            "swap")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkswap "$part_dev"
                else
                    sudo mkswap "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "ext4")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.ext4 "$part_dev"
                else
                    sudo mkfs.ext4 "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "ext3")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.ext3 "$part_dev"
                else
                    sudo mkfs.ext3 "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "xfs")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.xfs "$part_dev"
                else
                    sudo mkfs.xfs "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "btrfs")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.btrfs "$part_dev"
                else
                    sudo mkfs.btrfs "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "fat32"|"vfat")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.vfat -F 32 "$part_dev"
                else
                    sudo mkfs.vfat -F 32 "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "fat16")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.vfat -F 16 "$part_dev"
                else
                    sudo mkfs.vfat -F 16 "$part_dev" >/dev/null 2>&1
                fi
                ;;
            "ntfs")
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo mkfs.ntfs -f "$part_dev"
                else
                    sudo mkfs.ntfs -f "$part_dev" >/dev/null 2>&1
                fi
                ;;
            *)
                log "Skipping formatting for $part_dev (no filesystem specified)"
                continue
                ;;
        esac
        if [ $? -ne 0 ]; then
            error "Failed to format $part_dev as $part_fs"
        else
            log "Successfully formatted $part_dev as $part_fs"
        fi
    done

    # Ensure partitions are recognized
    sudo partprobe "$DEVICE" >/dev/null 2>&1
    udevadm settle >/dev/null 2>&1
    sleep 2
}

# Function to normalize filesystem type
normalize_fs_type() {
    local fs="$1"
    local type="$2"
    local name="$3"
    case "$fs" in
        "linux-swap(v1)"|"linux-swap") echo "swap" ;;
        "vfat"|"fat32") echo "fat32" ;;
        "fat16") echo "fat16" ;;
        "ntfs") echo "ntfs" ;;
        "ext4") echo "ext4" ;;
        "ext3") echo "ext3" ;;
        "xfs") echo "xfs" ;;
        "btrfs") echo "btrfs" ;;
        *)
            if [[ "$name" =~ "Microsoft reserved" || "$type" == "msr" ]]; then
                echo "msr"
            else
                echo "none"
            fi
            ;;
    esac
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
        if [ $? -ne 0 ]; then
            warning "Failed to disconnect ${DEVICE}, but continuing."
            return 1
        fi
    else
        log "Releasing loop device ${DEVICE}..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo losetup -d "$DEVICE"
        else
            sudo losetup -d "$DEVICE" >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            warning "Failed to release loop device ${DEVICE}, but continuing."
            return 1
        fi
    fi
    return 0
}

# Function to generate config.sh from an existing disk image
# Function to generate config.sh from an existing disk image
generate_config() {
    local DISK_FILE="$1"
    local CONFIG_FILE="${DISK_FILE%.*}_config.sh"

    log "Analyzing disk image $DISK_FILE..."

    # Get disk format and size using qemu-img
    local QEMU_INFO
    QEMU_INFO=$(qemu-img info "$DISK_FILE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read disk image info for $DISK_FILE"
        exit 1
    fi

    local DISK_FORMAT=$(echo "$QEMU_INFO" | awk -F': ' '/file format/ {print $2}')
    local DISK_SIZE=$(echo "$QEMU_INFO" | grep "virtual size" | grep -oP '\d+\.?\d*\s*(GiB|MiB|KiB)' | sed 's/\s*GiB/G/' | sed 's/\s*MiB/M/' | sed 's/\s*KiB/K/' | tr -d ' ')
    if [ -z "$DISK_SIZE" ]; then
        error "Failed to parse disk size from qemu-img info"
        exit 1
    fi
    log "DEBUG: QEMU_INFO: $QEMU_INFO"
    log "DEBUG: Parsed DISK_SIZE: $DISK_SIZE"

    # Set up device for parted
    local DEVICE=""
    if [ "$DISK_FORMAT" = "qcow2" ]; then
        log "Loading qemu-nbd kernel module..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo modprobe nbd max_part=16
        else
            sudo modprobe nbd max_part=16 >/dev/null 2>&1
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

        log "Connecting $DISK_FILE to $DEVICE via qemu-nbd..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --connect="$DEVICE" "$DISK_FILE"
        else
            sudo qemu-nbd --connect="$DEVICE" "$DISK_FILE" >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to connect qcow2 image via qemu-nbd"
            exit 1
        fi

        sleep 3
        sudo partprobe "$DEVICE" >/dev/null 2>&1
        udevadm settle >/dev/null 2>&1
        sleep 2
    else
        log "Setting up loop device for $DISK_FILE..."
        if [ "$VERBOSE" -eq 1 ]; then
            DEVICE=$(sudo losetup -f --show "$DISK_FILE")
        else
            DEVICE=$(sudo losetup -f --show "$DISK_FILE" 2>/dev/null)
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create loop device for $DISK_FILE"
            exit 1
        fi
        sleep 1
        sudo partprobe "$DEVICE" >/dev/null 2>&1
        udevadm settle >/dev/null 2>&1
        sleep 1
    fi

    log "DEBUG: Using device: $DEVICE"

    # Get partition table information using parted with LC_ALL=C
    local PARTED_INFO
    PARTED_INFO=$(LC_ALL=C sudo parted -m "$DEVICE" unit B print 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read partition table from $DEVICE"
        cleanup_device "$DEVICE"
        exit 1
    fi
    log "DEBUG: PARTED_INFO: $PARTED_INFO"

    # Extract partition table
    local PARTITION_TABLE=$(echo "$PARTED_INFO" | awk -F':' '/^BYT;/ {print $6}' | tr '[:upper:]' '[:lower:]')
    if [ -z "$PARTITION_TABLE" ]; then
        warning "No partition table detected, defaulting to 'mbr'"
        PARTITION_TABLE="mbr"
    elif [ "$PARTITION_TABLE" = "msdos" ]; then
        PARTITION_TABLE="mbr"
    fi
    log "DEBUG: Detected PARTITION_TABLE: $PARTITION_TABLE"

    # Get filesystem information using blkid
    local BLKID_INFO
    BLKID_INFO=$(LC_ALL=C sudo blkid -c /dev/null "${DEVICE}"* 2>/dev/null)
    log "DEBUG: BLKID_INFO: $BLKID_INFO"

    log "Disk info: Name=$DISK_FILE, Format=$DISK_FORMAT, Size=$DISK_SIZE"
    log "Partition table type: $PARTITION_TABLE"

    # Write configuration to file
    {
        echo "#!/bin/bash"
        echo "DISK_NAME=\"$(basename "$DISK_FILE")\""
        echo "DISK_SIZE=\"$DISK_SIZE\""
        echo "DISK_FORMAT=\"$DISK_FORMAT\""
        echo "PARTITION_TABLE=\"$PARTITION_TABLE\""
        echo "PREALLOCATION=\"off\" # Note: Preallocation cannot be determined from disk image"
        echo "PARTITIONS=("
    } > "$CONFIG_FILE"

    # Parse partitions
    echo "$PARTED_INFO" | grep -E '^[0-9]+:' | while IFS=: read -r num start end size fs type name flags; do
        local size_h=$(convert_parted_size "$size")
        # Get filesystem from blkid
        local part_dev="${DEVICE}p${num}"
        local fs_norm=$(echo "$BLKID_INFO" | grep "$part_dev" | grep -oP 'TYPE="\K[^"]+' || echo "$fs")
        fs_norm=$(normalize_fs_type "$fs_norm" "$type" "$name")

        if [ "$PARTITION_TABLE" = "mbr" ]; then
            local part_type=""
            if [ "$num" -eq 3 ] && [ -z "$fs_norm" ] || [ "$type" = "extended" ] || [[ "$flags" =~ "extended" ]]; then
                part_type="extended"
            elif [ "$num" -ge 5 ]; then
                part_type="logical"
            else
                part_type="primary"
            fi
            echo "    \"${size_h}:${fs_norm}:${part_type}\"" >> "$CONFIG_FILE"
            log "Found partition: ${size_h} ($fs_norm, $part_type)"
        else
            echo "    \"${size_h}:${fs_norm}\"" >> "$CONFIG_FILE"
            log "Found partition: ${size_h} ($fs_norm)"
        fi
    done

    echo ")" >> "$CONFIG_FILE"
    chmod +x "$CONFIG_FILE"

    log "Configuration file '$CONFIG_FILE' generated successfully."

    # Clean up device
    cleanup_device "$DEVICE"
}

convert_parted_size() {
    local size="$1"
    local bytes="${size%B}"
    # Use LC_ALL=C to ensure consistent decimal point handling
    LC_ALL=C
    if [ $bytes -ge $((1024*1024*1024)) ]; then
        local size_g=$(echo "scale=2; $bytes / (1024*1024*1024)" | bc)
        local rounded_g=$(printf "%.0f" "$size_g")
        # Round up if within 0.3GB of the next integer to match original sizes
        if [ $(echo "$size_g >= $rounded_g - 0.3" | bc) -eq 1 ]; then
            rounded_g=$((rounded_g + 1))
        fi
        echo "${rounded_g}G"
    elif [ $bytes -ge $((1024*1024)) ]; then
        local size_m=$(echo "scale=2; $bytes / (1024*1024)" | bc)
        local rounded_m=$(printf "%.0f" "$size_m")
        # Round up if within 50MB of the next integer
        if [ $(echo "$size_m >= $rounded_m - 50" | bc) -eq 1 ]; then
            rounded_m=$((rounded_m + 1))
        fi
        echo "${rounded_m}M"
    else
        local size_k=$(echo "scale=2; $bytes / 1024" | bc)
        local rounded_k=$(printf "%.0f" "$size_k")
        echo "${rounded_k}K"
    fi
}

# Helper function to convert parted size to bytes for calculations
parted_size_to_bytes() {
    local size_str=$1
    
    # Remove trailing 'B' if present
    size_str=${size_str%B}
    
    if [[ "$size_str" =~ TB$ ]]; then
        local num=${size_str%TB}
        echo "$((${num%.*} * 1000 * 1000 * 1000 * 1000))"  # TB = 1000^4 in parted
    elif [[ "$size_str" =~ GB$ ]]; then
        local num=${size_str%GB}
        echo "$((${num%.*} * 1000 * 1000 * 1000))"  # GB = 1000^3 in parted
    elif [[ "$size_str" =~ MB$ ]]; then
        local num=${size_str%MB}
        echo "$((${num%.*} * 1000 * 1000))"  # MB = 1000^2 in parted
    elif [[ "$size_str" =~ kB$ ]]; then
        local num=${size_str%kB}
        echo "$((${num%.*} * 1000))"  # kB = 1000 in parted
    else
        # Assume it's already in bytes
        echo "${size_str%.*}"
    fi
}

# Show help
show_help() {
    cat << EOF
Virtual Disk Creator - Enhanced Edition

Usage:
  $0                      Start in interactive mode
  $0 <config_file>        Use configuration file
  $0 --reverse <disk_image> Generate config.sh from an existing disk image
  $0 --info <disk_image>  Print disk information, partition table type, and partitions in a nice format
  $0 -h, --help           Show this help
  VERBOSE=1 $0            Enable verbose output for debugging

Features:
  - UEFI (GPT) and Legacy BIOS (MBR) support
  - Multiple disk formats (qcow2, raw)
  - Fixed/sparse disk allocation
  - Multiple filesystem support (ext4, ext3, xfs, btrfs, ntfs, fat16, vfat, fat32, none)
  - Linux swap partition support
  - MBR partition type support (primary, extended, logical)
  - Interactive and configuration file modes
  - Verbose mode for detailed command output (set VERBOSE=1)
  - Displays final partition table in a tabular format after creation
  - Generate config.sh from an existing disk image (--reverse)
  - Print disk information in a nice format (--info)

Configuration file example (GPT):
  DISK_NAME="example.qcow2"
  DISK_SIZE="10G"
  DISK_FORMAT="qcow2"
  PARTITION_TABLE="gpt"
  PREALLOCATION="off"
  PARTITIONS=(
      "2G:ext4"
      "1G:swap"
      "500M:fat32"
      "remaining:vfat"
  )

Configuration file example (MBR):
  DISK_NAME="example.qcow2"
  DISK_SIZE="10G"
  DISK_FORMAT="qcow2"
  PARTITION_TABLE="mbr"
  PREALLOCATION="off"
  PARTITIONS=(
      "2G:ext4:primary"
      "1G:swap:primary"
      "500M:fat32:primary"
      "remaining:none:extended"
  )

EOF
}

# Function to display disk information
info_disk() {
    local DISK_IMAGE=$1

    if [ ! -f "${DISK_IMAGE}" ]; then
        error "Disk image '${DISK_IMAGE}' not found."
        exit 1
    fi

    log "Disk Information for: ${DISK_IMAGE}"
    echo

    # Get disk format and size using qemu-img
    local QEMU_INFO
    QEMU_INFO=$(qemu-img info "${DISK_IMAGE}" 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read disk image info for ${DISK_IMAGE}"
        exit 1
    fi

    local DISK_NAME=$(basename "${DISK_IMAGE}")
    local DISK_FORMAT=$(echo "$QEMU_INFO" | grep "file format" | awk '{print $3}')
    local disk_size_bytes=$(echo "$QEMU_INFO" | grep "virtual size" | grep -oP '\(\K[0-9]+(?=\s*bytes)')
    local DISK_SIZE=$(bytes_to_readable "$disk_size_bytes")
    local disk_size_human=$(echo "$QEMU_INFO" | grep "virtual size" | awk '{for(i=3;i<=NF;i++) if($i !~ /^\(/) printf "%s ", $i}' | sed 's/,.*$//')
    
    # Get allocated size
    local actual_size_bytes=$(echo "$QEMU_INFO" | grep "disk size" | grep -oP '\(\K[0-9]+(?=\s*bytes)' || echo "$disk_size_bytes")
    local actual_size=$(bytes_to_readable "$actual_size_bytes")

    echo -e "${BLUE}=== DISK IMAGE INFORMATION ===${NC}"
    printf "%-20s %s\n" "File name:" "$DISK_NAME"
    printf "%-20s %s\n" "File format:" "$DISK_FORMAT"
    printf "%-20s %s (%s bytes)\n" "Virtual size:" "$disk_size_human" "$disk_size_bytes"
    printf "%-20s %s (%s bytes)\n" "Actual size:" "$actual_size" "$actual_size_bytes"
    
    # Calculate compression ratio for qcow2
    if [ "$DISK_FORMAT" = "qcow2" ] && [ "$actual_size_bytes" -ne "$disk_size_bytes" ]; then
        local compression_ratio=$(echo "scale=1; $actual_size_bytes * 100 / $disk_size_bytes" | bc 2>/dev/null || echo "N/A")
        if [ "$compression_ratio" != "N/A" ]; then
            printf "%-20s %s%%\n" "Space usage:" "$compression_ratio"
        fi
    fi
    
    echo

    # Set up device to read partition table
    local DEVICE=""
    if [ "$DISK_FORMAT" = "qcow2" ]; then
        log "Loading qemu-nbd kernel module..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo modprobe nbd max_part=16
        else
            sudo modprobe nbd max_part=16 >/dev/null 2>&1
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

        log "Connecting to device for partition analysis..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --connect="$DEVICE" "$DISK_IMAGE"
        else
            sudo qemu-nbd --connect="$DEVICE" "$DISK_IMAGE" >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to connect qcow2 image via qemu-nbd"
            exit 1
        fi

        sleep 3
    else
        log "Setting up loop device for partition analysis..."
        if [ "$VERBOSE" -eq 1 ]; then
            DEVICE=$(sudo losetup -f --show "${DISK_IMAGE}")
        else
            DEVICE=$(sudo losetup -f --show "${DISK_IMAGE}" 2>/dev/null)
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create loop device for ${DISK_IMAGE}"
            exit 1
        fi
        sleep 1
    fi

    # Wait for device to be ready and probe partitions
    sudo partprobe "${DEVICE}" >/dev/null 2>&1
    udevadm settle >/dev/null 2>&1
    sleep 2

    # Get partition table information
    local PARTED_INFO
    PARTED_INFO=$(LC_ALL=C sudo parted -s "${DEVICE}" print 2>/dev/null)
    if [ $? -ne 0 ]; then
        warning "Failed to read partition table from ${DEVICE}"
        cleanup_device "$DEVICE"
        echo -e "${YELLOW}No partition table found or disk is not partitioned.${NC}"
        exit 0
    fi

    local PARTITION_TABLE=$(echo "$PARTED_INFO" | grep -E "^Partition Table:" | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    
    echo -e "${BLUE}=== PARTITION TABLE INFORMATION ===${NC}"
    printf "%-20s %s\n" "Partition table:" "${PARTITION_TABLE^^}"
    echo

    # Check if there are any partitions
    local partition_count=$(echo "$PARTED_INFO" | grep -c "^[ ]*[0-9]")
    
    if [ "$partition_count" -eq 0 ]; then
        echo -e "${YELLOW}No partitions found on this disk.${NC}"
        cleanup_device "$DEVICE"
        exit 0
    fi

    # Get filesystem information using blkid
    local blkid_info=""
    blkid_info=$(sudo blkid "${DEVICE}"* 2>/dev/null || true)

    echo -e "${BLUE}=== PARTITION INFORMATION ===${NC}"
    
    # Generate table header
    if [ "$PARTITION_TABLE" = "mbr" ]; then
        printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n" "Number" "Start" "End" "Size" "File system" "Type" "Name"
        printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n" "------" "-------" "-------" "-------" "-----------" "-------" "----"
    else
        printf "%-8s %-12s %-12s %-12s %-12s %s\n" "Number" "Start" "End" "Size" "File system" "Name"
        printf "%-8s %-12s %-12s %-12s %-12s %s\n" "------" "-------" "-------" "-------" "-----------" "----"
    fi

    # Parse and display partition information
    echo "$PARTED_INFO" | awk -v part_table="$PARTITION_TABLE" -v blkid_info="$blkid_info" -v device="$DEVICE" '
        /^[ ]*[0-9]+/ {
            num=$1; start=$2; end=$3; size=$4
            fs=""; type=""; name=""
            
            # Parse remaining fields
            for(i=5; i<=NF; i++) {
                if ($i ~ /^(primary|logical|extended)$/) {
                    type=$i
                } else if ($i !~ /^(boot|swap|lvm|raid|lba|legacy_boot|hidden)$/ && fs == "") {
                    fs=$i
                }
            }
            
            # Get filesystem from blkid if available
            part_device = device "p" num
            cmd = "echo \"" blkid_info "\" | grep \"^" part_device ":\" | head -1"
            cmd | getline blkid_line
            close(cmd)
            
            if (blkid_line != "") {
                if (match(blkid_line, /TYPE="([^"]*)"/, arr)) {
                    actual_fs = arr[1]
                    if (actual_fs == "linux-swap" || actual_fs == "linux-swap(v1)") {
                        fs = "swap"
                    } else if (actual_fs != "") {
                        fs = actual_fs
                    }
                }
            }
            
            # Clean up filesystem name
            if (fs == "" || fs == "unknown") fs = "none"
            if (fs == "linux-swap(v1)" || fs == "linux-swap") fs = "swap"
            
            # Determine partition name/description
            if (fs == "swap") {
                name = "Linux swap"
            } else if (fs == "ext4" || fs == "ext3" || fs == "ext2" || fs == "xfs" || fs == "btrfs") {
                name = "Linux filesystem"
            } else if (fs == "ntfs" || fs == "vfat" || fs == "fat16" || fs == "fat32") {
                name = "Microsoft basic data"
            } else if (fs == "none") {
                name = "Unformatted"
            } else {
                name = fs " filesystem"
            }
            
            # Set default type for GPT
            if (part_table == "gpt" && type == "") {
                type = "N/A"
            } else if (part_table == "mbr" && type == "") {
                type = "primary"
            }
            
            # Print the row
            if (part_table == "mbr") {
                printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", num, start, end, size, fs, type, name
            } else {
                printf "%-8s %-12s %-12s %-12s %-12s %s\n", num, start, end, size, fs, name
            }
        }'

    echo
    success "Disk information displayed successfully."
    
    # Clean up
    cleanup_device "$DEVICE"
}

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