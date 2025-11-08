# Function to display disk information
info_disk() {
    local DISK_IMAGE=$1

    if [ ! -f "${DISK_IMAGE}" ]; then
        error "Disk image '${DISK_IMAGE}' not found."
        exit 1
    fi

    log "Disk Information for: ${DISK_IMAGE}"
    echo

    # Get disk format and size using qemu-img
    local QEMU_INFO
    QEMU_INFO=$(qemu-img info "${DISK_IMAGE}" 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read disk image info for ${DISK_IMAGE}"
        exit 1
    fi

    local DISK_NAME=$(basename "${DISK_IMAGE}")
    local DISK_FORMAT=$(echo "$QEMU_INFO" | grep "file format" | awk '{print $3}')
    local disk_size_bytes=$(echo "$QEMU_INFO" | grep "virtual size" | grep -oP '\(\K[0-9]+(?=\s*bytes)')
    local DISK_SIZE=$(bytes_to_readable "$disk_size_bytes")
    local disk_size_human=$(echo "$QEMU_INFO" | grep "virtual size" | awk '{for(i=3;i<=NF;i++) if($i !~ /^\(/) printf "%s ", $i}' | sed 's/,.*$//')
    
    # Get allocated size
    local actual_size_bytes=$(echo "$QEMU_INFO" | grep "disk size" | grep -oP '\(\K[0-9]+(?=\s*bytes)' || echo "$disk_size_bytes")
    local actual_size=$(bytes_to_readable "$actual_size_bytes")

    echo -e "${BLUE}=== DISK IMAGE INFORMATION ===${NC}"
    printf "%-20s %s\n" "File name:" "$DISK_NAME"
    printf "%-20s %s\n" "File format:" "$DISK_FORMAT"
    printf "%-20s %s (%s bytes)\n" "Virtual size:" "$disk_size_human" "$disk_size_bytes"
    printf "%-20s %s (%s bytes)\n" "Actual size:" "$actual_size" "$actual_size_bytes"
    
    # Calculate compression ratio for qcow2
    if [ "$DISK_FORMAT" = "qcow2" ] && [ "$actual_size_bytes" -ne "$disk_size_bytes" ]; then
        local compression_ratio=$(echo "scale=1; $actual_size_bytes * 100 / $disk_size_bytes" | bc 2>/dev/null || echo "N/A")
        if [ "$compression_ratio" != "N/A" ]; then
            printf "%-20s %s%%\n" "Space usage:" "$compression_ratio"
        fi
    fi
    
    echo

    # Set up device to read partition table
    local DEVICE=""
    if [ "$DISK_FORMAT" = "qcow2" ]; then
        log "Loading qemu-nbd kernel module..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo modprobe nbd max_part=16
        else
            sudo modprobe nbd max_part=16 >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to load qemu-nbd kernel module."
            exit 1
        fi

        for i in {0..15}; do
            if [ ! -e "/sys/block/nbd$i/pid" ]; then
                DEVICE="/dev/nbd$i"
                break
            fi
        done

        if [ -z "$DEVICE" ]; then
            error "No available NBD devices"
            exit 1
        fi

        log "Connecting to device for partition analysis..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --connect="$DEVICE" "$DISK_IMAGE"
        else
            sudo qemu-nbd --connect="$DEVICE" "$DISK_IMAGE" >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to connect qcow2 image via qemu-nbd"
            exit 1
        fi

        sleep 3
    else
        log "Setting up loop device for partition analysis..."
        if [ "$VERBOSE" -eq 1 ]; then
            DEVICE=$(sudo losetup -f --show "${DISK_IMAGE}")
        else
            DEVICE=$(sudo losetup -f --show "${DISK_IMAGE}" 2>/dev/null)
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create loop device for ${DISK_IMAGE}"
            exit 1
        fi
        sleep 1
    fi

    # Wait for device to be ready and probe partitions
    sudo partprobe "${DEVICE}" >/dev/null 2>&1
    udevadm settle >/dev/null 2>&1
    sleep 2

    # Get partition table information
    local PARTED_INFO
    PARTED_INFO=$(LC_ALL=C sudo parted -s "${DEVICE}" print 2>/dev/null)
    if [ $? -ne 0 ]; then
        warning "Failed to read partition table from ${DEVICE}"
        cleanup_device "$DEVICE"
        echo -e "${YELLOW}No partition table found or disk is not partitioned.${NC}"
        exit 0
    fi

    local PARTITION_TABLE=$(echo "$PARTED_INFO" | grep -E "^Partition Table:" | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    
    echo -e "${BLUE}=== PARTITION TABLE INFORMATION ===${NC}"
    printf "%-20s %s\n" "Partition table:" "${PARTITION_TABLE^^}"
    echo

    # Check if there are any partitions
    local partition_count=$(echo "$PARTED_INFO" | grep -c "^[ ]*[0-9]")
    
    if [ "$partition_count" -eq 0 ]; then
        echo -e "${YELLOW}No partitions found on this disk.${NC}"
        cleanup_device "$DEVICE"
        exit 0
    fi

    # Get filesystem information using blkid
    local blkid_info=""
    blkid_info=$(sudo blkid "${DEVICE}"* 2>/dev/null || true)

    echo -e "${BLUE}=== PARTITION INFORMATION ===${NC}"
    
    # Generate table header
    if [ "$PARTITION_TABLE" = "mbr" ]; then
        printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n" "Number" "Start" "End" "Size" "File system" "Type" "Name"
        printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n" "------" "-------" "-------" "-------" "-----------" "-------" "----"
    else
        printf "%-8s %-12s %-12s %-12s %-12s %s\n" "Number" "Start" "End" "Size" "File system" "Name"
        printf "%-8s %-12s %-12s %-12s %-12s %s\n" "------" "-------" "-------" "-------" "-----------" "----"
    fi

    # Parse and display partition information
    echo "$PARTED_INFO" | awk -v part_table="$PARTITION_TABLE" -v blkid_info="$blkid_info" -v device="$DEVICE" '
        /^[ ]*[0-9]+/ {
            num=$1; start=$2; end=$3; size=$4
            fs=""; type=""; name=""
            
            # Parse remaining fields
            for(i=5; i<=NF; i++) {
                if ($i ~ /^(primary|logical|extended)$/) {
                    type=$i
                } else if ($i !~ /^(boot|swap|lvm|raid|lba|legacy_boot|hidden)$/ && fs == "") {
                    fs=$i
                }
            }
            
            # Get filesystem from blkid if available
            part_device = device "p" num
            cmd = "echo \"" blkid_info "\" | grep \"^" part_device ":\" | head -1"
            cmd | getline blkid_line
            close(cmd)
            
            if (blkid_line != "") {
                if (match(blkid_line, /TYPE="([^"]*)"/, arr)) {
                    actual_fs = arr[1]
                    if (actual_fs == "linux-swap" || actual_fs == "linux-swap(v1)") {
                        fs = "swap"
                    } else if (actual_fs != "") {
                        fs = actual_fs
                    }
                }
            }
            
            # Clean up filesystem name
            if (fs == "" || fs == "unknown") fs = "none"
            if (fs == "linux-swap(v1)" || fs == "linux-swap") fs = "swap"
            
            # Determine partition name/description
            if (fs == "swap") {
                name = "Linux swap"
            } else if (fs == "ext4" || fs == "ext3" || fs == "ext2" || fs == "xfs" || fs == "btrfs") {
                name = "Linux filesystem"
            } else if (fs == "ntfs" || fs == "vfat" || fs == "fat16" || fs == "fat32") {
                name = "Microsoft basic data"
            } else if (fs == "none") {
                name = "Unformatted"
            } else {
                name = fs " filesystem"
            }
            
            # Set default type for GPT
            if (part_table == "gpt" && type == "") {
                type = "N/A"
            } else if (part_table == "mbr" && type == "") {
                type = "primary"
            }
            
            # Print the row
            if (part_table == "mbr") {
                printf "%-8s %-12s %-12s %-12s %-12s %-12s %s\n", num, start, end, size, fs, type, name
            } else {
                printf "%-8s %-12s %-12s %-12s %-12s %s\n", num, start, end, size, fs, name
            }
        }'

    echo
    success "Disk information displayed successfully."
    
    # Clean up
    cleanup_device "$DEVICE"
}