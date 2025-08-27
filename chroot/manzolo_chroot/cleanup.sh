cleanup() {
    local exit_code=$?
    
    debug "Starting cleanup process"
    
    rm -f "$LOCK_FILE" "$CHROOT_PID_FILE"
    
    if [[ ${#MOUNTED_POINTS[@]} -eq 0 ]]; then
        debug "No mount points to clean up"
        return $exit_code
    fi
    
    log "Cleaning up mount points gracefully"
    
    log "Terminating any lingering chroot processes"
    if ! terminate_chroot_processes; then
        warning "Some chroot processes may persist, proceeding with caution."
    fi
    sleep 2

    # Then, proceed with unmounting
    local reverse_mounts=()
    for ((i=${#MOUNTED_POINTS[@]}-1; i>=0; i--)); do
        reverse_mounts+=("${MOUNTED_POINTS[i]}")
    done

    for mount_point in "${reverse_mounts[@]}"; do
        if ! mountpoint -q "$mount_point"; then
            debug "$mount_point is not mounted, skipping"
            continue
        fi
        
        # Do NOT call terminate_processes_gracefully for bind-mounts of host directories
        case "$mount_point" in
            */proc|*/sys|*/dev|*/run|*/tmp|*/dev/pts)
                log "Unmounting virtual filesystem: $mount_point"
                ;;
            *)
                log "Unmounting physical filesystem: $mount_point"
                terminate_processes_gracefully "$mount_point" || warning "Could not terminate all processes for $mount_point"
                ;;
        esac
        
        safe_umount "$mount_point" || error "Failed to unmount $mount_point - check manually"
    done    

    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Cleaning up GUI support remnants"
        local chroot_user="${CHROOT_USER:-root}"
        if [[ "$chroot_user" == "root" ]]; then
            rm -f "$ROOT_MOUNT/root/.Xauthority" 2>/dev/null || true
        else
            rm -f "$ROOT_MOUNT/home/$chroot_user/.Xauthority" 2>/dev/null || true
        fi
        # Reset xhost settings
        if command -v xhost &> /dev/null; then
            xhost -local: || warning "Failed to reset xhost settings"
            debug "xhost settings after cleanup: $(xhost)"
        fi
        log "GUI cleanup complete"
    fi
    
    rm -f /tmp/mount_error.log /tmp/umount_error.log
    
    log "Cleanup complete"
    return $exit_code
}