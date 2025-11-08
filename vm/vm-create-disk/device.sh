setup_device() {
    register_cleanup
    
    if [ "$DISK_FORMAT" = "qcow2" ]; then
        setup_qcow2_device
    else
        setup_loop_device
    fi
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    log_info "Using device: ${DEVICE}"
    
    # Wait for device to be ready
    wait_for_device_ready "$DEVICE"
    return $?
}

# Wait for device to be ready with timeout
wait_for_device_ready() {
    local device="$1"
    local timeout="${2:-30}"
    local count=0
    
    while [ $count -lt $timeout ]; do
        if [ -b "$device" ]; then
            log_debug "Device $device is ready"
            sudo partprobe "$device" >/dev/null 2>&1
            udevadm settle 2>/dev/null
            sleep 1
            return 0
        fi
        
        sleep 1
        ((count++))
    done
    
    log_error "Device $device not ready after ${timeout}s timeout"
    return 1
}


setup_qcow2_device() {
    local nbd_device
    
    nbd_device=$(find_available_nbd)
    if [ $? -ne 0 ]; then
        log_error "No available NBD devices found"
        return 1
    fi
    
    DEVICE="$nbd_device"
    
    log_debug "Connecting ${DISK_NAME} to ${DEVICE} via qemu-nbd..."
    
    local cmd="sudo qemu-nbd --connect='$DEVICE' '$DISK_NAME'"
    if [ "$VERBOSE" -eq 1 ]; then
        eval "$cmd"
    else
        eval "$cmd" >/dev/null 2>&1
    fi
    
    if [ $? -ne 0 ]; then
        log_error "Failed to connect qcow2 image via qemu-nbd"
        DEVICE=""
        return 1
    fi
    
    return 0
}

setup_loop_device() {
    log_debug "Setting up loop device for ${DISK_NAME}..."
    
    local loop_device
    if [ "$VERBOSE" -eq 1 ]; then
        loop_device=$(sudo losetup -f --show "$DISK_NAME")
    else
        loop_device=$(sudo losetup -f --show "$DISK_NAME" 2>/dev/null)
    fi
    
    if [ $? -ne 0 ] || [ -z "$loop_device" ]; then
        log_error "Failed to create loop device for ${DISK_NAME}"
        return 1
    fi
    
    DEVICE="$loop_device"
    return 0
}

# Find available NBD device efficiently
find_available_nbd() {
    local nbd_device
    
    # Check if nbd module is loaded
    if ! lsmod | grep -q "^nbd "; then
        log_debug "Loading NBD kernel module..."
        if ! sudo modprobe nbd max_part=16; then
            log_error "Failed to load NBD kernel module"
            return 1
        fi
        sleep 1
    fi
    
    # Find first available NBD device
    for i in {0..15}; do
        nbd_device="/dev/nbd$i"
        if [ ! -e "/sys/block/nbd$i/pid" ] && ! fuser "$nbd_device" >/dev/null 2>&1; then
            echo "$nbd_device"
            return 0
        fi
    done
    
    return 1
}