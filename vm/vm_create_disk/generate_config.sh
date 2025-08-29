# Function to generate config.sh from an existing disk image
generate_config() {
    local DISK_FILE="$1"
    local CONFIG_FILE="${DISK_FILE%.*}_config.sh"

    log "Analyzing disk image $DISK_FILE..."

    # Get disk format and size using qemu-img
    local QEMU_INFO
    QEMU_INFO=$(qemu-img info "$DISK_FILE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read disk image info for $DISK_FILE"
        exit 1
    fi

    local DISK_FORMAT=$(echo "$QEMU_INFO" | awk -F': ' '/file format/ {print $2}')
    local DISK_SIZE=$(echo "$QEMU_INFO" | grep "virtual size" | grep -oP '\d+\.?\d*\s*(GiB|MiB|KiB)' | sed 's/\s*GiB/G/' | sed 's/\s*MiB/M/' | sed 's/\s*KiB/K/' | tr -d ' ')
    if [ -z "$DISK_SIZE" ]; then
        error "Failed to parse disk size from qemu-img info"
        exit 1
    fi
    log "DEBUG: QEMU_INFO: $QEMU_INFO"
    log "DEBUG: Parsed DISK_SIZE: $DISK_SIZE"

    # Set up device for parted
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

        log "Connecting $DISK_FILE to $DEVICE via qemu-nbd..."
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --connect="$DEVICE" "$DISK_FILE"
        else
            sudo qemu-nbd --connect="$DEVICE" "$DISK_FILE" >/dev/null 2>&1
        fi
        if [ $? -ne 0 ]; then
            error "Failed to connect qcow2 image via qemu-nbd"
            exit 1
        fi

        sleep 3
        sudo partprobe "$DEVICE" >/dev/null 2>&1
        udevadm settle >/dev/null 2>&1
        sleep 2
    else
        log "Setting up loop device for $DISK_FILE..."
        if [ "$VERBOSE" -eq 1 ]; then
            DEVICE=$(sudo losetup -f --show "$DISK_FILE")
        else
            DEVICE=$(sudo losetup -f --show "$DISK_FILE" 2>/dev/null)
        fi
        if [ $? -ne 0 ]; then
            error "Failed to create loop device for $DISK_FILE"
            exit 1
        fi
        sleep 1
        sudo partprobe "$DEVICE" >/dev/null 2>&1
        udevadm settle >/dev/null 2>&1
        sleep 1
    fi

    log "DEBUG: Using device: $DEVICE"

    # Get partition table information using parted with LC_ALL=C
    local PARTED_INFO
    PARTED_INFO=$(LC_ALL=C sudo parted -m "$DEVICE" unit B print 2>/dev/null)
    if [ $? -ne 0 ]; then
        error "Failed to read partition table from $DEVICE"
        cleanup_device "$DEVICE"
        exit 1
    fi
    log "DEBUG: PARTED_INFO: $PARTED_INFO"

    # Check for partition table type using blkid
    log "DEBUG: BLKID_INFO: $(sudo blkid "${DEVICE}" 2>/dev/null)"
    if sudo blkid "${DEVICE}" | grep -q 'PTTYPE="gpt"'; then
        log "DEBUG: Detected PARTITION_TABLE: gpt"
        PARTITION_TABLE="gpt"
    else
        log "DEBUG: Detected PARTITION_TABLE: mbr"
        PARTITION_TABLE="mbr"
        warning "No GPT partition table detected, defaulting to 'mbr'"
    fi

    # Get filesystem information using blkid
    local BLKID_INFO
    BLKID_INFO=$(LC_ALL=C sudo blkid -c /dev/null "${DEVICE}"* 2>/dev/null)
    log "DEBUG: BLKID_INFO: $BLKID_INFO"

    log "Disk info: Name=$DISK_FILE, Format=$DISK_FORMAT, Size=$DISK_SIZE"
    log "Partition table type: $PARTITION_TABLE"

    # Write configuration to file
    {
        echo "#!/bin/bash"
        echo "DISK_NAME=\"$(basename "$DISK_FILE")\""
        echo "DISK_SIZE=\"$DISK_SIZE\""
        echo "DISK_FORMAT=\"$DISK_FORMAT\""
        echo "PARTITION_TABLE=\"$PARTITION_TABLE\""
        echo "PREALLOCATION=\"off\" # Note: Preallocation cannot be determined from disk image"
        echo "PARTITIONS=("
    } > "$CONFIG_FILE"

    # Parse partitions
    echo "$PARTED_INFO" | grep -E '^[0-9]+:' | while IFS=: read -r num start end size fs type name flags; do
        local size_h=$(convert_parted_size "$size")
        # Get filesystem from blkid
        local part_dev="${DEVICE}p${num}"
        local fs_norm=$(echo "$BLKID_INFO" | grep "$part_dev" | grep -oP 'TYPE="\K[^"]+' || echo "$fs")
        fs_norm=$(normalize_fs_type "$fs_norm" "$type" "$name")

        if [ "$PARTITION_TABLE" = "mbr" ]; then
            local part_type=""
            if [ "$num" -eq 3 ] && [ -z "$fs_norm" ] || [ "$type" = "extended" ] || [[ "$flags" =~ "extended" ]]; then
                part_type="extended"
            elif [ "$num" -ge 5 ]; then
                part_type="logical"
            else
                part_type="primary"
            fi
            echo "    \"${size_h}:${fs_norm}:${part_type}\"" >> "$CONFIG_FILE"
            log "Found partition: ${size_h} ($fs_norm, $part_type)"
        else
            echo "    \"${size_h}:${fs_norm}\"" >> "$CONFIG_FILE"
            log "Found partition: ${size_h} ($fs_norm)"
        fi
    done

    echo ")" >> "$CONFIG_FILE"
    chmod +x "$CONFIG_FILE"

    log "Configuration file '$CONFIG_FILE' generated successfully."

    # Clean up device
    cleanup_device "$DEVICE"
}