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