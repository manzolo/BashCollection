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

# Convert size to exact megabytes (1048576 bytes) for precise partitioning
size_to_exact_mb() {
    local size=$1
    if [ "$size" = "remaining" ]; then
        echo "remaining"
        return
    fi
    
    local num=${size//[!0-9]/}
    local unit=${size//[0-9]/}
    
    case ${unit^^} in
        K) echo $((num * 1024 / 1024)) ;;      # KB to MB
        M) echo $num ;;                        # MB stays MB
        G) echo $((num * 1024)) ;;             # GB to MB
        T) echo $((num * 1024 * 1024)) ;;      # TB to MB
        *) echo $((num / 1024 / 1024)) ;;      # bytes to MB
    esac
}

# Convert size to exact bytes for validation
size_to_exact_bytes() {
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

calculate_partition_sizes() {
    local total_disk_mib=$(size_to_mib "$DISK_SIZE")
    local logical_total_mib=0
    local overhead_per_logical=32
    local logical_overhead_mib=0

    # Calculate total logical partition size
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        if [ "$part_type" = "logical" ] && [ "$part_size" != "remaining" ]; then
            logical_total_mib=$((logical_total_mib + $(size_to_mib "$part_size")))
        fi
    done
    
    logical_overhead_mib=$((overhead_per_logical * $(echo "${PARTITIONS[*]}" | grep -c ":logical")))
    
    echo "$total_disk_mib:$logical_total_mib:$logical_overhead_mib"
}