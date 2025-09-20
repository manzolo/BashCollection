clone_physical_to_virtual() {
    log "=== Physical to Virtual Cloning ==="
    
    local source_device=$(select_physical_device)
    if [ -z "$source_device" ] || [ ! -b "$source_device" ]; then
        return 1
    fi
    
    local device_size=$(blockdev --getsize64 "$source_device")
    
    log "Source: $source_device"
    log "Physical Size: $((device_size / 1073741824)) GB"
    
    local optimized_size=$(analyze_device_usage "$source_device")
    local optimized_gb=$(echo "scale=2; $optimized_size / 1073741824" | bc)
    local device_gb=$((device_size / 1073741824))
    
    local clone_mode
    clone_mode=$(dialog --clear --title "Cloning Mode" \
        --menu "Choose cloning mode:\n\nPhysical size: ${device_gb}GB\nOptimized size: ${optimized_gb}GB (only used space + overhead)" 15 70 2 \
        "optimized" "🚀 Smart Mode - Create optimized image (~${optimized_gb}GB)" \
        "full" "📼 Full Mode - Clone entire disk (${device_gb}GB)" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$clone_mode" ]; then
        return 1
    fi
    
    local dest_dir=$(select_directory "Select destination directory")
    
    if [ -z "$dest_dir" ]; then
        dialog --title "Error" --msgbox "Invalid or no directory selected!" 8 50
        return 1
    fi
    
    local filename
    filename=$(dialog --clear --title "File Name" \
        --inputbox "Name of the new virtual disk:" 10 60 \
        "clone_$(date +%Y%m%d_%H%M%S).qcow2" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$filename" ]; then
        return 1
    fi
    
    local dest_file="$dest_dir/$filename"
    if [ -e "$dest_file" ] && [ "$DRY_RUN" = false ]; then
        dialog --title "Error" --msgbox "File already exists!" 8 50
        return 1
    fi
    
    local format
    format=$(dialog --clear --title "Disk Format" \
        --menu "Select format:" 12 60 5 \
        "qcow2" "QCOW2 - Best compression & features" \
        "vmdk" "VMDK - VMware (dynamic)" \
        "vdi" "VDI - VirtualBox (dynamic)" \
        "raw" "RAW - No compression (sparse file)" \
        "vpc" "VHD - Hyper-V" \
        3>&1 1>&2 2>&3)
    
    if [ -z "$format" ]; then
        return 1
    fi
    
    local size_info=""
    if [ "$clone_mode" = "optimized" ]; then
        size_info="Optimized size: ~${optimized_gb}GB (smart copy)"
    else
        size_info="Full size: ${device_gb}GB"
    fi
    
    local confirm_msg="Clone the device?\n\nSource: $source_device\nDestination: $dest_file\nFormat: $format\n$size_info\n\nMode: $clone_mode"
    if [ "$DRY_RUN" = true ]; then
        confirm_msg="$confirm_msg\n\n🧪 DRY RUN: No actual file will be created"
    fi
    
    if ! dialog --title "Confirm Cloning" \
        --yesno "$confirm_msg" 16 70; then
        return 1
    fi
    
    clear
    
    if [ "$clone_mode" = "optimized" ]; then
        if [ "$DRY_RUN" = true ]; then
            log "=== DRY RUN - OPTIMIZED CLONING MODE ==="
        else
            log "=== OPTIMIZED CLONING MODE ==="
        fi
        log "Creating space-efficient image with proper partition handling..."
        
        clone_physical_to_virtual_optimized "$source_device" "$dest_file" "$format"
    else
        if [ "$DRY_RUN" = true ]; then
            log "=== DRY RUN - FULL CLONING MODE ==="
        else
            log "=== FULL CLONING MODE ==="
        fi
        log "Cloning entire device..."
        
        if [ "$DRY_RUN" = true ]; then
            if [ "$format" = "qcow2" ]; then
                log "🧪 DRY RUN - Would run: qemu-img convert -p -c -O qcow2 '$source_device' '$dest_file'"
            else
                log "🧪 DRY RUN - Would run: qemu-img convert -p -O '$format' '$source_device' '$dest_file'"
            fi
            log "✅ DRY RUN - Full cloning simulation completed!"
            dialog --title "✅ Dry Run Success" \
                --msgbox "DRY RUN simulation completed successfully!\n\nWould have cloned:\n$source_device → $dest_file\n\nFormat: $format" 12 70
            return 0
        else
            if [ "$format" = "qcow2" ]; then
                run_log "qemu-img convert -p -c -O qcow2 '$source_device' '$dest_file'"
            else
                run_log "qemu-img convert -p -O '$format' '$source_device' '$dest_file'"
            fi
        fi
    fi
    
    if [ $? -eq 0 ]; then
        if [ "$DRY_RUN" = false ]; then
            sync
            local final_size=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
            dialog --title "✅ Success" \
                --msgbox "Cloning completed successfully!\n\n$source_device → $dest_file\n\nFile size: $((final_size / 1073741824)) GB" 12 70
        fi
        return 0
    else
        if [ "$DRY_RUN" = false ]; then
            dialog --title "❌ Error" \
                --msgbox "Error during cloning!" 8 50
            rm -f "$dest_file" 2>/dev/null
        fi
        return 1
    fi
}

clone_physical_to_virtual_optimized() {
    local source_device="$1"
    local dest_file="$2"
    local dest_format="$3"
    
    log "Starting reliable cloning with filesystem preservation..."
    
    if ! validate_device_safety "$source_device" "read"; then
        return 1
    fi
    
    safe_unmount_device_partitions "$source_device"
    
    local temp_raw=$(create_temp_file "raw")
    local device_size=$(blockdev --getsize64 "$source_device")
    local pt_type=$(get_partition_table_type "$source_device")
    
    log "Device size: $((device_size / 1073741824)) GB"
    log "Partition table type: $pt_type"
    
    # Create temporary raw image with better error handling
    log "Creating temporary raw image..."
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would create temporary image: $temp_raw (size: $((device_size / 1073741824)) GB)"
    else
        if ! create_sparse_image "$temp_raw" "$device_size"; then
            log_with_level ERROR "Failed to create temporary image"
            return 1
        fi
    fi
    
    # Setup loop device with improved error handling
    local loop_dev
    if ! loop_dev=$(setup_loop_device_safe "$temp_raw"); then
        log_with_level ERROR "Failed to setup loop device"
        rm -f "$temp_raw"
        return 1
    fi
    
    log "Loop device: $loop_dev"
    
    # Copy partition table with improved GPT handling
    log "Copying partition table..."
    if [ "$pt_type" = "gpt" ]; then
        if ! copy_gpt_partition_table_safe "$source_device" "$loop_dev"; then
            log_with_level ERROR "Failed to copy GPT partition table"
            cleanup_resources
            return 1
        fi
    else
        # MBR partition table
        if [ "$DRY_RUN" = true ]; then
            log "🧪 DRY RUN - Would copy MBR: dd if='$source_device' of='$loop_dev' bs=512 count=1 conv=notrunc"
        else
            if ! dd if="$source_device" of="$loop_dev" bs=512 count=1 conv=notrunc 2>/dev/null; then
                log_with_level ERROR "Failed to copy MBR"
                cleanup_resources
                return 1
            fi
        fi
    fi
    
    # Setup partition mappings with improved error handling
    if ! setup_partition_mappings "$loop_dev"; then
        log_with_level WARN "Partition mappings failed, falling back to whole device copy"
        
        # Fallback to whole device copy
        log "Copying entire device..."
        if ! clone_with_retry "$source_device" "$loop_dev" "4M" 3; then
            log_with_level ERROR "Whole device copy failed"
            cleanup_resources
            return 1
        fi
    else
        # Partition-by-partition copy with improved error handling
        log "Found partition mappings, copying partition by partition..."
        
        local part_num=1
        local success_count=0
        local total_partitions=0
        
        while IFS= read -r source_part_name; do
            local source_part="/dev/$source_part_name"
            total_partitions=$((total_partitions + 1))
            
            # Find corresponding destination partition
            local dest_part=""
            for try_dest in "${loop_dev}p${part_num}" "/dev/mapper/$(basename $loop_dev)p${part_num}"; do
                if [ -b "$try_dest" ] || [ "$DRY_RUN" = true ]; then
                    dest_part="$try_dest"
                    break
                fi
            done
            
            if [ -z "$dest_part" ]; then
                log_with_level WARN "Cannot find destination partition for $source_part"
                part_num=$((part_num + 1))
                continue
            fi
            
            if [ -b "$source_part" ] && ([ -b "$dest_part" ] || [ "$DRY_RUN" = true ]); then
                local fs_type=$(detect_filesystem_robust "$source_part")
                
                log "Cloning partition $part_num: $source_part -> $dest_part"
                log "  Filesystem: ${fs_type:-unknown}"
                
                # Repair filesystem if needed
                if [ -n "$fs_type" ] && [ "$fs_type" != "" ] && [ "$fs_type" != "swap" ]; then
                    repair_filesystem "$source_part" "$fs_type" || true
                fi
                
                # Clone with retry logic
                if clone_with_retry "$source_part" "$dest_part" "4M" 2; then
                    log "    ✓ Partition cloned successfully"
                    success_count=$((success_count + 1))
                    
                    # Verify filesystem after cloning
                    if [ "$DRY_RUN" = false ]; then
                        sync
                        local dest_fs=$(detect_filesystem_robust "$dest_part")
                        if [ "$dest_fs" = "$fs_type" ]; then
                            log "    ✓ Filesystem verified: $dest_fs"
                        else
                            log "    ⚠ Filesystem mismatch: expected $fs_type, got $dest_fs"
                        fi
                    fi
                else
                    log_with_level ERROR "Partition clone failed for $source_part"
                fi
            fi
            
            part_num=$((part_num + 1))
        done < <(lsblk -ln -o NAME "$source_device" | tail -n +2)
        
        log "Partition cloning summary: $success_count/$total_partitions successful"
        
        # If too many partitions failed, consider it a failure
        if [ $success_count -eq 0 ] && [ $total_partitions -gt 0 ]; then
            log_with_level ERROR "All partition clones failed"
            cleanup_resources
            return 1
        fi
    fi
    
    if [ "$DRY_RUN" = false ]; then
        sync
        sleep 2
    fi
    
    # Clean up partition mappings
    if [ "$DRY_RUN" = false ]; then
        if command -v kpartx >/dev/null 2>&1; then
            kpartx -dv "$loop_dev" 2>/dev/null || true
        fi
        losetup -d "$loop_dev" 2>/dev/null || true
    fi
    
    # Convert to final format
    log "Converting to $dest_format format..."
    
    local convert_opts="-p"
    case "$dest_format" in
        qcow2)
            convert_opts="$convert_opts -c -o cluster_size=65536"
            ;;
        vmdk)
            convert_opts="$convert_opts -o adapter_type=lsilogic,subformat=streamOptimized"
            ;;
        vdi)
            convert_opts="$convert_opts -o static=off"
            ;;
    esac
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would convert with: qemu-img convert $convert_opts -O '$dest_format' '$temp_raw' '$dest_file'"
        log "✅ DRY RUN - Cloning simulation completed successfully!"
        return 0
    else
        if run_log "qemu-img convert $convert_opts -O '$dest_format' '$temp_raw' '$dest_file'"; then
            # Verification and cleanup
            log "Verifying cloned image..."
            qemu-img info "$dest_file" | tee -a "$LOGFILE"
            
            if [ "$dest_format" = "qcow2" ]; then
                qemu-img check "$dest_file" 2>&1 | tee -a "$LOGFILE"
            fi
            
            local final_size=$(stat -c%s "$dest_file" 2>/dev/null || echo 0)
            local final_gb=$(echo "scale=2; $final_size / 1073741824" | bc)
            local device_gb=$(echo "scale=2; $device_size / 1073741824" | bc)
            
            log "✅ Cloning completed successfully!"
            log "  Original device: ${device_gb}GB"
            log "  Final image: ${final_gb}GB"
            
            return 0
        else
            log_with_level ERROR "Conversion failed"
            return 1
        fi
    fi
}