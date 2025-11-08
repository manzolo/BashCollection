#!/bin/bash

# Function to find a free NBD device
find_free_nbd() {
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        if [ ! -s "/sys/block/nbd$i/pid" ] 2>/dev/null; then
            echo "$nbd_dev"
            return 0
        fi
    done
    echo "/dev/nbd0"
}

# Function to connect the image to NBD
connect_nbd() {
    local file=$1
    local format=${2:-raw}
    
    log "Starting connect_nbd for $file (format: $format)"
    
    if ! check_file_lock "$file"; then
        log "File lock check failed"
        return 1
    fi
    
    if ! lsmod | grep -q nbd; then
        log "Loading nbd module"
        modprobe nbd max_part=16 || { log "Failed to load nbd module"; return 1; }
    fi
    
    NBD_DEVICE=$(find_free_nbd)
    
    local retries=3
    (
        for i in $(seq 1 $retries); do
            echo $(( (i-1)*33 ))
            echo "# Attempt $i/$retries: Connecting NBD..."
            log "Attempt $i/$retries: Connecting $NBD_DEVICE"
            local qemu_pid
            timeout 30 qemu-nbd --connect="$NBD_DEVICE" -f "$format" "$file" 2>>"$LOG_FILE" &
            qemu_pid=$!
            wait $qemu_pid
            if [ $? -eq 0 ]; then
                sleep 3
                if [ -b "$NBD_DEVICE" ] && [ -s "/sys/block/$(basename "$NBD_DEVICE")/pid" ]; then
            echo 100
                    echo "# Connected successfully!"
                    log "NBD connected successfully, PID: $(cat /sys/block/$(basename "$NBD_DEVICE")/pid)"
                    sleep 1
                    exit 0
                fi
            fi
            log "Attempt $i failed: $(tail -n 1 "$LOG_FILE")"
            qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null
            sleep 2
        done
        echo 100
        echo "# Failed after $retries attempts."
        log "All NBD attempts failed"
        sleep 2
        exit 1
    ) | whiptail --gauge "Connecting NBD device..." 8 50 0
    
    if [ $? -eq 0 ]; then
        return 0
    else
        whiptail --msgbox "NBD connection failed after retries. Check log: $LOG_FILE" 8 50
        NBD_DEVICE=""
        return 1
    fi
}

# Function to safely disconnect NBD
safe_nbd_disconnect() {
    local device=$1
    
    if [ -z "$device" ]; then
        log "No NBD device specified for disconnect"
        return 0
    fi
    
    log "Starting safe disconnect for $device"
    
    # Metodo 1: lsof con filtri specifici e warning soppressi
    check_nbd_usage_filtered() {
        local nbd_device=$1
        
        # Usa lsof con opzioni specifiche per ridurre warning
        # -w: sopprime warning su filesystem inaccessibili
        # +D: cerca solo nella directory specifica se necessario
        local lsof_output
        lsof_output=$(lsof -w "$nbd_device" 2>/dev/null | tail -n +2)
        
        if [ -n "$lsof_output" ]; then
            log "NBD device $nbd_device is still in use:"
            log "$lsof_output"
            return 1
        fi
        return 0
    }
    
    # Metodo 2: Controllo alternativo senza lsof usando /proc
    check_nbd_usage_proc() {
        local nbd_device=$1
        local device_major_minor
        
        if [ ! -b "$nbd_device" ]; then
            return 0  # Device non esiste, quindi non è in uso
        fi
        
        # Ottieni major:minor del device
        device_major_minor=$(stat -c "%t:%T" "$nbd_device" 2>/dev/null)
        if [ -z "$device_major_minor" ]; then
            return 0
        fi
        
        # Converti da hex a decimale
        local major=$(printf "%d" "0x${device_major_minor%:*}")
        local minor=$(printf "%d" "0x${device_major_minor#*:}")
        local device_id="${major}:${minor}"
        
        # Cerca nei file descriptor aperti
        local processes_using_device=()
        for proc_fd in /proc/*/fd/*; do
            if [ -L "$proc_fd" ]; then
                local link_target=$(readlink "$proc_fd" 2>/dev/null)
                if [[ "$link_target" == "$nbd_device" ]] || [[ "$link_target" =~ ${nbd_device}p[0-9]+ ]]; then
                    local pid=$(echo "$proc_fd" | cut -d'/' -f3)
                    processes_using_device+=("$pid")
                fi
            fi
        done
        
        # Cerca nei mount points
        if mount | grep -q "$nbd_device"; then
            log "NBD device $nbd_device has mounted partitions"
            return 1
        fi
        
        if [ ${#processes_using_device[@]} -gt 0 ]; then
            log "NBD device $nbd_device is in use by processes: ${processes_using_device[*]}"
            return 1
        fi
        
        return 0
    }
    
    # Metodo 3: Controllo con fuser (se disponibile)
    check_nbd_usage_fuser() {
        local nbd_device=$1
        
        if ! command -v fuser &> /dev/null; then
            return 0  # fuser non disponibile, skip
        fi
        
        # fuser è generalmente più silenzioso di lsof
        if fuser -s "$nbd_device" 2>/dev/null; then
            log "NBD device $nbd_device is in use (detected by fuser)"
            return 1
        fi
        return 0
    }
    
    # Funzione principale di controllo con fallback multipli
    is_nbd_in_use() {
        local nbd_device=$1
        
        # Prova prima con fuser (più pulito)
        if command -v fuser &> /dev/null; then
            if ! check_nbd_usage_fuser "$nbd_device"; then
                return 0  # In uso
            fi
        fi
        
        # Poi con il metodo /proc (più affidabile)
        if ! check_nbd_usage_proc "$nbd_device"; then
            return 0  # In uso
        fi
        
        # Infine con lsof filtrato (come fallback)
        if ! check_nbd_usage_filtered "$nbd_device"; then
            return 0  # In uso
        fi
        
        return 1  # Non in uso
    }
    
    # Smonta tutte le partizioni prima della disconnessione
    unmount_nbd_partitions() {
        local base_device=$1
        log "Unmounting partitions for $base_device"
        
        # Trova e smonta tutte le partizioni
        for partition in "${base_device}p"*; do
            if [ -b "$partition" ]; then
                log "Checking partition $partition"
                if mount | grep -q "^$partition "; then
                    log "Unmounting $partition"
                    if ! umount "$partition" 2>/dev/null; then
                        log "Force unmounting $partition"
                        umount -f "$partition" 2>/dev/null || umount -l "$partition" 2>/dev/null
                    fi
                fi
            fi
        done
        
        # Verifica che il device base non sia montato
        if mount | grep -q "^$base_device "; then
            log "Unmounting base device $base_device"
            if ! umount "$base_device" 2>/dev/null; then
                log "Force unmounting base device $base_device"
                umount -f "$base_device" 2>/dev/null || umount -l "$base_device" 2>/dev/null
            fi
        fi
    }
    
    # Esecuzione della disconnessione
    unmount_nbd_partitions "$device"
    
    # Attendi un momento per il cleanup
    sleep 1
    
    # Controlla se è ancora in uso
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if is_nbd_in_use "$device"; then
            log "NBD device $device is free, proceeding with disconnect (attempt $attempt)"
            break
        else
            log "NBD device $device still in use, waiting... (attempt $attempt/$max_attempts)"
            if [ $attempt -eq $max_attempts ]; then
                log "Warning: Forcing NBD disconnect after $max_attempts attempts"
                # Lista i processi che ancora usano il device per il log
                if command -v fuser &> /dev/null; then
                    local using_processes=$(fuser -v "$device" 2>&1 | tail -n +2 || true)
                    if [ -n "$using_processes" ]; then
                        log "Processes still using $device: $using_processes"
                    fi
                fi
            fi
            sleep 2
            ((attempt++))
        fi
    done
    
    # Disconnetti il device NBD
    log "Disconnecting NBD device $device"
    if qemu-nbd --disconnect "$device" 2>/dev/null; then
        log "NBD device $device disconnected successfully"
        
        # Verifica che sia realmente disconnesso
        sleep 1
        if [ ! -b "$device" ] || ! ls -la "$device" &>/dev/null; then
            log "NBD device $device confirmed disconnected"
        else
            log "Warning: NBD device $device still exists after disconnect"
        fi
    else
        log "Error disconnecting NBD device $device, trying alternative methods"
        
        # Metodo alternativo: usa nbd-client se disponibile
        if command -v nbd-client &> /dev/null; then
            log "Trying nbd-client disconnect"
            nbd-client -d "$device" 2>/dev/null && log "NBD disconnected via nbd-client"
        fi
        
        # Ultimo tentativo: forza il cleanup del modulo
        if lsmod | grep -q nbd; then
            local nbd_num=$(echo "$device" | sed 's/.*nbd//')
            if [ -n "$nbd_num" ]; then
                echo "$nbd_num" > /sys/block/nbd${nbd_num}/pid 2>/dev/null || true
            fi
        fi
    fi
    
    log "NBD disconnect procedure completed for $device"
}

# Funzione per il controllo e cleanup preventivo dei device NBD
cleanup_stale_nbd_devices() {
    log "Checking for stale NBD devices..."
    
    for nbd_dev in /dev/nbd*; do
        if [ -b "$nbd_dev" ] && [[ "$nbd_dev" =~ /dev/nbd[0-9]+$ ]]; then
            # Controlla se il device è connesso ma non in uso
            if qemu-nbd --list 2>/dev/null | grep -q "$nbd_dev" || \
               [ -r "/sys/block/$(basename "$nbd_dev")/pid" ] && \
               [ "$(cat "/sys/block/$(basename "$nbd_dev")/pid" 2>/dev/null)" != "0" ]; then
                
                log "Found active NBD device: $nbd_dev"
                
                # Controlla se è in uso
                if is_nbd_in_use "$nbd_dev"; then
                    log "NBD device $nbd_dev is free but still connected, cleaning up"
                    qemu-nbd --disconnect "$nbd_dev" 2>/dev/null || true
                fi
            fi
        fi
    done
}


# Function to mount with NBD
mount_with_nbd() {
    local file=$1
    local format=$(detect_format "$file")
    
    if [ -z "$format" ]; then
        format="raw"
    fi
    
    preventive_cleanup
    
    if ! connect_nbd "$file" "$format"; then
        whiptail --msgbox "NBD connection error. Check $LOG_FILE for details." 8 50 3>&1 1>&2 2>&3
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
        whiptail --msgbox "No partitions found." 8 50 3>&1 1>&2 2>&3
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
        whiptail --title "Full Analysis" --msgbox "$analysis$luks_info" 20 80 3>&1 1>&2 2>&3
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
        whiptail --msgbox "Selection error." 8 50 3>&1 1>&2 2>&3
        safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
        NBD_DEVICE=""
        return 1
    fi
    
    echo "=== MOUNT DEBUG ===" >> "$LOG_FILE"
    echo "selected_part: $selected_part" >> "$LOG_FILE"
    echo "Is LUKS?: $(cryptsetup isLuks "$selected_part" 2>/dev/null && echo yes || echo no)" >> "$LOG_FILE"
    ls -la "$selected_part" >> "$LOG_FILE" 2>&1
    echo "===================" >> "$LOG_FILE"
    
    local luks_name=""
    if cryptsetup isLuks "$selected_part" 2>/dev/null; then
        local luks_mapped
        luks_mapped=$(open_luks "$selected_part")

        if [ $? -eq 0 ] && [ -n "$luks_mapped" ]; then
            selected_part="$luks_mapped"
            luks_name=$(basename "$luks_mapped")
            LUKS_MAPPED+=("$luks_name")
        else
            whiptail --msgbox "Cannot open the LUKS partition. Check $LOG_FILE for details." 8 50 3>&1 1>&2 2>&3
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            return 1
        fi
    fi
    
    local device_to_mount="$selected_part"
    local fs_type=$(blkid -o value -s TYPE "$selected_part" 2>/dev/null || echo "unknown")
    if [ "$fs_type" == "LVM2_member" ]; then
        log "LVM2_member filesystem detected on $selected_part. Activating volume groups..."
        
        if ! vgchange -ay &>>"$LOG_FILE"; then
            whiptail --msgbox "Failed to activate LVM volume groups.\nCheck log for details." 10 60 3>&1 1>&2 2>&3
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            return 1
        fi
        
        LVM_ACTIVE+=("$selected_part")
        log "LVM volume groups activated successfully."
        
        # Wait a moment for devices to appear
        sleep 2
        
        local lv_items=()
        local lv_counter=1
        local lv_devices=()
        
        # Build list of available logical volumes
        for lv_path in /dev/mapper/*; do
            if [ -b "$lv_path" ]; then
                local basename_lv=$(basename "$lv_path")
                # Skip LUKS devices and control device
                if [[ "$basename_lv" != "luks_"* ]] && [[ "$basename_lv" != "control" ]]; then
                    local lv_fs_type=$(blkid -o value -s TYPE "$lv_path" 2>/dev/null || echo "unknown")
                    local lv_size=$(lsblk -no SIZE "$lv_path" 2>/dev/null || echo "?")
                    lv_items+=("$lv_counter" "$basename_lv - $lv_fs_type ($lv_size)")
                    lv_devices+=("$lv_path")
                    log "Found LV: $lv_path ($lv_fs_type, $lv_size)"
                    ((lv_counter++))
                fi
            fi
        done
        
        if [ ${#lv_items[@]} -eq 0 ]; then
            whiptail --msgbox "No logical volumes found after activating LVM." 10 60 3>&1 1>&2 2>&3
            vgchange -an &>>"$LOG_FILE" || true
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            return 1
        fi
        
        local lv_choice=$(whiptail --title "LVM Logical Volumes" --menu "Select logical volume to mount:" 18 70 10 "${lv_items[@]}" 3>&1 1>&2 2>&3)
        if [ $? -ne 0 ]; then
            log "User cancelled LVM logical volume selection."
            vgchange -an &>>"$LOG_FILE" || true
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            return 1
        fi
        
        # Get the selected device using array index
        local array_index=$((lv_choice - 1))
        if [ $array_index -ge 0 ] && [ $array_index -lt ${#lv_devices[@]} ]; then
            device_to_mount="${lv_devices[$array_index]}"
            log "Selected logical volume: $device_to_mount"
        else
            whiptail --msgbox "Invalid selection." 8 50 3>&1 1>&2 2>&3
            vgchange -an &>>"$LOG_FILE" || true
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            return 1
        fi
    fi

    # === Fixed mounting section ===
    local mount_point="/mnt/nbd_mount_$$"
    mkdir -p "$mount_point"
    local original_user=${SUDO_USER:-$(who am i | awk '{print $1}')}

    local mount_success=false
    # First check if the mount point is already in use
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log "Mount point $mount_point already in use, cleaning up"
        umount "$mount_point" 2>/dev/null || umount -l "$mount_point" 2>/dev/null
    fi

    (
        echo 10
        echo "# Detecting filesystem on $device_to_mount..."
        
        local detected_fs=""
        # Preferred method: use lsblk which is reliable on logical volumes
        detected_fs=$(lsblk -no FSTYPE "$device_to_mount" 2>/dev/null | head -n 1 | tr -d ' ')
        
        if [ -z "$detected_fs" ] || [ "$detected_fs" = "" ]; then
            # Fallback to blkid if lsblk fails
            detected_fs=$(blkid -o value -s TYPE "$device_to_mount" 2>/dev/null)
        fi
        
        if [ -z "$detected_fs" ] || [ "$detected_fs" = "" ]; then
            # Further fallback to file command
            local file_output=$(file -s "$device_to_mount" 2>/dev/null)
            if echo "$file_output" | grep -q "ext4"; then
                detected_fs="ext4"
            elif echo "$file_output" | grep -q "ext3"; then
                detected_fs="ext3"
            elif echo "$file_output" | grep -q "ext2"; then
                detected_fs="ext2"
            elif echo "$file_output" | grep -q "XFS"; then
                detected_fs="xfs"
            elif echo "$file_output" | grep -q "BTRFS"; then
                detected_fs="btrfs"
            fi
        fi
        
        log "Device to mount: $device_to_mount"
        log "Detected filesystem: ${detected_fs:-unknown}"
        
        echo 40
        echo "# Attempting to mount..."
        
        # Prepare mount options
        local mount_opts=""
        local uid_gid_opts=""
        if [ -n "$original_user" ]; then
            local original_uid=$(id -u "$original_user" 2>/dev/null)
            local original_gid=$(id -g "$original_user" 2>/dev/null)
            if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
                uid_gid_opts="uid=$original_uid,gid=$original_gid,umask=022"
            fi
        fi
        
        echo 60
        # Try mounting with detected filesystem type and user options
        if [ -n "$detected_fs" ] && [ -n "$uid_gid_opts" ]; then
            if mount -t "$detected_fs" -o "$uid_gid_opts" "$device_to_mount" "$mount_point" 2>>"$LOG_FILE"; then
                echo "mount_success=true" > "/tmp/mount_result_$$"
                log "Mounted successfully with filesystem type: $detected_fs and user options"
            else
                log "Mount failed with detected filesystem type and user options"
            fi
        fi
        
        # Try without user options if that failed
        if [ ! -f "/tmp/mount_result_$$" ] && [ -n "$detected_fs" ]; then
            echo 70
            echo "# Retrying without user options..."
            if mount -t "$detected_fs" "$device_to_mount" "$mount_point" 2>>"$LOG_FILE"; then
                echo "mount_success=true" > "/tmp/mount_result_$$"
                log "Mounted successfully with filesystem type: $detected_fs"
            else
                log "Mount failed with detected filesystem type: $detected_fs"
            fi
        fi
        
        # Try auto-detection without specifying filesystem type
        if [ ! -f "/tmp/mount_result_$$" ]; then
            echo 80
            echo "# Retrying with auto-detection..."
            if [ -n "$uid_gid_opts" ]; then
                if mount -o "$uid_gid_opts" "$device_to_mount" "$mount_point" 2>>"$LOG_FILE"; then
                    echo "mount_success=true" > "/tmp/mount_result_$$"
                    log "Mounted successfully with auto-detection and user options"
                else
                    log "Mount failed with auto-detection and user options"
                fi
            fi
        fi
        
        # Final attempt: basic mount with no options
        if [ ! -f "/tmp/mount_result_$$" ]; then
            echo 90
            echo "# Final attempt with basic mount..."
            if mount "$device_to_mount" "$mount_point" 2>>"$LOG_FILE"; then
                echo "mount_success=true" > "/tmp/mount_result_$$"
                log "Mounted successfully with basic mount"
            else
                log "All mount attempts failed"
                echo "mount_success=false" > "/tmp/mount_result_$$"
            fi
        fi
        
        # Check final result
        if [ -f "/tmp/mount_result_$$" ] && grep -q "mount_success=true" "/tmp/mount_result_$$"; then
            echo 100
            echo "# Mounted successfully!"
            sleep 1
        else
            echo 100
            echo "# Mount failed - check logs"
            sleep 2
        fi
    ) | whiptail --gauge "Mounting partition" 8 50 0
    
    # Check the actual mount result
    if [ -f "/tmp/mount_result_$$" ] && grep -q "mount_success=true" "/tmp/mount_result_$$"; then
        mount_success=true
        rm -f "/tmp/mount_result_$$"
    else
        mount_success=false
        rm -f "/tmp/mount_result_$$"
    fi
    
    # Verify the mount actually worked by checking if mount point contains the device
    if [ "$mount_success" = true ]; then
        if ! mountpoint -q "$mount_point" 2>/dev/null; then
            mount_success=false
            log "Mount verification failed - mount point is not actually mounted"
        else
            # Double-check that it's our device that's mounted
            local mounted_device=$(mount | grep "$mount_point" | awk '{print $1}' | head -1)
            if [ "$mounted_device" != "$device_to_mount" ]; then
                log "Warning: Expected $device_to_mount but found $mounted_device mounted"
            fi
        fi
    fi
    
    if [ "$mount_success" = true ]; then
        MOUNTED_PATHS+=("$mount_point")
        if [ -n "$original_user" ]; then
            local original_uid=$(id -u "$original_user" 2>/dev/null)
            local original_gid=$(id -g "$original_user" 2>/dev/null)
            if [ -n "$original_uid" ] && [ -n "$original_gid" ]; then
                chmod 755 "$mount_point" 2>/dev/null || true
                chown "$original_uid:$original_gid" "$mount_point" 2>/dev/null || true
            fi
        fi
        
        log "Mounted $device_to_mount at $mount_point" >> "$LOG_FILE"
        
        local action_options=(
            "1" "Interactive shell in mount directory"
            "2" "Chroot into filesystem (Linux only)"
            "3" "Just mount and return to menu"
        )
        
        local action_choice=$(whiptail --title "Mount Action" --menu "Partition mounted at $mount_point\nWhat would you like to do?" 15 70 3 "${action_options[@]}" 3>&1 1>&2 2>&3)
        
        case $action_choice in
            1)
                whiptail --msgbox "Opening shell in mount directory.\n\nPath: $mount_point\n\nUse 'exit' to return to the menu." 12 70 3>&1 1>&2 2>&3
                if [ -n "$original_user" ]; then
                    sudo -u "$original_user" bash -c "cd '$mount_point' && exec bash -i"
                else
                    bash -c "cd '$mount_point' && exec bash -i"
                fi
                ;;
            2)
                if [ -d "$mount_point" ]; then
                    whiptail --msgbox "Entering isolated chroot environment.\n\nYou are now in the VM's filesystem as root.\nNetworking and some services may not work.\n\nUse 'exit' to return to the menu.\n\nWarning: Be careful with system modifications!" 15 70 3>&1 1>&2 2>&3
                    run_chroot_isolated "$mount_point"
                else
                    whiptail --msgbox "Invalid mount point.\nFalling back to regular shell." 10 60 3>&1 1>&2 2>&3
                    if [ -n "$original_user" ]; then
                        sudo -u "$original_user" bash -c "cd '$mount_point' && exec bash -i"
                    else
                        bash -c "cd '$mount_point' && exec bash -i"
                    fi
                fi
                ;;
            3)
                whiptail --msgbox "Partition mounted at: $mount_point\n\nReturning to menu. Use 'Active Mount Points' to manage." 10 70 3>&1 1>&2 2>&3
                return 0
                ;;
            *)
                whiptail --msgbox "No action selected. Returning to menu.\n\nMount point: $mount_point" 10 70 3>&1 1>&2 2>&3
                return 0
                ;;
        esac
        
        log "Shell/chroot exited, cleaning up mount and NBD"
        
                # === START OF IMPROVED CLEANUP LOGIC ===
        
        # 1. Unmount all mounted paths
        for mnt_path in "${MOUNTED_PATHS[@]}"; do
            if mountpoint -q "$mnt_path" 2>/dev/null; then
                log "Unmounting $mnt_path"
                umount "$mnt_path" 2>>"$LOG_FILE" || umount -l "$mnt_path" 2>>"$LOG_FILE"
                rmdir "$mnt_path" 2>/dev/null
            fi
        done
        MOUNTED_PATHS=()
        
        # 2. Comprehensive LVM cleanup
        cleanup_lvm_volumes
        LVM_ACTIVE=()
        
        # 3. Comprehensive LUKS cleanup
        cleanup_luks_mappings
        
        # 4. Wait for device cleanup
        sleep 3
        
        # 5. Disconnect NBD device
        if [ -n "$NBD_DEVICE" ] && [ -b "$NBD_DEVICE" ]; then
            safe_nbd_disconnect "$NBD_DEVICE" >> "$LOG_FILE" 2>&1
            NBD_DEVICE=""
            log "Disconnected NBD device"
        fi
        
        # 6. Final cleanup verification
        sleep 2
        if lsmod | grep -q nbd; then
            log "NBD module still loaded - this is normal"
        fi
        
        # === END OF IMPROVED CLEANUP LOGIC ===
        
        whiptail --msgbox "Mount and NBD cleaned up successfully." 8 50 3>&1 1>&2 2>&3
        return 0
    else
        # === START OF FAILED MOUNT CLEANUP LOGIC ===
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
        # === END OF FAILED MOUNT CLEANUP LOGIC ===
        whiptail --msgbox "Mount failed. Check $LOG_FILE for details." 8 50 3>&1 1>&2 2>&3
        return 1
    fi
}