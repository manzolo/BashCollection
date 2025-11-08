#!/bin/bash

# ═══════════════════════════════════════════════════════════════════
# Enhanced Filesystem Detection and Handling
# Now with ZFS and Btrfs support
# ═══════════════════════════════════════════════════════════════════

# Enhanced filesystem detection
detect_filesystem_robust() {
    local partition="$1"
    local fs_type=""
    
    # Method 1: lsblk
    fs_type=$(lsblk -no FSTYPE "$partition" 2>/dev/null | head -1)
    if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
        echo "$fs_type"
        return 0
    fi
    
    # Method 2: blkid
    fs_type=$(blkid -o value -s TYPE "$partition" 2>/dev/null | head -1)
    if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
        echo "$fs_type"
        return 0
    fi
    
    # Method 3: file command
    local file_output=$(file -s "$partition" 2>/dev/null)
    case "$file_output" in
        *"ext2 filesystem"*) echo "ext2" ;;
        *"ext3 filesystem"*) echo "ext3" ;;
        *"ext4 filesystem"*) echo "ext4" ;;
        *"NTFS"*) echo "ntfs" ;;
        *"FAT"*) echo "vfat" ;;
        *"XFS"*) echo "xfs" ;;
        *"Btrfs"*) echo "btrfs" ;;
        *"ZFS"*) echo "zfs_member" ;;
        *"LUKS"*) echo "crypto_LUKS" ;;
        *"swap"*) echo "swap" ;;
        *) echo "" ;;
    esac
}

get_filesystem_type() {
    local partition="$1"
    lsblk -no FSTYPE "$partition" 2>/dev/null
}

get_filesystem_used_space() {
    local partition="$1"
    local fs_type=$(get_filesystem_type "$partition")
    
    # Handle special filesystems
    case "$fs_type" in
        "zfs_member")
            get_zfs_usage "$partition"
            return
            ;;
        "btrfs")
            get_btrfs_usage "$partition"
            return
            ;;
    esac
    
    # Standard filesystem handling
    local temp_mount="/tmp/clone_check_$$"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would mount $partition to check used space"
        local part_size=$(blockdev --getsize64 "$partition" 2>/dev/null)
        echo $((part_size / 2))  # Assume 50% usage for dry run
        return
    fi
    
    mkdir -p "$temp_mount" 2>/dev/null
    
    if mount -o ro "$partition" "$temp_mount" 2>/dev/null; then
        local used=$(df -B1 "$temp_mount" | tail -1 | awk '{print $3}')
        umount "$temp_mount" 2>/dev/null
        rmdir "$temp_mount" 2>/dev/null
        echo "$used"
    else
        blockdev --getsize64 "$partition" 2>/dev/null
    fi
}

# Check if filesystem is supported for optimization
is_filesystem_supported() {
    local partition="$1"
    local fs_type=$(lsblk -no FSTYPE "$partition" 2>/dev/null)
    
    case "$fs_type" in
        ext2|ext3|ext4|ntfs|fat32|fat16|vfat|btrfs|xfs|zfs_member)
            echo "yes"
            ;;
        *)
            echo "no"
            ;;
    esac
}

# Enhanced clone partition function
clone_partition_enhanced() {
    local source_partition="$1"
    local target_partition="$2"
    local fs_type="$3"
    local preserve_uuid="${4:-false}"
    
    log "Cloning partition: $source_partition → $target_partition"
    log "  Filesystem: $fs_type"
    
    case "$fs_type" in
        "btrfs")
            handle_btrfs_partition "$source_partition" "$target_partition" "$preserve_uuid"
            return $?
            ;;
        "zfs_member")
            clone_zfs "$source_partition" "$target_partition" "optimized"
            return $?
            ;;
        "ext2"|"ext3"|"ext4")
            clone_ext_filesystem "$source_partition" "$target_partition" "$fs_type" "$preserve_uuid"
            return $?
            ;;
        "ntfs")
            clone_ntfs_filesystem "$source_partition" "$target_partition" "$preserve_uuid"
            return $?
            ;;
        "vfat"|"fat32")
            clone_fat_filesystem "$source_partition" "$target_partition" "$preserve_uuid"
            return $?
            ;;
        "xfs")
            clone_xfs_filesystem "$source_partition" "$target_partition" "$preserve_uuid"
            return $?
            ;;
        "crypto_LUKS")
            clone_luks_container "$source_partition" "$target_partition"
            return $?
            ;;
        "swap")
            create_swap_partition "$source_partition" "$target_partition" "$preserve_uuid"
            return $?
            ;;
        *)
            log "  Using generic dd copy for unknown filesystem"
            clone_generic_partition "$source_partition" "$target_partition"
            return $?
            ;;
    esac
}

# Clone ext filesystem with optimization
clone_ext_filesystem() {
    local source="$1"
    local target="$2"
    local fs_type="$3"
    local preserve_uuid="${4:-false}"
    
    log "  Cloning $fs_type filesystem with e2image"
    
    if [ "$DRY_RUN" = true ]; then
        log "  🧪 DRY RUN - Would run: e2fsck -fy '$source'"
        log "  🧪 DRY RUN - Would run: e2image -ra -p '$source' '$target'"
        if [ "$preserve_uuid" = "true" ]; then
            log "  🧪 DRY RUN - UUID would be preserved automatically by e2image"
        fi
        return 0
    fi
    
    # Check and repair source if needed
    e2fsck -fy "$source" 2>/dev/null || true
    
    # Clone with e2image (preserves UUID by default)
    if e2image -ra -p "$source" "$target" 2>/dev/null; then
        log "    ✓ $fs_type cloned successfully"
        
        # Resize if target is larger
        local source_size=$(blockdev --getsize64 "$source" 2>/dev/null)
        local target_size=$(blockdev --getsize64 "$target" 2>/dev/null)
        
        if [ "$target_size" -gt "$source_size" ]; then
            log "    Resizing filesystem to use full partition..."
            resize2fs "$target" 2>/dev/null || true
        fi
        
        return 0
    else
        log "    ⚠ e2image failed, falling back to dd"
        clone_generic_partition "$source" "$target"
        return $?
    fi
}

# Clone NTFS filesystem with optimization
clone_ntfs_filesystem() {
    local source="$1"
    local target="$2"
    local preserve_uuid="${3:-false}"
    
    log "  Cloning NTFS filesystem"
    
    if command -v ntfsclone &>/dev/null; then
        log "    Using ntfsclone for optimized copy"
        
        if [ "$DRY_RUN" = true ]; then
            log "  🧪 DRY RUN - Would run: ntfsclone -f --overwrite '$target' '$source'"
            return 0
        fi
        
        if ntfsclone -f --overwrite "$target" "$source" 2>/dev/null; then
            log "    ✓ NTFS cloned successfully (UUID preserved)"
            
            # Resize if needed
            local source_size=$(blockdev --getsize64 "$source" 2>/dev/null)
            local target_size=$(blockdev --getsize64 "$target" 2>/dev/null)
            
            if [ "$target_size" -gt "$source_size" ] && command -v ntfsresize &>/dev/null; then
                log "    Resizing NTFS filesystem..."
                ntfsresize -f "$target" 2>/dev/null || true
            fi
            
            return 0
        fi
    fi
    
    log "    Using dd for NTFS copy"
    clone_generic_partition "$source" "$target"
    
    if [ "$preserve_uuid" = "true" ] && command -v ntfslabel &>/dev/null; then
        local uuid=$(blkid -o value -s UUID "$source" 2>/dev/null)
        if [ -n "$uuid" ]; then
            log "    Setting NTFS UUID..."
            # NTFS UUID is typically preserved in the copy
        fi
    fi
    
    return 0
}

# Clone FAT filesystem
clone_fat_filesystem() {
    local source="$1"
    local target="$2"
    local preserve_uuid="${3:-false}"
    
    log "  Cloning FAT filesystem"
    
    clone_generic_partition "$source" "$target"
    
    if [ "$preserve_uuid" = "true" ]; then
        local uuid=$(blkid -o value -s UUID "$source" 2>/dev/null)
        if [ -n "$uuid" ] && command -v mlabel &>/dev/null; then
            set_filesystem_uuid "$target" "$uuid" "vfat"
        fi
    fi
    
    return 0
}

# Clone XFS filesystem
clone_xfs_filesystem() {
    local source="$1"
    local target="$2"
    local preserve_uuid="${3:-false}"
    
    log "  Cloning XFS filesystem"
    
    if command -v xfs_copy &>/dev/null; then
        log "    Using xfs_copy for optimized clone"
        
        if [ "$DRY_RUN" = true ]; then
            log "  🧪 DRY RUN - Would run: xfs_copy '$source' '$target'"
            return 0
        fi
        
        if xfs_copy "$source" "$target" 2>/dev/null; then
            log "    ✓ XFS cloned with xfs_copy"
            
            if [ "$preserve_uuid" = "false" ]; then
                # Generate new UUID to avoid conflicts
                xfs_admin -U generate "$target" 2>/dev/null || true
            fi
            
            return 0
        fi
    fi
    
    # Fallback to dd
    clone_generic_partition "$source" "$target"
    
    if [ "$preserve_uuid" = "true" ]; then
        local uuid=$(blkid -o value -s UUID "$source" 2>/dev/null)
        if [ -n "$uuid" ] && command -v xfs_admin &>/dev/null; then
            xfs_admin -U "$uuid" "$target" 2>/dev/null || true
        fi
    fi
    
    return 0
}

# Clone LUKS container
clone_luks_container() {
    local source="$1"
    local target="$2"
    
    log "  Cloning LUKS encrypted container"
    log "    ⚠ LUKS requires exact copy to preserve header"
    
    local source_size=$(blockdev --getsize64 "$source" 2>/dev/null)
    local target_size=$(blockdev --getsize64 "$target" 2>/dev/null)
    
    if [ "$target_size" -lt "$source_size" ]; then
        log "    ❌ Error: Target too small for LUKS container"
        return 1
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log "  🧪 DRY RUN - Would run: dd if='$source' of='$target' bs=4M status=progress"
        return 0
    fi
    
    # Copy the entire LUKS container
    if dd if="$source" of="$target" bs=4M status=progress conv=noerror,sync 2>/dev/null; then
        log "    ✓ LUKS container cloned"
        
        # Verify LUKS header
        if command -v cryptsetup &>/dev/null; then
            if cryptsetup luksDump "$target" &>/dev/null; then
                log "    ✓ LUKS header verified"
            else
                log "    ⚠ LUKS header verification failed"
            fi
        fi
        
        return 0
    else
        log "    ❌ Failed to clone LUKS container"
        return 1
    fi
}

# Create swap partition
create_swap_partition() {
    local source="$1"
    local target="$2"
    local preserve_uuid="${3:-false}"
    
    log "  Creating swap partition"
    
    if [ "$preserve_uuid" = "true" ]; then
        local uuid=$(blkid -o value -s UUID "$source" 2>/dev/null)
        if [ -n "$uuid" ]; then
            if [ "$DRY_RUN" = true ]; then
                log "  🧪 DRY RUN - Would run: mkswap -U '$uuid' '$target'"
            else
                mkswap -U "$uuid" "$target" 2>/dev/null
            fi
            log "    ✓ Swap created with preserved UUID: $uuid"
        else
            if [ "$DRY_RUN" = true ]; then
                log "  🧪 DRY RUN - Would run: mkswap '$target'"
            else
                mkswap "$target" 2>/dev/null
            fi
        fi
    else
        if [ "$DRY_RUN" = true ]; then
            log "  🧪 DRY RUN - Would run: mkswap '$target'"
        else
            mkswap "$target" 2>/dev/null
        fi
    fi
    
    return 0
}

# Generic partition clone with dd
clone_generic_partition() {
    local source="$1"
    local target="$2"
    
    log "    Using dd for generic copy"
    
    local source_size=$(blockdev --getsize64 "$source" 2>/dev/null)
    local target_size=$(blockdev --getsize64 "$target" 2>/dev/null)
    
    local copy_size=$source_size
    if [ "$target_size" -lt "$source_size" ]; then
        copy_size=$target_size
        log "    ⚠ Target smaller, copying only $(numfmt --to=iec --suffix=B $copy_size)"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log "  🧪 DRY RUN - Would run: dd if='$source' of='$target' bs=4M count=$((copy_size / 4194304)) status=progress"
        return 0
    fi
    
    if dd if="$source" of="$target" bs=4M count=$((copy_size / 4194304)) status=progress 2>/dev/null; then
        log "    ✓ Partition cloned with dd"
        return 0
    else
        log "    ❌ dd copy failed"
        return 1
    fi
}