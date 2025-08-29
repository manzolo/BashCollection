# Enhanced device cleanup with retry mechanism
cleanup_device() {
    local device=$1
    local max_attempts=3
    local attempt=1
    
    if [ -z "$device" ]; then
        return 0
    fi
    
    while [ $attempt -le $max_attempts ]; do
        if [[ "$device" =~ /dev/nbd ]]; then
            log "Disconnecting NBD device ${device} (attempt $attempt/$max_attempts)..."
            if [ "$VERBOSE" -eq 1 ]; then
                sudo qemu-nbd --disconnect "$device"
            else
                sudo qemu-nbd --disconnect "$device" >/dev/null 2>&1
            fi
        else
            log "Releasing loop device ${device} (attempt $attempt/$max_attempts)..."
            if [ "$VERBOSE" -eq 1 ]; then
                sudo losetup -d "$device"
            else
                sudo losetup -d "$device" >/dev/null 2>&1
            fi
        fi
        
        if [ $? -eq 0 ]; then
            log "Successfully cleaned up device $device"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            warning "Failed to cleanup device $device, retrying in 2 seconds..."
            sleep 2
        fi
        
        ((attempt++))
    done
    
    error "Failed to cleanup device $device after $max_attempts attempts"
    return 1
}