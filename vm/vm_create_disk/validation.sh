
# Comprehensive configuration validation
validate_configuration() {
    local errors=0
    
    # Check required variables
    if [ -z "$DISK_NAME" ]; then
        log_error "DISK_NAME is required"
        ((errors++))
    fi
    
    if [ -z "$DISK_SIZE" ]; then
        log_error "DISK_SIZE is required"
        ((errors++))
    elif ! validate_size "$DISK_SIZE"; then
        log_error "Invalid DISK_SIZE format: $DISK_SIZE"
        ((errors++))
    fi
    
    if [ -z "$DISK_FORMAT" ]; then
        log_error "DISK_FORMAT is required"
        ((errors++))
    elif [[ ! "$DISK_FORMAT" =~ ^(qcow2|raw)$ ]]; then
        log_error "Invalid DISK_FORMAT: $DISK_FORMAT (must be qcow2 or raw)"
        ((errors++))
    fi
    
    # Set defaults
    PARTITION_TABLE=${PARTITION_TABLE:-"mbr"}
    PREALLOCATION=${PREALLOCATION:-"off"}
    
    # Validate partition table type
    if [[ ! "$PARTITION_TABLE" =~ ^(mbr|gpt)$ ]]; then
        log_error "Invalid PARTITION_TABLE: $PARTITION_TABLE (must be mbr or gpt)"
        ((errors++))
    fi
    
    # Validate partitions if specified
    if [ ${#PARTITIONS[@]} -gt 0 ]; then
        validate_partition_specs
        ((errors += $?))
    fi
    
    # Check available disk space
    validate_disk_space
    ((errors += $?))
    
    return $errors
}

# Validate partition specifications
validate_partition_specs() {
    local errors=0
    local total_bytes=0
    local disk_bytes
    
    disk_bytes=$(size_to_bytes "$DISK_SIZE")
    
    local remaining_count=0
    for part_spec in "${PARTITIONS[@]}"; do
        if [[ "$part_spec" =~ :remaining: ]]; then
            ((remaining_count++))
        fi
    done
    
    if [ $remaining_count -gt 1 ]; then
        log_error "Only one partition can use 'remaining' size"
        ((errors++))
        return $errors
    fi
    
    for i in "${!PARTITIONS[@]}"; do
        local part_spec="${PARTITIONS[$i]}"
        IFS=':' read -r part_size part_fs part_type <<< "$part_spec"
        
        # Validate partition format
        if [[ ! "$part_spec" =~ ^[^:]+:[^:]*(:[^:]+)?$ ]]; then
            log_error "Invalid partition format at index $i: $part_spec"
            ((errors++))
            continue
        fi
        
        # Validate size
        if [ "$part_size" != "remaining" ]; then
            if ! validate_size "$part_size"; then
                log_error "Invalid partition size at index $i: $part_size"
                ((errors++))
                continue
            fi
            
            local part_bytes
            part_bytes=$(size_to_bytes "$part_size")
            total_bytes=$((total_bytes + part_bytes))
        fi
        
        # Validate filesystem type
        if [[ -n "$part_fs" && ! "$part_fs" =~ ^(none|ext[234]|xfs|btrfs|ntfs|fat(16|32)|vfat|swap|msr)$ ]]; then
            log_error "Invalid filesystem type at index $i: $part_fs"
            ((errors++))
        fi
        
        # Validate partition type for MBR
        if [ "$PARTITION_TABLE" = "mbr" ] && [[ -n "$part_type" && ! "$part_type" =~ ^(primary|extended|logical)$ ]]; then
            log_error "Invalid MBR partition type at index $i: $part_type"
            ((errors++))
        fi
    done
    
    # Check total size doesn't exceed disk
    if [ $remaining_count -eq 0 ] && [ $total_bytes -gt $disk_bytes ]; then
        log_error "Total partition sizes ($total_bytes bytes) exceed disk capacity ($disk_bytes bytes)"
        ((errors++))
    fi
    
    return $errors
}

# Check available disk space
validate_disk_space() {
    local disk_bytes
    disk_bytes=$(size_to_bytes "$DISK_SIZE")
    
    # Get available space in current directory
    local available_bytes
    available_bytes=$(df --output=avail . | tail -1)
    available_bytes=$((available_bytes * 1024)) # df returns KB
    
    # For raw disks with full preallocation, we need the full size
    # For sparse allocation, we need much less initially
    local required_bytes
    if [ "$PREALLOCATION" = "full" ]; then
        required_bytes=$disk_bytes
    else
        # Sparse files need minimal space initially, but check for at least 100MB
        required_bytes=$((100 * 1024 * 1024))
    fi
    
    if [ $available_bytes -lt $required_bytes ]; then
        log_error "Insufficient disk space: need $(bytes_to_human $required_bytes), have $(bytes_to_human $available_bytes)"
        return 1
    fi
    
    return 0
}

# Check if running as root or with sudo access
check_privileges() {
    if [ "$EUID" -eq 0 ]; then
        return 0
    fi
    
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    
    log_error "This script requires sudo privileges"
    return 1
}