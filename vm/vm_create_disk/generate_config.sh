#!/bin/bash

# ==============================================================================
# ENHANCED GENERATE CONFIG FUNCTION
# ==============================================================================

# Enhanced function to generate config.sh from existing disk image with precise size detection
generate_config() {
    local DISK_FILE="$1"
    local CONFIG_FILE="${DISK_FILE%.*}_config.sh"

    register_cleanup
    
    if [ ! -f "$DISK_FILE" ]; then
        log_error "Disk image '$DISK_FILE' not found"
        return 1
    fi

    log_info "Analyzing disk image $DISK_FILE..."

    # Get disk format and size using qemu-img
    local QEMU_INFO
    QEMU_INFO=$(qemu-img info "$DISK_FILE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_error "Failed to read disk image info for $DISK_FILE"
        return 1
    fi

    local DISK_FORMAT=$(echo "$QEMU_INFO" | awk -F': ' '/file format/ {print $2}')
    local DISK_SIZE_BYTES=$(echo "$QEMU_INFO" | grep "virtual size" | grep -oP '\(\K[0-9]+(?=\s*bytes)')
    local DISK_SIZE=$(bytes_to_human "$DISK_SIZE_BYTES" 0)
    
    if [ -z "$DISK_SIZE" ] || [ -z "$DISK_SIZE_BYTES" ]; then
        log_error "Failed to parse disk size from qemu-img info"
        return 1
    fi
    
    log_debug "Disk format: $DISK_FORMAT, Size: $DISK_SIZE ($DISK_SIZE_BYTES bytes)"

    # Set up device using enhanced device management
    local DEVICE=""
    DEVICE=$(setup_reverse_device "$DISK_FILE" "$DISK_FORMAT")
    if [ $? -ne 0 ] || [ -z "$DEVICE" ]; then
        log_error "Failed to set up device for $DISK_FILE"
        return 1
    fi

    log_debug "Using device: $DEVICE"

    # Get partition table information using parted with LC_ALL=C
    local PARTED_INFO
    PARTED_INFO=$(LC_ALL=C sudo parted -m "$DEVICE" unit B print 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_error "Failed to read partition table from $DEVICE"
        cleanup_device "$DEVICE"
        return 1
    fi
    
    log_debug "Parted info retrieved successfully"

    # Determine partition table type
    local PARTITION_TABLE=""
    if echo "$PARTED_INFO" | grep -E "^/dev/.*:gpt:" >/dev/null; then
        PARTITION_TABLE="gpt"
    elif echo "$PARTED_INFO" | grep -E "^/dev/.*:msdos:" >/dev/null; then
        PARTITION_TABLE="mbr"
    else
        log_error "Failed to determine partition table type"
        cleanup_device "$DEVICE"
        return 1
    fi

    log_info "Detected partition table: ${PARTITION_TABLE^^}"

    # Get filesystem information using blkid
    local BLKID_INFO
    BLKID_INFO=$(LC_ALL=C sudo blkid -c /dev/null "${DEVICE}"* 2>/dev/null)
    log_debug "Filesystem detection completed"

    # Parse partition information with enhanced precision
    local PARTITION_SPECS=()
    parse_partition_info "$PARTED_INFO" "$BLKID_INFO" "$DEVICE" "$PARTITION_TABLE" "$DISK_SIZE_BYTES" PARTITION_SPECS

    if [ $? -ne 0 ]; then
        log_error "Failed to parse partition information"
        cleanup_device "$DEVICE"
        return 1
    fi

    # Generate configuration file
    generate_config_file "$CONFIG_FILE" "$DISK_FILE" "$DISK_SIZE" "$DISK_FORMAT" "$PARTITION_TABLE" PARTITION_SPECS

    if [ $? -eq 0 ]; then
        log_success "Configuration file '$CONFIG_FILE' generated successfully"
    else
        log_error "Failed to generate configuration file"
        cleanup_device "$DEVICE"
        return 1
    fi

    # Clean up device
    cleanup_device "$DEVICE"
    return 0
}

# Set up device for reverse engineering with enhanced error handling
setup_reverse_device() {
    local DISK_FILE="$1"
    local DISK_FORMAT="$2"
    local DEVICE=""

    if [ "$DISK_FORMAT" = "qcow2" ]; then
        DEVICE=$(find_available_nbd)
        if [ $? -ne 0 ]; then
            log_error "No available NBD devices found"
            return 1
        fi

        log_debug "Connecting $DISK_FILE to $DEVICE via qemu-nbd..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --connect="$DEVICE" "$DISK_FILE"
        else
            sudo qemu-nbd --connect="$DEVICE" "$DISK_FILE" >/dev/null 2>&1
        fi
        
        if [ $? -ne 0 ]; then
            log_error "Failed to connect qcow2 image via qemu-nbd"
            return 1
        fi

        # Wait for device to be ready
        if ! wait_for_device_ready "$DEVICE" 10; then
            log_error "Device $DEVICE not ready after connection"
            cleanup_device "$DEVICE"
            return 1
        fi
    else
        log_debug "Setting up loop device for $DISK_FILE..."
        if [ "$VERBOSE" -eq 1 ]; then
            DEVICE=$(sudo losetup -f --show "$DISK_FILE")
        else
            DEVICE=$(sudo losetup -f --show "$DISK_FILE" 2>/dev/null)
        fi
        
        if [ $? -ne 0 ] || [ -z "$DEVICE" ]; then
            log_error "Failed to create loop device for $DISK_FILE"
            return 1
        fi

        # Wait for device to be ready
        if ! wait_for_device_ready "$DEVICE" 5; then
            log_error "Device $DEVICE not ready after setup"
            cleanup_device "$DEVICE"
            return 1
        fi
    fi

    echo "$DEVICE"
    return 0
}

# Enhanced partition information parsing with precise size calculation
parse_partition_info() {
    local PARTED_INFO="$1"
    local BLKID_INFO="$2"
    local DEVICE="$3"
    local PARTITION_TABLE="$4"
    local TOTAL_DISK_BYTES="$5"
    local -n partition_specs_ref="$6"
    
    local partition_count=$(echo "$PARTED_INFO" | grep -E '^[0-9]+:' | wc -l)
    local current_partition=0
    
    log_debug "Found $partition_count partitions to parse"
    
    if [ "$partition_count" -eq 0 ]; then
        log_debug "No partitions found in parted output"
        return 0
    fi
    
    # Get original partition specifications for size reconstruction
    local original_sizes=()
    
    # Parse each partition line
    local temp_file=$(mktemp)
    echo "$PARTED_INFO" | grep -E '^[0-9]+:' > "$temp_file"
    
    while IFS=: read -r num start end size fs type name flags; do
        ((current_partition++))
        log_debug "Processing partition $num: start=$start, end=$end, size=$size, fs=$fs"
        
        local size_bytes="${size%B}"
        local part_dev="${DEVICE}p${num}"
        
        # Handle case where partition device might use different naming
        if [ ! -b "$part_dev" ]; then
            part_dev="${DEVICE}${num}"
        fi
        
        # Get precise size using enhanced algorithm
        local precise_size
        precise_size=$(calculate_precise_partition_size "$size_bytes" "$current_partition" "$partition_count" "$TOTAL_DISK_BYTES")
        
        # Get filesystem information with fallback
        local fs_norm
        fs_norm=$(detect_filesystem_type "$BLKID_INFO" "$part_dev" "$fs" "$type" "$name")
        
        # Generate partition specification
        local part_spec
        if [ "$PARTITION_TABLE" = "mbr" ]; then
            local part_type
            part_type=$(determine_mbr_partition_type "$type" "$flags" "$num")
            part_spec="${precise_size}:${fs_norm}:${part_type}"
        else
            part_spec="${precise_size}:${fs_norm}"
        fi
        
        partition_specs_ref+=("$part_spec")
        log_debug "Parsed partition $num: $part_spec"
    done < "$temp_file"
    
    rm -f "$temp_file"
    log_debug "Total partitions parsed: ${#partition_specs_ref[@]}"
    return 0
}

# Reconstruct likely original sizes from partition layout
reconstruct_original_sizes() {
    local PARTED_INFO="$1"
    local TOTAL_DISK_BYTES="$2"
    local -n original_sizes_ref="$3"
    
    # Common partition sizes in bytes
    local common_sizes=(
        $((1 * 1024 * 1024 * 1024))        # 1G
        $((2 * 1024 * 1024 * 1024))        # 2G
        $((4 * 1024 * 1024 * 1024))        # 4G
        $((8 * 1024 * 1024 * 1024))        # 8G
        $((512 * 1024 * 1024))             # 512M
        $((256 * 1024 * 1024))             # 256M
        $((128 * 1024 * 1024))             # 128M
        $((100 * 1024 * 1024))             # 100M
    )
    
    # Analyze each partition size and find closest match
    echo "$PARTED_INFO" | grep -E '^[0-9]+:' | while IFS=: read -r num start end size fs type name flags; do
        local size_bytes="${size%B}"
        local best_match="$size_bytes"
        local min_diff="$size_bytes"
        
        # Check against common sizes with 5% tolerance
        for common_size in "${common_sizes[@]}"; do
            local diff=$((size_bytes > common_size ? size_bytes - common_size : common_size - size_bytes))
            local tolerance=$((common_size / 20))  # 5% tolerance
            
            if [ "$diff" -le "$tolerance" ] && [ "$diff" -lt "$min_diff" ]; then
                best_match="$common_size"
                min_diff="$diff"
            fi
        done
        
        original_sizes_ref+=("$best_match")
    done
}

# Calculate precise partition size with intelligent rounding (simplified version)
calculate_precise_partition_size() {
    local actual_bytes="$1"
    local partition_num="$2"
    local total_partitions="$3"
    local disk_bytes="$4"
    
    # Validate input is a positive integer
    if ! [[ "$actual_bytes" =~ ^[0-9]+$ ]]; then
        log_error "Invalid partition size in bytes: $actual_bytes"
        return 1
    fi
    
    # Use smart rounding for the actual size
    smart_size_rounding "$actual_bytes"
}

# Smart rounding algorithm for partition sizes with locale handling and better precision
smart_size_rounding() {
    local bytes="$1"
    
    # Ensure locale is C for consistent decimal handling
    export LC_NUMERIC=C
    
    if [ "$bytes" -ge $((1024*1024*1024)) ]; then
        # For GB sizes, check if close to a round number
        local gb_precise
        gb_precise=$(echo "scale=3; $bytes / (1024*1024*1024)" | bc)
        local gb_int
        gb_int=$(echo "scale=0; ($gb_precise + 0.5) / 1" | bc)
        
        # If within 5% of a round GB number, use the round number
        local diff_percent
        diff_percent=$(echo "scale=2; if ($gb_precise > $gb_int) ($gb_precise - $gb_int) else ($gb_int - $gb_precise) * 100 / $gb_int" | bc)
        
        if [ "$(echo "$diff_percent <= 5" | bc)" -eq 1 ] && [ "$gb_int" -gt 0 ]; then
            echo "${gb_int}G"
        else
            # Round to nearest 100MB
            local gb_rounded
            gb_rounded=$(echo "scale=1; ($gb_precise * 10 + 0.5) / 10" | bc)
            local gb_display
            gb_display=$(echo "scale=0; ($gb_rounded + 0.05) / 1" | bc)
            echo "${gb_display}G"
        fi
    elif [ "$bytes" -ge $((1024*1024)) ]; then
        # For MB sizes, check if close to a round number first
        local mb_precise
        mb_precise=$(echo "scale=2; $bytes / (1024*1024)" | bc)
        
        # Check for common round numbers (100, 250, 500, 512, 1000, etc.)
        local common_mb_sizes=(100 128 250 256 500 512 750 1000 1024)
        local best_match=""
        local min_diff_percent=10
        
        for target in "${common_mb_sizes[@]}"; do
            if [ "$(echo "$target <= ($mb_precise + 50)" | bc)" -eq 1 ] && [ "$(echo "$target >= ($mb_precise - 50)" | bc)" -eq 1 ]; then
                local diff_percent
                diff_percent=$(echo "scale=2; if ($mb_precise > $target) ($mb_precise - $target) else ($target - $mb_precise) * 100 / $target" | bc)
                if [ "$(echo "$diff_percent < $min_diff_percent" | bc)" -eq 1 ]; then
                    min_diff_percent=$diff_percent
                    best_match="$target"
                fi
            fi
        done
        
        if [ -n "$best_match" ]; then
            echo "${best_match}M"
        else
            # Standard rounding
            local mb_rounded
            if [ "$(echo "$mb_precise >= 100" | bc)" -eq 1 ]; then
                mb_rounded=$(echo "scale=0; ($mb_precise + 5) / 10 * 10" | bc)
            else
                mb_rounded=$(echo "scale=0; ($mb_precise + 0.5) / 1" | bc)
            fi
            echo "${mb_rounded}M"
        fi
    else
        # For smaller sizes, round to nearest KB
        local kb_rounded
        kb_rounded=$(echo "scale=0; ($bytes / 1024 + 0.5) / 1" | bc)
        echo "${kb_rounded}K"
    fi
}

# Enhanced filesystem type detection
detect_filesystem_type() {
    local BLKID_INFO="$1"
    local part_dev="$2"
    local parted_fs="$3"
    local parted_type="$4"
    local parted_name="$5"
    
    # Try blkid first (most reliable) - clean up the grep pattern
    local blkid_fs=$(echo "$BLKID_INFO" | grep "^$part_dev:" | sed 's/.*TYPE="\([^"]*\)".*/\1/' | head -1)
    
    if [ -n "$blkid_fs" ]; then
        case "$blkid_fs" in
            "linux-swap"|"linux-swap(v1)") echo "swap" ;;
            "vfat")
                # Distinguish between fat16, fat32, and vfat by checking SEC_TYPE
                local fat_variant=$(echo "$BLKID_INFO" | grep "^$part_dev:" | sed 's/.*SEC_TYPE="\([^"]*\)".*/\1/' | head -1)
                case "$fat_variant" in
                    "msdos") echo "fat16" ;;
                    *) 
                        # Check if it was originally fat16 based on parted info
                        if [ "$parted_fs" = "fat16" ]; then
                            echo "fat16"
                        else
                            echo "fat32"
                        fi
                        ;;
                esac
                ;;
            "ext2") 
                # Check if it was originally ext3 based on parted info
                if [ "$parted_fs" = "ext3" ]; then
                    echo "ext3"
                else
                    echo "ext2"
                fi
                ;;
            *) echo "$blkid_fs" ;;
        esac
        return 0
    fi
    
    # Fallback to parted information - clean single value
    if [ -n "$parted_fs" ]; then
        case "$parted_fs" in
            "linux-swap"|"linux-swap(v1)") echo "swap" ;;
            *) echo "$parted_fs" ;;
        esac
    else
        # Last resort: analyze partition type
        if [[ "$parted_name" =~ "Microsoft reserved" ]] || [ "$parted_type" = "msr" ]; then
            echo "msr"
        else
            echo "none"
        fi
    fi
}

# Determine MBR partition type from parted output
determine_mbr_partition_type() {
    local type="$1"
    local flags="$2"
    local num="$3"
    
    if [ "$type" = "extended" ] || [[ "$flags" =~ "extended" ]]; then
        echo "extended"
    elif [ "$num" -ge 5 ]; then
        echo "logical"
    else
        echo "primary"
    fi
}

# Generate the configuration file with proper formatting and escaped content
generate_config_file() {
    local CONFIG_FILE="$1"
    local DISK_FILE="$2"
    local DISK_SIZE="$3"
    local DISK_FORMAT="$4"
    local PARTITION_TABLE="$5"
    local -n partition_specs_ref="$6"
    
    # Create configuration file with proper escaping
    {
        echo "#!/bin/bash"
        echo "# Generated configuration for $(basename "$DISK_FILE")"
        echo "# Created on $(date)"
        echo ""
        echo "DISK_NAME=\"$(basename "$DISK_FILE")\""
        echo "DISK_SIZE=\"$DISK_SIZE\""
        echo "DISK_FORMAT=\"$DISK_FORMAT\""
        echo "PARTITION_TABLE=\"$PARTITION_TABLE\""
        echo "PREALLOCATION=\"off\"  # Note: Cannot be determined from existing image"
        echo ""
        echo "PARTITIONS=("
        
        for spec in "${partition_specs_ref[@]}"; do
            # Ensure spec is properly formatted and escaped
            local clean_spec=$(echo "$spec" | tr -d '\n\r' | sed 's/[[:space:]]\+/ /g')
            echo "    \"$clean_spec\""
        done
        
        echo ")"
    } > "$CONFIG_FILE"
    
    chmod +x "$CONFIG_FILE"
    
    # Log summary
    log_info "Generated configuration:"
    log_info "  Disk: $(basename "$DISK_FILE") ($DISK_SIZE, $DISK_FORMAT)"
    log_info "  Partition table: ${PARTITION_TABLE^^}"
    log_info "  Partitions: ${#partition_specs_ref[@]}"
    
    return 0
}