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
    
    local temp_mount="/tmp/clone_check_$$"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would mount $partition to check used space"
        # Return a realistic estimate for dry run
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