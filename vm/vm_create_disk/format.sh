# Updated create_and_format_disk function
create_and_format_disk() {
    log "Starting disk creation process..."
    
    if [ -f "${DISK_NAME}" ]; then
        error "File '${DISK_NAME}' already exists."
        if command -v whiptail >/dev/null 2>&1; then
            if ! whiptail --title "File Exists" --yesno "File '${DISK_NAME}' already exists. Overwrite?" 8 60; then
                log "Operation cancelled."
                exit 0
            fi
        else
            read -p "File '${DISK_NAME}' already exists. Overwrite? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Operation cancelled."
                exit 0
            fi
        fi
        rm -f "${DISK_NAME}" 2>/dev/null || { error "Failed to remove existing file '${DISK_NAME}'"; exit 1; }
    fi

    validate_mbr_partitions
    
    log "Creating disk ${DISK_NAME} with size ${DISK_SIZE} and format ${DISK_FORMAT}..."
    
    local create_cmd="qemu-img create -f ${DISK_FORMAT}"
    
    if [ "$PREALLOCATION" = "full" ]; then
        case "$DISK_FORMAT" in
            "raw")
                create_cmd+=" -o preallocation=full"
                ;;
            "qcow2")
                create_cmd+=" -o preallocation=metadata"
                ;;
        esac
    fi
    
    create_cmd+=" ${DISK_NAME} ${DISK_SIZE}"
    
    if [ "$VERBOSE" -eq 1 ]; then
        if ! eval $create_cmd; then
            error "Failed to create virtual disk."
            exit 1
        fi
    else
        if ! eval $create_cmd >/dev/null 2>&1; then
            error "Failed to create virtual disk."
            exit 1
        fi
    fi
    
    success "Virtual disk created successfully."
    
    if [ "${#PARTITIONS[@]}" -gt 0 ]; then
        log "Setting up partitions..."
        create_partitions

        # Ensure DEVICE is set
        if [ -z "$DEVICE" ]; then
            error "DEVICE not set after create_partitions"
            exit 1
        fi

        # Passa il device alla funzione
        format_partitions "$DEVICE"
        log "Final partition table for ${DISK_NAME}:"
        if [ "$VERBOSE" -eq 1 ]; then
            log "Full parted output:"
            sudo parted -s "${DEVICE}" print
            log "Formatted table:"
        fi
        # Generate tabular output
        sudo parted -s "${DEVICE}" print | awk -v part_table="$PARTITION_TABLE" '
            BEGIN {
                if (part_table == "mbr") {
                    printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", "Number", "Start", "End", "Size", "File system", "Type", "Name"
                    printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", "------", "-------", "-------", "-------", "-----------", "-------", "----"
                } else {
                    printf "%-8s %-12s %-12s %-12s %-12s %s\n", "Number", "Start", "End", "Size", "File system", "Name"
                    printf "%-8s %-12s %-12s %-12s %-12s %s\n", "------", "-------", "-------", "-------", "-----------", "----"
                }
            }
            /^[ ]*[0-9]+/ {
                fs=$5
                if (fs == "" || fs == "unknown") fs="none"
                if (fs == "linux-swap(v1)" || fs == "linux-swap") fs="swap"
                name=$6
                if (fs == "fat16" || fs == "fat32" || fs == "vfat") name="Microsoft basic data"
                else if (fs == "swap") name="Linux swap"
                else if (fs == "ext4" || fs == "ext3" || fs == "xfs" || fs == "btrfs") name="Linux filesystem"
                else if (name == "" || name == "unknown") name="Unformatted"
                type=""
                if (part_table == "mbr") {
                    if ($7 ~ /logical/) type="logical"
                    else if ($7 ~ /extended/) type="extended"
                    else type="primary"
                    printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", $1, $2, $3, $4, fs, type, name
                } else {
                    printf "%-8s %-12s %-12s %-12s %-12s %s\n", $1, $2, $3, $4, fs, name
                }
            }' | while IFS= read -r line; do
                log "  $line"
            done
        cleanup_device "${DEVICE}"
    else
        success "Virtual disk created successfully (no partitions specified)."
    fi
}