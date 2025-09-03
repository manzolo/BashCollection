create_and_format_disk() {
    log "Starting disk creation process..." >&2
    
    if [ -f "${DISK_NAME}" ]; then
        error "File '${DISK_NAME}' already exists." >&2
        if command -v whiptail >/dev/null 2>&1; then
            if ! whiptail --title "File Exists" --yesno "File '${DISK_NAME}' already exists. Overwrite?" 8 60; then
                log "Operation cancelled." >&2
                exit 0
            fi
        else
            read -p "File '${DISK_NAME}' already exists. Overwrite? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Operation cancelled." >&2
                exit 0
            fi
        fi
        rm -f "${DISK_NAME}" 2>/dev/null || { error "Failed to remove existing file '${DISK_NAME}'" >&2; exit 1; }
    fi

    log "DEBUG: PARTITIONS array: ${PARTITIONS[*]}" >&2
    
    # Validate total partition sizes
    local total_disk_bytes=$(size_to_bytes "$DISK_SIZE")
    local total_requested_bytes=0
    local part_size
    for part_info in "${PARTITIONS[@]}"; do
        IFS=':' read -r part_size _ <<< "${part_info}"
        if [ "$part_size" != "remaining" ]; then
            local size_bytes=$(size_to_bytes "$part_size")
            total_requested_bytes=$((total_requested_bytes + size_bytes))
        fi
    done
    if [ $total_requested_bytes -gt $total_disk_bytes ]; then
        error "Total requested partition sizes ($total_requested_bytes bytes) exceed disk size ($total_disk_bytes bytes)" >&2
        exit 1
    fi
    
    validate_mbr_partitions
    
    log "Creating disk ${DISK_NAME} with size ${DISK_SIZE} and format ${DISK_FORMAT}..." >&2
    
    local disk_bytes=$(size_to_bytes "$DISK_SIZE")
    log "DEBUG: Disk size in bytes: $disk_bytes" >&2
    local create_cmd="qemu-img create -f ${DISK_FORMAT}"
    
    if [ "$PREALLOCATION" = "full" ]; then
        case "$DISK_FORMAT" in
            "raw")
                create_cmd+=" -o preallocation=full"
                ;;
            "qcow2")
                create_cmd+=" -o preallocation=metadata"
                ;;
            "vpc")
                create_cmd+=" -o subformat=fixed"
                ;;
        esac
    else
        case "$DISK_FORMAT" in
            "vpc")
                #TODO: fix it
                #create_cmd+=" -o subformat=dynamic"
                create_cmd+=" -o subformat=fixed"
                ;;
        esac
    fi
    
    create_cmd+=" ${DISK_NAME} ${disk_bytes}"
    
    if [ "$VERBOSE" -eq 1 ]; then
        if ! eval $create_cmd 2>&1 | tee -a /dev/stderr; then
            error "Failed to create virtual disk." >&2
            exit 1
        fi
    else
        if ! eval $create_cmd >/dev/null 2>&1; then
            error "Failed to create virtual disk." >&2
            exit 1
        fi
    fi
    
    success "Virtual disk created successfully." >&2
    
    if [ "${#PARTITIONS[@]}" -gt 0 ]; then
        log "Setting up partitions..." >&2
        create_partitions "$disk_bytes"

        if [ -z "$DEVICE" ]; then
            error "DEVICE not set after create_partitions" >&2
            exit 1
        fi

        format_partitions "$DEVICE"
        log "Final partition table for ${DISK_NAME}:" >&2
        if [ "$VERBOSE" -eq 1 ]; then
            log "Full parted output:" >&2
            sudo parted -s "${DEVICE}" print >&2
            log "Formatted table:" >&2
        fi
        # Genera la tabella finale usando awk e column
        sudo parted -s "${DEVICE}" print | awk -v part_table="$PARTITION_TABLE" '
        BEGIN {
            # Colori ANSI (opzionale)
            BLUE="\033[1;34m"
            RESET="\033[0m"
            # Intestazione della tabella
            if (part_table == "mbr") {
                printf "%sNumber\tStart\tEnd\tSize\tFile system\tType\tName%s\n", BLUE, RESET
                printf "%s------\t-----\t-----\t-----\t-----------\t----\t----%s\n", BLUE, RESET
            } else {
                printf "%sNumber\tStart\tEnd\tSize\tFile system\tName%s\n", BLUE, RESET
                printf "%s------\t-----\t-----\t-----\t-----------\t----%s\n", BLUE, RESET
            }
        }
        /^[ ]*[0-9]+/ {
            # Rimuovi le unità e converti in byte
            start=$2; sub(/[a-zA-Z]+$/, "", start); start=start + 0
            end=$3; sub(/[a-zA-Z]+$/, "", end); end=end + 0
            size=$4; sub(/[a-zA-Z]+$/, "", size); size=size + 0
            # Converti kB, MB o GB in byte
            if ($2 ~ /kB$/) start *= 1000
            else if ($2 ~ /MB$/) start *= 1000000
            else if ($2 ~ /GB$/) start *= 1000000000
            if ($3 ~ /kB$/) end *= 1000
            else if ($3 ~ /MB$/) end *= 1000000
            else if ($3 ~ /GB$/) end *= 1000000000
            if ($4 ~ /kB$/) size *= 1000
            else if ($4 ~ /MB$/) size *= 1000000
            else if ($4 ~ /GB$/) size *= 1000000000
            number=$1
            fs=$5
            if (fs == "" || fs == "unknown") fs="none"
            if (fs == "linux-swap(v1)" || fs == "linux-swap") fs="swap"
            name=$6
            if (fs == "fat16" || fs == "fat32" || fs == "vfat") name="MS Basic Data"
            else if (fs == "swap") name="Linux Swap"
            else if (fs == "ext4" || fs == "ext3" || fs == "xfs" || fs == "btrfs") name="Linux FS"
            else if (fs == "ntfs") name="MS Basic Data"
            else if (name == "Microsoft_reserved_partition") name="MS Reserved"
            else if (name == "" || name == "unknown") name="Unformatted"
            # Converti in MiB
            start_mib=start / 1048576
            end_mib=end / 1048576
            size_mib=size / 1048576
            # Converti in formato human-friendly (MiB o GB)
            start_str = (start_mib >= 1024) ? sprintf("%.2f GB", start_mib / 1024) : sprintf("%.2f MiB", start_mib)
            end_str = (end_mib >= 1024) ? sprintf("%.2f GB", end_mib / 1024) : sprintf("%.2f MiB", end_mib)
            size_str = (size_mib >= 1024) ? sprintf("%.2f GB", size_mib / 1024) : sprintf("%.2f MiB", size_mib)
            # Output con tabulazioni
            if (part_table == "mbr") {
                if ($7 ~ /logical/) type="logical"
                else if ($7 ~ /extended/) type="extended"
                else type="primary"
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", number, start_str, end_str, size_str, fs, type, name
            } else {
                printf "%s\t%s\t%s\t%s\t%s\t%s\n", number, start_str, end_str, size_str, fs, name
            }
        }' | column -t -s $'\t'
        cleanup_device "$DEVICE"
    else
        success "Virtual disk created successfully (no partitions specified)." >&2
    fi
}