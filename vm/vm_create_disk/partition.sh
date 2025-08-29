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
    
    # Calculate sizes in MB for exact positioning
    local total_disk_mb=$(size_to_exact_mb "$DISK_SIZE")
    local logical_total_mb=0
    local logical_overhead_mb=0

    # Calculate total logical partition size
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ "$part_type" = "logical" ] && [ "$part_size" != "remaining" ]; then
            logical_total_mb=$((logical_total_mb + $(size_to_exact_mb "$part_size")))
        fi
    done
    
    logical_overhead_mb=$((1 * $(echo "${PARTITIONS[*]}" | grep -c ":logical")))
    
    # Create primary and extended partitions
    IFS=':' read -r next_partition_number start_mb <<< $(create_primary_partitions \
        "$DEVICE" 1 "$total_disk_mb" "$logical_total_mb" "$logical_overhead_mb")
    
    if [ $? -ne 0 ]; then
        cleanup_device "$DEVICE"
        exit 1
    fi
    
    # Create logical partitions if needed
    if [ $(echo "${PARTITIONS[*]}" | grep -c ":logical") -gt 0 ]; then
        create_logical_partitions "$DEVICE" "$start_mb" "$total_disk_mb"
        if [ $? -ne 0 ]; then
            cleanup_device "$DEVICE"
            exit 1
        fi
    fi
    
    # Debug: Print partition table and device list
    log "DEBUG: Partition table after creation:"
    sudo parted -s "${DEVICE}" print >&2
    log "DEBUG: Partition devices:"
    ls -la "${DEVICE}"* >&2
    
    # Final cleanup and verification
    finalize_partitions "$DEVICE"
}

verify_partition_sizes() {
    local device="$1"
    
    log "Verifying partition sizes..."
    
    sudo parted -s "$device" unit MB print | awk '
        /^[ ]*[0-9]+/ {
            part_num = $1
            start = $2 + 0
            end = $3 + 0
            size = $4 + 0
            expected_size = expected_sizes[part_num]
            
            if (expected_size != "" && expected_size != "remaining") {
                size_diff = (size > expected_size) ? size - expected_size : expected_size - size
                if (size_diff > 2) { # Allow 2MB tolerance for overhead
                    printf "WARNING: Partition %d: expected %dMB, got %dMB (diff: %dMB)\n", 
                           part_num, expected_size, size, size_diff
                } else {
                    printf "OK: Partition %d: %dMB (expected %dMB)\n", part_num, size, expected_size
                }
            }
        }
    ' expected_sizes="$(
        for i in "${!PARTITIONS[@]}"; do
            IFS=':' read -r size fs type <<< "${PARTITIONS[$i]}"
            if [ "$size" != "remaining" ]; then
                echo "$((i+1)):$(size_to_exact_mb "$size")"
            fi
        done
    )"
}

finalize_partitions() {
    local device="$1"
    
    log "Waiting for all partitions to be recognized..."
    sleep 2
    sudo partprobe "${device}" >/dev/null 2>&1
    sleep 1
    
    # Verify partition sizes
    if [ "$VERBOSE" -eq 1 ]; then
        verify_partition_sizes "$device"
    fi
    
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

# Format partition with retry mechanism and better error handling
format_single_partition() {
    local part_dev="$1"
    local part_fs="$2"
    local max_retries="${3:-3}"
    local retry_delay="${4:-2}"
    
    if [ ! -b "$part_dev" ]; then
        log_error "Partition device $part_dev does not exist"
        return 1
    fi
    
    if [ "$part_fs" = "none" ] || [ "$part_fs" = "msr" ]; then
        log_debug "Skipping formatting for $part_dev (filesystem: ${part_fs:-none})"
        return 0
    fi
    
    log_info "Formatting $part_dev as $part_fs..."
    
    local cmd
    case "$part_fs" in
        "swap")  cmd="sudo mkswap '$part_dev'" ;;
        "ext4")  cmd="sudo mkfs.ext4 -F '$part_dev'" ;;
        "ext3")  cmd="sudo mkfs.ext3 -F '$part_dev'" ;;
        "ext2")  cmd="sudo mkfs.ext2 -F '$part_dev'" ;;
        "xfs")   cmd="sudo mkfs.xfs -f '$part_dev'" ;;
        "btrfs") cmd="sudo mkfs.btrfs -f '$part_dev'" ;;
        "fat32"|"vfat") cmd="sudo mkfs.vfat -F 32 '$part_dev'" ;;
        "fat16") cmd="sudo mkfs.vfat -F 16 '$part_dev'" ;;
        "ntfs")  cmd="sudo mkfs.ntfs -f '$part_dev'" ;;
        *)
            log_error "Unknown filesystem type: $part_fs"
            return 1
            ;;
    esac
    
    # Try formatting with retries
    for attempt in $(seq 1 $max_retries); do
        log_debug "Format attempt $attempt/$max_retries for $part_dev"
        
        if [ "$VERBOSE" -eq 1 ]; then
            eval "$cmd"
        else
            eval "$cmd" >/dev/null 2>&1
        fi
        
        if [ $? -eq 0 ]; then
            log_success "Successfully formatted $part_dev as $part_fs"
            return 0
        fi
        
        if [ $attempt -lt $max_retries ]; then
            log_warn "Format attempt $attempt failed, retrying in ${retry_delay}s..."
            sleep $retry_delay
        fi
    done
    
    log_error "Failed to format $part_dev as $part_fs after $max_retries attempts"
    return 1
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
    local start_mb="$2"
    local total_disk_mb="$3"
    local logical_total_mb="$4"
    local logical_overhead_mb="$5"
    
    local partition_number=1
    
    log "DEBUG: Starting primary partition creation with start_mb=$start_mb, total_disk_mb=$total_disk_mb"
    
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        # Skip logical partitions in first pass
        if [ "$part_type" = "logical" ]; then
            continue
        fi

        if [ -z "$part_type" ] && [ "$PARTITION_TABLE" = "mbr" ]; then
            part_type="primary"
        fi

        log "DEBUG: Processing partition $partition_number: size=$part_size, fs=$part_fs, type=$part_type"
        
        # Get updated start position from create_single_partition
        local new_start_mb
        new_start_mb=$(create_single_partition "$device" "$part_size" "$part_fs" "$part_type" \
            "$partition_number" "$start_mb" "$total_disk_mb" \
            "$logical_total_mb" "$logical_overhead_mb")
        
        if [ $? -ne 0 ]; then
            error "Failed to create partition $partition_number"
            return 1
        fi
        
        start_mb=$new_start_mb
        log "DEBUG: Updated start_mb=$start_mb for partition $partition_number"
        ((partition_number++))
    done
    
    echo "$partition_number:$start_mb"
}

create_single_partition() {
    local device="$1"
    local part_size="$2"
    local part_fs="$3"
    local part_type="$4"
    local partition_number="$5"
    local start_mb="$6"
    local total_disk_mb="$7"
    local logical_total_mb="$8"
    local logical_overhead_mb="$9"
    
    {
        log "Creating partition ${partition_number}: ${part_size} (${part_fs:-none}, ${part_type:-none})"
        
        local size_mb
        local end_position
        local end_mb

        if [ "$part_size" = "remaining" ]; then
            size_mb=$((total_disk_mb - start_mb))
            if [ $size_mb -le 0 ]; then
                error "No remaining space for partition ${partition_number}"
                exit 1
            fi
            end_position="100%"
        else
            size_mb=$(size_to_exact_mb "$part_size")
            if [ $? -ne 0 ]; then
                error "Invalid size format for partition ${partition_number}: $part_size"
                exit 1
            fi
            end_mb=$((start_mb + size_mb))
            if [ $end_mb -gt $total_disk_mb ]; then
                warning "Partition ${partition_number} size exceeds remaining disk space, adjusting to fit"
                size_mb=$((total_disk_mb - start_mb))
                end_position="100%"
            else
                end_position="${end_mb}MB"
            fi
        fi
        
        # Validate extended partition size
        if [ "$part_type" = "extended" ] && [ "$part_size" != "remaining" ]; then
            local extended_size_mb=$(size_to_exact_mb "$part_size")
            if [ $((logical_total_mb + logical_overhead_mb)) -gt $extended_size_mb ]; then
                error "Extended partition size too small for logical partitions"
                exit 1
            fi
        fi
        
        local parted_args=()
        local part_name=$(get_partition_name "$part_fs")
        local parted_fs_type=$(get_parted_fs_type "$part_fs")
        
        # Use MB instead of MiB for exact positioning
        local start_position="${start_mb}MB"
        
        if [ "$PARTITION_TABLE" = "gpt" ]; then
            if [ "$part_fs" = "msr" ]; then
                parted_args=("${device}" mkpart "${part_name}" "" "${start_position}" "${end_position}")
            else
                parted_args=("${device}" mkpart "${part_name}" "${parted_fs_type}" "${start_position}" "${end_position}")
            fi
        else
            if [ "$part_type" = "extended" ]; then
                parted_args=("${device}" mkpart "${part_type}" "${start_position}" "${end_position}")
            else
                parted_args=("${device}" mkpart "${part_type}" "${parted_fs_type}" "${start_position}" "${end_position}")
            fi
        fi
        
        log "DEBUG: Running parted command: parted -s ${parted_args[*]}"
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${parted_args[@]}"
        else
            sudo parted -s "${parted_args[@]}" >/dev/null 2>&1
        fi
        
        if [ $? -ne 0 ]; then
            error "Failed to create partition ${partition_number} with command: parted -s ${parted_args[*]}"
            exit 1
        fi
        
        # Ensure partition table is updated
        log "DEBUG: Running partprobe and udevadm settle"
        sudo partprobe "${device}" >/dev/null 2>&1
        udevadm settle >/dev/null 2>&1
        sleep 1
        
        # Update start position for next partition exactly
        if [ "$part_size" = "remaining" ]; then
            start_mb=$total_disk_mb
        else
            start_mb=$end_mb
        fi
    } >&2  # Redirect all log output to stderr

    echo "$start_mb"  # Output only start_mb to stdout
}

create_logical_partitions() {
    local device="$1"
    local extended_start_mb="$2"
    local total_disk_mb="$3"
    
    log "Creating logical partitions..."
    
    # Get extended partition boundaries in MB
    local extended_info=$(sudo parted -s "${device}" unit MB print | awk '/extended/ {print int($2) ":" int($3)}')
    if [ -z "$extended_info" ]; then
        error "Extended partition not found for logical partitions"
        return 1
    fi
    
    IFS=':' read -r extended_start_mb extended_end_mb <<< "$extended_info"
    local logical_start_mb=$((extended_start_mb + 1)) # Start logical partitions after EBR
    
    local logical_number=5
    
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        
        if [ "$part_type" != "logical" ]; then
            continue
        fi

        log "Creating logical partition ${logical_number}: ${part_size} (${part_fs})"
        
        local parted_fs_type=$(get_parted_fs_type "$part_fs")
        local part_end_mb
        
        # Calculate end position in MB
        if [ "$part_size" = "remaining" ]; then
            part_end_mb=$((extended_end_mb - 1)) # Leave 1 MB for EBR
        else
            local size_mb=$(size_to_exact_mb "$part_size")
            part_end_mb=$((logical_start_mb + size_mb))
            
            if [ $part_end_mb -gt $((extended_end_mb - 1)) ]; then
                error "Logical partition size ($part_size) exceeds remaining space in extended partition ($((extended_end_mb - logical_start_mb)) MB available)"
                return 1
            fi
        fi
        
        # Create the logical partition with exact MB positioning
        if [ "$VERBOSE" -eq 1 ]; then
            sudo parted -s "${device}" mkpart logical "${parted_fs_type}" "${logical_start_mb}MB" "${part_end_mb}MB"
        else
            sudo parted -s "${device}" mkpart logical "${parted_fs_type}" "${logical_start_mb}MB" "${part_end_mb}MB" >/dev/null 2>&1
        fi
        
        if [ $? -ne 0 ]; then
            error "Failed to create logical partition ${logical_number}"
            return 1
        fi

        # Update start position exactly for next logical partition
        logical_start_mb=$((part_end_mb + 1)) # Add 1 MB for next EBR
        
        # Refresh partition table
        sleep 1
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