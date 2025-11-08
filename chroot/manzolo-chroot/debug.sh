create_debug_snapshot() {
    local snapshot_file="/tmp/luks_debug_$(date +%s).txt"
    
    debug "Creating debug snapshot: $snapshot_file"
    
    {
        echo "=== LUKS Debug Snapshot $(date) ==="
        echo
        echo "=== Block devices ==="
        lsblk -f
        echo
        echo "=== LUKS mappings ==="
        ls -la /dev/mapper/ 2>/dev/null || echo "No mappings"
        echo
        echo "=== Active LUKS devices ==="
        sudo cryptsetup status luks_* 2>/dev/null || echo "No active LUKS devices"
        echo
        echo "=== LVM Physical Volumes ==="
        sudo pvs 2>/dev/null || echo "No PVs found"
        echo
        echo "=== LVM Volume Groups ==="
        sudo vgs 2>/dev/null || echo "No VGs found" 
        echo
        echo "=== LVM Logical Volumes ==="
        sudo lvs 2>/dev/null || echo "No LVs found"
        echo
        echo "=== Mount points ==="
        mount | grep -E "(luks|mapper)" || echo "No LUKS/mapper mounts"
        echo
        echo "=== Script variables ==="
        echo "ROOT_DEVICE: $ROOT_DEVICE"
        echo "VIRTUAL_MODE: $VIRTUAL_MODE"
        echo "LUKS_MAPPINGS: ${LUKS_MAPPINGS[*]}"
        echo "ACTIVATED_VGS: ${ACTIVATED_VGS[*]}"
        echo "MOUNTED_POINTS: ${MOUNTED_POINTS[*]}"
    } > "$snapshot_file" 2>&1
    
    debug "Debug snapshot created: $snapshot_file"
    echo "$snapshot_file"
}