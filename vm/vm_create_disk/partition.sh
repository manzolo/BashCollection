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
    
    # Calcola dimensioni in settori per precisione massima
    local disk_bytes=$(size_to_bytes "$DISK_SIZE")
    local total_sectors=$((disk_bytes / 512))
    local logical_total_sectors=0
    local logical_overhead_sectors=0

    # Calcola dimensione totale delle partizioni logiche
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ "$part_type" = "logical" ] && [ "$part_size" != "remaining" ]; then
            local part_sectors=$(size_to_sectors "$part_size")
            logical_total_sectors=$((logical_total_sectors + part_sectors))
        fi
    done
    
    # Overhead per partizioni logiche (1 settore per EBR per partizione)
    logical_overhead_sectors=$(echo "${PARTITIONS[*]}" | grep -c ":logical")
    
    # Crea partizioni primarie ed estese
    IFS=':' read -r next_partition_number start_sectors <<< $(create_primary_partitions \
        "$DEVICE" 2048 "$total_sectors" "$logical_total_sectors" "$logical_overhead_sectors")
    
    if [ $? -ne 0 ]; then
        cleanup_device "$DEVICE"
        exit 1
    fi
    
    # Crea partizioni logiche se necessario
    if [ $(echo "${PARTITIONS[*]}" | grep -c ":logical") -gt 0 ]; then
        create_logical_partitions "$DEVICE" "$start_sectors" "$total_sectors"
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

create_single_partition() {
    local device="$1"
    local part_size="$2"
    local part_fs="$3"
    local part_type="$4"
    local partition_number="$5"
    local start_sectors="$6"
    local total_sectors="$7"
    local logical_total_sectors="${8:-0}"
    local logical_overhead_sectors="${9:-0}"
    
    {
        log "Creating partition ${partition_number}: ${part_size} (${part_fs:-none}, ${part_type:-none})"
        
        local size_sectors
        local end_sectors

        if [ "$part_size" = "remaining" ]; then
            # Usa tutto lo spazio rimanente
            size_sectors=$((total_sectors - start_sectors))
            if [ $size_sectors -le 0 ]; then
                error "No remaining space for partition ${partition_number}"
                exit 1
            fi
            end_sectors=$((total_sectors - 34))  # Lascia spazio per GPT secondario
        else
            size_sectors=$(size_to_sectors "$part_size")
            if [ $? -ne 0 ]; then
                error "Invalid size format for partition ${partition_number}: $part_size"
                exit 1
            fi
            end_sectors=$((start_sectors + size_sectors - 1))
            
            # Controlla se supera lo spazio disponibile
            if [ $end_sectors -gt $((total_sectors - 34)) ]; then
                warning "Partition ${partition_number} size exceeds remaining disk space, adjusting to fit"
                end_sectors=$((total_sectors - 34))
                size_sectors=$((end_sectors - start_sectors + 1))
            fi
        fi
        
        # Validazione extended partition per MBR
        if [ "$part_type" = "extended" ] && [ "$part_size" != "remaining" ]; then
            local extended_size_sectors=$(size_to_sectors "$part_size")
            if [ $((logical_total_sectors + logical_overhead_sectors)) -gt $extended_size_sectors ]; then
                error "Extended partition size too small for logical partitions"
                exit 1
            fi
        fi
        
        local parted_args=()
        local part_name=$(get_partition_name "$part_fs")
        local parted_fs_type=$(get_parted_fs_type "$part_fs")
        
        # Usa settori per precisione massima
        local start_position="${start_sectors}s"
        local end_position="${end_sectors}s"
        
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
        
        # Calcola il prossimo start sector
        local next_start_sectors=$((end_sectors + 1))
        
        # Allinea a 2048 settori (1MiB) per prestazioni ottimali
        next_start_sectors=$(( ((next_start_sectors + 2047) / 2048) * 2048 ))
        
    } >&2  # Redirect all log output to stderr

    echo "$next_start_sectors"  # Output only next start sectors to stdout
}

create_primary_partitions() {
    local device="$1"
    local start_sectors="${2:-2048}"  # Default: inizio a 1MiB
    local total_sectors="$3"
    local logical_total_sectors="$4"
    local logical_overhead_sectors="$5"
    
    local partition_number=1
    
    log "DEBUG: Starting primary partition creation with start_sectors=$start_sectors, total_sectors=$total_sectors"
    
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
        local new_start_sectors
        new_start_sectors=$(create_single_partition "$device" "$part_size" "$part_fs" "$part_type" \
            "$partition_number" "$start_sectors" "$total_sectors" \
            "$logical_total_sectors" "$logical_overhead_sectors")
        
        if [ $? -ne 0 ]; then
            error "Failed to create partition $partition_number"
            return 1
        fi
        
        start_sectors=$new_start_sectors
        log "DEBUG: Updated start_sectors=$start_sectors for partition $partition_number"
        ((partition_number++))
    done
    
    echo "$partition_number:$start_sectors"
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