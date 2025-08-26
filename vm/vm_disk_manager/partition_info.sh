# Function to analyze partitions
analyze_partitions() {
    local device=$1
    
    if [ ! -b "$device" ]; then
        log "Device $device not available"
        echo "Device $device not available"
        return 1
    fi
    
    log "Analyzing partitions on $device"
    echo "=== PARTITION ANALYSIS ==="
    parted "$device" print 2>/dev/null || {
        log "Error analyzing partitions"
        echo "Error analyzing partitions"
        return 1
    }
    
    echo ""
    echo "=== FILESYSTEMS ==="
    for part in "${device}"p*; do
        if [ -b "$part" ]; then
            local fs_info=$(blkid "$part" 2>/dev/null || echo "Unknown")
            echo "$(basename "$part"): $fs_info"
        fi
    done
    
    return 0
}

detect_luks() {
    local device=$1
    local luks_parts=()
    
    if command -v cryptsetup &> /dev/null; then
        for part in "${device}"p*; do
            if [ -b "$part" ] && cryptsetup isLuks "$part" 2>/dev/null; then
                luks_parts+=("$part")
            fi
        done
    fi
    
    echo "${luks_parts[@]}"
}