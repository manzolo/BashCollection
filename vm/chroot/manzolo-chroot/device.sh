get_devices() {
    debug "Detecting available devices"
    local devices
    devices=$(lsblk -rno NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | \
        awk '$2 == "part" && $4 != "swap" {
            fstype = ($4 == "") ? "unknown" : $4
            mp = ($5 == "" || $5 == "[SWAP]") ? "unmounted" : $5
            if (fstype != "swap") {
                if (fstype == "crypto_LUKS" || fstype == "LUKS") {
                    print "/dev/"$1" "$3" LUKS-encrypted "mp
                } else {
                    print "/dev/"$1" "$3" "fstype" "mp
                }
            }
        }')
    
    if [[ -z "$devices" ]]; then
        error "No suitable devices found"
        return 1
    fi
    
    echo "$devices"
}

select_device() {
    local device_type="$1"
    local allow_skip="$2"
    
    if [[ "$QUIET_MODE" == true ]]; then
        return 0
    fi
    
    debug "Selecting $device_type device" >&2
    
    local devices
    devices=$(get_devices)
    
    if [[ -z "$devices" ]]; then
        error "No devices found for selection"
        return 1
    fi
    
    local options=()
    while IFS= read -r device; do
        if [[ -n "$device" ]]; then
            local dev_name size fstype mountpoint
            read -r dev_name size fstype mountpoint <<< "$device"
            options+=("$dev_name" "$size $fstype ($mountpoint)")
        fi
    done <<< "$devices"
    
    if [[ "$allow_skip" == true ]]; then
        options+=("None" "Skip this mount")
    fi
    
    if [[ ${#options[@]} -eq 0 ]]; then
        error "No devices available for selection"
        return 1
    fi
    
    local selected
    if selected=$(dialog --title "Select $device_type Device" \
                        --menu "Choose $device_type device:" \
                        20 80 10 \
                        "${options[@]}" \
                        3>&1 1>&2 2>&3); then
        if [[ -z "$selected" ]] || [[ "$selected" == "None" ]]; then
            debug "$device_type device selection: None/Skip" >&2
            return 1
        fi
        debug "$device_type device selected: $selected" >&2
        echo "$selected"
        return 0
    else
        error "Device selection cancelled"
        return 1
    fi
}

detect_and_handle_luks() {
    local device="$1"
    local result_var="$2"  # Nome della variabile dove mettere il risultato
    
    debug "=== LUKS Detection for $device ==="
    
    # Log del comando blkid
    debug "Checking filesystem type with: blkid -o value -s TYPE $device"
    local fs_type=$(run_with_privileges blkid -o value -s TYPE "$device" 2>/dev/null || echo "unknown")
    debug "Filesystem type result: '$fs_type'"
    
    if [[ "$fs_type" == "crypto_LUKS" ]] || [[ "$fs_type" == "LUKS" ]]; then
        log "LUKS partition detected: $device"
        
        # Generate unique mapping name
        local mapping_name="luks_$(basename $device)_$(date +%s)"
        log "Generated mapping name: $mapping_name"
        
        log "Opening LUKS partition $device as /dev/mapper/$mapping_name"
        debug "Command: cryptsetup luksOpen $device $mapping_name"
        
        # Try to open LUKS partition
        if run_with_privileges cryptsetup luksOpen "$device" "$mapping_name" >/dev/null 2>&1; then
            
            # Aggiungere all'array GLOBALE (ora dovrebbe funzionare)
            LUKS_MAPPINGS+=("$mapping_name")
            debug "Added $mapping_name to LUKS_MAPPINGS array"
            debug "LUKS_MAPPINGS now contains: ${LUKS_MAPPINGS[*]}"
            
            log "LUKS partition opened successfully: /dev/mapper/$mapping_name"
            
            # Wait for device to be ready
            debug "Waiting for mapped device to be ready..."
            sleep 2
            
            # Verify the mapped device exists and is accessible
            local mapped_device="/dev/mapper/$mapping_name"
            debug "Verifying mapped device: $mapped_device"
            
            if [[ -b "$mapped_device" ]]; then
                log "Mapped device verified: $mapped_device"
                
                # Check what filesystem is inside
                debug "Checking inner filesystem with: blkid -o value -s TYPE $mapped_device"
                local inner_fs=$(run_with_privileges blkid -o value -s TYPE "$mapped_device" 2>/dev/null || echo "unknown")
                log "Filesystem inside LUKS: $inner_fs"
                
                # If it's LVM, handle it
                if [[ "$inner_fs" == "LVM2_member" ]]; then
                    log "LVM detected inside LUKS, activating volume groups"
                    
                    # Scan for LVM with full logging
                    debug "Running: pvscan --cache"
                    run_with_privileges pvscan --cache >/dev/null 2>&1 || true
                    
                    debug "Running: vgscan --mknodes"
                    run_with_privileges vgscan --mknodes >/dev/null 2>&1 || true
                    
                    # Find VGs on this PV
                    debug "Finding VGs with: pvs --noheadings -o vg_name $mapped_device"
                    local vgs
                    vgs=$(run_with_privileges pvs --noheadings -o vg_name "$mapped_device" 2>/dev/null | awk '{print $1}' | sort -u || true)
                    debug "Found VGs: '$vgs'"
                    
                    if [[ -n "$vgs" ]]; then
                        while read -r vg; do
                            [[ -z "$vg" ]] && continue
                            log "Activating VG: $vg"
                            debug "Command: vgchange -ay $vg"
                            
                            if run_with_privileges vgchange -ay "$vg" >/dev/null 2>&1; then
                                # Aggiungere VG all'array GLOBALE
                                ACTIVATED_VGS+=("$vg")
                                debug "Added $vg to ACTIVATED_VGS array"
                                debug "ACTIVATED_VGS now contains: ${ACTIVATED_VGS[*]}"
                                
                                debug "VG activated successfully: $vg"
                                
                                # Find root LV in this VG
                                debug "Finding LVs with: lvs --noheadings -o lv_path $vg"
                                local all_lvs
                                all_lvs=$(run_with_privileges lvs --noheadings -o lv_path "$vg" 2>/dev/null | awk '{print $1}' || true)
                                debug "All LVs in $vg: $all_lvs"
                                
                                # Try to find root-like LV
                                local root_lv
                                root_lv=$(echo "$all_lvs" | grep -E "(root|system|ubuntu)" | head -1 || echo "$all_lvs" | head -1 || true)
                                
                                if [[ -n "$root_lv" ]]; then
                                    log "Selected root LV: $root_lv"
                                    debug "Setting result variable $result_var to: $root_lv"
                                    eval "$result_var='$root_lv'"
                                    return 0
                                else
                                    debug "No suitable LV found in VG: $vg"
                                fi
                            else
                                error "Failed to activate VG: $vg"
                            fi
                        done <<< "$vgs"
                    else
                        debug "No VGs found on $mapped_device"
                    fi
                    
                    error "No suitable logical volume found after LVM activation"
                    return 1
                else
                    # Direct filesystem in LUKS
                    debug "Direct filesystem in LUKS, setting result variable $result_var to: $mapped_device"
                    eval "$result_var='$mapped_device'"
                    return 0
                fi
            else
                error "Mapped device not accessible: $mapped_device"
                debug "Device check failed for: $mapped_device"
                return 1
            fi
        else
            error "Failed to open LUKS partition: $device"
            return 1
        fi
    else
        # Not a LUKS partition, return original device
        debug "$device is not LUKS (type: $fs_type), setting result variable $result_var to original"
        eval "$result_var='$device'"
        return 0
    fi
}


show_luks_info() {
    local device="$1"
    
    if command -v cryptsetup &> /dev/null; then
        local fs_type=$(sudo blkid -o value -s TYPE "$device" 2>/dev/null || echo "unknown")
        
        if [[ "$fs_type" == "crypto_LUKS" ]] || [[ "$fs_type" == "LUKS" ]]; then
            local uuid=$(sudo blkid -o value -s UUID "$device" 2>/dev/null || echo "unknown")
            echo "  LUKS Partition: $device (UUID: $uuid)"
            
            # Show LUKS header info if available
            if sudo cryptsetup luksDump "$device" >/dev/null 2>&1; then
                local version=$(sudo cryptsetup luksDump "$device" | grep "Version:" | awk '{print $2}' || echo "unknown")
                echo "    LUKS Version: $version"
            fi
            return 0
        fi
    fi
    return 1
}

verify_luks_device() {
    local mapped_device="$1"
    
    log "Verifying LUKS mapped device: $mapped_device"

    # Verifica esistenza
    if [[ ! -b "$mapped_device" ]]; then
        error "Mapped device does not exist: $mapped_device"
        return 1
    fi
    
    # Verifica leggibilità
    if ! sudo dd if="$mapped_device" of=/dev/null bs=512 count=1 2>/dev/null; then
        error "Cannot read from mapped device: $mapped_device"
        return 1
    fi
    
    # Verifica filesystem
    local fs_type=$(sudo blkid -o value -s TYPE "$mapped_device" 2>/dev/null || echo "unknown")
    if [[ "$fs_type" == "unknown" ]] || [[ -z "$fs_type" ]]; then
        warning "Cannot determine filesystem type on $mapped_device"
        # Proviamo con file command
        local file_type=$(sudo file -s "$mapped_device" 2>/dev/null || echo "")
        log "File command output: $file_type"
    else
        log "Filesystem type: $fs_type"
    fi
    
    return 0
}