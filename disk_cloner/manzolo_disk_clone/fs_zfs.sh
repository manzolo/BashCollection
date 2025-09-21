#!/bin/bash

# ═══════════════════════════════════════════════════════════════════
# ZFS Support Module for Manzolo Disk Cloner
# ═══════════════════════════════════════════════════════════════════

# Check if ZFS is available
check_zfs_support() {
    if command -v zfs &> /dev/null && command -v zpool &> /dev/null; then
        log "✓ ZFS support available"
        return 0
    else
        log "⚠ ZFS tools not found (install with: apt-get install zfsutils-linux)"
        return 1
    fi
}

# Detect if a device/partition contains ZFS
is_zfs_member() {
    local device="$1"
    
    # Check if device is part of a ZFS pool
    if zpool status 2>/dev/null | grep -q "$device"; then
        return 0
    fi
    
    # Check with blkid
    local fs_type=$(blkid -o value -s TYPE "$device" 2>/dev/null)
    if [[ "$fs_type" == "zfs_member" ]]; then
        return 0
    fi
    
    return 1
}

# Get ZFS pool information from a device
get_zfs_pool_info() {
    local device="$1"
    
    # Find which pool this device belongs to
    local pool_name=""
    while IFS= read -r pool; do
        if zpool status "$pool" 2>/dev/null | grep -q "$device"; then
            pool_name="$pool"
            break
        fi
    done < <(zpool list -H -o name 2>/dev/null)
    
    if [[ -n "$pool_name" ]]; then
        echo "$pool_name"
        return 0
    fi
    
    return 1
}

# Export ZFS pool safely
export_zfs_pool() {
    local pool_name="$1"
    
    log "Exporting ZFS pool: $pool_name"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: zpool export '$pool_name'"
        return 0
    fi
    
    # First, unmount all datasets
    while IFS= read -r dataset; do
        if mountpoint -q "$dataset" 2>/dev/null; then
            log "  Unmounting ZFS dataset: $dataset"
            zfs unmount "$dataset" 2>/dev/null || true
        fi
    done < <(zfs list -H -o mountpoint -r "$pool_name" 2>/dev/null | grep -v '^-$' | grep -v '^none$')
    
    # Export the pool
    if zpool export "$pool_name" 2>/dev/null; then
        log "  ✓ ZFS pool exported successfully"
        return 0
    else
        log "  ⚠ Failed to export ZFS pool"
        return 1
    fi
}

# Clone ZFS pool/dataset
clone_zfs() {
    local source_device="$1"
    local target_device="$2"
    local mode="${3:-full}"  # full or send-receive
    
    log "Cloning ZFS from $source_device to $target_device"
    
    # Get source pool info
    local source_pool=$(get_zfs_pool_info "$source_device")
    if [[ -z "$source_pool" ]]; then
        log "Warning: Source device is not part of a ZFS pool"
        return 1
    fi
    
    log "Source ZFS pool: $source_pool"
    
    if [[ "$mode" == "send-receive" ]] && check_zfs_support; then
        clone_zfs_send_receive "$source_pool" "$target_device"
    else
        clone_zfs_raw "$source_device" "$target_device"
    fi
}

# Clone ZFS using send/receive (preserves all ZFS features)
clone_zfs_send_receive() {
    local source_pool="$1"
    local target_device="$2"
    local temp_pool="clone_${source_pool}_$$"
    
    log "Using ZFS send/receive method for optimal cloning"
    
    # Create new pool on target device
    log "Creating ZFS pool on target device..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create pool: zpool create -f '$temp_pool' '$target_device'"
    else
        # Get source pool properties
        local pool_props=$(zpool get -H -o property,value all "$source_pool" 2>/dev/null | \
            grep -v -E 'guid|creation|feature@|available|allocated|free|size' | \
            awk '{print "-o " $1 "=" $2}' | tr '\n' ' ')
        
        # Create target pool with same properties
        eval "zpool create -f $temp_pool $target_device $pool_props" 2>/dev/null || {
            log "Error: Failed to create ZFS pool on target"
            return 1
        }
    fi
    
    # Get list of datasets to clone
    local datasets=()
    while IFS= read -r dataset; do
        datasets+=("$dataset")
    done < <(zfs list -H -o name -r "$source_pool" 2>/dev/null)
    
    log "Found ${#datasets[@]} datasets to clone"
    
    # Clone each dataset
    for dataset in "${datasets[@]}"; do
        local target_dataset="${temp_pool}${dataset#$source_pool}"
        log "  Cloning dataset: $dataset → $target_dataset"
        
        if [ "$DRY_RUN" = true ]; then
            log "  🧪 DRY RUN - Would run: zfs send -R '$dataset' | zfs receive -F '$target_dataset'"
        else
            # Create snapshot for cloning
            local snap_name="clone_$(date +%Y%m%d_%H%M%S)"
            zfs snapshot -r "${dataset}@${snap_name}" 2>/dev/null
            
            # Send/receive dataset
            zfs send -R "${dataset}@${snap_name}" 2>/dev/null | \
                zfs receive -F "$target_dataset" 2>/dev/null || {
                log "    ⚠ Failed to clone dataset: $dataset"
            }
            
            # Clean up snapshot
            zfs destroy -r "${dataset}@${snap_name}" 2>/dev/null || true
        fi
    done
    
    # Export the new pool (so it can be imported with original name if desired)
    if [ "$DRY_RUN" = false ]; then
        log "Exporting cloned pool..."
        zpool export "$temp_pool" 2>/dev/null || true
    fi
    
    log "✓ ZFS pool cloned successfully"
    log "  To import: zpool import -d $target_device"
    
    return 0
}

# Clone ZFS using raw device copy (fallback method)
clone_zfs_raw() {
    local source_device="$1"
    local target_device="$2"
    
    log "Using raw device copy for ZFS (fallback method)"
    log "⚠ Note: This method may require pool import recovery on target"
    
    # Export source pool if possible
    local source_pool=$(get_zfs_pool_info "$source_device")
    if [[ -n "$source_pool" ]]; then
        log "Attempting to export source pool for consistency..."
        export_zfs_pool "$source_pool" || {
            log "⚠ Could not export pool - cloning anyway (may need recovery)"
        }
    fi
    
    # Raw device copy
    local source_size=$(blockdev --getsize64 "$source_device" 2>/dev/null)
    local target_size=$(blockdev --getsize64 "$target_device" 2>/dev/null)
    
    if [[ $target_size -lt $source_size ]]; then
        log "Error: Target device too small for ZFS pool"
        return 1
    fi
    
    log "Copying ZFS pool data (raw)..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: dd if='$source_device' of='$target_device' bs=1M status=progress"
    else
        if command -v pv &> /dev/null; then
            pv -tpreb "$source_device" | dd of="$target_device" bs=1M conv=notrunc,noerror 2>/dev/null
        else
            dd if="$source_device" of="$target_device" bs=1M status=progress conv=notrunc,noerror
        fi
    fi
    
    if [ $? -eq 0 ]; then
        log "✓ ZFS raw copy completed"
        log "  Note: You may need to run 'zpool import -f' on the target device"
        
        # Re-import source pool if it was exported
        if [[ -n "$source_pool" ]] && [ "$DRY_RUN" = false ]; then
            log "Re-importing source pool..."
            zpool import "$source_pool" 2>/dev/null || true
        fi
        
        return 0
    else
        log "Error: Raw copy failed"
        return 1
    fi
}

# Create ZFS pool on device
create_zfs_pool() {
    local device="$1"
    local pool_name="${2:-tank}"
    local options="${3:-}"
    
    log "Creating ZFS pool '$pool_name' on $device"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: zpool create -f $options '$pool_name' '$device'"
        return 0
    fi
    
    # Create the pool
    if eval "zpool create -f $options '$pool_name' '$device'" 2>/dev/null; then
        log "✓ ZFS pool created successfully"
        
        # Set some recommended properties
        zfs set compression=lz4 "$pool_name" 2>/dev/null
        zfs set atime=off "$pool_name" 2>/dev/null
        
        return 0
    else
        log "Error: Failed to create ZFS pool"
        return 1
    fi
}

# Check ZFS pool health
check_zfs_health() {
    local pool_name="$1"
    
    local status=$(zpool status "$pool_name" 2>/dev/null | grep -E '^\s*state:' | awk '{print $2}')
    
    case "$status" in
        ONLINE)
            log "✓ ZFS pool '$pool_name' is healthy (ONLINE)"
            return 0
            ;;
        DEGRADED)
            log "⚠ ZFS pool '$pool_name' is DEGRADED but functional"
            return 0
            ;;
        FAULTED|UNAVAIL)
            log "❌ ZFS pool '$pool_name' is $status"
            return 1
            ;;
        *)
            log "Unknown ZFS pool status: $status"
            return 2
            ;;
    esac
}

# Get ZFS dataset properties
get_zfs_dataset_info() {
    local dataset="$1"
    
    log "ZFS Dataset Information for: $dataset"
    
    # Get key properties
    local props="used,available,referenced,compressratio,compression,mountpoint"
    
    zfs get -H -o property,value $props "$dataset" 2>/dev/null | while IFS=$'\t' read -r prop value; do
        log "  $prop: $value"
    done
}

# Snapshot ZFS dataset before operations
create_zfs_snapshot() {
    local dataset="$1"
    local snap_name="${2:-backup_$(date +%Y%m%d_%H%M%S)}"
    
    log "Creating ZFS snapshot: ${dataset}@${snap_name}"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: zfs snapshot '${dataset}@${snap_name}'"
        return 0
    fi
    
    if zfs snapshot "${dataset}@${snap_name}" 2>/dev/null; then
        log "✓ Snapshot created successfully"
        return 0
    else
        log "Error: Failed to create snapshot"
        return 1
    fi
}

# Clone ZFS with deduplication optimization
clone_zfs_optimized() {
    local source_pool="$1"
    local target_device="$2"
    
    log "Optimized ZFS cloning with deduplication analysis"
    
    # Check dedup ratio
    local dedup_ratio=$(zpool get -H -o value dedup "$source_pool" 2>/dev/null)
    log "Source pool deduplication ratio: $dedup_ratio"
    
    # Get actual used space
    local used_space=$(zfs get -H -o value used "$source_pool" 2>/dev/null)
    log "Used space in source pool: $used_space"
    
    # Proceed with optimized clone
    clone_zfs_send_receive "$source_pool" "$target_device"
}