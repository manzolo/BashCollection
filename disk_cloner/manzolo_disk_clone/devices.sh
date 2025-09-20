setup_loop_device_safe() {
    local image_file="$1"
    
    if [ "$DRY_RUN" = true ]; then
        echo "/dev/loop99"  # Return simulated loop device
        return 0
    fi
    
    # Ensure loop module is loaded
    modprobe loop 2>/dev/null || true
    
    # Find available loop device
    local loop_dev
    loop_dev=$(losetup -f 2>/dev/null)
    if [ -z "$loop_dev" ]; then
        log "Error: No free loop devices available"
        return 1
    fi
    
    # Setup loop device
    if losetup "$loop_dev" "$image_file" 2>/dev/null; then
        echo "$loop_dev"
        return 0
    else
        log "Error: Failed to setup loop device"
        return 1
    fi
}