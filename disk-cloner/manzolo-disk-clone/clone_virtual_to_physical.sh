clone_virtual_to_physical() {
    log "=== Virtual to Physical Cloning ==="
    
    local source_file=$(select_file "Select source virtual disk")
    
    if [ -z "$source_file" ] || [ ! -f "$source_file" ]; then
        dialog --title "Error" --msgbox "Invalid or no file selected!" 8 50
        return 1
    fi
    
    local file_info=$(get_virtual_disk_info "$source_file")
    if [ -z "$file_info" ]; then
        dialog --title "Error" --msgbox "Unable to read disk file!\n\nFile might be corrupted." 10 60
        return 1
    fi
    
    local format=$(echo "$file_info" | grep "file format:" | cut -d: -f2 | tr -d ' ')
    local virt_size=$(echo "$file_info" | grep "virtual size:" | grep -o '[0-9]*' | tail -1)
    
    log "Source: $source_file"
    log "Format: $format"
    log "Size: $((virt_size / 1073741824)) GB"
    
    local dest_device=$(select_physical_device)
    if [ -z "$dest_device" ] || [ ! -b "$dest_device" ]; then
        return 1
    fi
    
    local dest_size=$(blockdev --getsize64 "$dest_device" 2>/dev/null)
    
    if [ "$dest_size" -lt "$virt_size" ]; then
        dialog --title "Error" \
            --msgbox "Destination device is too small!\n\nSource: $((virt_size / 1073741824)) GB\nDestination: $((dest_size / 1073741824)) GB" 10 60
        return 1
    fi
    
    local warning_msg="WARNING: This operation will DESTROY ALL DATA on $dest_device!\n\nSource: $source_file\nDestination: $dest_device"
    if [ "$DRY_RUN" = true ]; then
        warning_msg="$warning_msg\n\n🧪 DRY RUN: No actual changes will be made"
    fi
    
    if ! dialog --title "⚠️ CONFIRM CLONING ⚠️" \
        --yesno "$warning_msg\n\nAre you SURE you want to continue?" 14 70; then
        return 1
    fi
    
    clear
    
    log "Cloning in progress..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: qemu-img convert -p -O raw '$source_file' '$dest_device'"
        log "✅ DRY RUN - Virtual to physical cloning simulation completed!"
        dialog --title "✅ Dry Run Success" \
            --msgbox "DRY RUN simulation completed successfully!\n\nWould have cloned:\n$source_file → $dest_device" 10 60
        return 0
    else
        run_log "qemu-img convert -p -O raw '$source_file' '$dest_device'"
        
        if [ $? -eq 0 ]; then
            sync
            dialog --title "✅ Success" \
                --msgbox "Cloning completed successfully!\n\n$source_file → $dest_device" 10 60
            return 0
        else
            dialog --title "❌ Error" --msgbox "Error during cloning!" 8 50
            return 1
        fi
    fi
}