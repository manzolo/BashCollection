validate_mbr_partitions() {
    if [ "$PARTITION_TABLE" != "mbr" ]; then
        return 0
    fi
    
    local primary_count=0
    local extended_count=0
    local logical_count=0
    local logical_partitions=()
    local other_partitions=()
    
    # Prima passata: conteggio tipi di partizione
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
        case "$part_type" in
            "primary")  primary_count=$((primary_count + 1)); other_partitions+=("$part_info") ;;
            "extended") extended_count=$((extended_count + 1)); other_partitions+=("$part_info") ;;
            "logical")  logical_count=$((logical_count + 1)); logical_partitions+=("$part_info") ;;
            *)          other_partitions+=("$part_info") ;; # default = primary
        esac
    done
    
    # Se ci sono logiche senza estesa → aggiungila
    if [ $logical_count -gt 0 ] && [ $extended_count -eq 0 ]; then
        log "Logical partitions detected without an extended partition. Adding an extended partition."
        
        local has_remaining_logical=false
        local logical_total_bytes=0
        
        for part_info in "${logical_partitions[@]}"; do
            IFS=':' read -r part_size part_fs part_type <<< "${part_info}"
            if [ "$part_size" = "remaining" ]; then
                has_remaining_logical=true
                break
            fi
            logical_total_bytes=$((logical_total_bytes + $(size_to_bytes "$part_size")))
        done
        
        local extended_size
        if [ "$has_remaining_logical" = true ]; then
            extended_size="remaining"
        else
            # Overhead di 32 MiB per logica
            local overhead_per_logical=$((32 * 1024 * 1024))
            local overhead_bytes=$((overhead_per_logical * logical_count))
            local extended_total_bytes=$((logical_total_bytes + overhead_bytes + 64*1024*1024)) # +64 MiB margine
            
            # Arrotonda al GiB superiore
            local gib=$((1024 * 1024 * 1024))
            local rounded=$(( (extended_total_bytes + gib - 1) / gib * gib ))
            extended_size=$(bytes_to_readable "$rounded")
            
            log "DEBUG: Logical partitions total: $(bytes_to_readable $logical_total_bytes)"
            log "DEBUG: Extended partition size with overhead ($logical_count logical partitions): $extended_size"
        fi
        
        PARTITIONS=()
        for part in "${other_partitions[@]}"; do
            PARTITIONS+=("$part")
        done
        PARTITIONS+=("${extended_size}:none:extended")
        for part in "${logical_partitions[@]}"; do
            PARTITIONS+=("$part")
        done
        
        extended_count=1
        log "Added extended partition of size $extended_size containing $logical_count logical partition(s)"
    fi
    
    # Vincoli MBR
    local total_primary_extended=$((primary_count + extended_count))
    if [ $total_primary_extended -gt 4 ]; then
        error "MBR partition table can have max 4 primary+extended partitions (found: $total_primary_extended)"
        return 1
    fi
    if [ $extended_count -gt 1 ]; then
        error "MBR can have only 1 extended partition (found: $extended_count)"
        return 1
    fi
    
    return 0
}