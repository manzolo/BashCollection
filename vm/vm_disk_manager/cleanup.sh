#!/bin/bash

# Helper function for logging
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Comprehensive cleanup function
cleanup() {
    if [ "$CLEANUP_DONE" = true ]; then
        return 0
    fi
    
    log "Starting cleanup"
    echo "Cleaning up..."
    CLEANUP_DONE=true
    
    # Terminate QEMU if active
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log "Terminating QEMU (PID: $QEMU_PID)"
        echo "Terminating QEMU (PID: $QEMU_PID)..."
        kill "$QEMU_PID" 2>/dev/null
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null
    fi
    
    # Unmount all mounted paths
    for path in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$path" 2>/dev/null; then
            log "Unmounting $path"
            echo "Unmounting $path..."
            umount "$path" 2>/dev/null || fusermount -u "$path" 2>/dev/null
            rmdir "$path" 2>/dev/null
        fi
    done
    
    # Deactivate LVM
    for lv in "${LVM_ACTIVE[@]}"; do
        log "Deactivating LV $lv"
        echo "Deactivating LV $lv..."
        lvchange -an "$lv" 2>/dev/null
    done
    
    # Deactivate VG
    for vg in "${VG_DEACTIVATED[@]}"; do
        log "Deactivating VG $vg"
        echo "Deactivating VG $vg..."
        vgchange -an "$vg" 2>/dev/null
    done
    
    # Close LUKS
    for luks in "${LUKS_MAPPED[@]}"; do
        log "Closing LUKS $luks"
        echo "Closing LUKS $luks..."
        cryptsetup luksClose "$luks" 2>/dev/null
    done
    
    # Disconnect NBD with retries
    if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
        log "Disconnecting $NBD_DEVICE"
        echo "Disconnecting $NBD_DEVICE..."
        for i in {1..3}; do
            if qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null; then
                break
            fi
            sleep 1
        done
    fi
    
    # Disconnect all active NBD devices
    for nbd in /dev/nbd*; do
        if [ -b "$nbd" ] && [ -s "/sys/block/$(basename "$nbd")/pid" ] 2>/dev/null; then
            log "Disconnecting $nbd"
            echo "Disconnecting $nbd..."
            qemu-nbd --disconnect "$nbd" 2>/dev/null
        fi
    done
    
    # Remove NBD module if possible
    sleep 2
    if lsmod | grep -q nbd; then
        rmmod nbd 2>/dev/null
    fi
    
    # Remove installed packages if requested
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        if whiptail --title "Package Cleanup" --yesno "Do you want to remove the packages automatically installed by this script?\n\nPackages: ${INSTALLED_PACKAGES[*]}" 10 70; then
            apt-get remove -y "${INSTALLED_PACKAGES[@]}" 2>/dev/null
            apt-get autoremove -y 2>/dev/null
        fi
    fi
    
    log "Cleanup completed"
    echo "Cleanup completed."
}

# Function to cleanup orphaned NBD devices
cleanup_nbd_devices() {
    log "Starting NBD device cleanup"
    local nbd_devices=$(ls -1 /dev/nbd* 2>/dev/null)
    local cleaned_count=0
    local failed_list=""
    
    if [ -z "$nbd_devices" ]; then
        whiptail --msgbox "No NBD devices found to clean up." 8 60
        return 0
    fi
    
    for dev in $nbd_devices; do
        if [[ "$dev" =~ nbd[0-9]+$ ]]; then
            log "Attempting to disconnect $dev"
            # Attempt to disconnect and check the exit code
            if sudo qemu-nbd --disconnect "$dev" >/dev/null 2>&1; then
                log "Successfully disconnected $dev"
                ((cleaned_count++))
            else
                log "Failed to disconnect $dev. It might be in use."
                failed_list+="\n- $dev (in use)"
            fi
        fi
    done
    
    local message="NBD device cleanup complete.\n\nDisconnected: $cleaned_count"
    
    if [ -n "$failed_list" ]; then
        message+="\n\nThe following devices could not be disconnected:$failed_list"
    fi
    
    whiptail --msgbox "$message" 15 60
}