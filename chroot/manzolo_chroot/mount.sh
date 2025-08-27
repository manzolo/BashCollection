# Safe mount function
safe_mount() {
    local source="$1"
    local target="$2"
    local options="${3:-}"
    local retries=3
    local delay=1
    
    debug "Mounting $source to $target with options: $options"
    
    if ! mkdir -p "$target"; then
        error "Failed to create mount point: $target"
        return 1
    fi
    
    if mountpoint -q "$target"; then
        warning "$target is already mounted, attempting unmount"
        if ! terminate_processes_gracefully "$target"; then
            warning "Could not terminate all processes using $target"
        fi
        
        if ! run_with_privileges umount "$target" 2>/tmp/mount_error.log; then
            local error_msg
            error_msg=$(cat /tmp/mount_error.log 2>/dev/null || echo "Unknown error")
            error "Failed to unmount existing mount at $target: $error_msg"
            return 1
        fi
    fi
    
    for ((i=1; i<=retries; i++)); do
        debug "Mount attempt $i/$retries"
        
        local mount_result
        if [[ -n "$options" ]]; then
            debug "Running: sudo mount $options $source $target"
            if run_with_privileges mount $options "$source" "$target" 2>/tmp/mount_error.log; then
                mount_result=0
            else
                mount_result=1
            fi
        else
            debug "Running: sudo mount $source $target"
            if run_with_privileges mount "$source" "$target" 2>/tmp/mount_error.log; then
                mount_result=0
            else
                mount_result=1
            fi
        fi
        
        if [[ $mount_result -eq 0 ]]; then
            MOUNTED_POINTS+=("$target")
            log "Successfully mounted $source to $target"
            return 0
        else
            local error_msg
            error_msg=$(cat /tmp/mount_error.log 2>/dev/null || echo "Unknown error")
            
            if [[ $i -eq $retries ]]; then
                error "Failed to mount $source to $target after $retries attempts: $error_msg"
                return 1
            else
                debug "Mount attempt $i failed: $error_msg. Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done
}

# Safe unmount function with retries
safe_umount() {
    local target="$1"
    local retries=3
    local delay=2
    
    debug "Unmounting $target"
    
    for ((i=1; i<=retries; i++)); do
        debug "Unmount attempt $i/$retries for $target"
        
        if run_with_privileges umount "$target" 2>/tmp/umount_error.log; then
            log "Successfully unmounted $target"
            return 0
        else
            local error_msg
            error_msg=$(cat /tmp/umount_error.log 2>/dev/null || echo "Unknown error")
            warning "Unmount attempt $i failed: $error_msg"
            
            terminate_processes_gracefully "$target"
            
            sleep $delay
        fi
    done
    
    warning "All unmount attempts failed, trying lazy unmount for $target"
    if run_with_privileges umount -l "$target" 2>/tmp/umount_error.log; then
        log "Successfully lazy unmounted $target"
        return 0
    else
        local error_msg
        error_msg=$(cat /tmp/umount_error.log 2>/dev/null || echo "Unknown error")
        error "Failed to unmount $target even with lazy: $error_msg"
        return 1
    fi
}