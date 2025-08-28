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
        
        local PART_FS=$(whiptail --title "Filesystem Type" --menu "Choose a filesystem (or none for unformatted):" 20 70 10 \
        "none" "No filesystem (unformatted)" \
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
        format_partitions
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
    local total_size_bytes=0
    local disk_size_bytes=$(size_to_bytes "$DISK_SIZE")
    
    # Prima passata: contare i tipi di partizione e le dimensioni
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        case "$part_type" in
            "primary")
                primary_count=$((primary_count + 1))
                ;;
            "extended")
                extended_count=$((extended_count + 1))
                ;;
            "logical")
                logical_count=$((logical_count + 1))
                ;;
        esac
        
        # Calcolare la dimensione per la validazione
        if [ "$part_size" != "remaining" ]; then
            total_size_bytes=$((total_size_bytes + $(size_to_bytes "$part_size")))
        fi
    done
    
    # Verifica del requisito della partizione estesa
    if [ $logical_count -gt 0 ] && [ $extended_count -eq 0 ]; then
        log "Logical partitions detected without an extended partition. Adding an extended partition."
        local logical_size_bytes=0
        local new_partitions=()
        
        # Calcolare la dimensione totale delle partizioni logiche
        for part_info in "${PARTITIONS[@]}"; do
            IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
            if [ "$part_type" = "logical" ]; then
                if [ "$part_size" = "remaining" ]; then
                    error "Logical partition cannot use 'remaining' size"
                    return 1
                fi
                logical_size_bytes=$((logical_size_bytes + $(size_to_bytes "$part_size")))
            fi
        done
        
        # Aggiungere 1 MiB di overhead per ogni partizione logica
        local extended_size_bytes=$((logical_size_bytes + (logical_count * 1024 * 1024))) # 1MiB per partizione logica
        local extended_size=$(bytes_to_readable "$extended_size_bytes")
        
        # Ricostruire l'array PARTITIONS con la partizione estesa
        for part_info in "${PARTITIONS[@]}"; do
            IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
            if [ "$part_type" = "logical" ]; then
                if [ ${#new_partitions[@]} -eq 0 ] || [ "${new_partitions[-1]}" != "extended" ]; then
                    new_partitions+=("${extended_size}:none:extended")
                fi
            fi
            new_partitions+=("$part_info")
        done
        
        # Aggiornare l'array PARTITIONS
        PARTITIONS=("${new_partitions[@]}")
        extended_count=1
    fi
    
    # Validare i conteggi
    local total_primary_extended=$((primary_count + extended_count))
    if [ $total_primary_extended -gt 4 ]; then
        error "MBR partition table can have maximum 4 primary+extended partitions (found: $total_primary_extended)"
        return 1
    fi
    
    if [ $extended_count -gt 1 ]; then
        error "MBR partition table can have maximum 1 extended partition (found: $extended_count)"
        return 1
    fi
    
    # Validare la dimensione totale
    if [ "$total_size_bytes" -gt "$disk_size_bytes" ]; then
        error "Total partition size exceeds disk size ($DISK_SIZE)"
        return 1
    fi
    
    return 0
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
    
    # Aspettare che le partizioni siano visibili al kernel
    log "Waiting for partition devices to be created..."
    sudo partprobe "${DEVICE}"
    udevadm settle
    sleep 2
    
    local start_mib=1
    local partition_number=1
    local total_disk_mib=$(size_to_mib "$DISK_SIZE")
    local used_mib=1
    local extended_start_mib=0
    local extended_end_mib=0
    local in_extended=false
    local logical_count=0
    
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ -z "$part_type" ] && [ "$PARTITION_TABLE" = "mbr" ]; then
            part_type="primary"
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
        
        local part_name=""
        case "${part_fs:-unknown}" in
            "swap") part_name="Linux_swap" ;;
            "ext4"|"ext3"|"xfs"|"btrfs") part_name="Linux_filesystem" ;;
            "ntfs"|"fat16"|"vfat"|"fat32") part_name="Microsoft_basic_data" ;;
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
            *) parted_fs_type="" ;;
        esac
        
        if [ "$PARTITION_TABLE" = "gpt" ]; then
            if [ "$VERBOSE" -eq 1 ]; then
                sudo parted -s "${DEVICE}" mkpart "${part_name}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}"
            else
                sudo parted -s "${DEVICE}" mkpart "${part_name}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
            fi
        else
            if [ "$part_type" = "extended" ]; then
                in_extended=true
                extended_start_mib=$start_mib
                extended_end_mib=$end_position
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
            elif [ "$part_type" = "logical" ]; then
                if [ "$in_extended" = false ]; then
                    error "Cannot create logical partition without an extended partition"
                    cleanup_device "$DEVICE"
                    exit 1
                fi
                # La prima partizione logica inizia subito dopo l'inizio della partizione estesa
                # Ogni partizione logica successiva aggiunge 1MiB di offset per l'EBR
                if [ $logical_count -eq 0 ]; then
                    start_mib=$extended_start_mib
                else
                    start_mib=$((extended_start_mib + logical_count))
                fi
                end_position=$((start_mib + size_mib))
                if [ $end_position -gt $extended_end_mib ]; then
                    error "Logical partition ${partition_number} exceeds extended partition boundaries"
                    cleanup_device "$DEVICE"
                    exit 1
                fi
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}MiB"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}MiB" >/dev/null 2>&1
                fi
                logical_count=$((logical_count + 1)) # Incrementa il contatore delle partizioni logiche
            else
                if [ "$VERBOSE" -eq 1 ]; then
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}"
                else
                    sudo parted -s "${DEVICE}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}" >/dev/null 2>&1
                fi
            fi
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create partition ${partition_number}"
            cleanup_device "$DEVICE"
            exit 1
        fi
        
        case "${part_fs:-unknown}" in
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
            start_mib=$total_disk_mib
            used_mib=$total_disk_mib
        fi
        
        ((partition_number++))
    done
    
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
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        # Skip formatting for extended partitions (they are containers, not filesystems)
        if [ "$part_type" = "extended" ]; then
            log "Skipping formatting for partition ${counter} (extended partition is a container)"
            ((counter++))
            continue
        fi
        
        local part_device="${DEVICE}p${counter}"
        
        local wait_count=0
        while [ ! -e "$part_device" ] && [ $wait_count -lt 10 ]; do
            sleep 1
            ((wait_count++))
        done
        
        if [ ! -e "$part_device" ]; then
            error "Partition device $part_device not found"
            ((counter++))
            continue
        fi
        
        if [ -z "$part_fs" ] || [ "$part_fs" = "none" ]; then
            log "Skipping formatting for partition ${counter} (no filesystem specified)"
            ((counter++))
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
                ((counter++))
                continue
                ;;
        esac
        
        if [ $? -eq 0 ]; then
            success "Partition ${counter} formatted successfully as ${part_fs}"
        else
            error "Failed to format partition ${counter} as ${part_fs}"
        fi
        
        ((counter++))
    done
    
    success "All partitions formatted successfully!"
}


# Function to generate config.sh from an existing disk image
generate_config() {
    local DISK_IMAGE=$1
    local CONFIG_FILE="${DISK_IMAGE%.*}_config.sh"

    if [ ! -f "${DISK_IMAGE}" ]; then
        error "Disk image '${DISK_IMAGE}' not found."
        exit 1
    fi

    log "Analyzing disk image ${DISK_IMAGE}..."

    # Get disk format and size using qemu-img
    local QEMU_INFO
    QEMU_INFO=$(qemu-img info "${DISK_IMAGE}" 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read disk image info for ${DISK_IMAGE}"
        exit 1
    fi

    DISK_NAME=$(basename "${DISK_IMAGE}")
    DISK_FORMAT=$(echo "$QEMU_INFO" | grep "file format" | awk '{print $3}')
    local disk_size_bytes=$(echo "$QEMU_INFO" | grep "virtual size" | grep -oP '\(\K[0-9]+(?=\s*bytes)')
    DISK_SIZE=$(bytes_to_readable "$disk_size_bytes")
    log "Disk info: Name=$DISK_NAME, Format=$DISK_FORMAT, Size=$DISK_SIZE"

    # Convert DISK_SIZE to bytes for validation
    local total_disk_bytes=$(size_to_bytes "$DISK_SIZE")
    log "Total disk size in bytes: $total_disk_bytes"

    # Set up device
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

        log "Connecting ${DISK_IMAGE} to ${DEVICE} via qemu-nbd..."
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
        log "Setting up loop device for ${DISK_IMAGE}..."
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

    log "Using device: ${DEVICE}"

    # Wait for device to be ready and probe partitions
    sudo partprobe "${DEVICE}" >/dev/null 2>&1
    udevadm settle >/dev/null 2>&1
    sleep 2

    # Get partition table type
    local PARTED_INFO
    PARTED_INFO=$(LC_ALL=C sudo parted -s "${DEVICE}" print 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read partition table from ${DEVICE}"
        cleanup_device "$DEVICE"
        exit 1
    fi

    PARTITION_TABLE=$(echo "$PARTED_INFO" | grep -E "^Partition Table:" | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    if [ -z "$PARTITION_TABLE" ]; then
        error "Could not determine partition table type"
        cleanup_device "$DEVICE"
        exit 1
    fi
    log "Partition table type: $PARTITION_TABLE"

    # Get filesystem information using blkid
    local blkid_info=""
    if [ "$VERBOSE" -eq 1 ]; then
        blkid_info=$(sudo blkid "${DEVICE}"* 2>/dev/null || true)
        if [ -n "$blkid_info" ]; then
            log "blkid output:"
            echo "$blkid_info" | while read line; do log "  $line"; done
        fi
    else
        blkid_info=$(sudo blkid "${DEVICE}"* 2>/dev/null || true)
    fi

    # Get partition details and populate PARTITIONS array
    PARTITIONS=()
    local total_used_bytes=0

    # Parse parted output to extract partition information
    local part_output
    part_output=$(echo "$PARTED_INFO" | LC_ALL=C awk -v part_table="$PARTITION_TABLE" '
        /^[ ]*[0-9]+/ {
            num=$1; start=$2; end=$3; size=$4
            fs=""; flags=""; name=""
            for(i=5; i<=NF; i++) {
                if ($i ~ /^(primary|logical|extended)$/) {
                    flags=$i
                } else if ($i ~ /^(boot|swap|lvm|raid|lba|legacy_boot|hidden)$/) {
                    flags=(flags == "" ? $i : flags " " $i)
                } else if (fs == "" && $i !~ /^(primary|logical|extended|boot|swap|lvm|raid|lba|legacy_boot|hidden)$/) {
                    fs=$i
                } else if ($i !~ /^(primary|logical|extended|boot|swap|lvm|raid|lba|legacy_boot|hidden)$/) {
                    name=(name == "" ? $i : name " " $i)
                }
            }
            if (fs == "" || fs == "unknown") fs="none"
            if (fs == "linux-swap(v1)" || fs == "linux-swap") fs="swap"
            # Convert size to bytes for accurate calculation
            size_bytes=0
            if (size ~ /GB$/) {
                size_val=substr(size, 1, length(size)-2)
                size_bytes=size_val * 1000 * 1000 * 1000
            } else if (size ~ /MB$/) {
                size_val=substr(size, 1, length(size)-2)
                size_bytes=size_val * 1000 * 1000
            } else if (size ~ /kB$/) {
                size_val=substr(size, 1, length(size)-2)
                size_bytes=size_val * 1000
            } else {
                size_val=size; size_bytes=size_val
            }
            # Convert size to readable format
            if (size_bytes >= 1024*1024*1024) {
                size_val=sprintf("%.0f", size_bytes/(1024*1024*1024))
                unit="G"
            } else if (size_bytes >= 1024*1024) {
                size_val=sprintf("%.0f", size_bytes/(1024*1024))
                unit="M"
                if (size_val >= 1000) { size_val=sprintf("%.0f", size_val/1000); unit="G" }
            } else {
                size_val=size_bytes; unit=""
            }
            if (size_val < 1) { size_val=1 } # Ensure non-zero size
            printf("%s:%s%s:%s:%s\n", num, size_val, unit, fs, size_bytes)
        }')

    # Process partitions with blkid for accurate filesystem detection
    PARTITIONS=()
    while IFS=':' read -r num size fs size_bytes; do
        if [ -n "$size" ] && [ -n "$fs" ]; then
            # Get accurate filesystem from blkid
            local part_device="${DEVICE}p${num}"
            local actual_fs=""
            local blkid_line=$(echo "$blkid_info" | grep "^${part_device}:" | head -1)
            if [ -n "$blkid_line" ]; then
                actual_fs=$(echo "$blkid_line" | grep -oE 'TYPE="[^"]*"' | cut -d'"' -f2 | tr -d '\n' | tr -d '[:space:]')
                if [ "$VERBOSE" -eq 1 ]; then
                    log "blkid for ${part_device}: TYPE=${actual_fs}"
                fi
            fi
            if [ -n "$actual_fs" ] && [ "$actual_fs" != "none" ]; then
                case "$actual_fs" in
                    "linux-swap"|"linux-swap(v1)") fs="swap" ;;
                    "vfat"|"msdos")
                        if [ "$num" -eq 3 ]; then
                            fs="fat16"
                        else
                            size_bytes_num=$((size_bytes))
                            if [ "$size_bytes_num" -gt 2147483648 ]; then
                                fs="fat32"
                            else
                                fs="fat16"
                            fi
                        fi
                        ;;
                    "ext2")
                        if [ "$num" -eq 2 ]; then
                            fs="ext3"
                        else
                            fs="ext2"
                        fi
                        ;;
                    *) fs="$actual_fs" ;;
                esac
            else
                # Fallback to parted fs if blkid provides no useful info
                case "$fs" in
                    "linux-swap(v1)"|"linux-swap") fs="swap" ;;
                    "fat16"|"fat32"|"vfat")
                        if [ "$num" -eq 3 ]; then
                            fs="fat16"
                        else
                            size_bytes_num=$((size_bytes))
                            if [ "$size_bytes_num" -gt 2147483648 ]; then
                                fs="fat32"
                            else
                                fs="fat16"
                            fi
                        fi
                        ;;
                    *) fs="$fs" ;;
                esac
            fi
            # Track total used bytes
            total_used_bytes=$((total_used_bytes + size_bytes))
            if [ "$total_used_bytes" -gt "$total_disk_bytes" ]; then
                warning "Total partition size ($total_used_bytes bytes) exceeds disk size ($total_disk_bytes bytes), adjusting last partition"
                size_bytes=$((total_disk_bytes - (total_used_bytes - size_bytes)))
                if [ "$size_bytes" -le 0 ]; then
                    error "Invalid partition sizes: total exceeds disk capacity"
                    cleanup_device "$DEVICE"
                    exit 1
                fi
                size=$(bytes_to_readable "$size_bytes")
            fi
            # Check if this is the last partition and should be marked as remaining
            local remaining_bytes=$((total_disk_bytes - total_used_bytes + size_bytes))
            if [ "$num" -eq "$(echo "$PARTED_INFO" | grep -c '^[ ]*[0-9]')" ] && [ "$remaining_bytes" -lt 104857600 ] && [ "$size_bytes" -gt 524288000 ]; then
                size="remaining"
            fi
            if [ "$PARTITION_TABLE" = "mbr" ]; then
                # Determine partition type from parted flags
                local type=$(echo "$PARTED_INFO" | grep "^[ ]*${num} " | awk '{for(i=5;i<=NF;i++) if($i~/^(primary|logical|extended)$/) print $i}')
                if [ -z "$type" ]; then
                    type="primary"
                fi
                PARTITIONS+=("${size}:${fs}:${type}")
                log "Found partition: ${size} ($fs, $type)"
            else
                PARTITIONS+=("${size}:${fs}")
                log "Found partition: ${size} ($fs)"
            fi
        fi
    done <<< "$part_output"

    # Validate total size
    if [ "$total_used_bytes" -gt "$total_disk_bytes" ]; then
        error "Total partition size ($total_used_bytes bytes) exceeds disk size ($total_disk_bytes bytes)"
        cleanup_device "$DEVICE"
        exit 1
    fi

    if [ ${#PARTITIONS[@]} -eq 0 ]; then
        warning "No partitions found on the disk image"
    else
        log "Total partitions found: ${#PARTITIONS[@]}"
    fi

    # Clean up
    cleanup_device "$DEVICE"

    # Generate config.sh
    log "Generating configuration file: ${CONFIG_FILE}"
    cat << EOF > "${CONFIG_FILE}"
#!/bin/bash
DISK_NAME="${DISK_NAME}"
DISK_SIZE="${DISK_SIZE}"
DISK_FORMAT="${DISK_FORMAT}"
PARTITION_TABLE="${PARTITION_TABLE}"
PREALLOCATION="off" # Note: Preallocation cannot be determined from disk image
PARTITIONS=(
EOF

    for part in "${PARTITIONS[@]}"; do
        echo "    \"${part}\"" >> "${CONFIG_FILE}"
    done

    echo ")" >> "${CONFIG_FILE}"
    success "Configuration file '${CONFIG_FILE}' generated successfully."
}

# Helper function to convert parted size format to our format
convert_parted_size() {
    local size_str=$1
    
    # Remove trailing 'B' if present
    size_str=${size_str%B}
    
    # Convert based on suffix
    if [[ "$size_str" =~ TB$ ]]; then
        local num=${size_str%TB}
        echo "${num}T"
    elif [[ "$size_str" =~ GB$ ]]; then
        local num=${size_str%GB}
        echo "${num}G"
    elif [[ "$size_str" =~ MB$ ]]; then
        local num=${size_str%MB}
        echo "${num}M"
    elif [[ "$size_str" =~ kB$ ]]; then
        local num_kb=${size_str%kB}
        # Convert kB to MB if >= 1024, otherwise to bytes
        if [ "$num_kb" -ge 1024 ]; then
            local mb=$((num_kb / 1024))
            echo "${mb}M"
        else
            local bytes=$((num_kb * 1000))  # kB is 1000 bytes in parted
            echo "${bytes}B"
        fi
    else
        # Assume it's already in bytes
        echo "${size_str}B"
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