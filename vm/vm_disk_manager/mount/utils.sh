#!/bin/bash

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
