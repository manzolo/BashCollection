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
            guestmount_opts+=()
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