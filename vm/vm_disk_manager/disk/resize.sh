#!/bin/bash

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