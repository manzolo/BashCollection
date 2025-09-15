# Setup chroot environment
setup_chroot() {
    log "Setting up chroot environment at $ROOT_MOUNT"
    
    if ! validate_filesystem "$ROOT_DEVICE"; then
        return 1
    fi
    
    if ! safe_mount "$ROOT_DEVICE" "$ROOT_MOUNT"; then
        return 1
    fi

    # Handle boot partition mounting first, then EFI
    if [[ -n "$BOOT_PART" ]]; then
        if ! validate_filesystem "$BOOT_PART"; then
            return 1
        fi
        
        if ! safe_mount "$BOOT_PART" "$ROOT_MOUNT/boot"; then
            return 1
        fi

        # If we have both boot partition and EFI partition
        if [[ -n "$EFI_PART" ]]; then
            if ! validate_filesystem "$EFI_PART"; then
                return 1
            fi

            # Check if /boot/efi exists in the boot partition, if not create it
            if [[ ! -d "$ROOT_MOUNT/boot/efi" ]]; then
                debug "Creating /boot/efi directory in boot partition"
                if ! run_with_privileges mkdir -p "$ROOT_MOUNT/boot/efi"; then
                    error "Failed to create /boot/efi directory in boot partition"
                    return 1
                fi
            fi
            
            if ! safe_mount "$EFI_PART" "$ROOT_MOUNT/boot/efi"; then
                return 1
            fi
        fi

    else
        # No separate boot partition, mount EFI directly under /boot/efi
        if [[ -n "$EFI_PART" ]]; then
            if ! validate_filesystem "$EFI_PART"; then
                return 1
            fi
            
            # Ensure /boot/efi exists in root filesystem
            if ! run_with_privileges mkdir -p "$ROOT_MOUNT/boot/efi"; then
                error "Failed to create /boot/efi directory in root filesystem"
                return 1
            fi
            
            if ! safe_mount "$EFI_PART" "$ROOT_MOUNT/boot/efi"; then
                return 1
            fi
        fi
    fi
    
    for mount_spec in "${ADDITIONAL_MOUNTS[@]}"; do
        if [[ "$mount_spec" =~ ^([^:]+):([^:]+)(:(.+))?$ ]]; then
            local src="${BASH_REMATCH[1]}"
            local dst="${BASH_REMATCH[2]}"
            local opts="${BASH_REMATCH[4]}"
            
            if ! safe_mount "$src" "$ROOT_MOUNT$dst" "$opts"; then
                return 1
            fi
        else
            error "Invalid mount specification: $mount_spec"
            return 1
        fi
    done
    
    local virtual_mounts=(
        "/proc:proc:$ROOT_MOUNT/proc"
        "/sys:sysfs:$ROOT_MOUNT/sys"
        "/dev:--bind:$ROOT_MOUNT/dev"
        "/dev/pts:devpts:$ROOT_MOUNT/dev/pts:--options=ptmxmode=666,gid=5,mode=620"
        "/run:--bind:$ROOT_MOUNT/run"
        "/tmp:--bind:$ROOT_MOUNT/tmp"
    )
    
    for mount_spec in "${virtual_mounts[@]}"; do
        IFS=':' read -r src fstype target options <<< "$mount_spec"
        
        local mount_opts=""
        if [[ "$fstype" == "--bind" ]]; then
            mount_opts="--bind"
        elif [[ -n "$options" ]]; then
            mount_opts="-t $fstype $options"
        else
            mount_opts="-t $fstype"
        fi
        
        if ! safe_mount "$src" "$target" "$mount_opts"; then
            return 1
        fi
    done
    
    # Debug checks for /dev/pts
    debug "Checking /dev/pts in chroot: $(ls -ld "$ROOT_MOUNT/dev/pts")"
    if [[ -n "$(ls $ROOT_MOUNT/dev/pts)" ]]; then
        debug "PTY devices in chroot: $(ls $ROOT_MOUNT/dev/pts)"
    else
        warning "No PTY devices found in $ROOT_MOUNT/dev/pts"
    fi
    
    local files_to_copy=(
        "/etc/resolv.conf"
        "/etc/hosts"
    )
    
    for file in "${files_to_copy[@]}"; do
        if [[ -f "$file" ]]; then
            debug "Copying $file to chroot"
            run_with_privileges cp "$file" "$ROOT_MOUNT$file" 2>/dev/null || debug "Failed to copy $file"
        fi
    done
    
    local dirs_to_create=(
        "/proc"
        "/sys"
        "/dev"
        "/dev/pts"
        "/run"
        "/tmp"
        "/var/tmp"
    )
    
    for dir in "${dirs_to_create[@]}"; do
        run_with_privileges mkdir -p "$ROOT_MOUNT$dir"
        run_with_privileges chmod 1777 "$ROOT_MOUNT$dir" || debug "Failed to set permissions on $ROOT_MOUNT$dir"
    done
    
    log "Chroot environment setup complete"
}

# Helper function to ensure user exists in chroot and create home dir if needed
ensure_chroot_user() {
    local chroot_user="${CHROOT_USER:-root}"
    local chroot_passwd="$ROOT_MOUNT/etc/passwd"
    
    if [[ "$chroot_user" != "root" ]]; then
        if ! grep -q "^$chroot_user:" "$chroot_passwd" 2>/dev/null; then
            error "User $chroot_user does not exist in chroot's /etc/passwd"
            return 1
        fi
        local home_dir
        home_dir=$(grep "^$chroot_user:" "$chroot_passwd" | cut -d: -f6)
        if [[ -z "$home_dir" ]]; then
            error "No home directory found for $chroot_user in chroot"
            return 1
        fi
        run_with_privileges mkdir -p "$ROOT_MOUNT$home_dir" || {
            error "Failed to create home directory $home_dir for $chroot_user"
            return 1
        }
        run_with_privileges chown "$chroot_user:$chroot_user" "$ROOT_MOUNT$home_dir" || {
            warning "Failed to set ownership for $home_dir"
        }
    fi
    return 0
}

# Enter chroot environment with better process tracking
enter_chroot() {
    local shell="${CUSTOM_SHELL:-/bin/bash}"
    
    log "Entering chroot environment"
    
    if [[ "$QUIET_MODE" == false ]]; then
        clear
        echo "================================================="
        echo "           CHROOT SESSION READY"
        echo "================================================="
        echo "Chroot Environment: $ROOT_DEVICE"
        echo "Mount Point: $ROOT_MOUNT"
        echo "Shell: $shell"
        echo "Chroot User: ${CHROOT_USER:-root}"
        if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
            echo "GUI Support: ENABLED (experimental)"
            echo
            echo "WARNING: GUI support is experimental!"
            echo "If you experience host system issues, exit immediately."
        else
            echo "GUI Support: DISABLED (recommended)"
        fi
        echo
        echo "Tips:"
        echo "- Type 'exit' to return to host system"
        echo "- The cleanup process will handle mount points automatically"
        echo "- Monitor system resources if GUI support is enabled"
        echo "================================================="
        echo
        if [[ -t 0 ]]; then
            echo "Press Enter to continue into chroot environment..."
            local dummy_input
            read -r dummy_input || {
                warning "Failed to read input, continuing anyway"
            }
        else
            debug "Non-interactive session, skipping Enter prompt"
        fi
    fi
    
    if [[ ! -x "$ROOT_MOUNT$shell" ]]; then
        warning "Shell $shell not found in chroot, falling back to /bin/sh"
        shell="/bin/sh"
        
        if [[ ! -x "$ROOT_MOUNT$shell" ]]; then
            error "No suitable shell found in chroot"
            return 1
        fi
    fi
    
    echo $$ > "$CHROOT_PID_FILE"
    
    local chroot_env_vars=()
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then
            chroot_env_vars+=("DISPLAY=$DISPLAY")
            debug "Setting DISPLAY=$DISPLAY for chroot"
        fi
        # Temporarily disable Wayland
        # if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        #     chroot_env_vars+=("WAYLAND_DISPLAY=$WAYLAND_DISPLAY")
        #     debug "Setting WAYLAND_DISPLAY=$WAYLAND_DISPLAY for chroot"
        # fi
        if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
            local original_uid=$(id -u "$ORIGINAL_USER")
            chroot_env_vars+=("XDG_RUNTIME_DIR=/run/user/$original_uid")
            debug "Setting XDG_RUNTIME_DIR=/run/user/$original_uid for chroot"
        fi
    fi
    
    debug "Environment variables for chroot: ${chroot_env_vars[*]}"
    
    if [[ -n "${CHROOT_USER:-}" ]] && [[ "$CHROOT_USER" != "root" ]]; then
        log "Entering chroot as user $CHROOT_USER"
        debug "Chroot user home: $(grep "^$CHROOT_USER:" $ROOT_MOUNT/etc/passwd | cut -d: -f6)"
        if [[ ${#chroot_env_vars[@]} -gt 0 ]]; then
            run_with_privileges chroot "$ROOT_MOUNT" su - "$CHROOT_USER" -c "env ${chroot_env_vars[*]} $shell"
        else
            run_with_privileges chroot "$ROOT_MOUNT" su - "$CHROOT_USER" -c "$shell"
        fi
    else
        log "Entering chroot as root"
        if [[ ${#chroot_env_vars[@]} -gt 0 ]]; then
            run_with_privileges env "${chroot_env_vars[@]}" chroot "$ROOT_MOUNT" "$shell"
        else
            run_with_privileges chroot "$ROOT_MOUNT" "$shell"
        fi
    fi
    
    log "Exited chroot environment"
}