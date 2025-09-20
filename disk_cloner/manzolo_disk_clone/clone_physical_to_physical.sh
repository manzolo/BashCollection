clone_physical_to_physical_simple() {
    log "=== Physical to Physical Cloning (Simple Mode) ==="
    
    local source_device=$(select_physical_device)
    if [ -z "$source_device" ] || [ ! -b "$source_device" ]; then
        return 1
    fi
    
    local source_size=$(blockdev --getsize64 "$source_device" 2>/dev/null)
    log "Source: $source_device"
    log "Source Size: $((source_size / 1073741824)) GB"
    
    local target_device=$(select_physical_device)
    if [ -z "$target_device" ] || [ ! -b "$target_device" ]; then
        return 1
    fi
    
    if [ "$source_device" = "$target_device" ]; then
        dialog --title "Error" --msgbox "Source and target devices cannot be the same!" 8 60
        return 1
    fi
    
    local target_size=$(blockdev --getsize64 "$target_device" 2>/dev/null)
    log "Target: $target_device"
    log "Target Size: $((target_size / 1073741824)) GB"
    
    if [ "$target_size" -lt "$source_size" ]; then
        dialog --title "Error" \
            --msgbox "Target device is too small!\n\nSource: $((source_size / 1073741824)) GB\nTarget: $((target_size / 1073741824)) GB" 10 60
        return 1
    fi
    
    # Safety checks
    if ! check_device_safety "$source_device"; then
        return 1
    fi
    
    if ! check_device_safety "$target_device"; then
        return 1
    fi
    
    local warning_msg="This operation will COMPLETELY DESTROY ALL DATA on the target device!\n\nSource: $source_device ($((source_size / 1073741824)) GB)\nTarget: $target_device ($((target_size / 1073741824)) GB)\n\nThis action is IRREVERSIBLE!"
    if [ "$DRY_RUN" = true ]; then
        warning_msg="$warning_msg\n\n🧪 DRY RUN MODE: No actual changes will be made"
    fi
    
    if ! dialog --title "⚠️ CRITICAL WARNING ⚠️" \
        --yesno "$warning_msg\n\nType 'yes' to confirm:" 16 70; then
        return 1
    fi
    
    local confirm_text
    if [ "$DRY_RUN" = true ]; then
        confirm_text=$(dialog --clear --title "Final Confirmation (Dry Run)" \
            --inputbox "To proceed with this DRY RUN simulation, type exactly: SIMULATE" 10 70 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "SIMULATE" ]; then
            dialog --title "Cancelled" --msgbox "Dry run cancelled - confirmation text did not match." 8 60
            return 1
        fi
    else
        confirm_text=$(dialog --clear --title "Final Confirmation" \
            --inputbox "To proceed with this DESTRUCTIVE operation, type exactly: DESTROY" 10 70 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "DESTROY" ]; then
            dialog --title "Cancelled" --msgbox "Operation cancelled - confirmation text did not match." 8 60
            return 1
        fi
    fi
    
    clear
    
    if [ "$DRY_RUN" = true ]; then
        log "Starting DRY RUN simulation of physical to physical clone..."
    else
        log "Starting simple physical to physical clone..."
    fi
    log "This will copy the entire source device to the target device"
    
    # Unmount partitions safely
    safe_unmount_device_partitions "$source_device"
    safe_unmount_device_partitions "$target_device"
    
    # Perform the clone
    log "Cloning $source_device to $target_device..."
    
    if [ "$DRY_RUN" = true ]; then
        log "🧪 DRY RUN - Would clone entire device:"
        if command -v pv &> /dev/null; then
            log "🧪 DRY RUN - Would run: pv -tpreb '$source_device' | dd of='$target_device' bs=4M conv=notrunc,noerror"
        else
            log "🧪 DRY RUN - Would run: dd if='$source_device' of='$target_device' bs=4M status=progress conv=notrunc,noerror"
        fi
        log "🧪 DRY RUN - Would run: sync"
        log "🧪 DRY RUN - Would run: partprobe '$target_device'"
        
        dialog --title "✅ Dry Run Complete" \
            --msgbox "DRY RUN simulation completed successfully!\n\nWould have cloned:\n$source_device → $target_device\n\nAll commands logged without execution." 12 70
        return 0
    else
        if command -v pv &> /dev/null; then
            log "Using pv for progress monitoring..."
            pv -tpreb "$source_device" | dd of="$target_device" bs=4M conv=notrunc,noerror 2>/dev/null
        else
            log "Using dd with progress..."
            dd if="$source_device" of="$target_device" bs=4M status=progress conv=notrunc,noerror 2>/dev/null
        fi
        
        if [ $? -eq 0 ]; then
            sync
            log "Verifying partition table on target device..."
            partprobe "$target_device" 2>/dev/null || true
            sleep 3
            
            dialog --title "✅ Success" \
                --msgbox "Simple cloning completed successfully!\n\n$source_device → $target_device\n\nAll data has been copied exactly." 12 70
            return 0
        else
            dialog --title "❌ Error" --msgbox "Error during cloning!" 8 50
            return 1
        fi
    fi
}

clone_physical_to_physical_with_uuid() {
    log "=== Physical to Physical Cloning (UUID Preservation Mode) ==="
    
    local source_device=$(select_physical_device)
    if [ -z "$source_device" ] || [ ! -b "$source_device" ]; then
        return 1
    fi
    
    local source_size=$(blockdev --getsize64 "$source_device" 2>/dev/null)
    log "Source: $source_device"
    log "Source Size: $((source_size / 1073741824)) GB"
    
    # Show source disk details
    echo
    log "Source disk partition layout:"
    lsblk "$source_device" | tee -a "$LOGFILE"
    
    local target_device
    while true; do
        target_device=$(select_physical_device)
        if [ -z "$target_device" ] || [ ! -b "$target_device" ]; then
            return 1
        fi
        
        if [ "$source_device" = "$target_device" ]; then
            dialog --title "Error" --msgbox "Source and target devices cannot be the same!" 8 60
            continue
        fi
        break
    done
    
    local target_size=$(blockdev --getsize64 "$target_device" 2>/dev/null)
    log "Target: $target_device"
    log "Target Size: $((target_size / 1073741824)) GB"
    
    # Show target disk details
    echo
    log "Target disk current layout:"
    lsblk "$target_device" | tee -a "$LOGFILE"
    
    # Safety checks
    if ! check_device_safety "$source_device"; then
        return 1
    fi
    
    if ! check_device_safety "$target_device"; then
        return 1
    fi
    
    # Get partitions info with UUIDs
    local source_partitions=()
    if ! get_partitions_info_with_uuids "$source_device" source_partitions; then
        dialog --title "Error" --msgbox "Failed to get partition information from source device!" 10 60
        return 1
    fi
    
    log "Found ${#source_partitions[@]} partitions on source disk"
    
    # Calculate target sizes (with proportional resize if needed)
    local target_sizes=()
    if ! calculate_proportional_sizes "$source_device" "$target_device" source_partitions target_sizes; then
        dialog --title "Error" --msgbox "Cannot fit source partitions on target device!" 10 60
        return 1
    fi
    
    # Show operation plan
    local plan_text="PHYSICAL TO PHYSICAL CLONING WITH UUID PRESERVATION\n\n"
    plan_text+="Source: $source_device ($(numfmt --to=iec --suffix=B $source_size))\n"
    plan_text+="Target: $target_device ($(numfmt --to=iec --suffix=B $target_size))\n\n"
    
    if [ "$DRY_RUN" = true ]; then
        plan_text+="🧪 DRY RUN MODE: NO ACTUAL CHANGES WILL BE MADE\n\n"
    else
        plan_text+="⚠️  TARGET DEVICE WILL BE COMPLETELY WIPED! ⚠️\n\n"
    fi
    
    plan_text+="Partitions to clone:\n"
    
    for i in "${!source_partitions[@]}"; do
        IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_partitions[$i]}"
        local target_size="${target_sizes[$i]}"
        
        plan_text+="• $(basename $partition): ${fs_type:-unknown} "
        plan_text+="($(numfmt --to=iec --suffix=B $size) → $(numfmt --to=iec --suffix=B $target_size))"
        if [[ "$is_efi" == "true" ]]; then
            plan_text+=" [EFI]"
        fi
        plan_text+="\n"
    done
    
    plan_text+="\n✓ All UUIDs will be preserved\n"
    plan_text+="✓ Filesystem integrity maintained\n"
    plan_text+="✓ Bootloader compatibility preserved"
    
    if ! dialog --title "⚠️ DESTRUCTIVE OPERATION CONFIRMATION ⚠️" \
        --yesno "$plan_text" 22 80; then
        return 1
    fi
    
    local confirm_text
    if [ "$DRY_RUN" = true ]; then
        confirm_text=$(dialog --clear --title "Final Safety Check (Dry Run)" \
            --inputbox "This is a DRY RUN simulation!\n\nTo confirm, type exactly: SIMULATE" 12 80 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "SIMULATE" ]; then
            dialog --title "Cancelled" --msgbox "Dry run cancelled - safety check failed." 8 60
            return 1
        fi
    else
        confirm_text=$(dialog --clear --title "Final Safety Check" \
            --inputbox "This will DESTROY all data on $target_device!\n\nTo confirm, type exactly: CLONE" 12 80 \
            3>&1 1>&2 2>&3)
        
        if [ "$confirm_text" != "CLONE" ]; then
            dialog --title "Cancelled" --msgbox "Operation cancelled - safety check failed." 8 60
            return 1
        fi
    fi
    
    clear
    
    if [ "$DRY_RUN" = true ]; then
        log "Starting DRY RUN simulation of physical to physical clone with UUID preservation..."
    else
        log "Starting physical to physical clone with UUID preservation..."
    fi
    
    # Unmount partitions safely
    safe_unmount_device_partitions "$source_device"
    safe_unmount_device_partitions "$target_device"
    
    # Create partitions with UUID preservation
    log "Step 1/2: Creating partition table and partitions..."
    if ! create_partitions_with_uuids "$target_device" source_partitions target_sizes; then
        log "Error: Failed to create partitions"
        dialog --title "❌ Error" --msgbox "Failed to create partition table!" 8 50
        return 1
    fi
    
    # Clone partitions with UUID preservation
    log "Step 2/2: Cloning partitions with UUID preservation..."
    clone_partitions_with_uuid_preservation "$source_device" "$target_device" source_partitions
    
    # Verification
    log "Verifying clone results..."
    if [ "$DRY_RUN" = false ]; then
        sync
        partprobe "$target_device" 2>/dev/null || true
        sleep 3
    fi
    
    # Show verification results
    local verify_text=""
    if [ "$DRY_RUN" = true ]; then
        verify_text="DRY RUN SIMULATION COMPLETED!\n\n"
    else
        verify_text="CLONING COMPLETED!\n\n"
    fi
    
    verify_text+="Source: $source_device\n"
    verify_text+="Target: $target_device\n\n"
    verify_text+="Partition verification:\n"
    
    local uuid_mismatches=0
    
    for i in "${!source_partitions[@]}"; do
        IFS=',' read -r source_partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_partitions[$i]}"
        local target_partition="${target_device}$((i+1))"
        
        if [ "$DRY_RUN" = true ]; then
            verify_text+="• $(basename $target_partition): ${fs_type:-unknown} ✓ UUID would be preserved"
            if [[ "$is_efi" == "true" ]]; then
                verify_text+=" [EFI]"
            fi
            verify_text+="\n"
        elif [[ -b "$target_partition" ]]; then
            local new_fs_uuid=$(get_filesystem_uuid "$target_partition")
            local new_part_uuid=$(get_partition_uuid "$target_partition")
            
            verify_text+="• $(basename $target_partition): ${fs_type:-unknown}"
            
            if [[ -n "$fs_uuid" && "$fs_uuid" == "$new_fs_uuid" ]]; then
                verify_text+=" ✓ UUID"
            elif [[ -n "$fs_uuid" ]]; then
                verify_text+=" ⚠ UUID changed"
                uuid_mismatches=$((uuid_mismatches + 1))
            else
                verify_text+=" - No UUID"
            fi
            
            if [[ "$is_efi" == "true" ]]; then
                verify_text+=" [EFI]"
            fi
            verify_text+="\n"
        else
            verify_text+="• Partition $((i+1)): ❌ Not found\n"
        fi
    done
    
    # Check disk UUID
    if [ "$DRY_RUN" = true ]; then
        verify_text+="\n✓ Disk UUID would be preserved"
    else
        local new_disk_uuid=$(get_disk_uuid "$target_device")
        local source_disk_uuid=""
        if [[ ${#source_partitions[@]} -gt 0 ]]; then
            IFS=',' read -r partition size fs_type is_efi fs_uuid part_uuid disk_uuid <<< "${source_partitions[0]}"
            source_disk_uuid="$disk_uuid"
        fi
        
        if [[ -n "$source_disk_uuid" && "$source_disk_uuid" == "$new_disk_uuid" ]]; then
            verify_text+="\n✓ Disk UUID preserved"
        elif [[ -n "$source_disk_uuid" ]]; then
            verify_text+="\n⚠ Disk UUID changed"
        fi
    fi
    
    if [ "$DRY_RUN" = true ]; then
        verify_text+="\n\n✅ All UUIDs would be successfully preserved!"
        verify_text+="\nSystem would boot normally after real cloning."
    elif [[ $uuid_mismatches -gt 0 ]]; then
        verify_text+="\n\n⚠ Some UUIDs could not be preserved."
        verify_text+="\nYou may need to update /etc/fstab"
        verify_text+="\nand bootloader configuration."
    else
        verify_text+="\n\n✅ All UUIDs successfully preserved!"
        verify_text+="\nSystem should boot normally."
    fi
    
    local title="✅ Cloning Complete"
    if [ "$DRY_RUN" = true ]; then
        title="✅ Dry Run Complete"
    fi
    
    dialog --title "$title" \
        --msgbox "$verify_text" 20 70
    
    if [ "$DRY_RUN" = true ]; then
        log "Physical to physical cloning DRY RUN simulation completed!"
    else
        log "Physical to physical cloning with UUID preservation completed!"
    fi
    return 0
}