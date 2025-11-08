cleanup() {
    log "🧹 Cleaning up resources..."
    cleanup_resources
}

cleanup_resources() {
    log_with_level INFO "Cleaning up resources..."
    
    # Clean up loop devices
    for loop_dev in $(losetup -a | grep "$TEMP_PREFIX" | cut -d: -f1); do
        if [ -b "$loop_dev" ]; then
            log_with_level DEBUG "Detaching loop device: $loop_dev"
            if command -v kpartx >/dev/null 2>&1; then
                kpartx -dv "$loop_dev" 2>/dev/null || true
            fi
            losetup -d "$loop_dev" 2>/dev/null || true
        fi
    done
    
    # Clean up temporary files
    if [ -n "$TEMP_PREFIX" ]; then
        rm -f "${TEMP_PREFIX}"* 2>/dev/null || true
    fi
    
    # Sync filesystem
    sync 2>/dev/null || true
}

