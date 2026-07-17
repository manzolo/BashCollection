cleanup() {
    local exit_code=$?
    debug "Starting cleanup process"

    # Rimuovo file temporanei di lock/pid
    rm -f "$LOCK_FILE" "$CHROOT_PID_FILE"

    # GUI cleanup
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Cleaning up GUI support"
        if command -v xhost &> /dev/null; then
            xhost -local: 2>/dev/null || true
        fi
    fi

    # Kill lingering chroot processes prima degli smontaggi
    log "Checking for lingering chroot processes"
    if ! terminate_chroot_processes; then
        warning "Some chroot processes may persist, please check manually"
    fi

    # Unmount bind mounts (in ordine inverso)
    for ((i=${#BIND_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${BIND_MOUNTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting bind/virtual FS: $mount_point"
            debug "EXECUTING: umount $mount_point"
            run_with_privileges umount "$mount_point" || \
                warning "Error unmounting $mount_point"
        fi
    done

    # Unmount main mounts (escludendo i bind)
    for ((i=${#MOUNTED_POINTS[@]}-1; i>=0; i--)); do
        local mount_point="${MOUNTED_POINTS[i]}"
        # Skippa se è anche in BIND_MOUNTS
        if [[ " ${BIND_MOUNTS[*]} " == *" $mount_point "* ]]; then
            continue
        fi
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting: $mount_point"
            debug "EXECUTING: umount $mount_point"
            run_with_privileges umount "$mount_point" || {
                warning "Failed to unmount $mount_point, retrying with lazy umount"
                debug "EXECUTING: umount -l $mount_point"
                run_with_privileges umount -l "$mount_point" || \
                    warning "Lazy umount failed for $mount_point"
            }
        fi
    done

    # ⚠️ IMPORTANTE: Cleanup LUKS/LVM per ENTRAMBE le modalità
    debug "LUKS_MAPPINGS array contains: ${LUKS_MAPPINGS[*]}"
    debug "ACTIVATED_VGS array contains: ${ACTIVATED_VGS[*]}"
    debug "VIRTUAL_MODE is: $VIRTUAL_MODE"

    # Deactivate LVM VGs (per entrambe le modalità)
    if [[ ${#ACTIVATED_VGS[@]} -gt 0 ]]; then
        log "Deactivating LVM Volume Groups..."
        for vg in "${ACTIVATED_VGS[@]}"; do
            [[ -z "$vg" ]] && continue
            log "Deactivating VG: $vg"
            debug "EXECUTING: vgchange -an $vg"
            if run_with_privileges vgchange -an "$vg" 2>/dev/null; then
                log "Successfully deactivated VG: $vg"
            else
                warning "Error deactivating VG $vg"
            fi
        done
    else
        debug "No LVM Volume Groups to deactivate"
    fi

    # Close LUKS mappings (per entrambe le modalità)
    if [[ ${#LUKS_MAPPINGS[@]} -gt 0 ]]; then
        log "Closing LUKS encrypted devices..."
        for name in "${LUKS_MAPPINGS[@]}"; do
            [[ -z "$name" ]] && continue
            log "Closing LUKS mapping: $name"
            debug "EXECUTING: cryptsetup luksClose $name"
            
            # Verifica che il mapping esista
            if [[ -e "/dev/mapper/$name" ]]; then
                if run_with_privileges cryptsetup luksClose "$name" 2>/dev/null; then
                    log "Successfully closed LUKS mapping: $name"
                else
                    warning "Error closing LUKS $name, trying force removal"
                    debug "EXECUTING: dmsetup remove $name"
                    run_with_privileges dmsetup remove "$name" 2>/dev/null || \
                        error "Failed to force remove LUKS mapping $name"
                fi
            else
                debug "LUKS mapping $name already removed"
            fi
        done
    else
        debug "No LUKS mappings to close"
    fi

    # Virtual disk specific cleanup (solo per virtual mode)
    if [[ "$VIRTUAL_MODE" == true ]]; then
        # Disconnect NBD
        if [[ -n "$NBD_DEVICE" ]]; then
            log "Disconnecting NBD device: $NBD_DEVICE"
            debug "EXECUTING: qemu-nbd --disconnect $NBD_DEVICE"
            if run_with_privileges qemu-nbd --disconnect "$NBD_DEVICE"; then
                log "Successfully disconnected NBD device: $NBD_DEVICE"
            else
                warning "Error disconnecting $NBD_DEVICE"
            fi
            
            debug "EXECUTING: modprobe -r nbd"
            run_with_privileges modprobe -r nbd || warning "Unable to unload nbd module"
        fi
    fi

    # Verifica finale che i dispositivi LUKS siano effettivamente chiusi
    if [[ ${#LUKS_MAPPINGS[@]} -gt 0 ]]; then
        log "Final verification: checking LUKS devices are closed..."
        local remaining_devices=()
        
        for name in "${LUKS_MAPPINGS[@]}"; do
            [[ -z "$name" ]] && continue
            if [[ -e "/dev/mapper/$name" ]]; then
                remaining_devices+=("$name")
                error "LUKS mapping $name still exists after cleanup!"
            else
                debug "LUKS mapping $name successfully closed"
            fi
        done
        
        if [[ ${#remaining_devices[@]} -gt 0 ]]; then
            error "WARNING: ${#remaining_devices[@]} LUKS devices still open: ${remaining_devices[*]}"
            log "You may need to manually close them with: cryptsetup luksClose <name>"
        else
            log "All LUKS devices successfully closed"
        fi
    fi

    # Rimuovo directory temporanee
    for mount_point in "${MOUNTED_POINTS[@]}"; do
        [[ "$mount_point" == /tmp/disk_mount_* ]] && rmdir "$mount_point" 2>/dev/null || true
    done

    # Pulizia log di errore temporanei
    rm -f /tmp/mount_error.log /tmp/umount_error.log 2>/dev/null || true

    success "Cleanup complete"
    return $exit_code
}