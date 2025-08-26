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