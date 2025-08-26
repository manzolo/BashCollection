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

# Versione migliorata della funzione connect_nbd
connect_nbd_improved() {
    local file=$1
    local format=${2:-raw}
    
    # Cleanup preventivo
    cleanup_stale_nbd_devices
    
    # Trova un device NBD libero
    for i in {0..15}; do
        local nbd_dev="/dev/nbd$i"
        if [ -b "$nbd_dev" ]; then
            # Controlla se è già in uso
            if is_nbd_in_use "$nbd_dev"; then
                log "NBD device $nbd_dev is available"
                NBD_DEVICE="$nbd_dev"
                break
            else
                log "NBD device $nbd_dev is in use, trying next"
            fi
        fi
    done
    
    if [ -z "$NBD_DEVICE" ]; then
        log "No free NBD devices found"
        return 1
    fi
    
    log "Connecting $file to $NBD_DEVICE with format $format"
    
    # Connetti il device
    if qemu-nbd --connect="$NBD_DEVICE" --format="$format" "$file"; then
        log "NBD connection successful"
        
        # Attendi che il device sia pronto
        local timeout=10
        while [ $timeout -gt 0 ] && [ ! -b "$NBD_DEVICE" ]; do
            sleep 1
            ((timeout--))
        done
        
        if [ -b "$NBD_DEVICE" ]; then
            log "NBD device $NBD_DEVICE is ready"
            return 0
        else
            log "NBD device $NBD_DEVICE not ready after timeout"
            return 1
        fi
    else
        log "NBD connection failed"
        return 1
    fi
}

# Function to detect Windows image
detect_windows_image() {
    local device=$1
    log "Detecting if $device is a Windows image"
    for part in "${device}"p*; do
        if [ -b "$part" ]; then
            local fs_type=$(blkid -o value -s TYPE "$part" 2>/dev/null)
            if [ "$fs_type" = "ntfs" ]; then
                local temp_mount="/tmp/win_check_$$"
                mkdir -p "$temp_mount"
                if mount -o ro "$part" "$temp_mount" 2>/dev/null; then
                    if [ -f "$temp_mount/Windows/System32/config/SYSTEM" ] || [ -f "$temp_mount/bootmgr" ]; then
                        umount "$temp_mount"
                        rmdir "$temp_mount"
                        log "Windows image detected"
                        return 0
                    fi
                    umount "$temp_mount"
                fi
                rmdir "$temp_mount"
            fi
        fi
    done
    log "Not a Windows image"
    return 1
}

# Function to open LUKS
open_luks() {
    local luks_part=$1
    local mapper_name="luks_$(basename "$luks_part")_$$"
    
    log "Attempting to open LUKS on $luks_part"
    if whiptail --title "LUKS Detected" --yesno "LUKS partition: $luks_part\nDo you want to open it?" 10 60; then
        local password=$(whiptail --title "LUKS Password" --passwordbox "Password for $luks_part:" 10 60 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ] || [ -z "$password" ]; then
            log "LUKS password input cancelled"
            return 1
        fi
        
        if echo "$password" | cryptsetup luksOpen "$luks_part" "$mapper_name" 2>>"$LOG_FILE"; then
            LUKS_MAPPED+=("$mapper_name")
            log "LUKS opened: /dev/mapper/$mapper_name"
            echo "/dev/mapper/$mapper_name"
            return 0
        else
            log "Failed to open LUKS: $(tail -n 1 "$LOG_FILE")"
            whiptail --msgbox "Incorrect password or error opening LUKS." 8 50
            return 1
        fi
    fi
    return 1
}

# Function to handle LVM
handle_lvm() {
    log "Scanning for LVM"
    vgscan >/dev/null 2>&1
    pvscan >/dev/null 2>&1
    lvscan >/dev/null 2>&1
    
    local vgs=($(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '))
    
    if [ ${#vgs[@]} -eq 0 ]; then
        log "No Volume Groups found"
        return 1
    fi
    
    local vg_items=()
    for i in "${!vgs[@]}"; do
        vg_items+=("$((i+1))" "${vgs[i]}")
    done
    
    local choice=$(whiptail --title "LVM Detected" --menu "Select Volume Group:" 15 60 8 "${vg_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$choice" ]; then
        log "LVM VG selection cancelled"
        return 1
    fi
    
    local selected_vg="${vgs[$((choice-1))]}"
    local lvs=($(lvs --noheadings -o lv_name "$selected_vg" 2>/dev/null | tr -d ' '))
    
    if [ ${#lvs[@]} -eq 0 ]; then
        log "No Logical Volumes found in $selected_vg"
        whiptail --msgbox "No Logical Volumes found in $selected_vg" 8 50
        return 1
    fi
    
    local lv_items=()
    for i in "${!lvs[@]}"; do
        lv_items+=("$((i+1))" "${lvs[i]}")
    done
    
    local lv_choice=$(whiptail --title "Logical Volumes" --menu "Select LV to resize:" 15 60 8 "${lv_items[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$lv_choice" ]; then
        log "Selected LV: $selected_vg/${lvs[$((lv_choice-1))]}"
        echo "$selected_vg/${lvs[$((lv_choice-1))]}"
        return 0
    fi
    
    log "LVM LV selection cancelled"
    return 1
}

# Function to resize LVM
resize_lvm() {
    local vg_lv=$1
    local luks_device=$2
    
    log "Resizing LVM: $vg_lv"
    (
        echo 0
        echo "# Resizing LVM..."
        if [ -n "$luks_device" ]; then
            echo 20
            echo "# Resizing PV..."
            pvresize "$luks_device" 2>>"$LOG_FILE" || {
                log "Error resizing PV: $(tail -n 1 "$LOG_FILE")"
                exit 1
            }
            local luks_name=$(basename "$luks_device" | sed 's|^mapper/||')
            echo 40
            echo "# Resizing LUKS..."
            cryptsetup resize "$luks_name" 2>>"$LOG_FILE" || {
                log "Error resizing LUKS: $(tail -n 1 "$LOG_FILE")"
                exit 1
            }
        fi
        echo 60
        echo "# Extending LV..."
        lvextend -l +100%FREE "/dev/$vg_lv" 2>>"$LOG_FILE" || {
            log "Error resizing LV: $(tail -n 1 "$LOG_FILE")"
            exit 1
        }
        echo 80
        echo "# Checking filesystem..."
        local fs_type=$(blkid -o value -s TYPE "/dev/$vg_lv" 2>/dev/null)
        case "$fs_type" in
            "ext2"|"ext3"|"ext4")
                e2fsck -f -y "/dev/$vg_lv" >/dev/null 2>&1 || true
                echo 90
                echo "# Resizing ext filesystem..."
                resize2fs -p "/dev/$vg_lv" >/dev/null 2>&1
                ;;
            "xfs")
                echo 100
                echo "# XFS detected, manual resize needed"
                exit 2
                ;;
        esac
        echo 100
        echo "# Done!"
        sleep 1
    ) | whiptail --gauge "Resizing LVM..." 8 50 0
    
    local result=$?
    if [ $result -eq 0 ]; then
        LVM_ACTIVE+=("/dev/$vg_lv")
        log "LVM resize completed successfully"
        whiptail --msgbox "LVM resizing completed successfully!" 8 50
        return 0
    elif [ $result -eq 2 ]; then
        log "XFS detected, manual resize suggested"
        whiptail --msgbox "XFS detected. After mounting, use:\nxfs_growfs /mount/path" 10 60
        return 0
    else
        log "LVM resize failed"
        whiptail --msgbox "Error resizing the LV. Check log: $LOG_FILE" 8 50
        return 1
    fi
}

# Function to resize an ext filesystem
resize_ext_filesystem() {
    local device_path=$1
    
    if ! command -v e2fsck &> /dev/null || ! command -v resize2fs &> /dev/null; then
        log "e2fsck or resize2fs not found. Aborting."
        whiptail --msgbox "Error: e2fsck or resize2fs not found.\nPlease install 'e2fsprogs' with:\nsudo apt install e2fsprogs" 10 60
        return 1
    fi
    
    log "Attempting to resize ext filesystem on $device_path"
    
    (
        echo 0
        echo "# Step 1/3: Checking filesystem consistency..."
        e2fsck -f -p "$device_path" 2>>"$LOG_FILE"
        if [ $? -gt 1 ]; then
            log "Filesystem check failed with critical errors on $device_path"
            echo 100
            echo "# Filesystem check failed."
            sleep 2
            exit 1
        fi
        
        echo 40
        echo "# Step 2/3: Resizing filesystem to the maximum size..."
        local resize_output=$(resize2fs -p "$device_path" 2>&1)
        if [ $? -ne 0 ]; then
            log "resize2fs failed on $device_path: $resize_output"
            echo 100
            echo "# Filesystem resize failed."
            sleep 2
            exit 1
        fi
        
        echo 80
        echo "# Step 3/3: Verifying resize..."
        local final_check=$(e2fsck -n "$device_path" 2>&1)
        if [ $? -gt 1 ]; then
            log "Post-resize check failed with errors on $device_path: $final_check"
            echo 100
            echo "# Post-resize check failed."
            sleep 2
            exit 2
        fi
        
        echo 100
        echo "# Filesystem resized successfully!"
        log "Filesystem on $device_path resized successfully"
        sleep 1
    ) | whiptail --gauge "Resizing ext filesystem..." 8 50 0
    
    local result=$?
    
    if [ $result -eq 0 ]; then
        whiptail --msgbox "Ext filesystem resized successfully!" 8 60
        return 0
    elif [ $result -eq 2 ]; then
        whiptail --msgbox "Ext resize completed with warnings.\nThe filesystem should be functional but a manual check is recommended." 10 60
        return 0
    else
        whiptail --msgbox "Error resizing ext filesystem.\nCheck the log file for details." 10 60
        return 1
    fi
}

# Funzione principale semplificata
advanced_resize() {
    local file=$1
    local size=$2
    
    log "Starting advanced_resize for $file to $size"
    
    # Controlli preliminari
    if ! check_file_lock "$file"; then
        log "File lock failed"
        return 1
    fi
    
    # Backup
    if ! handle_backup "$file"; then
        return 1
    fi
    
    # Controllo spazio
    if ! check_free_space "$file" "$size"; then
        return 1
    fi
    
    # Resize dell'immagine
    if ! resize_disk_image "$file" "$size"; then
        return 1
    fi
    
    # Connessione NBD e resize partizioni
    if ! resize_partitions "$file"; then
        return 1
    fi
    
    log "Resize completed for $file to $size"
    whiptail --msgbox "Resizing completed!\n\nFile: $(basename "$file")\nNew size: $size\n\nVerify the result with analysis or QEMU test." 12 70
    return 0
}

# Gestione backup
handle_backup() {
    local file=$1
    
    if whiptail --title "Backup" --yesno "Do you want to create a backup before resizing?\n(Highly recommended)" 10 60; then
        (
            echo 0
            echo "# Creating backup..."
            cp "$file" "$file.backup.$(date +%Y%m%d_%H%M%S)"
            echo 100
            echo "# Backup created!"
            sleep 1
        ) | whiptail --gauge "Creating backup..." 8 50 0
        
        if [ $? -ne 0 ]; then
            log "Error creating backup"
            whiptail --msgbox "Error creating backup." 8 50
            return 1
        fi
    fi
    return 0
}

# Resize dell'immagine disco
resize_disk_image() {
    local file=$1
    local size=$2
    
    local format=$(qemu-img info "$file" 2>/dev/null | grep "file format:" | awk '{print $3}')
    if [ -z "$format" ]; then
        format="raw"
    fi
    
    (
        echo 0
        echo "# Resizing image to $size... This may take time."
        log "Resizing image with qemu-img"
        timeout 60 qemu-img resize -f "$format" "$file" "$size" 2>>"$LOG_FILE"
        echo 100
        if [ $? -eq 0 ]; then
            echo "# Resize completed!"
            log "Image resized successfully"
            sleep 1
        else
            echo "# Resize failed."
            log "Resize failed: $(tail -n 1 "$LOG_FILE")"
            sleep 2
            exit 1
        fi
    ) | whiptail --gauge "Resizing image..." 8 50 0
    
    if [ $? -ne 0 ]; then
        whiptail --msgbox "Error resizing the image. Check log: $LOG_FILE" 8 50
        return 1
    fi
    return 0
}

# Gestione connessione NBD e resize partizioni
resize_partitions() {
    local file=$1
    local format=$(qemu-img info "$file" 2>/dev/null | grep "file format:" | awk '{print $3}')
    if [ -z "$format" ]; then
        format="raw"
    fi
    
    if ! connect_nbd "$file" "$format"; then
        whiptail --msgbox "NBD connection error." 8 50
        return 1
    fi
    
    sleep 2
    
    if [ ! -b "$NBD_DEVICE" ]; then
        log "NBD device not found after connect"
        whiptail --msgbox "Error: The NBD device $NBD_DEVICE does not exist. Check the connection." 10 70
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    # Controllo Windows e selezione partizione
    if ! handle_windows_detection_and_partition_selection; then
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    # Resize partizione e filesystem
    if ! resize_selected_partition; then
        safe_nbd_disconnect "$NBD_DEVICE"
        return 1
    fi
    
    safe_nbd_disconnect "$NBD_DEVICE"
    NBD_DEVICE=""
    return 0
}

# Gestione rilevamento Windows e selezione partizione
handle_windows_detection_and_partition_selection() {
    if detect_windows_image "$NBD_DEVICE"; then
        log "Windows image warning shown"
        if whiptail --title "Windows Detected" --yesno "This appears to be a Windows image with potentially complex partitions (e.g., recovery at end).\nAutomatic resize may fail.\n\nProceed anyway, or use GParted Live?" 12 70; then
            echo "continue"
        else
            log "User chose GParted for Windows image"
            gparted_boot "$file"
            return 1
        fi
    fi
    
    if ! analyze_and_select_partition; then
        return 1
    fi
    
    return 0
}

# Analisi partizioni e selezione
analyze_and_select_partition() {
    log "Analyzing partitions with parted"
    local parted_output=$(timeout 30 parted -s "$NBD_DEVICE" print 2>>"$LOG_FILE")
    if [ $? -ne 0 ]; then
        log "Parted failed: $(tail -n 1 "$LOG_FILE")"
        whiptail --msgbox "Error while reading partitions with parted.\n\nDetails:\n$parted_output\nCheck log: $LOG_FILE" 15 70
        return 1
    fi
    log "Parted output: $parted_output"
    
    local partitions=($(echo "$parted_output" | grep "^ " | awk '{print $1}'))
    local partition_items=()
    
    # Costruzione lista partizioni con informazioni
    for part in "${partitions[@]}"; do
        if ! build_partition_info "$part" "$parted_output" partition_items; then
            continue
        fi
    done
    
    if [ ${#partition_items[@]} -eq 0 ]; then
        whiptail --msgbox "No partitions were found on the disk. The parted command output was:\n\n$parted_output" 15 70
        return 1
    fi
    
    # Selezione partizione
    if ! selected_partition=$(whiptail --title "Select Partition" --menu "Select the partition to resize:" 20 80 12 "${partition_items[@]}" 3>&1 1>&2 2>&3); then
        whiptail --msgbox "Partition selection cancelled. The script will now terminate and perform cleanup." 10 60
        log "Partition selection cancelled by the user."
        return 1
    fi
    
    # Controllo se è l'ultima partizione
    is_last_partition=false
    if [ "$selected_partition" = "${partitions[-1]}" ]; then
        is_last_partition=true
    fi
    
    return 0
}

# Costruzione informazioni partizione
build_partition_info() {
    local part=$1
    local parted_output=$2
    local -n partition_items_ref=$3
    
    local part_info=$(echo "$parted_output" | grep "^ $part " | sed 's/^[[:space:]]*//')
    local part_dev="${NBD_DEVICE}p${part}"
    local fs_type=$(blkid -o value -s TYPE "$part_dev" 2>/dev/null || echo "Unknown FS")
    local tmp_mount="/mnt/tmp_resize_check_$$"
    
    mkdir -p "$tmp_mount"
    local total_size="?"
    local used_size="?"
    local free_size="?"
    
    if mount "$part_dev" "$tmp_mount" 2>/dev/null; then
        total_size=$(df -h --output=size "$tmp_mount" | sed '1d' | tr -d ' ')
        used_size=$(df -h --output=used "$tmp_mount" | sed '1d' | tr -d ' ')
        free_size=$(df -h --output=avail "$tmp_mount" | sed '1d' | tr -d ' ')
        umount "$tmp_mount"
    fi
    rmdir "$tmp_mount" 2>/dev/null
    
    local label="Partition $part | Total: $total_size | Used: $used_size | Free: $free_size | FS Type: $fs_type"
    partition_items_ref+=("$part" "$label")
    return 0
}

# Resize partizione selezionata
resize_selected_partition() {
    (
        echo 0
        echo "# Resizing partition $selected_partition..."
        
        if [ "$is_last_partition" = false ] && detect_windows_image "$NBD_DEVICE"; then
            echo 100
            echo "# Non-last partition in Windows image, needs GParted"
            log "Non-last partition selected in Windows image"
            sleep 2
            exit 2
        fi
        
        if ! resize_partition_table; then
            log "Partition resize failed: $(tail -n 1 "$LOG_FILE")"
            echo 100
            echo "# Partition resize failed"
            sleep 2
            exit 1
        fi
        
        echo 100
        echo "# Partition resized!"
        sleep 1
    ) | whiptail --gauge "Resizing partition..." 8 50 0
    
    local part_result=$?
    if [ $part_result -eq 2 ]; then
        whiptail --title "Complex Layout" --yesno "Selected partition is not the last one in a Windows image.\nUse GParted Live to move partitions?" 10 60
        if [ $? -eq 0 ]; then
            gparted_boot "$file"
        fi
        return 1
    elif [ $part_result -ne 0 ]; then
        whiptail --title "WARNING: Partition Resize Failed" --yesno "Automatic resizing failed (common for Windows layouts).\n\nLaunch GParted Live to resize manually?" 12 80
        if [ $? -eq 0 ]; then
            gparted_boot "$file"
        fi
        return 1
    fi
    
    # Resize filesystem
    if ! resize_filesystem_on_partition; then
        return 1
    fi
    
    return 0
}

# Resize tabella partizioni
resize_partition_table() {
    local resize_success=false
    local partition_table=""
    local parted_output=$(timeout 30 parted -s "$NBD_DEVICE" print 2>>"$LOG_FILE")
    
    if echo "$parted_output" | grep -q "gpt"; then
        partition_table="gpt"
    elif echo "$parted_output" | grep -q "msdos"; then
        partition_table="msdos"
    fi
    
    if [ "$partition_table" = "gpt" ] && command -v sgdisk &> /dev/null; then
        log "Using sgdisk for GPT"
        echo 50
        echo "# Resizing GPT partition..."
        sgdisk --move-second-header "$NBD_DEVICE" 2>>"$LOG_FILE"
        sgdisk --delete="$selected_partition" --new="$selected_partition":0:0 --typecode="$selected_partition":0700 "$NBD_DEVICE" 2>>"$LOG_FILE"
        if [ $? -eq 0 ]; then
            resize_success=true
        fi
    fi
    
    if [ "$resize_success" = false ]; then
        log "Fallback to parted resizepart"
        echo 50
        echo "# Fallback to parted..."
        parted --script "$NBD_DEVICE" resizepart "$selected_partition" 100% 2>>"$LOG_FILE"
        if [ $? -eq 0 ]; then
            resize_success=true
        fi
    fi
    
    if [ "$resize_success" = true ]; then
        echo 75
        echo "# Updating partition table..."
        partprobe "$NBD_DEVICE" 2>/dev/null
        sleep 2
        log "Partition resize success"
        return 0
    fi
    
    return 1
}

# Resize filesystem sulla partizione
resize_filesystem_on_partition() {
    log "Preparing to resize filesystem on selected partition $selected_partition"
    
    local target_dev="${NBD_DEVICE}p${selected_partition}"
    if [ ! -b "$target_dev" ]; then
        log "Error: Target device $target_dev not found after partition resize."
        whiptail --msgbox "Error: Could not find the selected partition after resizing. The partition table might be corrupted. You may need to use GParted Live." 15 80
        return 1
    fi
    
    local fs_type=$(blkid -o value -s TYPE "$target_dev" 2>/dev/null)
    
    case "$fs_type" in
        "ext2"|"ext3"|"ext4")
            resize_ext_filesystem "$target_dev"
            ;;
        "ntfs")
            resize_ntfs_filesystem "$target_dev"
            ;;
        "btrfs")
            resize_btrfs_filesystem "$target_dev"
            ;;
        "xfs")
            handle_xfs_filesystem "$target_dev"
            ;;
        *)
            handle_unsupported_filesystem "$fs_type"
            ;;
    esac
    
    return 0
}

# Resize filesystem NTFS
resize_ntfs_filesystem() {
    local target_dev=$1
    
    if command -v ntfsresize &> /dev/null && command -v ntfsfix &> /dev/null; then
        (
            echo 0
            echo "# Checking NTFS consistency..."
            ntfsfix --clear-dirty "$target_dev" >/dev/null 2>&1
            echo 30
            echo "# Running chkdsk equivalent..."
            ntfsfix --no-action "$target_dev" >/tmp/ntfs_check_$$.log 2>&1
            echo 60
            echo "# Resizing NTFS..."
            local ntfs_output=$(ntfsresize --force --no-action "$target_dev" 2>&1)
            if echo "$ntfs_output" | grep -q "successfully would be resized"; then
                echo 80
                echo "# Applying resize..."
                local final_output=$(ntfsresize --force "$target_dev" 2>&1)
                echo 100
                if [ $? -eq 0 ]; then
                    echo "# NTFS resized successfully!"
                    log "NTFS resize successful: $final_output"
                    sleep 1
                else
                    echo "# NTFS resize failed"
                    log "NTFS resize failed: $final_output"
                    sleep 2
                    exit 1
                fi
            else
                echo 100
                echo "# NTFS resize simulation failed"
                log "NTFS simulation failed: $ntfs_output"
                sleep 2
                exit 1
            fi
        ) | whiptail --gauge "Resizing NTFS filesystem..." 8 50 0
        
        if [ $? -eq 0 ]; then
            whiptail --msgbox "NTFS resized successfully!" 8 60
        else
            local error_log=$(cat /tmp/ntfs_check_$$.log 2>/dev/null)
            rm -f /tmp/ntfs_check_$$.log
            whiptail --msgbox "Error resizing NTFS.\n\nDetails:\n$ntfs_output\n\nTry booting in Windows and running:\nchkdsk /f C:\n\nOr use GParted Live." 15 70
        fi
        rm -f /tmp/ntfs_check_$$.log
    else
        log "ntfs-3g tools missing"
        whiptail --msgbox "ntfs-3g tools missing. Install with:\nsudo apt install ntfs-3g" 10 60
    fi
}

# Resize filesystem Btrfs
resize_btrfs_filesystem() {
    local target_dev=$1
    
    if command -v btrfs &> /dev/null; then
        (
            echo 0
            echo "# Checking btrfs filesystem..."
            btrfs check --repair --force "$target_dev" >/dev/null 2>&1 || true
            echo 50
            echo "# Resizing btrfs filesystem..."
            btrfs filesystem resize max "$target_dev" >/dev/null 2>&1
            echo 100
            echo "# Btrfs resize completed!"
            sleep 1
        ) | whiptail --gauge "Resizing btrfs filesystem..." 8 50 0
        
        if [ $? -eq 0 ]; then
            whiptail --msgbox "Btrfs filesystem resized successfully!" 8 60
        else
            whiptail --msgbox "Error resizing btrfs. Try manual resize with:\nbtrfs filesystem resize max /mount/point" 10 60
        fi
    else
        whiptail --msgbox "btrfs tools not found. Install with:\nsudo apt install btrfs-progs" 10 60
    fi
}

# Gestione filesystem XFS
handle_xfs_filesystem() {
    local target_dev=$1
    whiptail --msgbox "XFS detected. The partition has been extended, but the filesystem still needs to be resized.\n\nTo complete, use the 'Advanced Mount (NBD)' option, mount the partition, and run 'xfs_growfs <mount_point>'.\n\nAlternatively, you can boot the image with GParted Live to do it graphically." 20 80
}

# Gestione filesystem non supportati
handle_unsupported_filesystem() {
    local fs_type=$1
    
    if [ -n "$fs_type" ]; then
        log "Unsupported filesystem: $fs_type"
        whiptail --msgbox "Filesystem '$fs_type' is not supported for automatic resizing. You may need to use GParted Live." 10 70
    else
        log "Filesystem not recognized"
        whiptail --msgbox "Filesystem not recognized. You may need to use GParted Live to verify and resize manually." 10 70
    fi
}