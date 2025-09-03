cleanup_device() {
    local device="$1"
    local max_attempts=3
    local attempt=1

    if [ -z "$device" ]; then
        log "No device specified for cleanup" >&2
        return 0
    fi

    # Validate device path (NBD or loop)
    if [[ ! "$device" =~ ^/dev/(nbd|loop)[0-9]+$ ]]; then
        log "Invalid device path: $device, skipping cleanup" >&2
        return 0
    fi

    if [ ! -b "$device" ]; then
        log "Device $device does not exist, no cleanup needed" >&2
        return 0
    fi

    # Sync to ensure pending writes are completed
    sync
    udevadm settle >/dev/null 2>&1
    sleep 1

    # Check for mounted partitions and unmount them
    for part in "${device}"p*; do
        if [ -b "$part" ]; then
            if mount | grep -q "$part"; then
                log "Unmounting partition $part..." >&2
                sudo umount "$part" >/dev/null 2>&1 || {
                    log_error "Failed to unmount $part" >&2
                    return 1
                }
            fi
        fi
    done

    # Handle NBD devices
    if [[ "$device" =~ ^/dev/nbd[0-9]+$ ]]; then
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
                log "Successfully cleaned up NBD device $device" >&2
                return 0
            fi

            if lsof "$device" >/dev/null 2>&1 || fuser "$device" >/dev/null 2>&1; then
                warning "Device $device is in use, attempting to terminate processes..." >&2
                sudo fuser -k "$device" >/dev/null 2>&1
                sleep 1
            fi

            if [ $attempt -lt $max_attempts ]; then
                warning "Failed to cleanup NBD device $device, retrying in 2 seconds..." >&2
                sleep 2
            fi

            ((attempt++))
        done

        error "Failed to cleanup NBD device $device after $max_attempts attempts" >&2
        return 1
    fi

    # Handle loop devices
    if [[ "$device" =~ ^/dev/loop[0-9]+$ ]]; then
        # Check if the loop device is still attached
        if ! losetup "$device" >/dev/null 2>&1; then
            log "Loop device $device is already detached, no cleanup needed" >&2
            return 0
        fi

        while [ $attempt -le $max_attempts ]; do
            log "Disconnecting loop device ${device} (attempt $attempt/$max_attempts)..." >&2
            # Ensure partitions are not in use
            for part in "${device}"p*; do
                if [ -b "$part" ] && { lsof "$part" >/dev/null 2>&1 || fuser "$part" >/dev/null 2>&1; }; then
                    warning "Partition $part is in use, attempting to terminate processes..." >&2
                    sudo fuser -k "$part" >/dev/null 2>&1
                    sleep 1
                fi
            done

            if [ "$VERBOSE" -eq 1 ]; then
                sudo losetup -d "$device" 2>&1 | tee -a /dev/stderr
            else
                sudo losetup -d "$device" >/dev/null 2>&1
            fi

            if [ $? -eq 0 ]; then
                udevadm settle >/dev/null 2>&1
                sleep 1
                log "Successfully cleaned up loop device $device" >&2
                return 0
            fi

            if lsof "$device" >/dev/null 2>&1 || fuser "$device" >/dev/null 2>&1; then
                warning "Device $device is in use, attempting to terminate processes..." >&2
                sudo fuser -k "$device" >/dev/null 2>&1
                sleep 1
            fi

            if [ $attempt -lt $max_attempts ]; then
                warning "Failed to cleanup loop device $device, retrying in 2 seconds..." >&2
                sleep 2
            fi

            ((attempt++))
        done

        error "Failed to cleanup loop device $device after $max_attempts attempts" >&2
        return 1
    fi

    return 0
}