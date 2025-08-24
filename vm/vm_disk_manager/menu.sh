# Main menu
main_menu() {
    local file=$1
    local current_file="$file"

    while true; do
        local status_info=""
        
        # Add info about active QEMU processes
        if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
            status_info="🟢 QEMU active (PID: $QEMU_PID)"
        fi
        
        local menu_items=(
            "1" "🖼️ Change Image"
            "2" "📏 Resize Image"
            "3" "🗂️ Safe Mount (guestmount)"
            "4" "💾 Advanced Mount (NBD)"
            "5" "🔍 Analyze Structure"
            "6" "🚀 Test with QEMU"
            "7" "🔧 Launch GParted Live"
            "8" "ℹ️ File Information"
            "9" "🧹 Manual Cleanup"
            "10" "📋 Active Mount Points"
            "11" "🚪 Exit"
        )
        
        local menu_text="File: $(basename "$current_file")"
        if [ -n "$status_info" ]; then
            menu_text="$menu_text\n$status_info"
        fi
        menu_text="$menu_text\n\nWhat would you like to do?"
        
        local choice=$(whiptail --title "$SCRIPT_NAME" --menu "$menu_text" 20 70 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                # Cleanup before changing file
                cleanup
                
                local new_file=$(select_file)
                if [ $? -eq 0 ] && [ -f "$new_file" ]; then
                    current_file="$new_file"
                    CLEANUP_DONE=false
                    NBD_DEVICE=""
                    MOUNTED_PATHS=()
                    LUKS_MAPPED=()
                    LVM_ACTIVE=()
                    VG_DEACTIVATED=()
                    QEMU_PID=""
                else
                    whiptail --msgbox "Selection cancelled. Staying on the current image." 8 60
                fi
                ;;
            2)
                local size=$(get_size)
                if [ $? -eq 0 ] && [ -n "$size" ]; then
                    if whiptail --title "Confirmation" --yesno "Resize to $size?\n\nWARNING: This operation is irreversible!\nMake sure you have a backup." 12 70; then
                        advanced_resize "$current_file" "$size"
                    fi
                fi
                ;;
            3)
                mount_with_guestmount "$current_file"
                ;;
            4)
                mount_with_nbd "$current_file"
                ;;
            5)
                local format=$(qemu-img info "$current_file" 2>/dev/null | grep "file format:" | awk '{print $3}')
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
                    
                    safe_nbd_disconnect "$NBD_DEVICE"
                    NBD_DEVICE=""
                    
                    whiptail --title "Structure Analysis" --msgbox "$analysis$luks_info" 20 80
                else
                    whiptail --msgbox "Error analyzing the file." 8 50
                fi
                ;;
            6)
                test_vm_qemu "$current_file"
                ;;
            7)
                gparted_boot "$current_file"
                ;;
            8)
                local info=$(qemu-img info "$current_file" 2>/dev/null || echo "Could not read image information")
                local size=$(du -h "$current_file" 2>/dev/null | cut -f1 || echo "?")
                local format=$(echo "$info" | grep "file format:" | awk '{print $3}' || echo "Unknown")
                
                whiptail --title "File Information" --msgbox "File: $(basename "$current_file")\nFull path: $current_file\nSize on disk: $size\nFormat: $format\n\n=== qemu-img Details ===\n$info" 20 90
                ;;
            9)
                # Manual cleanup
                cleanup
                whiptail --msgbox "Manual cleanup completed." 8 50
                ;;
            10)
                # Display active mounts
                show_active_mounts
                ;;
            11|"")
                break
                ;;
        esac
    done
}