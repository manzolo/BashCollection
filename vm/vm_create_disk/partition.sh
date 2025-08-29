create_partitions() {
    declare -g DEVICE

    # Setup device
    setup_device
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # Create partition table
    create_partition_table "$DEVICE"
    if [ $? -ne 0 ]; then
        cleanup_device "$DEVICE"
        exit 1
    fi
    
    # Calculate sizes
    IFS=':' read -r total_disk_mib logical_total_mib logical_overhead_mib <<< $(calculate_partition_sizes)
    
    # Create primary and extended partitions
    IFS=':' read -r next_partition_number start_mib <<< $(create_primary_partitions \
        "$DEVICE" 1 "$total_disk_mib" "$logical_total_mib" "$logical_overhead_mib")
    
    if [ $? -ne 0 ]; then
        cleanup_device "$DEVICE"
        exit 1
    fi
    
    # Create logical partitions if needed
    if [ $(echo "${PARTITIONS[*]}" | grep -c ":logical") -gt 0 ]; then
        create_logical_partitions "$DEVICE" "$start_mib" "$total_disk_mib"
        if [ $? -ne 0 ]; then
            cleanup_device "$DEVICE"
            exit 1
        fi
    fi
    
    # Final cleanup and verification
    finalize_partitions "$DEVICE"
}

finalize_partitions() {
    local device="$1"
    
    log "Waiting for all partitions to be recognized..."
    sleep 3
    sudo partprobe "${device}" >/dev/null 2>&1
    sleep 2
    
    # Debug info
    log "DEBUG: Checking partition devices:"
    ls -la "${device}"* 2>/dev/null | while IFS= read -r line; do log "DEBUG: $line"; done
    
    # Save device info for cleanup
    echo "${device}:${DISK_FORMAT}" > /tmp/disk_creator_device_info
}

format_partitions() {
    local DEVICE="$1"
    local partition_number=1
    local logical_number=5

    log "Formatting partitions on $DEVICE..."

    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        # Determine device path
        if [ "$part_type" = "logical" ]; then
            local part_dev="${DEVICE}p${logical_number}"
            ((logical_number++))
        else
            local part_dev="${DEVICE}p${partition_number}"
            ((partition_number++))
        fi

        # Format the partition
        format_single_partition "$part_dev" "$part_fs"
    done

    finalize_formatting "$DEVICE"
}

format_single_partition() {
    local part_dev="$1"
    local part_fs="$2"
    
    if [ ! -b "$part_dev" ]; then
        error "Partition device $part_dev does not exist"
        return 1
    fi

    log "Formatting $part_dev as $part_fs..."
    
    local success=0
    case "$part_fs" in
        "swap") run_format_command "sudo mkswap $part_dev" ;;
        "ext4") run_format_command "sudo mkfs.ext4 $part_dev" ;;
        "ext3") run_format_command "sudo mkfs.ext3 $part_dev" ;;
        "xfs") run_format_command "sudo mkfs.xfs $part_dev" ;;
        "btrfs") run_format_command "sudo mkfs.btrfs $part_dev" ;;
        "fat32"|"vfat") run_format_command "sudo mkfs.vfat -F 32 $part_dev" ;;
        "fat16") run_format_command "sudo mkfs.vfat -F 16 $part_dev" ;;
        "ntfs") run_format_command "sudo mkfs.ntfs -f $part_dev" ;;
        *) 
            log "Skipping formatting for $part_dev (no filesystem specified)"
            return 0
            ;;
    esac
    
    success=$?
    
    if [ $success -eq 0 ]; then
        log "Successfully formatted $part_dev as $part_fs"
    else
        error "Failed to format $part_dev as $part_fs"
    fi
    
    return $success
}

run_format_command() {
    local cmd="$1"
    
    if [ "$VERBOSE" -eq 1 ]; then
        $cmd
    else
        $cmd >/dev/null 2>&1
    fi
    
    return $?
}

create_partition_table() {
    local device="$1"
    
    if [ "$PARTITION_TABLE" = "gpt" ]; then
        log "Creating GPT partition table..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${device}" mklabel gpt
        else
            sudo parted -s "${device}" mklabel gpt >/dev/null 2>&1
        fi
    else
        log "Creating MBR partition table..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${device}" mklabel msdos
        else
            sudo parted -s "${device}" mklabel msdos >/dev/null 2>&1
        fi
    fi
    
    if [ $? -ne 0 ]; then
        error "Failed to create partition table"
        return 1
    fi
    
    wait_for_partitions "$device"
    return 0
}

wait_for_partitions() {
    local device="$1"
    log "Waiting for partition devices to be created..."
    sudo partprobe "${device}"
    udevadm settle
    sleep 2
}

create_primary_partitions() {
    local device="$1"
    local start_mib="$2"
    local total_disk_mib="$3"
    local logical_total_mib="$4"
    local logical_overhead_mib="$5"
    
    local partition_number=1
    local used_mib="$start_mib"
    
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        # Skip logical partitions in first pass
        if [ "$part_type" = "logical" ]; then
            continue
        fi

        if [ -z "$part_type" ] && [ "$PARTITION_TABLE" = "mbr" ]; then
            part_type="primary"
        fi

        create_single_partition "$device" "$part_size" "$part_fs" "$part_type" \
            "$partition_number" "$start_mib" "$total_disk_mib" \
            "$logical_total_mib" "$logical_overhead_mib"
        
        if [ $? -ne 0 ]; then
            return 1
        fi
        
        # Update positions
        start_mib=$(sudo parted -s "${device}" print | awk -v num="$partition_number" '$1 == num {print int($3)}')
        used_mib="$start_mib"
        ((partition_number++))
    done
    
    echo "$partition_number:$start_mib"
}

create_single_partition() {
    local device="$1"
    local part_size="$2"
    local part_fs="$3"
    local part_type="$4"
    local partition_number="$5"
    local start_mib="$6"
    local total_disk_mib="$7"
    local logical_total_mib="$8"
    local logical_overhead_mib="$9"
    
    log "Creating partition ${partition_number}: ${part_size} (${part_fs:-none}, ${part_type:-none})"
    
    local size_mib
    local end_position
    
    if [ "$part_size" = "remaining" ]; then
        size_mib=$((total_disk_mib - start_mib))
        if [ $size_mib -le 0 ]; then
            error "No remaining space for partition ${partition_number}"
            return 1
        fi
        end_position="100%"
    else
        size_mib=$(size_to_mib "$part_size")
        end_position=$((start_mib + size_mib))
        if [ $end_position -gt $total_disk_mib ]; then
            warning "Partition ${partition_number} size exceeds remaining disk space, adjusting to fit"
            size_mib=$((total_disk_mib - start_mib))
            end_position="100%"
        fi
    fi
    
    # Validate extended partition size
    if [ "$part_type" = "extended" ] && [ "$part_size" != "remaining" ]; then
        local extended_size_mib=$(size_to_mib "$part_size")
        if [ $((logical_total_mib + logical_overhead_mib)) -gt $extended_size_mib ]; then
            error "Extended partition size too small for logical partitions"
            return 1
        fi
    fi
    
    local parted_args=()
    local part_name=$(get_partition_name "$part_fs")
    local parted_fs_type=$(get_parted_fs_type "$part_fs")
    
    if [ "$PARTITION_TABLE" = "gpt" ]; then
        if [ "$part_fs" = "msr" ]; then
            parted_args=("${device}" mkpart "${part_name}" "" "${start_mib}MiB" "${end_position}")
        else
            parted_args=("${device}" mkpart "${part_name}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}")
        fi
    else
        if [ "$part_type" = "extended" ]; then
            parted_args=("${device}" mkpart "${part_type}" "${start_mib}MiB" "${end_position}")
        else
            parted_args=("${device}" mkpart "${part_type}" "${parted_fs_type}" "${start_mib}MiB" "${end_position}")
        fi
    fi
    
    if [ "$VERBOSE" -eq 1 ]; then
        sudo parted -s "${parted_args[@]}"
    else
        sudo parted -s "${parted_args[@]}" >/dev/null 2>&1
    fi
    
    if [ $? -ne 0 ]; then
        error "Failed to create partition ${partition_number}"
        return 1
    fi
    
    return 0
}

create_logical_partitions() {
    local device="$1"
    local extended_start_mib="$2"
    local total_disk_mib="$3"
    
    log "Creating logical partitions..."
    
    # Get extended partition boundaries
    local extended_info=$(sudo parted -s "${device}" print | awk '/extended/ {print int($2) ":" int($3)}')
    if [ -z "$extended_info" ]; then
        error "Extended partition not found for logical partitions"
        return 1
    fi
    
    IFS=':' read -r extended_start_mib extended_end_mib <<< "$extended_info"
    local logical_start_mib=$((extended_start_mib + 1)) # Start logical partitions after EBR
    
    local logical_number=5
    
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        if [ "$part_type" != "logical" ]; then
            continue
        fi

        log "Creating logical partition ${logical_number}: ${part_size} (${part_fs})"
        
        local parted_fs_type=$(get_parted_fs_type "$part_fs")
        local part_end_position
        
        # Calculate end position
        if [ "$part_size" = "remaining" ]; then
            part_end_position=$((extended_end_mib - 1)) # Leave 1 MiB for EBR
        else
            local size_mib=$(size_to_mib "$part_size")
            part_end_position=$((logical_start_mib + size_mib))
            
            if [ $part_end_position -gt $((extended_end_mib - 1)) ]; then
                error "Logical partition size ($part_size) exceeds remaining space in extended partition ($((extended_end_mib - logical_start_mib)) MiB available)"
                return 1
            fi
        fi
        
        # Create the logical partition
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${device}" mkpart logical "${parted_fs_type}" "${logical_start_mib}MiB" "${part_end_position}MiB"
        else
            sudo parted -s "${device}" mkpart logical "${parted_fs_type}" "${logical_start_mib}MiB" "${part_end_position}MiB" >/dev/null 2>&1
        fi
        
        local parted_exit_code=$?
        if [ $parted_exit_code -ne 0 ]; then
            error "Failed to create logical partition ${logical_number} (exit code: $parted_exit_code)"
            return 1
        fi

        # Update start position for next logical partition
        local actual_end_mib=$(sudo parted -s "${device}" print | awk -v num="$logical_number" '$1 == num {print int($3)}')
        if [ -n "$actual_end_mib" ]; then
            logical_start_mib=$((actual_end_mib + 1)) # Add 1 MiB for next EBR
        else
            error "Failed to get end position for logical partition ${logical_number}"
            return 1
        fi
        
        # Refresh partition table
        sleep 2
        sudo partprobe "${device}" >/dev/null 2>&1
        sleep 1

        ((logical_number++))
    done
    
    return 0
}

finalize_formatting() {
    local device="$1"
    
    log "Finalizing formatting process..."
    
    # Ensure partitions are recognized
    if [ "$VERBOSE" -eq 1 ]; then
        sudo partprobe "$device"
        udevadm settle
    else
        sudo partprobe "$device" >/dev/null 2>&1
        udevadm settle >/dev/null 2>&1
    fi
    
    sleep 2
    log "Formatting completed for all partitions on $device"
}