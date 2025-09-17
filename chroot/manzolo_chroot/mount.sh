safe_mount() {
    local source="$1"
    local target="$2"
    local options="${3:-}"
    local retries=3
    local delay=1
    
    debug "=== MOUNTING $source to $target ==="
    debug "Mount options: '$options'"
    
    # Verifica che il source device esista e sia accessibile
    if [[ ! -b "$source" ]] && [[ ! -d "$source" ]] && [[ ! -f "$source" ]]; then
        error "Source device/path does not exist or is not accessible: $source"
        debug "ls -la $source:"
        ls -la "$source" 2>&1 | while IFS= read -r line; do debug "$line"; done || true
        return 1
    fi
    
    # Se è un block device, verifica che sia leggibile
    if [[ -b "$source" ]]; then
        debug "Testing device readability with: dd if=$source of=/dev/null bs=512 count=1"
        if ! run_with_privileges dd if="$source" of=/dev/null bs=512 count=1 >/dev/null 2>&1; then
            error "Cannot read from block device: $source"
            return 1
        fi
        debug "Device is readable"
        
        # Mostra informazioni sul device
        debug "Getting device info with blkid commands"
        local fs_type=$(run_with_privileges blkid -o value -s TYPE "$source" 2>/dev/null || echo "unknown")
        local fs_label=$(run_with_privileges blkid -o value -s LABEL "$source" 2>/dev/null || echo "")
        local fs_uuid=$(run_with_privileges blkid -o value -s UUID "$source" 2>/dev/null || echo "")
        
        log "Device info - Type: $fs_type, Label: '$fs_label', UUID: $fs_uuid"
    fi
    
    debug "Creating mount point: mkdir -p $target"
    if ! mkdir -p "$target"; then
        error "Failed to create mount point: $target"
        return 1
    fi
    debug "Mount point created successfully"
    
    debug "Checking if already mounted: mountpoint -q $target"
    if mountpoint -q "$target"; then
        warning "$target is already mounted"
        return 0
    fi
    debug "Target is not already mounted"
    
    for ((i=1; i<=retries; i++)); do
        debug "=== Mount attempt $i/$retries ==="
        
        local mount_cmd="mount"
        if [[ -n "$options" ]]; then
            mount_cmd="$mount_cmd $options"
        fi
        mount_cmd="$mount_cmd $source $target"
        
        debug "Full mount command: $mount_cmd"
        
        local mount_result
        local mount_error=""
        
        if [[ -n "$options" ]]; then
            debug "Executing: mount $options $source $target"
            mount_error=$(run_with_privileges mount $options "$source" "$target" 2>&1) && mount_result=0 || mount_result=1
        else
            debug "Executing: mount $source $target"
            mount_error=$(run_with_privileges mount "$source" "$target" 2>&1) && mount_result=0 || mount_result=1
        fi
        
        debug "Mount command exit code: $mount_result"
        
        if [[ $mount_result -eq 0 ]]; then
            MOUNTED_POINTS+=("$target")
            log "Successfully mounted $source to $target"
            
            # Verifica che il mount sia effettivamente riuscito
            debug "Verifying mount with: mountpoint -q $target"
            if mountpoint -q "$target"; then
                debug "Mount verified with mountpoint command"
                
                # Mostra contenuto directory per debug
                debug "Mount point contents:"
                ls -la "$target" 2>/dev/null | head -10 | while IFS= read -r line; do debug "  $line"; done || true
                
                return 0
            else
                error "Mount command succeeded but mountpoint verification failed"
                return 1
            fi
        else
            warning "Mount attempt $i failed with error: $mount_error"
            debug "Mount error details: $mount_error"
            
            if [[ $i -eq $retries ]]; then
                error "Failed to mount $source to $target after $retries attempts"
                error "Last error: $mount_error"
                
                # Suggerimenti per il troubleshooting
                if [[ "$mount_error" == *"wrong fs type"* ]]; then
                    error "Filesystem type mismatch. Try specifying -t <fstype>"
                    debug "Try manually: mount -t <fstype> $source $target"
                elif [[ "$mount_error" == *"busy"* ]]; then
                    error "Device or mount point is busy"
                    debug "Check with: lsof +D $target; fuser -m $target"
                elif [[ "$mount_error" == *"permission denied"* ]]; then
                    error "Permission denied - check device permissions"
                    debug "Check with: ls -la $source"
                fi
                
                return 1
            else
                debug "Retrying in ${delay}s..."
                sleep $delay
            fi
        fi
    done
}

safe_umount() {
    local target="$1"
    local retries=3
    local delay=2
    
    debug "Unmounting $target"
    
    for ((i=1; i<=retries; i++)); do
        debug "Unmount attempt $i/$retries for $target"
        
        if run_with_privileges umount "$target" 2>/dev/null; then
            log "Successfully unmounted $target"
            return 0
        else
            warning "Unmount attempt $i failed"
            sleep $delay
        fi
    done
    
    warning "All unmount attempts failed, trying lazy unmount for $target"
    if run_with_privileges umount -l "$target" 2>/dev/null; then
        log "Successfully lazy unmounted $target"
        return 0
    else
        error "Failed to unmount $target even with lazy"
        return 1
    fi
}

mount_partition_btrfs() {
    local partition="$1"
    local mount_point="$2"
    
    log "Probing Btrfs partition $partition for subvolumes..."
    mkdir -p "$mount_point"
    
    local probe=$(mktemp -d)
    run_with_privileges mount -o ro "$partition" "$probe" || {
        warning "Cannot mount $partition for probing"
        return 1
    }
    
    mapfile -t found_subs < <(
        run_with_privileges btrfs subvolume list "$probe" 2>/dev/null | \
        awk '{for(i=9;i<=NF;i++) printf "%s%s",$i,(i==NF?"":" "); print ""}' | \
        sed 's/^ *//; s/ *$//'
    )
    
    run_with_privileges umount "$probe"
    rmdir "$probe"
    
    local candidates_root=("@" "@root" "root")
    local mounted_root=0
    
    for s in "${found_subs[@]}"; do
        [[ -z "$s" ]] && continue
        candidates_root+=("$s")
    done
    
    for sub in "${candidates_root[@]}"; do
        [[ -z "$sub" ]] && continue
        log "Trying Btrfs subvolume candidate: $sub"
        if run_with_privileges mount -t btrfs -o subvol="$sub" "$partition" "$mount_point" 2>/dev/null; then
            if [[ -d "$mount_point/etc" ]] && { [[ -d "$mount_point/bin" ]] || [[ -d "$mount_point/usr/bin" ]]; }; then
                log "Using Btrfs subvolume for root: $sub"
                MOUNTED_POINTS+=("$mount_point")
                mounted_root=1
                break
            else
                run_with_privileges umount "$mount_point" 2>/dev/null || true
            fi
        fi
    done
    
    if [[ $mounted_root -eq 0 ]]; then
        log "No valid root subvolume found; mounting raw partition"
        run_with_privileges mount -t btrfs "$partition" "$mount_point" 2>/dev/null || warning "Cannot mount raw"
        MOUNTED_POINTS+=("$mount_point")
    fi
}

setup_bind_mounts() {
    local chroot_dir="$1"
    
    local bind_dirs=(
        "/proc:proc:proc"
        "/sys:sysfs:sys"  
        "/dev:--bind:dev"
        "/dev/pts:devpts:dev/pts:--options=ptmxmode=666,gid=5,mode=620"
        "/run:--bind:run"
        "/tmp:--bind:tmp"
    )
    
    for mount_spec in "${bind_dirs[@]}"; do
        IFS=':' read -r src fstype rel_target options <<< "$mount_spec"
        local target="$chroot_dir/$rel_target"
        
        run_with_privileges mkdir -p "$target"
        
        local mount_opts=""
        if [[ "$fstype" == "--bind" ]]; then
            mount_opts="--bind"
        elif [[ -n "$options" ]]; then
            mount_opts="-t $fstype $options"
        else
            mount_opts="-t $fstype"
        fi
        
        if safe_mount "$src" "$target" "$mount_opts"; then
            BIND_MOUNTS+=("$target")
            log "Bind mounted: $src -> $target"
        else
            warning "Failed to bind mount $src to $target"
        fi
    done
}