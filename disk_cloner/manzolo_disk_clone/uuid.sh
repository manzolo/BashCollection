get_filesystem_uuid() {
    local partition="$1"
    blkid -s UUID -o value "$partition" 2>/dev/null || echo ""
}

get_partition_uuid() {
    local partition="$1"
    blkid -s PARTUUID -o value "$partition" 2>/dev/null || echo ""
}

get_disk_uuid() {
    local device="$1"
    blkid -s PTUUID -o value "$device" 2>/dev/null || echo ""
}

set_filesystem_uuid() {
    local partition="$1"
    local uuid="$2"
    local fs_type="$3"
    
    if [[ -z "$uuid" ]]; then
        log "Warning: No UUID to set for $partition"
        return 0
    fi
    
    case "$fs_type" in
        "ext2"|"ext3"|"ext4")
            log "Setting ext filesystem UUID: $uuid"
            dry_run_cmd tune2fs -U "$uuid" "$partition"
            ;;
        "vfat"|"fat32")
            log "Setting FAT filesystem UUID: $uuid"
            local fat_uuid=$(echo "$uuid" | tr -d '-' | cut -c1-8 | tr '[:lower:]' '[:upper:]')
            if command -v mlabel >/dev/null 2>&1; then
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would create mtools config and run: mlabel -N ${fat_uuid:0:8}"
                else
                    echo "drive z: file=\"$partition\"" > /tmp/mtools.conf.$
                    MTOOLSRC=/tmp/mtools.conf.$ mlabel -N "${fat_uuid:0:8}" z: 2>/dev/null || true
                    rm -f /tmp/mtools.conf.$
                fi
            else
                log "Warning: Cannot set FAT UUID - mlabel not available"
            fi
            ;;
        "ntfs")
            log "NTFS UUID preserved automatically by ntfsclone"
            ;;
        "swap")
            log "Setting swap UUID: $uuid"
            dry_run_cmd mkswap -U "$uuid" "$partition"
            ;;
        "xfs")
            log "Setting XFS UUID: $uuid"
            dry_run_cmd xfs_admin -U "$uuid" "$partition"
            ;;
        *)
            log "Warning: Cannot set UUID for filesystem type: $fs_type"
            ;;
    esac
}

set_partition_uuid() {
    local disk="$1"
    local part_num="$2"
    local part_uuid="$3"
    
    if [[ -z "$part_uuid" ]]; then
        log "Warning: No partition UUID to set for partition $part_num"
        return 0
    fi
    
    if command -v sgdisk >/dev/null 2>&1; then
        log "Setting partition UUID for partition $part_num: $part_uuid"
        dry_run_cmd sgdisk --partition-guid="$part_num:$part_uuid" "$disk"
    else
        log "Warning: sgdisk not available - cannot set partition UUID"
    fi
}

set_disk_uuid() {
    local disk="$1"
    local disk_uuid="$2"
    
    if [[ -z "$disk_uuid" ]]; then
        log "Warning: No disk UUID to set"
        return 0
    fi
    
    if command -v sgdisk >/dev/null 2>&1; then
        log "Setting disk UUID: $disk_uuid"
        dry_run_cmd sgdisk --disk-guid="$disk_uuid" "$disk"
    else
        log "Warning: sgdisk not available - cannot set disk UUID"
    fi
}

get_partitions_info_with_uuids() {
    local disk="$1"
    local -n partitions_ref=$2
    
    partitions_ref=()
    
    local disk_base=$(basename "$disk")
    local disk_uuid=$(get_disk_uuid "$disk")
    log "Source disk UUID: ${disk_uuid:-none}"
    
    local partitions_list
    partitions_list=$(lsblk -ln -o NAME "$disk" | grep "^${disk_base}[0-9]")
    
    if [[ -z "$partitions_list" ]]; then
        log "Warning: No partitions found on $disk"
        return 1
    fi
    
    while IFS= read -r partition_name; do
        local partition_path="/dev/$partition_name"
        
        if [[ ! -b "$partition_path" ]]; then
            log "Warning: Partition $partition_path does not exist, skipping"
            continue
        fi
        
        local size=$(blockdev --getsize64 "$partition_path" 2>/dev/null || echo "0")
        local fs_type=$(get_filesystem_type "$partition_path")
        local fs_uuid=$(get_filesystem_uuid "$partition_path")
        local part_uuid=$(get_partition_uuid "$partition_path")
        local is_efi=false
        
        if is_efi_partition "$partition_path"; then
            is_efi=true
        fi
        
        if [[ $size -gt 0 ]]; then
            partitions_ref+=("$partition_path,$size,$fs_type,$is_efi,$fs_uuid,$part_uuid,$disk_uuid")
            log "Found partition: $partition_path ($(numfmt --to=iec --suffix=B $size), $fs_type, EFI: $is_efi)"
            log "  FS UUID: ${fs_uuid:-none}, Part UUID: ${part_uuid:-none}"
        fi
    done <<< "$partitions_list"
    
    if [[ ${#partitions_ref[@]} -eq 0 ]]; then
        log "Error: No valid partitions found on $disk"
        return 1
    fi
    
    return 0
}