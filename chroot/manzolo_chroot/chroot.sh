setup_chroot() {
    log "Setting up chroot environment at $ROOT_MOUNT"
    
    if [[ "$VIRTUAL_MODE" == true ]]; then
        # Virtual disk mode
        if ! setup_virtual_disk "$VIRTUAL_IMAGE"; then
            error "Failed to setup virtual disk"
            return 1
        fi
    fi
    
    # Validate and mount root filesystem
    local fs_type=$(run_with_privileges blkid -o value -s TYPE "$ROOT_DEVICE" 2>/dev/null || "")
    
    if [[ "$fs_type" == "btrfs" ]]; then
        mount_partition_btrfs "$ROOT_DEVICE" "$ROOT_MOUNT"
    else
        if ! safe_mount "$ROOT_DEVICE" "$ROOT_MOUNT"; then
            return 1
        fi
    fi
    
    # Handle boot partition mounting
    if [[ -n "$BOOT_PART" ]]; then
        if ! safe_mount "$BOOT_PART" "$ROOT_MOUNT/boot"; then
            return 1
        fi
    fi
    
    # Handle EFI partition
    if [[ -n "$EFI_PART" ]]; then
        local efi_target="$ROOT_MOUNT/boot/efi"
        if [[ -n "$BOOT_PART" ]]; then
            # EFI under separate /boot
            efi_target="$ROOT_MOUNT/boot/efi"
        else
            # EFI directly under root
            efi_target="$ROOT_MOUNT/boot/efi"
        fi
        
        run_with_privileges mkdir -p "$efi_target"
        if ! safe_mount "$EFI_PART" "$efi_target"; then
            warning "Failed to mount EFI partition"
        fi
    fi
    
    # Setup bind mounts for chroot
    setup_bind_mounts "$ROOT_MOUNT"
    
    # Copy network configuration
    if [[ -f /etc/resolv.conf ]]; then
        run_with_privileges cp --remove-destination /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf" 2>/dev/null || true
    fi
    
    if [[ -f /etc/hosts ]]; then
        run_with_privileges cp /etc/hosts "$ROOT_MOUNT/etc/hosts" 2>/dev/null || true
    fi
    
    log "Chroot environment setup complete"
    return 0
}

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
        echo "Mode: $([ "$VIRTUAL_MODE" == true ] && echo "Virtual Disk" || echo "Physical Disk")"
        [[ "$VIRTUAL_MODE" == true ]] && echo "Image: $VIRTUAL_IMAGE"
        echo "Shell: $shell"
        echo "Chroot User: ${CHROOT_USER:-root}"
        echo "GUI Support: $([ "$ENABLE_GUI_SUPPORT" == true ] && echo "ENABLED" || echo "DISABLED")"
        echo
        echo "Tips:"
        echo "- Type 'exit' to return to host system"
        echo "- The cleanup process will handle everything automatically"
        echo "================================================="
        echo
        if [[ -t 0 ]]; then
            echo "Press Enter to continue into chroot environment..."
            read -r
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
    
    echo $ > "$CHROOT_PID_FILE"
    
    local chroot_env_vars=()
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        if [[ -n "${DISPLAY:-}" ]]; then
            chroot_env_vars+=("DISPLAY=$DISPLAY")
        fi
        if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
            local original_uid=$(id -u "$ORIGINAL_USER")
            chroot_env_vars+=("XDG_RUNTIME_DIR=/run/user/$original_uid")
        fi
    fi
    
    if [[ -n "${CHROOT_USER:-}" ]] && [[ "$CHROOT_USER" != "root" ]]; then
        log "Entering chroot as user $CHROOT_USER"
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