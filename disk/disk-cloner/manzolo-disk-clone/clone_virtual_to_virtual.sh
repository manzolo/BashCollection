clone_virtual_to_virtual() {
    log "=== Virtual to Virtual Cloning ==="
    
    local source_file=$(select_file "Select source virtual disk")
    if [ -z "$source_file" ] || [ ! -f "$source_file" ]; then
        dialog --title "Error" --msgbox "Invalid or no file selected!" 8 50
        return 1
    fi
    
    local file_info=$(get_virtual_disk_info "$source_file")
    if [ -z "$file_info" ]; then
        dialog --title "Error" --msgbox "Unable to read disk file!" 8 50
        return 1
    fi
    
    local src_format=$(echo "$file_info" | grep "file format:" | cut -d: -f2 | tr -d ' ')
    local virt_size=$(echo "$file_info" | grep "virtual size:" | grep -o '[0-9]*' | tail -1)
    local actual_size=$(echo "$file_info" | grep "disk size:" | cut -d: -f2 | tr -d ' ')
    
    log "Source: $source_file"
    log "Format: $src_format"
    log "Virtual Size: $((virt_size / 1073741824)) GB"
    log "Actual Size: $actual_size"
    
    local dest_choice
    dest_choice=$(dialog --clear --title "Destination Virtual Disk" \
        --menu "Choose destination option:" 12 60 2 \
        "new" "Create new virtual disk" \
        "existing" "Use existing virtual disk file" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$dest_choice" ]; then
        return 1
    fi
    
    local dest_file=""
    local dest_format=""
    local USE_MAX_COMPRESS=false
    
    if [ "$dest_choice" = "new" ]; then
        local dest_dir=$(select_directory "Select destination directory")
        if [ -z "$dest_dir" ]; then
            dialog --title "Error" --msgbox "Invalid or no directory selected!" 8 50
            return 1
        fi
        
        local filename
        filename=$(dialog --clear --title "File Name" \
            --inputbox "Name of the new virtual disk:" 10 60 \
            "copy_$(date +%Y%m%d_%H%M%S).qcow2" \
            3>&1 1>&2 2>&3)
        
        if [ -z "$filename" ]; then
            return 1
        fi
        
        dest_file="$dest_dir/$filename"
        if [ -e "$dest_file" ] && [ "$DRY_RUN" = false ]; then
            dialog --title "Error" --msgbox "File already exists!" 8 50
            return 1
        fi
        
        dest_format=$(dialog --clear --title "Disk Format" \
            --menu "Select format (with optimization):" 14 65 6 \
            "qcow2" "QCOW2 - Best compression & features" \
            "qcow2-compress" "QCOW2 - Maximum compression (slower)" \
            "vmdk" "VMDK - VMware (dynamic/thin)" \
            "vdi" "VDI - VirtualBox (dynamic)" \
            "raw" "RAW - No compression (sparse)" \
            "vpc" "VHD - Hyper-V" \
            3>&1 1>&2 2>&3)
        
        if [ -z "$dest_format" ]; then
            return 1
        fi
        
        if [ "$dest_format" = "qcow2-compress" ]; then
            dest_format="qcow2"
            USE_MAX_COMPRESS=true
        fi
    else
        dest_file=$(select_file "Select destination virtual disk file")
        if [ -z "$dest_file" ] || [ ! -f "$dest_file" ]; then
            dialog --title "Error" --msgbox "Invalid or no file selected!" 8 50
            return 1
        fi
        
        if [ "$source_file" = "$dest_file" ]; then
            dialog --title "Error" --msgbox "Source and destination cannot be the same file!" 8 60
            return 1
        fi
        
        local dest_info=$(get_virtual_disk_info "$dest_file")
        if [ -z "$dest_info" ]; then
            dialog --title "Error" --msgbox "Unable to read destination disk file!" 8 50
            return 1
        fi
        
        local dest_size=$(echo "$dest_info" | grep "virtual size:" | grep -o '[0-9]*' | tail -1)
        dest_format=$(echo "$dest_info" | grep "file format:" | cut -d: -f2 | tr -d ' ')
        
        if [ "$dest_size" -lt "$virt_size" ]; then
            dialog --title "Error" \
                --msgbox "Destination file is too small!\n\nSource: $((virt_size / 1073741824)) GB\nDestination: $((dest_size / 1073741824)) GB" 10 60
            return 1
        fi
        
        local warning_msg="This will OVERWRITE the existing file:\n$dest_file"
        if [ "$DRY_RUN" = true ]; then
            warning_msg="$warning_msg\n\n🧪 DRY RUN: No actual changes will be made"
        fi
        
        if ! dialog --title "⚠️ WARNING ⚠️" \
            --yesno "$warning_msg\n\nAre you sure?" 12 70; then
            return 1
        fi
    fi
    
    local confirm_msg="Clone the virtual disk?\n\nSource: $source_file ($src_format)\nDestination: $dest_file ($dest_format)\n\nOptimization will be applied automatically."
    if [ "$DRY_RUN" = true ]; then
        confirm_msg="$confirm_msg\n\n🧪 DRY RUN: No actual file changes will be made"
    fi
    
    if ! dialog --title "Confirm Cloning" \
        --yesno "$confirm_msg" 14 70; then
        [ "$dest_choice" = "new" ] && [ "$DRY_RUN" = false ] && rm -f "$dest_file"
        return 1
    fi
    
    clear
    log "Cloning with optimization..."
    log "Converting from $src_format to $dest_format"
    
    local convert_cmd="qemu-img convert -p"
    
    case "$dest_format" in
        qcow2)
            if [ "$USE_MAX_COMPRESS" = true ]; then
                log "Using maximum compression (this will be slower)..."
                convert_cmd="$convert_cmd -c -o cluster_size=65536"
            else
                convert_cmd="$convert_cmd -c"
            fi
            ;;
        vmdk)
            convert_cmd="$convert_cmd -o adapter_type=lsilogic,subformat=streamOptimized"
            ;;
        vdi)
            convert_cmd="$convert_cmd -o static=off"
            ;;
        raw)
            convert_cmd="$convert_cmd -S 512k"
            ;;
    esac
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would run: $convert_cmd -O '$dest_format' '$source_file' '$dest_file'"
        if [ "$dest_format" = "qcow2" ]; then
            log "🧪 DRY RUN - Would run final optimization: qemu-img check -r all '$dest_file'"
        fi
        log "✅ DRY RUN - Virtual to virtual cloning simulation completed!"
        
        dialog --title "✅ Dry Run Success" \
            --msgbox "DRY RUN simulation completed!\n\nWould have cloned:\nSource: $(basename \"$source_file\") ($src_format)\nDestination: $(basename \"$dest_file\") ($dest_format)" 12 70
        return 0
    else
        run_log "set -o pipefail; $convert_cmd -O '$dest_format' '$source_file' '$dest_file'"
        
        if [ $? -eq 0 ]; then
            sync
            if [ "$dest_format" = "qcow2" ]; then
                log "Running final optimization..."
                run_log qemu-img check -r all "$dest_file" || true
            fi
            
            local src_actual=$(stat -c%s "$source_file" 2>/dev/null || echo 0)
            local dst_actual=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
            local src_gb=$(echo "scale=2; $src_actual / 1073741824" | bc)
            local dst_gb=$(echo "scale=2; $dst_actual / 1073741824" | bc)
            local saved=$(echo "scale=2; $src_gb - $dst_gb" | bc)
            
            dialog --title "✅ Success" \
                --msgbox "Cloning completed!\n\nSource: $(basename \"$source_file\") ($src_gb GB)\nDestination: $(basename \"$dest_file\") ($dst_gb GB)\n\nSpace saved: $saved GB" 12 70
            return 0
        else
            dialog --title "❌ Error" --msgbox "Error during cloning!" 8 50
            [ "$dest_choice" = "new" ] && rm -f "$dest_file"
            return 1
        fi
    fi
}