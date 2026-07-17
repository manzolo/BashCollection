calculate_proportional_sizes() {
    local source_disk="$1"
    local target_disk="$2"
    local -n source_parts_ref=$3
    local -n target_sizes_ref=$4
    
    local source_size=$(blockdev --getsize64 "$source_disk" 2>/dev/null || echo "0")
    local target_size=$(blockdev --getsize64 "$target_disk" 2>/dev/null || echo "0")
    
    target_sizes_ref=()
    
    log "Source disk size: $(numfmt --to=iec --suffix=B $source_size)"
    log "Target disk size: $(numfmt --to=iec --suffix=B $target_size)"
    
    local total_partitions_size=0
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        total_partitions_size=$((total_partitions_size + size))
    done
    
    log "Total partitions size: $(numfmt --to=iec --suffix=B $total_partitions_size)"
    
    local usable_target_size=$((target_size - 4 * 1024 * 1024))
    
    if [[ $total_partitions_size -le $usable_target_size ]]; then
        log "Target disk has enough space, keeping original sizes"
        for part_info in "${source_parts_ref[@]}"; do
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
            target_sizes_ref+=("$size")
        done
        return
    fi
    
    log "Target disk is smaller, calculating proportional sizes..."
    
    local total_efi_size=0
    local total_other_size=0
    
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        if [[ "$is_efi" == "true" ]]; then
            total_efi_size=$((total_efi_size + size))
        else
            total_other_size=$((total_other_size + size))
        fi
    done
    
    if [[ $total_efi_size -gt $usable_target_size ]]; then
        log "Error: EFI partitions ($(numfmt --to=iec --suffix=B $total_efi_size)) don't fit in target disk"
        return 1
    fi
    
    local remaining_size=$((usable_target_size - total_efi_size))
    
    for part_info in "${source_parts_ref[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "$part_info"
        
        if [[ "$is_efi" == "true" ]]; then
            target_sizes_ref+=("$size")
        else
            if [[ $total_other_size -eq 0 ]]; then
                target_sizes_ref+=("$size")
            else
                local new_size=$((size * remaining_size / total_other_size))
                new_size=$(((new_size / 1048576) * 1048576))
                [[ $new_size -lt 1048576 ]] && new_size=1048576
                target_sizes_ref+=("$new_size")
            fi
        fi
    done
}

# ───────────────────────────────
# Size alignment helper
# ───────────────────────────────
calculate_aligned_size() {
    local size="$1"
    local alignment="${2:-1048576}"  # Default 1MB
    echo $(( (size + alignment - 1) / alignment * alignment ))
}