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
    
    if cryptsetup isLuks "$selected_part" 2>/dev/null; then
        local luks_mapped=$(open_luks "$selected_part" 2>>"$LOG_FILE")
        if [ $? -eq 0 ] && [ -n "$luks_mapped" ]; then
            selected_part="$luks_mapped"
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
        
        whiptail --msgbox "Partition mounted!\n\nPath: $mount_point\n\nUse the 'exit' command to return to the menu.\n" 12 70
        
        # Open interactive shell in current terminal, waiting for user to exit
        if [ -n "$original_user" ]; then
            sudo -u "$original_user" bash -c "cd '$mount_point' && exec bash -i"
        else
            bash -c "cd '$mount_point' && exec bash -i"
        fi
        
        # Cleanup is now correctly placed AFTER the shell exits
        log "Shell exited, checking mount and NBD status" >> "$LOG_FILE"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount "$mount_point" 2>>"$LOG_FILE" || log "Failed to unmount $mount_point" >> "$LOG_FILE"
            rmdir "$mount_point" 2>/dev/null
            MOUNTED_PATHS=("${MOUNTED_PATHS[@]/$mount_point}")
            log "Unmounted $mount_point" >> "$LOG_FILE"
        fi
        if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            log "Disconnected $NBD_DEVICE" >> "$LOG_FILE"
        fi
        
        whiptail --msgbox "Shell closed and mount cleaned up." 8 50
        return 0
    else
        rmdir "$mount_point" 2>/dev/null
        log "Mount failed for $selected_part" >> "$LOG_FILE"
        if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
        fi
        whiptail --msgbox "Error mounting $(basename "$selected_part").\nFilesystem may be corrupted or unsupported.\nCheck log: $LOG_FILE" 10 70
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