#!/bin/bash

# Function to mount with guestmount
mount_with_guestmount() {
    local file=$1
    
    if ! command -v guestmount &> /dev/null; then
        log "guestmount not found"
        whiptail --msgbox "guestmount is not available.\nInstall with: apt install libguestfs-tools" 10 60
        return 1
    fi
    
    if ! check_file_lock "$file"; then
        return 1
    fi
    
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    local original_uid=${SUDO_UID:-$(id -u "$original_user" 2>/dev/null)}
    local original_gid=${SUDO_GID:-$(id -g "$original_user" 2>/dev/null)}
    
    local mount_point="/mnt/vm_guest_$$"
    mkdir -p "$mount_point"
    
    (
        echo 0
        echo "# Mounting with guestmount..."
        local guestmount_opts=(--add "$file" -i --rw)
        if [ -n "$original_uid" ]; then
            guestmount_opts+=(--uid "$original_uid" --gid "$original_gid")
        fi
        guestmount_opts+=(-o allow_other)
        guestmount "${guestmount_opts[@]}" "$mount_point" 2>>"$LOG_FILE"
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Mounted successfully!"
            sleep 1
        else
            echo "# Mount failed"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Mounting with guestmount..." 8 50 0
    
    if [ $? -eq 0 ]; then
        MOUNTED_PATHS+=("$mount_point")
        sleep 2
        if [ -n "$original_uid" ]; then
            chown "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
            chmod 755 "$mount_point" 2>/dev/null || true
        fi
        local access_test="OK"
        if [ -n "$original_user" ]; then
            if ! su - "$original_user" -c "test -r '$mount_point'" 2>/dev/null; then
                access_test="LIMITED - Use sudo for full access"
            fi
        fi
        local space_info=$(df -h "$mount_point" 2>/dev/null | tail -1)
        local user_info=""
        if [ -n "$original_user" ]; then
            user_info="\nUser: $original_user\nAccess: $access_test"
        fi
        log "Mounted at $mount_point, access: $access_test"
        whiptail --msgbox "Image mounted successfully!\n\nPath: $mount_point$user_info\nSpace: $space_info\n\nCommands:\n- cd $mount_point\n- ls -la $mount_point\n- sudo -u $original_user ls $mount_point\n\nPress OK when you're done." 20 80
        (
            echo 0
            echo "# Unmounting..."
            guestunmount "$mount_point" 2>/dev/null || fusermount -u "$mount_point" 2>/dev/null
            rmdir "$mount_point" 2>/dev/null
            echo 100
            echo "# Unmounted!"
            sleep 1
        ) | whiptail --gauge "Unmounting..." 8 50 0
        MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mount_point}")
        log "Unmounted $mount_point"
        whiptail --msgbox "Unmounting completed." 8 50
        return 0
    else
        rmdir "$mount_point" 2>/dev/null
        log "guestmount failed"
        whiptail --msgbox "Error mounting with guestmount.\nPossible causes:\n- Corrupted image\n- Unsupported filesystem\n- Insufficient permissions\nCheck log: $LOG_FILE" 12 70
        return 1
    fi
}

# Function to mount with NBD
mount_with_nbd() {
    local file=$1
    local format=$(qemu-img info "$file" 2>/dev/null | grep "file format:" | awk '{print $3}')
    
    if [ -z "$format" ]; then
        format="raw"
    fi
    
    if ! connect_nbd "$file" "$format" >> "$LOG_FILE" 2>&1; then
        whiptail --msgbox "NBD connection error. Check $LOG_FILE for details." 8 50
        return 1
    fi
    
    local part_items=()
    local counter=1
    for part in "${NBD_DEVICE}"p*; do
        if [ -b "$part" ]; then
            local fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null || echo "unknown")
            local size=$(lsblk -no SIZE "$part" 2>/dev/null || echo "?")
            part_items+=("$counter" "$(basename "$part") - $fs_type ($size)")
            ((counter++))
        fi
    done
    
    if [ ${#part_items[@]} -eq 0 ]; then
        whiptail --msgbox "No partitions found." 8 50
        safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
        NBD_DEVICE=""
        return 1
    fi
    
    part_items+=("$counter" "Full analysis (without mounting)")
    local analyze_option=$counter
    
    local choice=$(whiptail --title "NBD Mount" --menu "Select the partition to mount:" 18 70 10 "${part_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
        NBD_DEVICE=""
        return 1
    fi
    
    if [ "$choice" -eq "$analyze_option" ]; then
        local analysis=$(analyze_partitions "$NBD_DEVICE" 2>>"$LOG_FILE")
        local luks_info=""
        local luks_parts=($(detect_luks "$NBD_DEVICE" 2>>"$LOG_FILE"))
        if [ ${#luks_parts[@]} -gt 0 ]; then
            luks_info="\n\n=== LUKS PARTITIONS ===\n"
            for part in "${luks_parts[@]}"; do
                luks_info="$luks_info$(basename "$part")\n"
            done
        fi
        safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
        NBD_DEVICE=""
        whiptail --title "Full Analysis" --msgbox "$analysis$luks_info" 20 80
        return 0
    fi
    
    local selected_part=""
    local current_counter=1
    for part in "${NBD_DEVICE}"p*; do
        if [ -b "$part" ] && [ "$choice" -eq "$current_counter" ]; then
            selected_part="$part"
            break
        fi
        ((current_counter++))
    done
    
    if [ -z "$selected_part" ]; then
        whiptail --msgbox "Selection error." 8 50
        safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
        NBD_DEVICE=""
        return 1
    fi
    
    local luks_name=""
    if cryptsetup isLuks "$selected_part" 2>/dev/null; then
        local luks_mapped=$(open_luks "$selected_part" 2>>"$LOG_FILE")
        if [ $? -eq 0 ] && [ -n "$luks_mapped" ]; then
            selected_part="$luks_mapped"
            luks_name=$(basename "$luks_mapped")
            LUKS_MAPPED+=("$luks_name")
        else
            whiptail --msgbox "Cannot open the LUKS partition. Check $LOG_FILE for details." 8 50
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            return 1
        fi
    fi
    
    local mount_point="/mnt/nbd_mount_$$"
    mkdir -p "$mount_point"
    
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    
    (
        echo 0
        echo "# Mounting $selected_part..."
        local mount_opts=""
        if [ -n "$original_user" ]; then
            local original_uid=$(id -u "$original_user" 2>/dev/null)
            local original_gid=$(id -g "$original_user" 2>/dev/null)
            if [ -n "$original_uid" ]; then
                mount_opts="-o uid=$original_uid,gid=$original_gid,umask=022"
            fi
        fi
        if ! mount $mount_opts "$selected_part" "$mount_point" 2>>"$LOG_FILE"; then
            mount "$selected_part" "$mount_point" 2>>"$LOG_FILE"
        fi
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Mounted successfully!"
            sleep 1
        else
            echo "# Mount failed"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Mounting partition..." 8 50 0
    
    if [ $? -eq 0 ]; then
        MOUNTED_PATHS+=("$mount_point")
        if [ -n "$original_user" ]; then
            local original_uid=$(id -u "$original_user" 2>/dev/null)
            local original_gid=$(id -g "$original_user" 2>/dev/null)
            if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
                chmod 755 "$mount_point" 2>/dev/null || true
                chown "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
            fi
        fi
        
        log "Mounted $selected_part at $mount_point" >> "$LOG_FILE"
        
        local action_options=(
            "1" "Interactive shell in mount directory"
            "2" "Chroot into filesystem (Linux only)"
            "3" "Just mount and return to menu"
        )
        
        local action_choice=$(whiptail --title "Mount Action" --menu "Partition mounted at $mount_point\nWhat would you like to do?" 15 70 3 "${action_options[@]}" 3>&1 1>&2 2>&3)
        
        case $action_choice in
            1)
                whiptail --msgbox "Opening shell in mount directory.\n\nPath: $mount_point\n\nUse 'exit' to return to the menu." 12 70
                if [ -n "$original_user" ]; then
                    sudo -u "$original_user" bash -c "cd '$mount_point' && exec bash -i"
                else
                    bash -c "cd '$mount_point' && exec bash -i"
                fi
                ;;
            2)
                if [ -d "$mount_point" ]; then
                    whiptail --msgbox "Entering isolated chroot environment.\n\nYou are now in the VM's filesystem as root.\nNetworking and some services may not work.\n\nUse 'exit' to return to the menu.\n\nWarning: Be careful with system modifications!" 15 70
                    run_chroot_isolated "$mount_point"
                else
                    whiptail --msgbox "Invalid mount point.\nFalling back to regular shell." 10 60
                    if [ -n "$original_user" ]; then
                        sudo -u "$original_user" bash -c "cd '$mount_point' && exec bash -i"
                    else
                        bash -c "cd '$mount_point' && exec bash -i"
                    fi
                fi
                ;;
            3)
                whiptail --msgbox "Partition mounted at: $mount_point\n\nReturning to menu. Use 'Active Mount Points' to manage." 10 70
                return 0
                ;;
            *)
                whiptail --msgbox "No action selected. Returning to menu.\n\nMount point: $mount_point" 10 70
                return 0
                ;;
        esac
        
        # Cleanup after shell/chroot exits
        log "Shell/chroot exited, cleaning up mount and NBD"
        
        # Unmount any partitions
        for part in "${NBD_DEVICE}"p*; do
            if [ -b "$part" ]; then
                for mnt in $(mount | grep "$part" | awk '{print $3}'); do
                    log "Unmounting $mnt from $part"
                    for i in {1..3}; do
                        if umount "$mnt" 2>>"$LOG_FILE" || umount -f "$mnt" 2>>"$LOG_FILE"; then
                            break
                        fi
                        log "Failed to unmount $mnt, retrying ($i/3)"
                        sleep 1
                    done
                    if mountpoint -q "$mnt" 2>/dev/null; then
                        log "Resorting to lazy unmount for $mnt"
                        umount -l "$mnt" 2>>"$LOG_FILE"
                    fi
                    MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mnt}")
                done
            fi
        done
        
        # Unmount main partition
        if mountpoint -q "$mount_point" 2>/dev/null; then
            for i in {1..3}; do
                if umount "$mount_point" 2>>"$LOG_FILE" || umount -f "$mount_point" 2>>"$LOG_FILE"; then
                    break
                fi
                log "Failed to unmount $mount_point, retrying ($i/3)"
                sleep 1
            done
            if mountpoint -q "$mount_point" 2>/dev/null; then
                log "Resorting to lazy unmount for $mount_point"
                umount -l "$mount_point" 2>>"$LOG_FILE"
            fi
            rmdir "$mount_point" 2>/dev/null
            MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mount_point}")
            log "Unmounted $mount_point"
        fi
        
        # Close LUKS mapping if it exists
        if [ -n "$luks_name" ] && [ -b "/dev/mapper/$luks_name" ]; then
            log "Closing LUKS mapping $luks_name"
            cryptsetup luksClose "$luks_name" 2>>"$LOG_FILE" || log "Failed to close LUKS $luks_name"
            LUKS_MAPPED=("${LUKS_MAPPED[@]/$luks_name}")
        fi
        
        # Check for processes using the NBD device
        if [ -n "$NBD_DEVICE" ] && lsof -e /run/user/*/gvfs -e /run/user/*/doc -e /tmp/.mount_* "$NBD_DEVICE" >/dev/null 2>&1; then
            log "Processes using $NBD_DEVICE found, attempting to terminate"
            lsof -e /run/user/*/gvfs -e /run/user/*/doc -e /tmp/.mount_* "$NBD_DEVICE" | tail -n +2 | awk '{print $2}' | sort -u | while read pid; do
                log "Terminating PID $pid holding $NBD_DEVICE"
                kill "$pid" 2>/dev/null
                sleep 1
                kill -9 "$pid" 2>/dev/null
            done
        fi
        
        # Disconnect NBD
        if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            log "Disconnected $NBD_DEVICE"
        fi
        
        whiptail --msgbox "Mount and NBD cleaned up successfully." 8 50
        return 0
    else
        # Cleanup on mount failure
        if [ -n "$luks_name" ] && [ -b "/dev/mapper/$luks_name" ]; then
            log "Closing LUKS mapping $luks_name on mount failure"
            cryptsetup luksClose "$luks_name" 2>>"$LOG_FILE" || log "Failed to close LUKS $luks_name"
            LUKS_MAPPED=("${LUKS_MAPPED[@]/$luks_name}")
        fi
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount "$mount_point" 2>>"$LOG_FILE" || umount -l "$mount_point" 2>>"$LOG_FILE"
            MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mount_point}")
        fi
        rmdir "$mount_point" 2>/dev/null
        if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
        fi
        whiptail --msgbox "Mount failed. Check $LOG_FILE for details." 8 50
        return 1
    fi
}

# Function to show active mount points
show_active_mounts() {
    local active_mounts=""
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    
    for mount_point in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            local mount_info=$(df -h "$mount_point" 2>/dev/null | tail -1)
            local access_test="OK"
            if [ -n "$original_user" ]; then
                if ! su - "$original_user" -c "test -r '$mount_point'" 2>/dev/null; then
                    access_test="LIMITED"
                fi
            fi
            active_mounts="$active_mounts$mount_point (Access: $access_test)\n$mount_info\n\n"
        fi
    done
    
    if [ -n "$active_mounts" ]; then
        whiptail --title "Active Mount Points" --msgbox "Currently active mount points:\n\n$active_mounts\nUseful commands:\n- sudo -u $original_user bash\n- sudo chmod -R 755 /mount/path\n- sudo chown -R $original_user:$original_user /mount/path" 20 80
    else
        whiptail --msgbox "No active mount points found at the moment." 8 50
    fi
}

# Function to fix permissions of existing mounts
fix_mount_permissions() {
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}
    local original_uid=${SUDO_UID:-$(id -u "$original_user" 2>/dev/null)}
    local original_gid=${SUDO_GID:-$(id -g "$original_user" 2>/dev/null)}
    
    if [ ${#MOUNTED_PATHS[@]} -eq 0 ]; then
        whiptail --msgbox "No active mount points found." 8 50
        return 1
    fi
    
    local mount_items=()
    local counter=1
    for mount_point in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            mount_items+=("$counter" "$mount_point")
            ((counter++))
        fi
    done
    
    if [ ${#mount_items[@]} -eq 0 ]; then
        whiptail --msgbox "No active mount points." 8 50
        return 1
    fi
    
    mount_items+=("$counter" "All mount points")
    local all_option=$counter
    
    local choice=$(whiptail --title "Fix Permissions" --menu "Which mount point to fix?" 15 70 8 "${mount_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    local target_mounts=()
    if [ "$choice" -eq "$all_option" ]; then
        target_mounts=("${MOUNTED_PATHS[@]}")
    else
        local current_counter=1
        for mount_point in "${MOUNTED_PATHS[@]}"; do
            if mountpoint -q "$mount_point" 2>/dev/null && [ "$choice" -eq "$current_counter" ]; then
                target_mounts=("$mount_point")
                break
            fi
            ((current_counter++))
        done
    fi
    
    local fixed_count=0
    for mount_point in "${target_mounts[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            (
                echo 0
                echo "# Fixing permissions for $mount_point..."
                timeout 30 chmod -R 755 "$mount_point" 2>/dev/null || true
                if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
                    timeout 30 chown -R "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
                fi
                echo 100
                echo "# Permissions fixed!"
                sleep 1
            ) | whiptail --gauge "Fixing permissions..." 8 50 0
            ((fixed_count++))
            log "Fixed permissions for $mount_point"
        fi
    done
    
    whiptail --msgbox "Permissions fixed for $fixed_count mount points.\n\nUser: $original_user\n\nNow you can try:\ncd $mount_point\nls -la $mount_point" 12 70
}

# Run a chroot in an isolated mount namespace
run_chroot_isolated() {
    local root="$1"

    if [ ! -d "$root" ]; then
        whiptail --msgbox "Invalid root directory: $root" 8 60
        return 1
    fi

    if ! command -v unshare >/dev/null 2>&1; then
        whiptail --msgbox "'unshare' command not found.\nPlease install util-linux." 10 60
        return 1
    fi

    # Define preferred shells in order of preference
    local preferred_shells=("/bin/bash" "/usr/bin/bash" "/bin/sh" "/usr/bin/sh")
    local shell_path=""

    # Check for the first available shell in the chroot
    for shell in "${preferred_shells[@]}"; do
        if [ -x "$root$shell" ]; then
            shell_path="$shell"
            break
        fi
    done

    # If no suitable shell was found, exit
    if [ -z "$shell_path" ]; then
        whiptail --msgbox "No suitable shell found in $root.\nExpected one of: ${preferred_shells[*]}" 12 70
        return 1
    fi

    unshare -m bash -c "
        set -e
        mount --make-rprivate /

        # Ensure required mountpoints exist
        for d in proc sys dev dev/pts run; do
            [ -d '$root/'\$d ] || mkdir -p '$root/'\$d
        done

        # Bind required filesystems
        mountpoint -q '$root/proc'    2>/dev/null || mount -t proc  proc  '$root/proc'
        mountpoint -q '$root/sys'     2>/dev/null || mount -t sysfs sys   '$root/sys'
        mountpoint -q '$root/dev'     2>/dev/null || mount --bind /dev   '$root/dev'
        mountpoint -q '$root/dev/pts' 2>/dev/null || mount -t devpts devpts '$root/dev/pts'
        mountpoint -q '$root/run'     2>/dev/null || mount --bind /run   '$root/run'

        # Cleanup on exit
        cleanup_mounts() {
            umount -l '$root/run'     2>/dev/null || true
            umount -l '$root/dev/pts' 2>/dev/null || true
            umount -l '$root/dev'     2>/dev/null || true
            umount -l '$root/sys'     2>/dev/null || true
            umount -l '$root/proc'    2>/dev/null || true
        }
        trap cleanup_mounts EXIT

        echo 'Entering isolated chroot...'
        exec chroot '$root' '$shell_path' -l
    "
}