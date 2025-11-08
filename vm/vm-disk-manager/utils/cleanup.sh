#!/bin/bash

# Helper function for logging
log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"
}

# Comprehensive cleanup function
cleanup() {
    log "Starting cleanup"
    
    # Terminate QEMU if active
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        log "Terminating QEMU (PID: $QEMU_PID)"
        kill "$QEMU_PID" 2>/dev/null
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null
    fi
    
    # Unmount all mounted paths
    for path in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$path" 2>/dev/null; then
            log "Unmounting $path"
            for i in {1..3}; do
                if umount "$path" 2>/dev/null || umount -f "$path" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if mountpoint -q "$path" 2>/dev/null; then
                umount -l "$path" 2>/dev/null
            fi
            rmdir "$path" 2>/dev/null
        fi
    done
    
    # Deactivate LVM
    for lv in "${LVM_ACTIVE[@]}"; do
        log "Deactivating LV $lv"
        lvchange -an "$lv" 2>/dev/null
    done
    
    # Deactivate VG
    for vg in "${VG_DEACTIVATED[@]}"; do
        log "Deactivating VG $vg"
        vgchange -an "$vg" &>/dev/null
    done
    
    # Close LUKS
    for luks in "${LUKS_MAPPED[@]}"; do
        log "Closing LUKS $luks"
        cryptsetup luksClose "$luks" 2>/dev/null
    done
    
    # Disconnect all NBD devices
    cleanup_nbd_devices

    # Clean up temporary NVRAM files (fallback files when persistent NVRAM fails)
    local temp_nvram_files=$(find /tmp -maxdepth 1 -name "OVMF_VARS_*.fd" -type f 2>/dev/null)
    if [ -n "$temp_nvram_files" ]; then
        log "Cleaning up temporary NVRAM files"
        echo "$temp_nvram_files" | while read -r nvram_file; do
            if [ -f "$nvram_file" ]; then
                rm -f "$nvram_file" 2>/dev/null && log "Removed temporary NVRAM: $nvram_file"
            fi
        done
    fi

    # Remove NBD module if possible
    sleep 2
    if lsmod | grep -q nbd; then
        rmmod nbd 2>/dev/null || log "Failed to remove nbd module"
    fi

    log "Cleanup completed"
    CLEANUP_DONE=true
}

# Function to cleanup orphaned NBD devices
cleanup_nbd_devices() {
    log "Starting NBD device cleanup"
    local cleaned=0
    local failed=()

    # Helper: detach one NBD device robustly
    _detach_one_nbd() {
        local dev="$1"            # e.g. /dev/nbd0
        [ -b "$dev" ] || return 0

        log "Detaching $dev"

        # 1) Unmount anything on its partitions (hard → lazy)
        local m
        while read -r m; do
            [ -n "$m" ] || continue
            log "Unmounting $m"
            umount "$m" 2>/dev/null || umount -f "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
        done < <(mount | awk -v d="^${dev}p[0-9]+$" '$1 ~ d {print $3}')

        # 2) Kill any process using the mounts or the block device
        #    (ignore errors if fuser not available)
        command -v fuser >/dev/null 2>&1 && {
            # partitions
            for p in "${dev}"p*; do
                [ -b "$p" ] && fuser -km "$p" 2>/dev/null || true
            done
            # device itself
            fuser -km "$dev" 2>/dev/null || true
        }

        # 3) Try to disconnect repeatedly
        local i
        for i in $(seq 1 10); do
            if qemu-nbd --disconnect "$dev" >/dev/null 2>&1; then
                # Wait until the kernel drops the pid file (if present)
                local base; base=$(basename "$dev")
                local pidf="/sys/block/${base}/pid"
                local j
                for j in $(seq 1 10); do
                    if [ ! -e "$pidf" ] || ! ps -p "$(cat "$pidf" 2>/dev/null)" >/dev/null 2>&1; then
                        break
                    fi
                    sleep 0.3
                done
                # Double-check not mounted anymore
                if ! mount | grep -q "^$dev"; then
                    log "Successfully disconnected $dev"
                    cleaned=$((cleaned+1))
                    return 0
                fi
            fi
            sleep 0.5
        done

        # 4) Fallback with kernel tool if available
        if command -v nbd-client >/dev/null 2>&1; then
            if nbd-client -d "$dev" >/dev/null 2>&1; then
                log "Disconnected $dev via nbd-client"
                cleaned=$((cleaned+1))
                return 0
            fi
        fi

        log "Failed to disconnect $dev"
        failed+=("$dev")
        return 1
    }

    # Prefer the tracked device first
    if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
        _detach_one_nbd "$NBD_DEVICE" || true
        NBD_DEVICE=""
    fi

    # Then handle any other orphaned /dev/nbdN still around
    local d
    for d in /dev/nbd[0-9]*; do
        [ -e "$d" ] || break
        # Skip if already detached (no pid and no mounts)
        if ! mount | grep -q "^$d" && [ ! -e "/sys/block/$(basename "$d")/pid" ]; then
            continue
        fi
        _detach_one_nbd "$d" || true
    done

    local msg="NBD cleanup finished. Disconnected: $cleaned"
    if [ ${#failed[@]} -gt 0 ]; then
        msg="$msg. Still in use (could not disconnect):"
        for f in "${failed[@]}"; do msg="$msg $f"; done
        msg="$msg. Tip: if this persists after chroot, something is still running from the chroot (e.g., udev/dbus)."
        whiptail --msgbox "$msg" 16 70
    fi
    log "$msg"
}