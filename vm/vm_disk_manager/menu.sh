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
        whiptail --msgbox "Image changed successfully!\n\nNew image: $(basename "$new_file")" 10 60
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


# Main menu function (now much cleaner)
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
            "2" "📏 Resize Image"
            "3" "🗂️  Safe Mount (guestmount)"
            "4" "💾 Advanced Mount (NBD)"
            "5" "🔍 Analyze Structure"
            "6" "🚀 Test with QEMU"
            "7" "🔧 Launch GParted Live"
            "8" "ℹ️  Detailed File Information"
            "9" "🧹 NBD cleaner"
            "10" "📋 Active Mount Points"
            "11" "🚪 Exit"
        )
        
        local temp_text_file=$(mktemp)
        echo -e "Image: $(basename "$current_file") (Size: $size_on_disk | Virt: $virtual_size)\nFormat: $format" > "$temp_text_file"

        if [ -n "$status_info" ]; then
            echo -e "\nStatus:\n$status_info" >> "$temp_text_file"
        fi
        
        echo -e "\n\nWhat would you like to do?" >> "$temp_text_file"
        
        local choice=$(whiptail --title "$SCRIPT_NAME" --menu "$(cat "$temp_text_file")" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)
        
        rm "$temp_text_file"

        case $choice in
            1)
                handle_change_image
                ;;
            2)
                handle_resize_image
                ;;
            3)
                mount_with_guestmount "$current_file"
                ;;
            4)
                mount_with_nbd "$current_file"
                ;;
            5)
                handle_analyze_structure
                ;;
            6)
                test_vm_qemu "$current_file"
                ;;
            7)
                gparted_boot "$current_file"
                ;;
            8)
                show_detailed_info "$current_file"
                ;;
            9)
                cleanup_nbd_devices
                ;;
            10)
                show_active_mounts
                ;;
            11|"")
                break
                ;;
        esac
    done
}