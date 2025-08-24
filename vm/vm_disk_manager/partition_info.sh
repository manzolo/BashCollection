analyze_partitions() {
    local device=$1
    local output=""
    
    if command -v parted &> /dev/null; then
        output=$(parted -s "$device" print 2>/dev/null)
        if [ -z "$output" ]; then
            output="No partition table found or parted failed"
        fi
    else
        output="parted not installed"
    fi
    
    echo "$output"
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