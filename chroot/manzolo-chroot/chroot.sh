setup_chroot() {
    log "Setting up chroot environment at $ROOT_MOUNT"
    
    # Debug iniziale degli array
    debug "Initial LUKS_MAPPINGS: ${LUKS_MAPPINGS[*]}"
    debug "Initial ACTIVATED_VGS: ${ACTIVATED_VGS[*]}"
    
    # Crea snapshot iniziale per debug
    if [[ "$DEBUG_MODE" == true ]]; then
        local snapshot=$(create_debug_snapshot)
        debug "Initial system snapshot: $snapshot"
    fi
    
    if [[ "$VIRTUAL_MODE" == true ]]; then
        # Virtual disk mode
        if ! setup_virtual_disk "$VIRTUAL_IMAGE"; then
            error "Failed to setup virtual disk"
            return 1
        fi
    else
        # Physical mode - check for LUKS
        log "Checking for LUKS encryption on root device: $ROOT_DEVICE"
        
        # Handle LUKS if present - NUOVA SINTASSI
        debug "Calling detect_and_handle_luks for: $ROOT_DEVICE"
        
        local actual_root_device=""
        if detect_and_handle_luks "$ROOT_DEVICE" "actual_root_device"; then
            debug "detect_and_handle_luks set actual_root_device to: '$actual_root_device'"
            ROOT_DEVICE="$actual_root_device"
            log "Final root device: $ROOT_DEVICE"
            
            # Debug post-LUKS degli array
            debug "Post-LUKS LUKS_MAPPINGS: ${LUKS_MAPPINGS[*]}"
            debug "Post-LUKS ACTIVATED_VGS: ${ACTIVATED_VGS[*]}"
            
            # Verifica che il device sia sano
            if ! verify_luks_device "$ROOT_DEVICE"; then
                error "LUKS device verification failed"
                [[ "$DEBUG_MODE" == true ]] && create_debug_snapshot
                return 1
            fi
        else
            error "Failed to handle LUKS partition"
            [[ "$DEBUG_MODE" == true ]] && create_debug_snapshot
            return 1
        fi
        
        # Handle EFI partition LUKS if present - NUOVA SINTASSI
        if [[ -n "$EFI_PART" ]]; then
            debug "Handling EFI partition: $EFI_PART"
            local actual_efi_device=""
            if detect_and_handle_luks "$EFI_PART" "actual_efi_device"; then
                EFI_PART="$actual_efi_device"
                log "Using EFI device: $EFI_PART"
            else
                warning "Failed to handle LUKS on EFI partition, continuing without it"
                EFI_PART=""
            fi
        fi
        
        # Handle Boot partition LUKS if present - NUOVA SINTASSI
        if [[ -n "$BOOT_PART" ]]; then
            debug "Handling boot partition: $BOOT_PART"
            local actual_boot_device=""
            if detect_and_handle_luks "$BOOT_PART" "actual_boot_device"; then
                BOOT_PART="$actual_boot_device"
                log "Using boot device: $BOOT_PART"
            else
                warning "Failed to handle LUKS on boot partition, continuing without it"
                BOOT_PART=""
            fi
        fi
    fi
    
    # Final debug degli array prima del mount
    debug "Final LUKS_MAPPINGS before mount: ${LUKS_MAPPINGS[*]}"
    debug "Final ACTIVATED_VGS before mount: ${ACTIVATED_VGS[*]}"
    
    # Crea snapshot dopo LUKS/LVM setup
    if [[ "$DEBUG_MODE" == true ]]; then
        local snapshot=$(create_debug_snapshot)
        debug "Post-LUKS system snapshot: $snapshot"
    fi
    
    # Validate and mount root filesystem
    debug "Getting filesystem type for: $ROOT_DEVICE"
    local fs_type=$(run_with_privileges blkid -o value -s TYPE "$ROOT_DEVICE" 2>/dev/null || echo "")
    log "Root filesystem type: $fs_type"
    
    if [[ "$fs_type" == "btrfs" ]]; then
        debug "Using Btrfs mount procedure for $ROOT_DEVICE"
        if ! mount_partition_btrfs "$ROOT_DEVICE" "$ROOT_MOUNT"; then
            error "Failed to mount Btrfs filesystem"
            [[ "$DEBUG_MODE" == true ]] && create_debug_snapshot
            return 1
        fi
    else
        debug "Using standard mount procedure for $ROOT_DEVICE"
        if ! safe_mount "$ROOT_DEVICE" "$ROOT_MOUNT"; then
            error "Failed to mount root filesystem"
            [[ "$DEBUG_MODE" == true ]] && create_debug_snapshot
            return 1
        fi
    fi
    
    # Verify root mount was successful and contains a valid Linux system
    debug "Verifying mounted root filesystem"
    if [[ ! -d "$ROOT_MOUNT/etc" ]]; then
        error "Mounted filesystem does not contain /etc directory"
        return 1
    fi
    
    if [[ ! -d "$ROOT_MOUNT/bin" ]] && [[ ! -d "$ROOT_MOUNT/usr/bin" ]]; then
        error "Mounted filesystem does not contain valid bin directories"
        return 1
    fi
    
    log "Root filesystem mounted and verified successfully"
    
    # Handle boot partition mounting
    if [[ -n "$BOOT_PART" ]]; then
        debug "Mounting boot partition: $BOOT_PART"
        run_with_privileges mkdir -p "$ROOT_MOUNT/boot"
        if ! safe_mount "$BOOT_PART" "$ROOT_MOUNT/boot"; then
            warning "Failed to mount boot partition, continuing without it"
        else
            log "Boot partition mounted successfully"
        fi
    fi
    
    # Handle EFI partition
    if [[ -n "$EFI_PART" ]]; then
        debug "Mounting EFI partition: $EFI_PART"
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
            warning "Failed to mount EFI partition, continuing without it"
        else
            log "EFI partition mounted successfully"
        fi
    fi
    
    # Setup bind mounts for chroot
    debug "Setting up bind mounts"
    if ! setup_bind_mounts "$ROOT_MOUNT"; then
        error "Failed to setup bind mounts"
        return 1
    fi
    log "Bind mounts setup successfully"
    
    # Copy network configuration
    debug "Copying network configuration"
    if [[ -f /etc/resolv.conf ]]; then
        if run_with_privileges cp --remove-destination /etc/resolv.conf "$ROOT_MOUNT/etc/resolv.conf" 2>/dev/null; then
            debug "Copied /etc/resolv.conf successfully"
        else
            warning "Failed to copy /etc/resolv.conf"
        fi
    else
        debug "/etc/resolv.conf not found on host"
    fi
    
    if [[ -f /etc/hosts ]]; then
        if run_with_privileges cp /etc/hosts "$ROOT_MOUNT/etc/hosts" 2>/dev/null; then
            debug "Copied /etc/hosts successfully"
        else
            warning "Failed to copy /etc/hosts"
        fi
    else
        debug "/etc/hosts not found on host"
    fi
    
    # Final verification
    debug "Final chroot environment verification"
    if ! mountpoint -q "$ROOT_MOUNT"; then
        error "Root mount point verification failed"
        return 1
    fi
    
    # Check that we can access basic directories
    if ! run_with_privileges test -d "$ROOT_MOUNT/etc"; then
        error "Cannot access /etc in chroot"
        return 1
    fi
    
    if ! run_with_privileges test -d "$ROOT_MOUNT/proc"; then
        error "Proc bind mount directory missing"
        return 1
    fi
    
    log "Chroot environment setup complete"
    
    # Create final debug snapshot if in debug mode
    if [[ "$DEBUG_MODE" == true ]]; then
        local final_snapshot=$(create_debug_snapshot)
        debug "Final system snapshot: $final_snapshot"
    fi
    
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
    
    # Rileva shell disponibili seguendo anche i symlink
    local available_shells=()
    local possible_shells=(
        "/bin/bash"
        "/bin/sh" 
        "/usr/bin/bash"
        "/usr/bin/sh"
        "/run/current-system/sw/bin/bash"  # NixOS
        "/run/current-system/sw/bin/sh"    # NixOS fallback
    )
    
    debug "Detecting available shells in chroot..."
    for potential_shell in "${possible_shells[@]}"; do
        local chroot_shell_path="$ROOT_MOUNT$potential_shell"
        
        # Controlla se esiste (file o symlink)
        if [[ -L "$chroot_shell_path" ]]; then
            # È un symlink - controlla se il target esiste
            local target
            target=$(readlink "$chroot_shell_path")
            debug "Found symlink $potential_shell -> $target"
            
            # Se il target è relativo, rendilo assoluto rispetto al chroot
            if [[ "$target" != /* ]]; then
                target="$(dirname "$chroot_shell_path")/$target"
            else
                target="$ROOT_MOUNT$target"
            fi
            
            if [[ -x "$target" ]]; then
                available_shells+=("$potential_shell")
                debug "Valid shell via symlink: $potential_shell"
            else
                debug "Symlink target not executable: $target"
            fi
        elif [[ -x "$chroot_shell_path" ]]; then
            available_shells+=("$potential_shell")
            debug "Found executable shell: $potential_shell"
        fi
    done
    
    # Se non trovo shell standard, provo a seguire i symlink manualmente
    if [[ ${#available_shells[@]} -eq 0 ]]; then
        debug "No standard shells found, checking symlinks in /bin and /usr/bin"
        
        # Controlla i symlink in /bin
        if [[ -L "$ROOT_MOUNT/bin/sh" ]]; then
            local sh_target
            sh_target=$(readlink "$ROOT_MOUNT/bin/sh")
            debug "Found /bin/sh -> $sh_target"
            
            # Se il target è assoluto, provalo
            if [[ "$sh_target" == /* ]]; then
                if [[ -x "$ROOT_MOUNT$sh_target" ]]; then
                    available_shells+=("/bin/sh")
                    debug "Using symlinked shell: /bin/sh -> $sh_target"
                fi
            fi
        fi
        
        # Controlla /bin/bash se esiste come symlink
        if [[ -L "$ROOT_MOUNT/bin/bash" ]]; then
            local bash_target
            bash_target=$(readlink "$ROOT_MOUNT/bin/bash")
            debug "Found /bin/bash -> $bash_target"
            
            if [[ "$bash_target" == /* ]]; then
                if [[ -x "$ROOT_MOUNT$bash_target" ]]; then
                    available_shells+=("/bin/bash")
                    debug "Using symlinked shell: /bin/bash -> $bash_target"
                fi
            fi
        fi
    fi
    
    if [[ ${#available_shells[@]} -eq 0 ]]; then
        error "No suitable shell found in chroot environment"
        debug "Checked paths: ${possible_shells[*]}"
        debug "Contents of chroot /bin:"
        ls -la "$ROOT_MOUNT/bin" 2>/dev/null | head -10 | while IFS= read -r line; do debug "  $line"; done || debug "  /bin directory not found"
        return 1
    fi
    
    # Scegli la shell migliore (preferisci bash over sh)
    local chosen_shell=""
    for shell_candidate in "${available_shells[@]}"; do
        if [[ "$shell_candidate" == *bash* ]]; then
            chosen_shell="$shell_candidate"
            break
        fi
    done
    
    if [[ -z "$chosen_shell" ]]; then
        chosen_shell="${available_shells[0]}"
    fi
    
    log "Using shell: $chosen_shell"
    
    echo $$ > "$CHROOT_PID_FILE"
    
    # Setup environment variables per GUI se necessario
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
    
    # Entra nel chroot - SENZA usare run_with_privileges per evitare buffering
    if [[ -n "${CHROOT_USER:-}" ]] && [[ "$CHROOT_USER" != "root" ]]; then
        log "Entering chroot as user $CHROOT_USER"
        if [[ ${#chroot_env_vars[@]} -gt 0 ]]; then
            sudo chroot "$ROOT_MOUNT" su - "$CHROOT_USER" -c "env ${chroot_env_vars[*]} $chosen_shell"
        else
            sudo chroot "$ROOT_MOUNT" su - "$CHROOT_USER" -c "$chosen_shell"
        fi
    else
        log "Entering chroot as root"
        if [[ ${#chroot_env_vars[@]} -gt 0 ]]; then
            sudo env "${chroot_env_vars[@]}" chroot "$ROOT_MOUNT" "$chosen_shell"
        else
            sudo chroot "$ROOT_MOUNT" "$chosen_shell"
        fi
    fi
    
    log "Exited chroot environment"
}