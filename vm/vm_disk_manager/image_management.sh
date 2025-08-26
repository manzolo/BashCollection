#!/bin/bash

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

# Gestione rilevamento Windows e selezione partizione
handle_windows_detection_and_partition_selection() {
    if detect_windows_image "$NBD_DEVICE"; then
        log "Windows image warning shown"
        if whiptail --title "Windows Detected" --yesno "This appears to be a Windows image with potentially complex partitions (e.g., recovery at end).\nAutomatic resize may fail.\n\nProceed anyway, or use GParted Live?" 12 70; then
            log "Windows image with potentially complex partitions -> Automatic resize"
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

# Function to analyze partitions
analyze_partitions() {
    local device=$1
    
    if [ ! -b "$device" ]; then
        log "Device $device not available"
        echo "Device $device not available"
        return 1
    fi
    
    log "Analyzing partitions on $device"
    echo "=== PARTITION ANALYSIS ==="
    parted "$device" print 2>/dev/null || {
        log "Error analyzing partitions"
        echo "Error analyzing partitions"
        return 1
    }
    
    echo ""
    echo "=== FILESYSTEMS ==="
    for part in "${device}"p*; do
        if [ -b "$part" ]; then
            local fs_info=$(blkid "$part" 2>/dev/null || echo "Unknown")
            echo "$(basename "$part"): $fs_info"
        fi
    done
    
    return 0
}

detect_luks() {
    local device=$1
    local luks_parts=()
    
    if command -v cryptsetup &> /dev/null; then
        for part in "${device}"p*; do
            if [ -b "$part" ] && cryptsetup isLuks "$part" 2>/dev/null; then
                luks_parts+=("$part")
            fi
        done
    fi
    
    echo "${luks_parts[@]}"
}