safe_unmount_device_partitions() {
    local device="$1"
    log "Safely unmounting partitions on $device..."
    
    local unmounted_any=false
    
    while IFS= read -r partition; do
        if [ -b "/dev/$partition" ]; then
            local mount_point=$(findmnt -n -o TARGET "/dev/$partition" 2>/dev/null)
            if [ -n "$mount_point" ]; then
                case "$mount_point" in
                    /|/proc|/sys|/dev|/run|/boot|/boot/efi)
                        log "  Skipping critical system mount: /dev/$partition -> $mount_point"
                        continue
                        ;;
                esac
                
                log "  Unmounting /dev/$partition from $mount_point..."
                if [ "$DRY_RUN" = true ]; then
                    log "  🧪 DRY RUN - Would unmount: /dev/$partition"
                    unmounted_any=true
                elif umount "/dev/$partition" 2>/dev/null; then
                    log "    ✓ Successfully unmounted /dev/$partition"
                    unmounted_any=true
                elif umount -l "/dev/$partition" 2>/dev/null; then
                    log "    ✓ Lazy unmount successful for /dev/$partition"
                    unmounted_any=true
                else
                    log "    ⚠ Failed to unmount /dev/$partition"
                fi
            fi
        fi
    done < <(lsblk -ln -o NAME "$device" | tail -n +2)
    
    if [ "$unmounted_any" = true ]; then
        log "  Waiting 3 seconds for unmount operations to complete..."
        if [ "$DRY_RUN" = false ]; then
            sleep 3
            sync
        fi
    fi
    
    return 0
}