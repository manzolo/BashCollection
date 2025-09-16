find_available_nbd() {
    debug "Looking for available NBD devices..."
    
    # Ensure NBD module is loaded with enough devices
    if ! lsmod | grep -q nbd; then
        log "Loading NBD module..."
        if ! run_with_privileges modprobe nbd max_part=16 nbds_max=16; then
            error "Failed to load NBD module"
            return 1
        fi
        sleep 1
    fi
    
    # Check if we have NBD devices
    if ! ls /dev/nbd* >/dev/null 2>&1; then
        error "No NBD devices found. NBD module may not be loaded correctly."
        return 1
    fi
    
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        debug "Checking NBD device: $nbd_dev"
        
        if [[ ! -e "$nbd_dev" ]]; then
            debug "Device $nbd_dev does not exist"
            continue
        fi
        
        # Check if device is in use by trying to read its status
        if sudo qemu-nbd -d "$nbd_dev" 2>/dev/null; then
            # Device was connected, we just freed it
            NBD_DEVICE="$nbd_dev"
            log "Found and freed NBD device: $NBD_DEVICE"
            return 0
        else
            # Check if device is truly free by looking at /proc/partitions
            if ! grep -q "$(basename $nbd_dev)" /proc/partitions 2>/dev/null; then
                # Device appears to be free
                NBD_DEVICE="$nbd_dev"
                log "Found available NBD device: $NBD_DEVICE"
                return 0
            else
                debug "Device $nbd_dev appears to be in use"
            fi
        fi
    done
    
    error "No available NBD device found. All devices may be in use."
    error "Try disconnecting unused NBD devices with: sudo qemu-nbd -d /dev/nbd0"
    return 1
}

connect_nbd() {
    local image_file="$1"
    
    log "Connecting $image_file to $NBD_DEVICE..."
    
    local file_type=$(file "$image_file")
    local format=""
    
    # Determine format
    if [[ "$image_file" == *.vtoy ]] || [[ "$image_file" == *.vhd ]]; then
        format="vpc"
    elif [[ "$file_type" == *"QEMU QCOW"* ]]; then
        format="qcow2"
    elif [[ "$file_type" == *"VDI disk image"* ]]; then
        format="vdi"
    elif [[ "$image_file" == *.vmdk ]]; then
        format="vmdk"
    else
        format="raw"
    fi
    
    log "Attempting to connect with format: $format"
    
    # Use sudo directly for qemu-nbd commands (not run_with_privileges)
    if ! sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file" 2>/dev/null; then
        if [[ "$format" == "vpc" ]]; then
            log "Falling back to raw format..."
            format="raw"
            if ! sudo qemu-nbd -c "$NBD_DEVICE" -f "$format" "$image_file"; then
                error "Failed to connect $image_file"
                exit 1
            fi
        else
            error "Failed to connect $image_file with format $format"
            exit 1
        fi
    fi
    
    log "Successfully connected with format: $format"
    
    sleep 2
    sudo partprobe "$NBD_DEVICE" 2>/dev/null || true
    sleep 1
}

disconnect_nbd() {
    if [[ -z "$NBD_DEVICE" ]]; then
        debug "No NBD device recorded, skipping disconnect"
        return 0
    fi

    if [[ -n "$NBD_DEVICE" ]]; then
        log "Disconnecting NBD device: $NBD_DEVICE"
        sudo qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null \
            || warning "Error disconnecting $NBD_DEVICE"
    fi
}
