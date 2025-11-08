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
    
    # Se è l'ultima partizione e usa circa tutto lo spazio rimanente,
    # probabilmente era definita come "remaining"
    if [ "$partition_num" -eq "$total_partitions" ]; then
        local remaining_threshold=$((disk_bytes / 10))  # 10% del disco
        if [ "$actual_bytes" -gt "$remaining_threshold" ]; then
            # Controlla se è molto vicino allo spazio totale disponibile
            local used_by_others=0
            # Questo calcolo dovrebbe essere fatto dal chiamante, per ora uso euristica semplice
            local expected_remaining=$((disk_bytes * 8 / 10))  # Stima 80% per ultima partizione
            if [ "$actual_bytes" -gt "$expected_remaining" ]; then
                echo "remaining"
                return 0
            fi
        fi
    fi
    
    # Usa l'algoritmo di rounding intelligente
    smart_size_rounding "$actual_bytes"
}

# Smart rounding algorithm for partition sizes with locale handling and better precision
smart_size_rounding() {
    local bytes="$1"
    
    # Ensure locale is C for consistent decimal handling
    export LC_NUMERIC=C
    
    # Array di dimensioni comuni in bytes
    local common_sizes_bytes=(
        $((512 * 1024 * 1024))      # 512M
        $((1024 * 1024 * 1024))     # 1G
        $((2048 * 1024 * 1024))     # 2G
        $((4096 * 1024 * 1024))     # 4G
        $((8192 * 1024 * 1024))     # 8G
        $((1536 * 1024 * 1024))     # 1536M (1.5G)
        $((256 * 1024 * 1024))      # 256M
        $((128 * 1024 * 1024))      # 128M
        $((100 * 1024 * 1024))      # 100M
    )
    
    local common_sizes_labels=(
        "512M" "1G" "2G" "4G" "8G" "1536M" "256M" "128M" "100M"
    )
    
    # Cerca la dimensione comune più vicina con tolleranza del 2%
    local min_diff=$bytes
    local best_match=""
    
    for i in "${!common_sizes_bytes[@]}"; do
        local common_size=${common_sizes_bytes[$i]}
        local diff=$((bytes > common_size ? bytes - common_size : common_size - bytes))
        local tolerance=$((common_size / 50))  # 2% tolerance
        
        if [ $diff -le $tolerance ] && [ $diff -lt $min_diff ]; then
            min_diff=$diff
            best_match=${common_sizes_labels[$i]}
        fi
    done
    
    if [ -n "$best_match" ]; then
        echo "$best_match"
        return 0
    fi
    
    # Fallback al vecchio algoritmo
    if [ "$bytes" -ge $((1024*1024*1024)) ]; then
        # Per GB, arrotonda al GB più vicino
        local gb_precise=$(echo "scale=3; $bytes / (1024*1024*1024)" | bc)
        local gb_rounded=$(echo "scale=0; ($gb_precise + 0.5) / 1" | bc)
        echo "${gb_rounded}G"
    elif [ "$bytes" -ge $((1024*1024)) ]; then
        # Per MB, arrotonda ai 10MB più vicini se >100MB, altrimenti al MB
        local mb_precise=$(echo "scale=2; $bytes / (1024*1024)" | bc)
        local mb_rounded
        if [ "$(echo "$mb_precise >= 100" | bc)" -eq 1 ]; then
            mb_rounded=$(echo "scale=0; ($mb_precise + 5) / 10 * 10" | bc)
        else
            mb_rounded=$(echo "scale=0; ($mb_precise + 0.5) / 1" | bc)
        fi
        echo "${mb_rounded}M"
    else
        # Per dimensioni più piccole, arrotonda al KB più vicino
        local kb_rounded=$(echo "scale=0; ($bytes / 1024 + 0.5) / 1" | bc)
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
    
    # blkid first (most reliable)
    local blkid_fs
    blkid_fs=$(echo "$BLKID_INFO" | grep "^$part_dev:" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p' | head -1)
    
    if [ -n "$blkid_fs" ]; then
        case "$blkid_fs" in
            "linux-swap"|"linux-swap(v1)") echo "swap" ;;
            "vfat")
                # Distinzione fat16/fat32
                local fat_variant
                fat_variant=$(echo "$BLKID_INFO" | grep "^$part_dev:" | sed -n 's/.*SEC_TYPE="\([^"]*\)".*/\1/p' | head -1)
                case "$fat_variant" in
                    "msdos") echo "fat16" ;;
                    *) [ "$parted_fs" = "fat16" ] && echo "fat16" || echo "fat32" ;;
                esac
                ;;
            "ext2")
                [ "$parted_fs" = "ext3" ] && echo "ext3" || echo "ext2"
                ;;
            *) echo "$blkid_fs" ;;
        esac
        return 0
    fi

    # Fallback to parted information
    if [ -n "$parted_fs" ] && [ "$parted_fs" != "unknown" ]; then
        case "$parted_fs" in
            "linux-swap"|"linux-swap(v1)") echo "swap" ;;
            "msftres") echo "msr" ;;   # <- qui normalizziamo la MSR
            *) echo "$parted_fs" ;;
        esac
        return 0
    fi

    # 3. Detection MSR
    if [[ "$parted_name" =~ [Mm]icrosoft ]] && [[ "$parted_name" =~ [Rr]eserved ]]; then
        echo "msr"
        return 0
    fi
    if [ "$parted_type" = "msftres" ]; then
        echo "msr"
        return 0
    fi
    if [[ "$parted_name" =~ "msftres" ]]; then
        echo "msr"
        return 0
    fi

    # 4. Default
    echo "none"
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