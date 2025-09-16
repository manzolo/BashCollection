cleanup() {
    local exit_code=$?
    debug "Starting cleanup process"
    #echo "Starting cleanup process"
    #read -r

    # Rimuovo file temporanei di lock/pid
    rm -f "$LOCK_FILE" "$CHROOT_PID_FILE"

    # GUI cleanup
    if [[ "$ENABLE_GUI_SUPPORT" == true ]]; then
        log "Cleaning up GUI support"
        if command -v xhost &> /dev/null; then
            xhost -local: 2>/dev/null || true
        fi
    fi

    # 🔥 Kill lingering chroot processes prima degli smontaggi
    log "Checking for lingering chroot processes"
    if ! terminate_chroot_processes; then
        warning "Some chroot processes may persist, please check manually"
    fi

    # Unmount bind mounts (in ordine inverso)
    for ((i=${#BIND_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${BIND_MOUNTS[i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting bind/virtual FS: $mount_point"
            #run_with_privileges safe_umount "$mount_point"
            run_with_privileges umount "$mount_point" || \
                warning "Error unmounting $mount_point"
        fi
        #sleep 1
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
            #run_with_privileges safe_umount "$mount_point"
            run_with_privileges umount "$mount_point" || {
                warning "Failed to unmount $mount_point, retrying with lazy umount"
                run_with_privileges umount -l "$mount_point" || \
                    warning "Lazy umount failed for $mount_point"
            }
        fi
    done

    # Virtual disk specific cleanup
    if [[ "$VIRTUAL_MODE" == true ]]; then
        # Deactivate LVM VGs
        for vg in "${ACTIVATED_VGS[@]}"; do
            log "Deactivating VG: $vg"
            run_with_privileges vgchange -an "$vg" 2>/dev/null || warning "Error deactivating VG $vg"
        done

        # Close LUKS mappings
        for name in "${LUKS_MAPPINGS[@]}"; do
            log "Closing LUKS mapping: $name"
            run_with_privileges cryptsetup luksClose "$name" 2>/dev/null || warning "Error closing LUKS $name"
        done

        # Disconnect NBD
        if [[ -n "$NBD_DEVICE" ]]; then
            log "Disconnecting NBD device: $NBD_DEVICE"
            run_with_privileges qemu-nbd --disconnect "$NBD_DEVICE" || warning "Error disconnecting $NBD_DEVICE"
            run_with_privileges modprobe -r nbd || warning "Unable to unload nbd module"
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
