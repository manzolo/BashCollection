get_partition_table_type() {
    local device="$1"
    
    # First check with gdisk if available (most reliable for GPT)
    if command -v gdisk >/dev/null 2>&1; then
        local gdisk_output=$(echo 'p' | gdisk "$device" 2>/dev/null | head -20)
        if echo "$gdisk_output" | grep -qi "gpt\|guid partition table"; then
            echo "gpt"
            return
        fi
    fi
    
    # Check with parted
    local parted_output=$(parted "$device" print 2>/dev/null | head -10)
    if echo "$parted_output" | grep -qi "partition table: gpt"; then
        echo "gpt"
        return
    elif echo "$parted_output" | grep -qi "partition table: msdos\|partition table: dos"; then
        echo "mbr"
        return
    fi
    
    # Check with fdisk
    local fdisk_output=$(fdisk -l "$device" 2>/dev/null | head -10)
    if echo "$fdisk_output" | grep -qi "disklabel type: gpt"; then
        echo "gpt"
        return
    elif echo "$fdisk_output" | grep -qi "disklabel type: dos"; then
        echo "mbr"
        return
    fi
    
    # Binary check as fallback
    if dd if="$device" bs=1 count=8 skip=512 2>/dev/null | grep -q "EFI PART"; then
        echo "gpt"
    else
        echo "mbr"
    fi
}

copy_gpt_partition_table_safe() {
    local source_device="$1"
    local target_device="$2"
    
    log "Copying GPT partition table safely..."
    
    # Get actual device size to calculate backup GPT location correctly
    local device_size=$(blockdev --getsize64 "$source_device")
    local sector_size=512
    local total_sectors=$((device_size / sector_size))
    
    # Copy primary GPT (first 34 sectors)
    log "Copying primary GPT header and table..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would copy primary GPT: dd if='$source_device' of='$target_device' bs=512 count=34 conv=notrunc"
    else
        dd if="$source_device" of="$target_device" bs=512 count=34 conv=notrunc 2>/dev/null || {
            log "Error: Failed to copy primary GPT"
            return 1
        }
    fi
    
    # Instead of copying backup GPT directly, let sgdisk regenerate it
    log "Regenerating backup GPT header..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would regenerate backup GPT: sgdisk -e '$target_device'"
    else
        # Force regeneration of backup GPT
        sgdisk -e "$target_device" 2>/dev/null || {
            log "Warning: Could not regenerate backup GPT with sgdisk"
            # Fallback: use parted to fix the table
            parted "$target_device" --script print 2>/dev/null || true
        }
    fi
    
    # Verify the partition table
    log "Verifying GPT integrity..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would verify with: sgdisk -v '$target_device'"
    else
        if sgdisk -v "$target_device" >/dev/null 2>&1; then
            log "✓ GPT partition table is valid"
        else
            log "⚠ GPT partition table has issues, attempting repair..."
            sgdisk -e "$target_device" 2>/dev/null || true
        fi
    fi
    
    return 0
}

setup_partition_mappings() {
    local loop_dev="$1"
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would setup partition mappings for $loop_dev"
        return 0
    fi
    
    log "Setting up partition mappings..."
    
    # Try partprobe first
    partprobe "$loop_dev" 2>/dev/null || true
    sleep 2
    
    # Try kpartx if available
    if command -v kpartx >/dev/null 2>&1; then
        kpartx -av "$loop_dev" 2>/dev/null || true
    fi
    
    # Try partx as fallback
    if command -v partx >/dev/null 2>&1; then
        partx -a "$loop_dev" 2>/dev/null || true
    fi
    
    # Wait for devices to appear with timeout
    local timeout=10
    local count=0
    while [ $count -lt $timeout ]; do
        if ls "${loop_dev}"p* 2>/dev/null | head -1 >/dev/null; then
            log "✓ Partition mappings created successfully"
            return 0
        fi
        sleep 1
        count=$((count + 1))
        partprobe "$loop_dev" 2>/dev/null || true
    done
    
    log "⚠ Warning: Partition mappings may not be available"
    return 0  # Don't fail completely
}

create_partitions_with_uuids() {
    local target_disk="$1"
    local -n source_parts_ref=$2
    local -n target_sizes_ref=$3
    
    log "Creating GPT partition table on $target_disk with UUID preservation"
    
    local source_disk_uuid=""
    if [[ ${#source_parts_ref[@]} -gt 0 ]]; then
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[0]}"
        source_disk_uuid="$disk_uuid"
    fi
    
    dry_run_cmd wipefs -af "$target_disk"
    dry_run_cmd parted "$target_disk" --script mklabel gpt
    
    if [[ -n "$source_disk_uuid" ]]; then
        set_disk_uuid "$target_disk" "$source_disk_uuid"
    fi
    
    local sector_size=512
    local start_sector=2048
    
    for i in "${!source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        local target_size="${target_sizes_ref[$i]}"
        local part_num=$((i+1))
        
        local size_sectors=$((target_size / sector_size))
        
        if [[ "$fs_type" == "crypto_LUKS" ]]; then
            local source_sectors=$((size / sector_size))
            if [[ $size_sectors -lt $source_sectors ]]; then
                size_sectors=$source_sectors
                log "Adjusting LUKS partition size to match source: $size_sectors sectors"
            fi
        fi
        
        if [[ "$fs_type" != "crypto_LUKS" ]]; then
            size_sectors=$(((size_sectors / 2048) * 2048))
        else
            size_sectors=$(((size_sectors + 2047) / 2048 * 2048))
        fi
        
        local end_sector=$((start_sector + size_sectors - 1))
        
        log "Creating partition ${part_num} (sectors ${start_sector} to ${end_sector}, size: $(numfmt --to=iec --suffix=B $((size_sectors * sector_size))))"
        
        if [[ "$is_efi" == "true" ]]; then
            dry_run_cmd parted "$target_disk" --script mkpart "EFI" fat32 "${start_sector}s" "${end_sector}s"
            dry_run_cmd parted "$target_disk" --script set $part_num esp on
        else
            local part_name="partition${part_num}"
            dry_run_cmd parted "$target_disk" --script mkpart "$part_name" "${start_sector}s" "${end_sector}s"
        fi
        
        target_sizes_ref[$i]=$((size_sectors * sector_size))
        
        start_sector=$((end_sector + 1))
        local remainder=$((start_sector % 2048))
        if [[ $remainder -ne 0 ]]; then
            start_sector=$((start_sector + 2048 - remainder))
        fi
    done
    
    dry_run_cmd partprobe "$target_disk"
    if [ "$DRY_RUN" = false ]; then
        sleep 3
    fi
    
    for i in "${!source_parts_ref[@]}"; do
        local target_partition="${target_disk}$((i+1))"
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would wait for partition $target_partition to be created"
        else
            local count=0
            while [[ ! -b "$target_partition" && $count -lt 10 ]]; do
                sleep 1
                count=$((count + 1))
                partprobe "$target_disk" 2>/dev/null || true
            done
            
            if [[ ! -b "$target_partition" ]]; then
                log "Error: Failed to create partition $target_partition"
                return 1
            fi
        fi
        
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_parts_ref[$i]}"
        if [[ -n "$part_uuid" ]]; then
            set_partition_uuid "$target_disk" "$((i+1))" "$part_uuid"
        fi
        
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Partition $target_partition would be created with size: $(numfmt --to=iec --suffix=B ${target_sizes_ref[$i]})"
        else
            local actual_size=$(blockdev --getsize64 "$target_partition" 2>/dev/null || echo "0")
            log "Partition $target_partition created with size: $(numfmt --to=iec --suffix=B $actual_size)"
        fi
    done
    
    dry_run_cmd partprobe "$target_disk"
    if [ "$DRY_RUN" = false ]; then
        sleep 2
    fi
    return 0
}