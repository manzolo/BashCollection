clone_partitions_with_uuid_preservation() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_partition="${target_disk}$((i+1))"
        
        log "Cloning $source_partition to $target_partition with UUID preservation"
        log "Filesystem type: ${fs_type:-unknown}, EFI: $is_efi"
        log "FS UUID: ${fs_uuid:-none}"
        
        if [[ ! -b "$source_partition" ]] || ([[ ! -b "$target_partition" ]] && [ "$DRY_RUN" = false ]); then
            log "Error: Source or target partition does not exist"
            continue
        fi
        
        local source_size=$(blockdev --getsize64 "$source_partition" 2>/dev/null || echo "0")
        local target_size
        if [ "$DRY_RUN" = true ]; then
            target_size=$source_size  # Assume same size for dry run
        else
            target_size=$(blockdev --getsize64 "$target_partition" 2>/dev/null || echo "0")
        fi
        
        log "Source size: $(numfmt --to=iec --suffix=B $source_size)"
        log "Target size: $(numfmt --to=iec --suffix=B $target_size)"
        
        local copy_size=$source_size
        local size_diff=$((source_size - target_size))
        local tolerance=$((1024 * 1024))

        if [[ $size_diff -gt $tolerance ]]; then
            copy_size=$target_size
            log "Warning: Target partition is significantly smaller, copying only $(numfmt --to=iec --suffix=B $copy_size)"
        elif [[ $target_size -lt $source_size ]]; then
            copy_size=$target_size
            log "Target partition slightly smaller due to alignment, copying $(numfmt --to=iec --suffix=B $copy_size)"
        fi
        
        local block_size=1048576
        local blocks_to_copy=$((copy_size / block_size))
        
        case "$fs_type" in
            "vfat"|"fat32")
                log "Using dd for FAT filesystem (copying $blocks_to_copy blocks of 1MB)"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress 
                        }
                    fi
                else
                    log "Warning: Partition too small, copying sector by sector"
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress 
                    fi
                fi
                set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                ;;
            "ext2"|"ext3"|"ext4")
                log "Using e2image for ext filesystem"
                dry_run_cmd e2fsck -fy "$source_partition"
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would run: e2image -ra -p '$source_partition' '$target_partition'"
                    if [[ $target_size -gt $source_size ]]; then
                        log "🧪 DRY RUN - Would run: resize2fs '$target_partition'"
                    fi
                else
                    e2image -ra -p "$source_partition" "$target_partition" 2>/dev/null
                    if [[ $target_size -gt $source_size ]]; then
                        resize2fs "$target_partition" 2>/dev/null || true
                    fi
                fi
                log "UUID preserved by e2image: $fs_uuid"
                ;;
            "ntfs")
                if command -v ntfsclone >/dev/null 2>&1; then
                    log "Using ntfsclone for NTFS filesystem"
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: ntfsclone -f --overwrite '$target_partition' '$source_partition'"
                        if [[ $target_size -gt $source_size ]]; then
                            log "🧪 DRY RUN - Would run: ntfsresize -f '$target_partition'"
                        fi
                    else
                        ntfsclone -f --overwrite "$target_partition" "$source_partition" 2>/dev/null
                        if [[ $target_size -gt $source_size ]]; then
                            ntfsresize -f "$target_partition" 2>/dev/null || true
                        fi
                    fi
                    log "UUID preserved by ntfsclone: $fs_uuid"
                else
                    log "Warning: ntfsclone not available, using dd with size limit"
                    if [[ $blocks_to_copy -gt 0 ]]; then
                        if [ "$DRY_RUN" = true ]; then
                            log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                        else
                            dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                        fi
                    fi
                    log "Warning: UUID may not be preserved with dd copy"
                fi
                ;;
            "crypto_LUKS")
                local source_sectors=$((source_size / 512))
                local target_sectors=$((target_size / 512))
                
                if [[ $source_sectors -gt $target_sectors ]]; then
                    log "Error: LUKS partition cannot be truncated: source has $source_sectors sectors, target has $target_sectors"
                    continue
                fi
                
                log "Using dd with exact sector copy for LUKS container"
                local sectors_to_copy=$source_sectors
                
                if [ "$DRY_RUN" = true ]; then
                    log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$sectors_to_copy status=progress conv=noerror,sync"
                else
                    dd if="$source_partition" of="$target_partition" bs=512 count=$sectors_to_copy status=progress conv=noerror,sync
                fi
                
                if command -v cryptsetup >/dev/null 2>&1; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would verify LUKS header with: cryptsetup luksDump '$target_partition'"
                    elif cryptsetup luksDump "$target_partition" >/dev/null 2>&1; then
                        log "LUKS header verified successfully"
                    else
                        log "Error: LUKS header verification failed - partition may be corrupted"
                    fi
                else
                    log "Warning: cryptsetup not available - cannot verify LUKS integrity"
                fi
                
                log "LUKS UUID preserved in header: $fs_uuid"
                ;;
            "swap")
                log "Creating new swap partition with preserved UUID"
                if [[ -n "$fs_uuid" ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: mkswap -U '$fs_uuid' '$target_partition'"
                    else
                        mkswap -U "$fs_uuid" "$target_partition" 2>/dev/null
                    fi
                    log "Swap UUID set to: $fs_uuid"
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: mkswap '$target_partition'"
                    else
                        mkswap "$target_partition" 2>/dev/null
                    fi
                    log "New swap partition created"
                fi
                ;;
            "xfs")
                log "Using dd for XFS filesystem"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                        }
                    fi
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                fi
                if [[ -n "$fs_uuid" ]]; then
                    set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                fi
                ;;
            "")
                log "Warning: Unknown filesystem, attempting dd copy with size limit"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                        }
                    fi
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                fi
                ;;
            *)
                log "Warning: Unsupported filesystem $fs_type, using dd with size limit"
                if [[ $blocks_to_copy -gt 0 ]]; then
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=$block_size count=$blocks_to_copy status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=$block_size count=$blocks_to_copy status=progress || {
                            log "Warning: dd with 1MB blocks failed, trying with 512KB"
                            local small_block_size=524288
                            local small_blocks_to_copy=$((copy_size / small_block_size))
                            dd if="$source_partition" of="$target_partition" bs=$small_block_size count=$small_blocks_to_copy status=progress
                        }
                    fi
                else
                    if [ "$DRY_RUN" = true ]; then
                        log "🧪 DRY RUN - Would run: dd if='$source_partition' of='$target_partition' bs=512 count=$((copy_size / 512)) status=progress"
                    else
                        dd if="$source_partition" of="$target_partition" bs=512 count=$((copy_size / 512)) status=progress
                    fi
                fi
                if [[ -n "$fs_uuid" ]]; then
                    set_filesystem_uuid "$target_partition" "$fs_uuid" "$fs_type"
                fi
                ;;
        esac
        
        log "Successfully cloned $source_partition to $target_partition"
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would verify UUID preservation"
        else
            local new_fs_uuid=$(get_filesystem_uuid "$target_partition")
            if [[ -n "$new_fs_uuid" && "$new_fs_uuid" == "$fs_uuid" ]]; then
                log "UUID correctly preserved: $new_fs_uuid"
            elif [[ -n "$new_fs_uuid" ]]; then
                log "Warning: UUID changed: $fs_uuid -> $new_fs_uuid"
            else
                log "Warning: No UUID found on target partition"
            fi
        fi
    done
}