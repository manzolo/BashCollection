#!/bin/bash

# ═══════════════════════════════════════════════════════════════════
# Btrfs Support Module for Manzolo Disk Cloner
# ═══════════════════════════════════════════════════════════════════

# Check if Btrfs tools are available
check_btrfs_support() {
    if command -v btrfs &> /dev/null && command -v btrfsck &> /dev/null; then
        log "✓ Btrfs support available"
        return 0
    else
        log "⚠ Btrfs tools not found (install with: apt-get install btrfs-progs)"
        return 1
    fi
}

# Detect if a device/partition contains Btrfs
is_btrfs() {
    local device="$1"
    
    local fs_type=$(blkid -o value -s TYPE "$device" 2>/dev/null)
    if [[ "$fs_type" == "btrfs" ]]; then
        return 0
    fi
    
    # Additional check with btrfs tools
    if btrfs filesystem show "$device" &>/dev/null; then
        return 0
    fi
    
    return 1
}

# Get Btrfs filesystem information
get_btrfs_info() {
    local device="$1"
    
    log "Btrfs filesystem information for $device:"
    
    # Get filesystem UUID
    local fs_uuid=$(btrfs filesystem show "$device" 2>/dev/null | grep -oP 'uuid: \K[^ ]+' | head -1)
    log "  UUID: $fs_uuid"
    
    # Get filesystem label
    local label=$(btrfs filesystem label "$device" 2>/dev/null)
    [[ -n "$label" ]] && log "  Label: $label"
    
    # Get device info
    if btrfs filesystem show "$device" 2>/dev/null | grep -q "Multiple devices"; then
        log "  ⚠ Multi-device Btrfs detected"
        local devices=$(btrfs filesystem show "$device" 2>/dev/null | grep -oP '^\s+devid\s+\d+.*path\s+\K.*')
        log "  Devices:"
        echo "$devices" | while read -r dev; do
            log "    - $dev"
        done
    fi
    
    echo "$fs_uuid"
}

# Get Btrfs subvolumes
get_btrfs_subvolumes() {
    local mount_point="$1"
    
    log "Listing Btrfs subvolumes at $mount_point:"
    
    local subvols=()
    while IFS= read -r line; do
        local subvol=$(echo "$line" | awk '{print $9}')
        if [[ -n "$subvol" ]]; then
            subvols+=("$subvol")
            log "  - $subvol"
        fi
    done < <(btrfs subvolume list "$mount_point" 2>/dev/null)
    
    printf '%s\n' "${subvols[@]}"
}

# Clone Btrfs filesystem
clone_btrfs() {
    local source_device="$1"
    local target_device="$2"
    local method="${3:-optimized}"  # optimized, raw, or send-receive
    
    log "Cloning Btrfs filesystem from $source_device to $target_device"
    
    case "$method" in
        "send-receive")
            clone_btrfs_send_receive "$source_device" "$target_device"
            ;;
        "raw")
            clone_btrfs_raw "$source_device" "$target_device"
            ;;
        "optimized"|*)
            clone_btrfs_optimized "$source_device" "$target_device"
            ;;
    esac
}

# Clone Btrfs using send/receive (best for subvolumes and snapshots)
clone_btrfs_send_receive() {
    local source_device="$1"
    local target_device="$2"
    
    log "Using Btrfs send/receive method (preserves all features)"
    
    # Create temporary mount points
    local source_mount="/tmp/btrfs_source_$$"
    local target_mount="/tmp/btrfs_target_$$"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create mount points and proceed with send/receive"
        return 0
    fi
    
    # Create mount points
    mkdir -p "$source_mount" "$target_mount"
    
    # Mount source
    if ! mount -t btrfs -o ro "$source_device" "$source_mount" 2>/dev/null; then
        log "Error: Failed to mount source Btrfs filesystem"
        rmdir "$source_mount" "$target_mount" 2>/dev/null
        return 1
    fi
    
    # Create Btrfs on target
    log "Creating Btrfs filesystem on target..."
    
    # Get source filesystem label
    local label=$(btrfs filesystem label "$source_device" 2>/dev/null)
    local mkfs_opts=""
    [[ -n "$label" ]] && mkfs_opts="-L '$label'"
    
    if ! eval "mkfs.btrfs -f $mkfs_opts '$target_device'" 2>/dev/null; then
        log "Error: Failed to create Btrfs on target"
        umount "$source_mount" 2>/dev/null
        rmdir "$source_mount" "$target_mount" 2>/dev/null
        return 1
    fi
    
    # Mount target
    if ! mount -t btrfs "$target_device" "$target_mount" 2>/dev/null; then
        log "Error: Failed to mount target Btrfs filesystem"
        umount "$source_mount" 2>/dev/null
        rmdir "$source_mount" "$target_mount" 2>/dev/null
        return 1
    fi
    
    # Get list of subvolumes
    local subvolumes=()
    while IFS= read -r subvol; do
        subvolumes+=("$subvol")
    done < <(get_btrfs_subvolumes "$source_mount")
    
    if [[ ${#subvolumes[@]} -eq 0 ]]; then
        # No subvolumes, just clone the root
        log "No subvolumes found, cloning root filesystem..."
        
        # Create read-only snapshot
        local snap_name="clone_snapshot_$(date +%Y%m%d_%H%M%S)"
        btrfs subvolume snapshot -r "$source_mount" "$source_mount/$snap_name" 2>/dev/null
        
        # Send/receive
        btrfs send "$source_mount/$snap_name" 2>/dev/null | \
            btrfs receive "$target_mount" 2>/dev/null
        
        # Clean up snapshot
        btrfs subvolume delete "$source_mount/$snap_name" 2>/dev/null || true
    else
        # Clone each subvolume
        log "Found ${#subvolumes[@]} subvolumes to clone"
        
        for subvol in "${subvolumes[@]}"; do
            log "  Cloning subvolume: $subvol"
            
            # Create read-only snapshot
            local snap_name="${subvol}_snapshot_$(date +%Y%m%d_%H%M%S)"
            if btrfs subvolume snapshot -r "$source_mount/$subvol" "$source_mount/$snap_name" 2>/dev/null; then
                # Send/receive
                btrfs send "$source_mount/$snap_name" 2>/dev/null | \
                    btrfs receive "$target_mount" 2>/dev/null || {
                    log "    ⚠ Failed to clone subvolume: $subvol"
                }
                
                # Clean up snapshot
                btrfs subvolume delete "$source_mount/$snap_name" 2>/dev/null || true
            fi
        done
    fi
    
    # Set the same default subvolume if exists
    local default_subvol=$(btrfs subvolume get-default "$source_mount" 2>/dev/null | awk '{print $2}')
    if [[ -n "$default_subvol" ]] && [[ "$default_subvol" != "5" ]]; then
        btrfs subvolume set-default "$default_subvol" "$target_mount" 2>/dev/null || true
    fi
    
    # Copy compression settings
    local compress=$(mount | grep "$source_mount" | grep -oP 'compress=\K[^,)]+' || true)
    if [[ -n "$compress" ]]; then
        log "  Preserving compression setting: $compress"
        btrfs property set "$target_mount" compression "$compress" 2>/dev/null || true
    fi
    
    # Cleanup
    umount "$source_mount" "$target_mount" 2>/dev/null || true
    rmdir "$source_mount" "$target_mount" 2>/dev/null || true
    
    log "✓ Btrfs filesystem cloned successfully"
    return 0
}

# Clone Btrfs using optimized method
clone_btrfs_optimized() {
    local source_device="$1"
    local target_device="$2"
    
    log "Using optimized Btrfs cloning method"
    
    # Check if we can use btrfs-image for metadata preservation
    if command -v btrfs-image &>/dev/null; then
        clone_btrfs_with_image "$source_device" "$target_device"
    else
        clone_btrfs_send_receive "$source_device" "$target_device"
    fi
}

# Clone Btrfs using btrfs-image (metadata-focused)
clone_btrfs_with_image() {
    local source_device="$1"
    local target_device="$2"
    
    log "Using btrfs-image for metadata-optimized cloning"
    
    local temp_image="/tmp/btrfs_image_$$.img"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create metadata image: btrfs-image -c9 '$source_device' '$temp_image'"
        log "🧪 DRY RUN - Would restore to target: btrfs-image -r '$temp_image' '$target_device'"
        return 0
    fi
    
    # Create compressed metadata image
    log "Creating Btrfs metadata image..."
    if ! btrfs-image -c9 -t4 "$source_device" "$temp_image" 2>/dev/null; then
        log "Error: Failed to create Btrfs image"
        return 1
    fi
    
    # Get image size
    local image_size=$(stat -c%s "$temp_image" 2>/dev/null)
    log "  Metadata image size: $(numfmt --to=iec --suffix=B $image_size)"
    
    # Restore to target
    log "Restoring Btrfs to target device..."
    if btrfs-image -r "$temp_image" "$target_device" 2>/dev/null; then
        log "✓ Btrfs filesystem restored successfully"
        
        # Resize filesystem to use full device
        log "Resizing filesystem to use full device..."
        local temp_mount="/tmp/btrfs_resize_$$"
        mkdir -p "$temp_mount"
        
        if mount -t btrfs "$target_device" "$temp_mount" 2>/dev/null; then
            btrfs filesystem resize max "$temp_mount" 2>/dev/null || true
            umount "$temp_mount" 2>/dev/null
        fi
        
        rmdir "$temp_mount" 2>/dev/null
        rm -f "$temp_image"
        return 0
    else
        log "Error: Failed to restore Btrfs image"
        rm -f "$temp_image"
        return 1
    fi
}

# Clone Btrfs using raw copy (fallback)
clone_btrfs_raw() {
    local source_device="$1"
    local target_device="$2"
    
    log "Using raw device copy for Btrfs (fallback method)"
    
    local source_size=$(blockdev --getsize64 "$source_device" 2>/dev/null)
    local target_size=$(blockdev --getsize64 "$target_device" 2>/dev/null)
    
    if [[ $target_size -lt $source_size ]]; then
        log "Error: Target device too small"
        return 1
    fi
    
    log "Copying Btrfs filesystem (raw)..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: dd if='$source_device' of='$target_device' bs=4M status=progress"
        return 0
    fi
    
    if command -v pv &> /dev/null; then
        pv -tpreb "$source_device" | dd of="$target_device" bs=4M conv=notrunc,noerror 2>/dev/null
    else
        dd if="$source_device" of="$target_device" bs=4M status=progress conv=notrunc,noerror
    fi
    
    if [ $? -eq 0 ]; then
        sync
        
        # Update UUID to avoid conflicts
        log "Generating new UUID for cloned filesystem..."
        btrfstune -U "$target_device" 2>/dev/null || true
        
        log "✓ Btrfs raw copy completed"
        return 0
    else
        log "Error: Raw copy failed"
        return 1
    fi
}

# Create Btrfs snapshot
create_btrfs_snapshot() {
    local source_path="$1"
    local snapshot_path="${2:-${source_path}_snapshot_$(date +%Y%m%d_%H%M%S)}"
    local readonly="${3:-true}"
    
    log "Creating Btrfs snapshot: $source_path → $snapshot_path"
    
    if [ "$DRY_RUN" = true ]; then
        if [[ "$readonly" == "true" ]]; then
            log "🧪 DRY RUN - Would run: btrfs subvolume snapshot -r '$source_path' '$snapshot_path'"
        else
            log "🧪 DRY RUN - Would run: btrfs subvolume snapshot '$source_path' '$snapshot_path'"
        fi
        return 0
    fi
    
    local opts=""
    [[ "$readonly" == "true" ]] && opts="-r"
    
    if btrfs subvolume snapshot $opts "$source_path" "$snapshot_path" 2>/dev/null; then
        log "✓ Snapshot created successfully"
        return 0
    else
        log "Error: Failed to create snapshot"
        return 1
    fi
}

# Check Btrfs filesystem health
check_btrfs_health() {
    local device="$1"
    
    log "Checking Btrfs filesystem health on $device..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: btrfs check --readonly '$device'"
        return 0
    fi
    
    # Run check in readonly mode
    if btrfs check --readonly "$device" &>/dev/null; then
        log "✓ Btrfs filesystem is healthy"
        return 0
    else
        log "⚠ Btrfs filesystem has issues"
        
        # Try to get more details
        local errors=$(btrfs check --readonly "$device" 2>&1 | grep -E 'ERROR|WARNING' | head -5)
        if [[ -n "$errors" ]]; then
            log "  Issues found:"
            echo "$errors" | while read -r line; do
                log "    $line"
            done
        fi
        
        return 1
    fi
}

# Defragment Btrfs filesystem
defragment_btrfs() {
    local mount_point="$1"
    local compress="${2:-zstd}"
    
    log "Defragmenting Btrfs filesystem at $mount_point"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: btrfs filesystem defragment -r -c'$compress' '$mount_point'"
        return 0
    fi
    
    # Run defragmentation with compression
    if btrfs filesystem defragment -r -c"$compress" "$mount_point" 2>/dev/null; then
        log "✓ Defragmentation completed"
        
        # Show space usage after defrag
        local usage=$(btrfs filesystem df "$mount_point" 2>/dev/null | head -2)
        log "  Space usage after defragmentation:"
        echo "$usage" | while read -r line; do
            log "    $line"
        done
        
        return 0
    else
        log "Error: Defragmentation failed"
        return 1
    fi
}

# Balance Btrfs filesystem
balance_btrfs() {
    local mount_point="$1"
    
    log "Balancing Btrfs filesystem at $mount_point"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: btrfs balance start -dusage=50 -musage=50 '$mount_point'"
        return 0
    fi
    
    # Start balance with usage filters to optimize
    if btrfs balance start -dusage=50 -musage=50 "$mount_point" 2>/dev/null; then
        log "✓ Balance completed successfully"
        return 0
    else
        log "⚠ Balance failed or was cancelled"
        return 1
    fi
}

# Get Btrfs space usage information
get_btrfs_usage() {
    local device="$1"
    
    local temp_mount="/tmp/btrfs_usage_$"
    mkdir -p "$temp_mount"
    
    if mount -t btrfs -o ro "$device" "$temp_mount" 2>/dev/null; then
        local total_size=$(btrfs filesystem show "$temp_mount" 2>/dev/null | grep -oP 'Total devices \d+ FS bytes used \K[0-9.]+[KMGT]iB')
        local data_usage=$(btrfs filesystem df "$temp_mount" 2>/dev/null | grep "Data" | grep -oP 'used=\K[0-9.]+[KMGT]iB')
        local metadata_usage=$(btrfs filesystem df "$temp_mount" 2>/dev/null | grep "Metadata" | grep -oP 'used=\K[0-9.]+[KMGT]iB')
        
        umount "$temp_mount" 2>/dev/null
        rmdir "$temp_mount" 2>/dev/null
        
        log "  Total used: ${total_size:-unknown}"
        log "  Data used: ${data_usage:-unknown}"
        log "  Metadata used: ${metadata_usage:-unknown}"
        
        # Convert to bytes for return
        echo "$total_size" | grep -oP '[0-9.]+' | awk '{
            unit = substr($0, length($0))
            num = substr($0, 1, length($0)-1)
            if (unit == "T") print num * 1099511627776
            else if (unit == "G") print num * 1073741824
            else if (unit == "M") print num * 1048576
            else if (unit == "K") print num * 1024
            else print num
        }'
    else
        # Fallback to device size
        blockdev --getsize64 "$device" 2>/dev/null
    fi
}

# Optimize Btrfs for cloning
optimize_btrfs_for_clone() {
    local device="$1"
    
    log "Optimizing Btrfs filesystem for cloning..."
    
    local temp_mount="/tmp/btrfs_optimize_$"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would mount and optimize Btrfs filesystem"
        return 0
    fi
    
    mkdir -p "$temp_mount"
    
    if mount -t btrfs "$device" "$temp_mount" 2>/dev/null; then
        # Sync and flush
        sync
        btrfs filesystem sync "$temp_mount" 2>/dev/null
        
        # Clear free space cache
        log "  Clearing free space cache..."
        mount -o remount,clear_cache "$temp_mount" 2>/dev/null || true
        
        # Run scrub if time permits (quick check only)
        log "  Running quick scrub check..."
        btrfs scrub start -B -d "$temp_mount" 2>/dev/null || true
        
        umount "$temp_mount" 2>/dev/null
    fi
    
    rmdir "$temp_mount" 2>/dev/null
    
    log "✓ Optimization completed"
    return 0
}

# Handle multi-device Btrfs
handle_btrfs_raid() {
    local primary_device="$1"
    
    log "Detecting multi-device Btrfs configuration..."
    
    local fs_info=$(btrfs filesystem show "$primary_device" 2>/dev/null)
    local device_count=$(echo "$fs_info" | grep -c "devid")
    
    if [[ $device_count -gt 1 ]]; then
        log "⚠ Multi-device Btrfs detected ($device_count devices)"
        
        local devices=()
        while IFS= read -r line; do
            local dev=$(echo "$line" | grep -oP 'path \K.*')
            if [[ -n "$dev" ]]; then
                devices+=("$dev")
                log "  Device: $dev"
            fi
        done <<< "$fs_info"
        
        # Get RAID level
        local raid_level="unknown"
        local temp_mount="/tmp/btrfs_raid_$"
        mkdir -p "$temp_mount"
        
        if mount -t btrfs -o ro "$primary_device" "$temp_mount" 2>/dev/null; then
            raid_level=$(btrfs filesystem df "$temp_mount" 2>/dev/null | grep -oP 'Data, \K[^:]+' | head -1)
            umount "$temp_mount" 2>/dev/null
        fi
        
        rmdir "$temp_mount" 2>/dev/null
        
        log "  RAID Level: $raid_level"
        
        return 0
    else
        log "  Single device Btrfs filesystem"
        return 1
    fi
}

# Preserve Btrfs UUID
preserve_btrfs_uuid() {
    local source_device="$1"
    local target_device="$2"
    
    log "Preserving Btrfs UUID..."
    
    local source_uuid=$(blkid -o value -s UUID "$source_device" 2>/dev/null)
    
    if [[ -n "$source_uuid" ]]; then
        log "  Source UUID: $source_uuid"
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would set UUID: btrfstune -U '$source_uuid' '$target_device'"
        else
            # Note: This requires the filesystem to be unmounted
            if btrfstune -U "$source_uuid" "$target_device" 2>/dev/null; then
                log "✓ UUID preserved successfully"
            else
                log "⚠ Could not preserve UUID (filesystem may be mounted)"
            fi
        fi
    fi
}

# Integration function for main script
handle_btrfs_partition() {
    local source_partition="$1"
    local target_partition="$2"
    local preserve_uuid="${3:-true}"
    
    if ! is_btrfs "$source_partition"; then
        return 1
    fi
    
    log "Detected Btrfs filesystem on $source_partition"
    
    # Check health first
    check_btrfs_health "$source_partition"
    
    # Get usage info
    local used_space=$(get_btrfs_usage "$source_partition")
    log "  Used space: $(numfmt --to=iec --suffix=B ${used_space:-0})"
    
    # Check for multi-device
    if handle_btrfs_raid "$source_partition"; then
        log "⚠ Multi-device Btrfs requires special handling"
        log "  Using raw copy method for safety"
        clone_btrfs_raw "$source_partition" "$target_partition"
    else
        # Optimize before cloning
        optimize_btrfs_for_clone "$source_partition"
        
        # Clone with appropriate method
        if check_btrfs_support; then
            clone_btrfs "$source_partition" "$target_partition" "send-receive"
        else
            clone_btrfs "$source_partition" "$target_partition" "raw"
        fi
    fi
    
    # Preserve UUID if requested
    if [[ "$preserve_uuid" == "true" ]]; then
        preserve_btrfs_uuid "$source_partition" "$target_partition"
    fi
    
    return 0
}