cleanup_device() {
    local device="$1"
    local max_attempts=3
    local attempt=1
    
    if [ -z "$device" ]; then
        log "No device specified for cleanup" >&2
        return 0
    fi
    
    if [[ ! "$device" =~ ^/dev/nbd[0-9]+$ ]]; then
        log "Invalid device path: $device, skipping cleanup" >&2
        return 0
    fi
    
    if [ ! -b "$device" ]; then
        log "Device $device does not exist, no cleanup needed" >&2
        return 0
    fi
    
    while [ $attempt -le $max_attempts ]; do
        log "Disconnecting NBD device ${device} (attempt $attempt/$max_attempts)..." >&2
        if [ "$VERBOSE" -eq 1 ]; then
            sudo qemu-nbd --disconnect "$device" 2>&1 | tee -a /dev/stderr
        else
            sudo qemu-nbd --disconnect "$device" >/dev/null 2>&1
        fi
        
        if [ $? -eq 0 ]; then
            udevadm settle >/dev/null 2>&1
            sleep 1
            log "Successfully cleaned up device $device" >&2
            return 0
        fi
        
        if lsof "$device" >/dev/null 2>&1; then
            warning "Device $device is in use, attempting to terminate processes..." >&2
            sudo fuser -k "$device" >/dev/null 2>&1
            sleep 1
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            warning "Failed to cleanup device $device, retrying in 2 seconds..." >&2
            sleep 2
        fi
        
        ((attempt++))
    done
    
    error "Failed to cleanup device $device after $max_attempts attempts" >&2
    return 1
}