#!/bin/bash

# A simple function to get file info (already in your script, but for context)
get_file_info() {
    local file=$1
    local size_on_disk=$(du -sh "$file" 2>/dev/null | awk '{print $1}')
    local virtual_size=$(sudo qemu-img info "$file" 2>/dev/null | grep "virtual size" | awk '{print $3$4}')
    local format=$(sudo qemu-img info "$file" 2>/dev/null | grep "file format:" | awk '{print $3}')
    echo "$size_on_disk" "$virtual_size" "$format"
}

# New function to handle the "Change Image" action
handle_change_image() {
    local new_file=$(select_file)
    if [ $? -eq 0 ] && [ -f "$new_file" ]; then
        log "Changing image to: $new_file"
        cleanup_all_state
        current_file="$new_file"
        #whiptail --msgbox "Image changed successfully!\n\nNew image: $(basename "$new_file")" 10 60
    else
        whiptail --msgbox "Selection cancelled. Staying on the current image." 8 60
    fi
}

# New function to handle the "Resize Image" action
handle_resize_image() {
    local size=$(get_size)
    if [ $? -eq 0 ] && [ -n "$size" ]; then
        if whiptail --title "Confirmation" --yesno "Resize to $size?\n\nWARNING: This operation is irreversible!\nMake sure you have a backup." 12 70; then
            advanced_resize "$current_file" "$size"
        fi
    fi
}

# New function to handle the "Analyze Structure" action
handle_analyze_structure() {
    local format=$(sudo qemu-img info --output=json "$current_file" | jq -r '.format')
    [ -z "$format" ] && format="raw"

    if connect_nbd "$current_file" "$format"; then
        local analysis=$(analyze_partitions "$NBD_DEVICE")
        local luks_parts=($(detect_luks "$NBD_DEVICE"))
        local luks_info=""
        
        if [ ${#luks_parts[@]} -gt 0 ]; then
            luks_info="\n\n=== LUKS PARTITIONS ===\n"
            for part in "${luks_parts[@]}"; do
                luks_info="$luks_info$(basename "$part")\n"
            done
        fi
        
        safe_nbd_disconnect "$NBD_DEVICE" >/dev/null 2>&1
        NBD_DEVICE=""
        
        whiptail --title "Structure Analysis" --msgbox "$analysis$luks_info" 20 80
    else
        whiptail --msgbox "Error analyzing the file." 8 50
    fi
}

# New function to handle cleanup and state reset
cleanup_all_state() {
    log "Performing full state cleanup"
    
    # Terminate QEMU process if active
    if [ -n "$QEMU_PID" ] && sudo kill -0 "$QEMU_PID" 2>/dev/null; then
        whiptail --msgbox "Terminating active QEMU process (PID: $QEMU_PID)." 8 50
        sudo kill "$QEMU_PID" 2>/dev/null || true
        QEMU_PID=""
    fi

    # Unmount all active mount points
    for mount_point in "${MOUNTED_PATHS[@]}"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log "Unmounting $mount_point"
            sudo umount "$mount_point" 2>/dev/null || sudo umount -l "$mount_point" 2>/dev/null
        fi
        sudo rmdir "$mount_point" 2>/dev/null
    done
    MOUNTED_PATHS=()

    # Disconnect NBD devices
    cleanup_nbd_devices
    
    # Reset state variables
    CLEANUP_DONE=false
    NBD_DEVICE=""
    MOUNTED_PATHS=()
    LUKS_MAPPED=()
    LVM_ACTIVE=()
    VG_DEACTIVATED=()
    QEMU_PID=""

    log "State cleanup complete."
}

handle_mount_menu() {
    local file=$1
    while true; do
        local menu_title="Mount/Unmount Options for $(basename "$file")"
        local menu_items=(
            "1" "🗂️  Safe Mount (guestmount)"
            "2" "💾 Advanced Mount (NBD)"
            "3" "📋 Active Mount Points"
            "4" "🧹 NBD Cleaner"
            "5" "🚪 Back to Main Menu"
        )
        local choice=$(whiptail --title "$menu_title" --menu "Select a mounting option:" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)

        case $choice in
            1)
                mount_with_guestmount "$file"
                ;;
            2)
                mount_with_nbd "$file"
                ;;
            3)
                show_active_mounts
                ;;
            4)
                cleanup_nbd_devices
                ;;
            5|"")
                return
                ;;
        esac
    done
}

handle_image_compression() {
    local file=$1
    local filename=$(basename -- "$file")
    local extension="${filename##*.}"
    local base="${filename%.*}"
    local output_file="${base}_compressed.${extension}"

    # Mostra il messaggio di conferma
    if whiptail --title "Compressing Image" --yesno "The compressed file will be saved as:\n\n$output_file\n\nPress OK to continue." 10 60; then
        # Esegui la compressione
        compress_image "$file" "$output_file"
        # Mostra un messaggio di successo
        whiptail --title "Compression Complete" --msgbox "Image successfully compressed to:\n\n$output_file" 10 60
    else
        # Se l'utente annulla, mostra un messaggio e torna al menu
        whiptail --title "Compression Cancelled" --msgbox "Compression cancelled. Returning to menu." 8 60
    fi
    # Non è necessario fare altro; il flusso tornerà automaticamente al menu chiamante
}

handle_disk_ops_menu() {
    local file=$1
    while true; do
        local menu_title="Disk Operations for $(basename "$file")"
        local menu_items=(
            "1" "📏 Resize Image"
            "2" "🔧 Launch GParted Live"
            "3" "⬇️  Compress Image"
            "4" "🚪 Back to Main Menu"
        )
        local choice=$(whiptail --title "$menu_title" --menu "Select a disk operation:" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)

        case $choice in
            1)
                handle_resize_image
                ;;
            2)
                gparted_boot "$file"
                ;;
            3)
                handle_image_compression "$file"
                ;;
            4|"")
                return
                ;;
        esac
    done
}

handle_nvram_reset() {
    local file=$1
    local nvram_dir="$HOME/.local/share/vm-disk-manager/nvram"
    local vm_basename=$(basename "$file")
    local nvram_file="$nvram_dir/${vm_basename}.nvram.fd"

    if [ -f "$nvram_file" ]; then
        if whiptail --title "Reset UEFI NVRAM" --yesno "This will reset all UEFI settings for this VM:\n\n- Boot order\n- Boot entries\n- UEFI configuration\n\nNVRAM file: $nvram_file\n\nAre you sure you want to reset?" 16 70; then
            if reset_nvram "$file"; then
                whiptail --msgbox "NVRAM has been reset successfully.\n\nThe VM will start with fresh UEFI settings on next UEFI boot." 10 60
            else
                whiptail --msgbox "Error resetting NVRAM.\n\nCheck log file: $LOG_FILE" 10 60
            fi
        fi
    else
        whiptail --msgbox "No NVRAM file found for this VM.\n\nNVRAM is created automatically when you boot in UEFI mode.\n\nExpected location:\n$nvram_file" 12 70
    fi
}

handle_analysis_menu() {
    local file=$1
    while true; do
        local menu_title="Analysis and Info for $(basename "$file")"
        local menu_items=(
            "1" "🔍 Analyze Structure"
            "2" "ℹ️  Detailed File Information"
            "3" "🔧 Reset UEFI NVRAM"
            "4" "🚪 Back to Main Menu"
        )
        local choice=$(whiptail --title "$menu_title" --menu "Select an analysis option:" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)

        case $choice in
            1)
                handle_analyze_structure
                ;;
            2)
                show_detailed_info "$file"
                ;;
            3)
                handle_nvram_reset "$file"
                ;;
            4|"")
                return
                ;;
        esac
    done
}

# --- Funzione del Menu Principale ---
main_menu() {
    local file=$1
    local current_file="$file"

    # Ensure cleanup is performed on script exit
    trap cleanup_all_state EXIT

    while true; do
        # Get file information using the helper function
        local file_info=($(get_file_info "$current_file"))
        local size_on_disk="${file_info[0]}"
        local virtual_size="${file_info[1]}"
        local format="${file_info[2]}"

        local status_info=""
        
        # Check for active QEMU processes
        if [ -n "$QEMU_PID" ] && sudo kill -0 "$QEMU_PID" 2>/dev/null; then
            status_info+="🟢 QEMU active (PID: $QEMU_PID)"
        fi
        
        # Check for active mounts
        if [ ${#MOUNTED_PATHS[@]} -gt 0 ]; then
            if [ -n "$status_info" ]; then
                status_info+="\n"
            fi
            status_info+="📁 Mounted: ${#MOUNTED_PATHS[@]} path(s)"
        fi
        
        local menu_items=(
            "1" "🖼️  Change Image"
            "2" "📁 Mount/Unmount Options"
            "3" "🔧 Disk Operations"
            "4" "🚀 Test with QEMU"
            "5" "🔍 Analysis and Info"
            "6" "🚪 Exit"
        )
        
        local temp_text_file=$(mktemp)
        echo -e "Image: $(basename "$current_file") (Size: $size_on_disk | Virt: $virtual_size)\nFormat: $format" > "$temp_text_file"

        if [ -n "$status_info" ]; then
            echo -e "\nStatus:\n$status_info" >> "$temp_text_file"
        fi
        
        echo -e "\n\nWhat would you like to do?" >> "$temp_text_file"
        
        local choice=$(whiptail --title "Disk Image Manager" --menu "$(cat "$temp_text_file")" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)
        
        rm "$temp_text_file"

        case $choice in
            1)
                handle_change_image
                ;;
            2)
                handle_mount_menu "$current_file"
                ;;
            3)
                handle_disk_ops_menu "$current_file"
                ;;
            4)
                test_vm_qemu "$current_file"
                ;;
            5)
                handle_analysis_menu "$current_file"
                ;;
            6|"")
                break
                ;;
        esac
    done
}