validate_device_safety() {
    local device="$1"
    local operation="$2"  # "read" or "write"
    
    if [ ! -b "$device" ]; then
        log_with_level ERROR "Device $device is not a block device"
        return 1
    fi
    
    # Check if device exists and is accessible
    if ! blockdev --getsize64 "$device" >/dev/null 2>&1; then
        log_with_level ERROR "Cannot access device $device"
        return 1
    fi
    
    # Check for ZFS pool membership
    if command -v zpool &>/dev/null; then
        if zpool status 2>/dev/null | grep -q "$device"; then
            log_with_level WARN "Device $device is part of a ZFS pool"
            if [ "$operation" = "write" ]; then
                log_with_level ERROR "Cannot write to device in active ZFS pool"
                return 1
            fi
        fi
    fi
    
    # Check for Btrfs filesystem
    if command -v btrfs &>/dev/null; then
        if btrfs filesystem show 2>/dev/null | grep -q "$device"; then
            log_with_level WARN "Device $device contains Btrfs filesystem"
            local btrfs_mounted=$(mount | grep "$device" | grep "type btrfs")
            if [ -n "$btrfs_mounted" ] && [ "$operation" = "write" ]; then
                log_with_level ERROR "Cannot write to mounted Btrfs filesystem"
                return 1
            fi
        fi
    fi
    
    # For write operations, additional safety checks
    if [ "$operation" = "write" ]; then
        # Check if it's a system disk
        local root_device=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
        if [ "$device" = "$root_device" ]; then
            log_with_level ERROR "Cannot write to root device $device"
            return 1
        fi
        
        # Check if device is read-only
        if [ "$(blockdev --getro "$device" 2>/dev/null)" = "1" ]; then
            log_with_level ERROR "Device $device is read-only"
            return 1
        fi
        
        # Check for critical mounts
        if findmnt -n -o SOURCE | grep -q "^$device"; then
            local critical_mounts=$(findmnt -n -o SOURCE,TARGET | grep "^$device" | grep -E '/$|/boot|/home|/usr|/var')
            if [ -n "$critical_mounts" ]; then
                log_with_level WARN "Device contains critical system mounts:"
                echo "$critical_mounts" | while read line; do
                    log_with_level WARN "  $line"
                done
                return 1
            fi
        fi
    fi
    
    return 0
}

check_partclone_tools() {
    local partclone_found=false
    local available_tools=()
    
    for tool in partclone.ext4 partclone.ext3 partclone.ext2 partclone.ntfs partclone.vfat partclone.btrfs partclone.xfs; do
        if command -v $tool &> /dev/null; then
            partclone_found=true
            available_tools+=("$tool")
        fi
    done
    
    # Check for Btrfs-specific partclone
    if command -v partclone.btrfs &> /dev/null; then
        log "  ✓ Btrfs partclone support available"
    fi
    
    if [ "$partclone_found" = false ]; then
        log "Warning: No partclone tools found!"
        log "For optimal cloning, install with: sudo apt-get install partclone"
        log "The script will work with basic dd cloning."
        sleep 2
    else
        log "✓ Partclone tools found: ${available_tools[*]}"
    fi
}

# Check UUID preservation tools
check_uuid_tools() {
    local missing_uuid_tools=()
    
    command -v sgdisk &> /dev/null || missing_uuid_tools+=("gdisk")
    command -v e2image &> /dev/null || missing_uuid_tools+=("e2fsprogs")
    command -v ntfsclone &> /dev/null || missing_uuid_tools+=("ntfs-3g")
    command -v tune2fs &> /dev/null || missing_uuid_tools+=("e2fsprogs")
    command -v xfs_admin &> /dev/null || missing_uuid_tools+=("xfsprogs")
    command -v btrfstune &> /dev/null || missing_uuid_tools+=("btrfs-progs")
    
    if [ ${#missing_uuid_tools[@]} -gt 0 ]; then
        log "Optional UUID tools not found: ${missing_uuid_tools[*]}"
        log "For complete UUID preservation, install: sudo apt-get install gdisk e2fsprogs ntfs-3g xfsprogs btrfs-progs dosfstools mtools"
        UUID_SUPPORT="partial"
    else
        log "✅ Full UUID preservation support available"
        UUID_SUPPORT="full"
    fi
}

# Check ZFS and Btrfs support
check_advanced_filesystems() {
    log "Checking advanced filesystem support..."
    
    local zfs_available=false
    local btrfs_available=false
    
    # Check ZFS
    if command -v zfs &> /dev/null && command -v zpool &> /dev/null; then
        zfs_available=true
        log "✓ ZFS support available"
        
        # Check ZFS kernel module
        if ! lsmod | grep -q "^zfs"; then
            log "  ⚠ ZFS kernel module not loaded (may load on demand)"
        fi
    else
        log "⚠ ZFS not available (install with: apt-get install zfsutils-linux)"
    fi
    
    # Check Btrfs
    if command -v btrfs &> /dev/null && command -v btrfsck &> /dev/null; then
        btrfs_available=true
        log "✓ Btrfs support available"
        
        # Check for additional Btrfs tools
        command -v btrfs-image &> /dev/null && log "  ✓ btrfs-image available (optimized cloning)"
        command -v btrfstune &> /dev/null && log "  ✓ btrfstune available (UUID management)"
    else
        log "⚠ Btrfs tools not available (install with: apt-get install btrfs-progs)"
    fi
    
    # Store availability globally
    ZFS_SUPPORT=$zfs_available
    BTRFS_SUPPORT=$btrfs_available
    
    return 0
}

check_device_safety() {
    local device="$1"
    
    local root_device=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
    
    if [ "$device" = "$root_device" ]; then
        log "❌ CRITICAL: Cannot clone the device containing the root filesystem!"
        dialog --title "Critical Error" \
            --msgbox "ERROR: You cannot clone the device ($device) that contains the root filesystem!\n\nThis would destroy the running system.\n\nPlease select a different device." 12 70
        return 1
    fi
    
    if findmnt -n -o SOURCE | grep -q "^$device"; then
        local mounted_parts=$(findmnt -n -o SOURCE,TARGET | grep "^$device" | grep -E '/$|/boot|/home|/usr|/var')
        if [ -n "$mounted_parts" ]; then
            log "⚠ WARNING: Device contains critical system partitions:"
            log "$mounted_parts"
            
            if ! dialog --title "⚠️ WARNING ⚠️" \
                --yesno "The selected device contains mounted system partitions:\n\n$mounted_parts\n\nCloning this device is dangerous and may crash the system.\n\nDo you want to continue anyway?" 14 70; then
                return 1
            fi
        fi
    fi
    
    return 0
}

is_filesystem_supported() {
    local partition="$1"
    local fs_type=$(lsblk -no FSTYPE "$partition" 2>/dev/null)
    
    case "$fs_type" in
        ext2|ext3|ext4|ntfs|fat32|fat16|vfat|btrfs|xfs)
            echo "yes"
            ;;
        *)
            echo "no"
            ;;
    esac
}

analyze_device_usage() {
    local device="$1"
    local total_used=0
    local partition_info=""
    local can_optimize=true
    
    log "Analyzing device partitions and filesystems..."
    
    local pt_type=$(get_partition_table_type "$device")
    log "Partition table type: $pt_type"
    
    if [ "$pt_type" = "gpt" ]; then
        local table_size=$((2 * 1024 * 1024))
    else
        local table_size=$((512 * 1024))
    fi
    
    total_used=$table_size
    
    while IFS= read -r part; do
        if [ -b "/dev/$part" ]; then
            local fs_type=$(get_filesystem_type "/dev/$part")
            local part_size=$(blockdev --getsize64 "/dev/$part" 2>/dev/null)
            
            if [ -n "$fs_type" ] && [ "$fs_type" != "" ]; then
                local used_space=$(get_filesystem_used_space "/dev/$part")
                local used_gb=$(echo "scale=2; $used_space / 1073741824" | bc)
                local part_gb=$(echo "scale=2; $part_size / 1073741824" | bc)
                
                log "  /dev/$part: ${fs_type} - Used: ${used_gb}GB of ${part_gb}GB"
                partition_info="${partition_info}  /dev/$part: ${fs_type} - Used: ${used_gb}GB / Total: ${part_gb}GB\n"
                
                local part_with_overhead=$(echo "scale=0; $used_space * 1.1 / 1" | bc)
                total_used=$((total_used + part_with_overhead))
                
                if [ "$(is_filesystem_supported "/dev/$part")" = "no" ]; then
                    can_optimize=false
                    log "    Warning: $fs_type may not support optimization"
                fi
            else
                log "  /dev/$part: Unknown/No filesystem - Full size: $(echo "scale=2; $part_size / 1073741824" | bc)GB"
                total_used=$((total_used + part_size))
                can_optimize=false
            fi
        fi
    done < <(lsblk -ln -o NAME "$device" | tail -n +2)
    
    if [ "$total_used" -eq "$table_size" ]; then
        total_used=$(blockdev --getsize64 "$device" 2>/dev/null)
        partition_info="No partitions detected, using full disk size"
        can_optimize=false
    fi
    
    log ""
    log "Summary:"
    printf '%b' "$partition_info" | while read line; do log "$line"; done
    log "Total space needed (with overhead): $(echo "scale=2; $total_used / 1073741824" | bc)GB"
    
    if [ "$can_optimize" = true ]; then
        log "✓ Device can be optimized for space"
    else
        log "⚠ Some partitions cannot be optimized"
    fi
    
    echo "$total_used"
}

is_efi_partition() {
    local partition="$1"
    local part_num="${partition##*[a-z]}"
    local disk_path="${partition%$part_num}"
    
    local part_type=$(fdisk -l "$disk_path" 2>/dev/null | grep "^$partition" | grep -i "EFI\|ef00" || true)
    local fs_type=$(get_filesystem_type "$partition")
    
    if [[ -n "$part_type" ]] || [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]; then
        if mount | grep -q "$partition"; then
            local mount_point=$(mount | grep "$partition" | awk '{print $3}' | head -n1)
            [[ -d "$mount_point/EFI" ]]
        else
            if [ "$DRY_RUN" = true ]; then
                log "🧪 DRY RUN - Would check if $partition contains EFI directory"
                [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]
            else
                local temp_mount="/tmp/efi_check_$"
                mkdir -p "$temp_mount"
                if mount "$partition" "$temp_mount" 2>/dev/null; then
                    local is_efi=false
                    [[ -d "$temp_mount/EFI" ]] && is_efi=true
                    umount "$temp_mount" 2>/dev/null || true
                    rmdir "$temp_mount" 2>/dev/null || true
                    $is_efi
                else
                    [[ "$fs_type" == "vfat" && "$part_num" == "1" ]]
                fi
            fi
        fi
    else
        false
    fi
}

check_optional_tools() {
    local missing_tools=()
    for tool in partclone.ext4 partclone.ntfs zerofree; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log "Optional optimization tools not found:"
        log "  ${missing_tools[*]}"
        log "For best results, install with: sudo apt-get install partclone zerofree"
        log "The script will work without them but with reduced optimization."
        sleep 3
    fi
}