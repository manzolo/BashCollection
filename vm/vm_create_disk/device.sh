setup_device() {
    declare -g DEVICE

    if [ "$DISK_FORMAT" = "qcow2" ]; then
        setup_qcow2_device
    else
        setup_loop_device
    fi
    
    log "Using device: ${DEVICE}"
}

setup_qcow2_device() {
    log "Loading qemu-nbd kernel module..."
    if [ "$VERBOSE" -eq 1 ]; then
        sudo modprobe nbd max_part=8
    else
        sudo modprobe nbd max_part=8 >/dev/null 2>&1
    fi
    
    if [ $? -ne 0 ]; then
        error "Failed to load qemu-nbd kernel module."
        exit 1
    fi
    
    # Find available NBD device
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
    
    log "Connecting ${DISK_NAME} to ${DEVICE} via qemu-nbd..."
    if [ "$VERBOSE" -eq 1 ]; then
        sudo qemu-nbd --connect="$DEVICE" "$DISK_NAME"
    else
        sudo qemu-nbd --connect="$DEVICE" "$DISK_NAME" >/dev/null 2>&1
    fi
    
    if [ $? -ne 0 ]; then
        error "Failed to connect qcow2 image via qemu-nbd"
        exit 1
    fi
    
    sleep 2
}

setup_loop_device() {
    log "Setting up loop device for ${DISK_NAME}..."
    if [ "$VERBOSE" -eq 1 ]; then
        DEVICE=$(sudo losetup -f --show "${DISK_NAME}")
    else
        DEVICE=$(sudo losetup -f --show "${DISK_NAME}" 2>/dev/null)
    fi
    
    if [ $? -ne 0 ]; then
        error "Failed to create loop device for ${DISK_NAME}"
        exit 1
    fi
}