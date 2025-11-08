open_luks() {
    local luks_part=$1
    local mapper_name="luks_$(basename "$luks_part" | sed 's/[^a-zA-Z0-9]/_/g')_$$"
    local max_attempts=3
    
    log "Attempting to open LUKS partition: $luks_part"
    
    if ! cryptsetup isLuks "$luks_part" 2>/dev/null; then
        log "Error: $luks_part is not a valid LUKS partition"
        whiptail --msgbox "Error: Not a valid LUKS partition\n$luks_part" 10 60 3>&1 1>&2 2>&3
        return 1
    fi
    
    local luks_info=$(cryptsetup luksDump "$luks_part" 2>/dev/null | head -10)
    local luks_version=$(echo "$luks_info" | grep "Version:" | awk '{print $2}' || echo "Unknown")
    local cipher=$(echo "$luks_info" | grep "Cipher name:" | awk '{print $3}' || echo "Unknown")
    
    if ! whiptail --title "LUKS Partition Detected" --yesno \
        "LUKS encrypted partition found:\n\nDevice: $luks_part\nVersion: LUKS$luks_version\nCipher: $cipher\n\nDo you want to unlock this partition?" 14 70 3>&1 1>&2 2>&3; then
        log "User declined to open LUKS partition"
        return 1
    fi
    
    for attempt in $(seq 1 $max_attempts); do
        log "LUKS unlock attempt $attempt/$max_attempts"
        
        local password=""
        # Ripristino I/O per la passwordbox
        password=$(whiptail --title "LUKS Password - Attempt $attempt/$max_attempts" \
            --passwordbox "Enter password for encrypted partition:\n$luks_part" \
            12 70 3>&1 1>&2 2>&3)
        local whiptail_exit=$?
        
        if [[ $whiptail_exit -ne 0 ]]; then
            log "Password input cancelled by user"
            return 1
        fi
        
        if [[ -z "$password" ]]; then
            log "Empty password provided on attempt $attempt"
            if [[ $attempt -lt $max_attempts ]]; then
                whiptail --msgbox "Empty password. Please try again.\n\nAttempt $attempt of $max_attempts" 10 50 3>&1 1>&2 2>&3
                continue
            else
                whiptail --msgbox "No password provided. Aborting LUKS unlock." 8 50 3>&1 1>&2 2>&3
                return 1
            fi
        fi
        
        local temp_pass_file=$(mktemp)
        chmod 600 "$temp_pass_file"
        echo -n "$password" > "$temp_pass_file"
        unset password
        
        local luks_error=""
        if timeout 30 cryptsetup luksOpen "$luks_part" "$mapper_name" --key-file "$temp_pass_file" 2>"$temp_pass_file.err"; then
            rm -f "$temp_pass_file" "$temp_pass_file.err" 2>/dev/null
            LUKS_MAPPED+=("$mapper_name")
            log "LUKS partition successfully opened: /dev/mapper/$mapper_name"
            echo "/dev/mapper/$mapper_name"
            return 0
        else
            luks_error=$(cat "$temp_pass_file.err" 2>/dev/null || echo "Unknown error")
            log "LUKS unlock attempt $attempt failed: $luks_error"
            rm -f "$temp_pass_file" "$temp_pass_file.err" 2>/dev/null
            
            if [[ $attempt -lt $max_attempts ]]; then
                local retry_msg="Failed to unlock LUKS partition.\n\n"
                if [[ "$luks_error" == *"No key available"* ]] || [[ "$luks_error" == *"incorrect passphrase"* ]]; then
                    retry_msg+="❌ Incorrect password."
                elif [[ "$luks_error" == *"timeout"* ]]; then
                    retry_msg+="⏰ Operation timed out."
                else
                    retry_msg+="⚠️  Error: ${luks_error:0:100}"
                fi
                retry_msg+="\n\nAttempt $attempt of $max_attempts"
                retry_msg+="\nWould you like to try again?"
                
                if whiptail --title "LUKS Unlock Failed" --yesno "$retry_msg" 14 60 3>&1 1>&2 2>&3; then
                    continue
                else
                    log "User chose not to retry LUKS unlock"
                    return 1
                fi
            else
                whiptail --msgbox "❌ Failed to unlock LUKS partition after $max_attempts attempts.\n\nLast error: ${luks_error:0:150}" 12 70 3>&1 1>&2 2>&3
                return 1
            fi
        fi
    done
    
    return 1
}

cleanup_lvm_volumes() {
    log "Starting comprehensive LVM cleanup..."
    
    # Disattiva tutti i volumi logici attivi
    for lv_path in /dev/mapper/vgubuntu-*; do
        if [ -b "$lv_path" ]; then
            local lv_name=$(basename "$lv_path")
            log "Deactivating logical volume: $lv_name"
            lvchange -an "$lv_path" &>>"$LOG_FILE" || true
        fi
    done
    
    # Disattiva tutti i volume groups (SILENZIOSAMENTE)
    for vg in $(vgs --noheadings -o vg_name 2>/dev/null); do
        vg=$(echo "$vg" | tr -d ' ')
        if [ -n "$vg" ]; then
            log "Deactivating volume group: $vg"
            vgchange -an "$vg" &>>"$LOG_FILE" || true
        fi
    done
    
    # Forzatura finale dei device mapper
    for dm_dev in /dev/mapper/vgubuntu-*; do
        if [ -b "$dm_dev" ]; then
            local dm_name=$(basename "$dm_dev")
            log "Removing device mapper: $dm_name"
            dmsetup remove "$dm_name" &>>"$LOG_FILE" || true
        fi
    done
    
    sleep 2
    log "LVM cleanup completed"
}

# 2. Miglioramento della funzione di cleanup LUKS
cleanup_luks_mappings() {
    log "Starting comprehensive LUKS cleanup..."
    
    # Chiudi tutti i mapping LUKS esistenti
    for luks_map in "${LUKS_MAPPED[@]}"; do
        if [ -n "$luks_map" ] && [ -b "/dev/mapper/$luks_map" ]; then
            log "Closing LUKS mapping: $luks_map"
            cryptsetup luksClose "$luks_map" 2>>"$LOG_FILE" || {
                log "Force closing LUKS mapping: $luks_map"
                dmsetup remove "$luks_map" 2>>"$LOG_FILE" || true
            }
        fi
    done
    
    # Cerca e chiudi eventuali mapping LUKS orfani
    for luks_dev in /dev/mapper/luks_*; do
        if [ -b "$luks_dev" ]; then
            local luks_name=$(basename "$luks_dev")
            log "Found orphaned LUKS mapping: $luks_name"
            cryptsetup luksClose "$luks_name" 2>>"$LOG_FILE" || {
                log "Force removing orphaned LUKS mapping: $luks_name"
                dmsetup remove "$luks_name" 2>>"$LOG_FILE" || true
            }
        fi
    done
    
    LUKS_MAPPED=()
    sleep 2
    log "LUKS cleanup completed"
}

# 3. Funzione di cleanup preventivo all'inizio di ogni operazione
preventive_cleanup() {
    log "Starting preventive cleanup before NBD operations..."
    
    # Pulisci eventuali mount points orfani
    for mount_dir in /mnt/nbd_mount_*; do
        if [ -d "$mount_dir" ] && mountpoint -q "$mount_dir" 2>/dev/null; then
            log "Unmounting orphaned mount point: $mount_dir"
            umount "$mount_dir" 2>/dev/null || umount -l "$mount_dir" 2>/dev/null
            rmdir "$mount_dir" 2>/dev/null
        fi
    done
    
    # Pulisci LVM e LUKS prima di iniziare
    cleanup_lvm_volumes
    cleanup_luks_mappings
    
    # Pulisci device NBD orfani
    cleanup_stale_nbd_devices
    
    log "Preventive cleanup completed"
}

verify_device_state() {
    local device=$1
    log "Verifying device state: $device"
    
    # Verifica che il device esista e sia accessibile
    if [ ! -b "$device" ]; then
        log "Error: Device $device does not exist"
        return 1
    fi
    
    # Verifica che il device non sia già in uso
    if mount | grep -q "^$device "; then
        log "Warning: Device $device is already mounted"
        return 1
    fi
    
    # Per device LUKS, verifica che sia correttamente aperto
    if [[ "$device" == "/dev/mapper/luks_"* ]]; then
        if ! cryptsetup status "$(basename "$device")" >/dev/null 2>&1; then
            log "Error: LUKS device $device is not properly opened"
            return 1
        fi
    fi
    
    # Verifica filesystem con file command come backup
    local file_output=$(file -s "$device" 2>/dev/null)
    log "Device $device file output: $file_output"
    
    return 0
}

improve_filesystem_detection() {
    local device=$1
    local detected_fs=""
    
    # Metodo 1: lsblk (più affidabile per LVM)
    detected_fs=$(lsblk -no FSTYPE "$device" 2>/dev/null | head -n 1 | tr -d ' ')
    
    # Metodo 2: blkid come fallback
    if [ -z "$detected_fs" ] || [ "$detected_fs" = "" ]; then
        detected_fs=$(blkid -o value -s TYPE "$device" 2>/dev/null)
    fi
    
    # Metodo 3: file command con sleep per dare tempo al kernel
    if [ -z "$detected_fs" ] || [ "$detected_fs" = "" ]; then
        sleep 1  # Importante: dai tempo al kernel di aggiornare le informazioni
        local file_output=$(file -s "$device" 2>/dev/null)
        if echo "$file_output" | grep -qi "ext4"; then
            detected_fs="ext4"
        elif echo "$file_output" | grep -qi "ext3"; then
            detected_fs="ext3"
        elif echo "$file_output" | grep -qi "ext2"; then
            detected_fs="ext2"
        elif echo "$file_output" | grep -qi "xfs"; then
            detected_fs="xfs"
        elif echo "$file_output" | grep -qi "btrfs"; then
            detected_fs="btrfs"
        fi
    fi
    
    # Metodo 4: Prova diretta con fsck (read-only)
    if [ -z "$detected_fs" ] || [ "$detected_fs" = "" ]; then
        if fsck.ext4 -n "$device" >/dev/null 2>&1; then
            detected_fs="ext4"
        elif fsck.ext3 -n "$device" >/dev/null 2>&1; then
            detected_fs="ext3"
        elif fsck.ext2 -n "$device" >/dev/null 2>&1; then
            detected_fs="ext2"
        fi
    fi
    
    echo "$detected_fs"
}