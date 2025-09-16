get_devices() {
    debug "Detecting available devices"
    local devices
    devices=$(lsblk -rno NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null | \
        awk '$2 == "part" && $4 != "swap" {
            fstype = ($4 == "") ? "unknown" : $4
            mp = ($5 == "" || $5 == "[SWAP]") ? "unmounted" : $5
            if (fstype != "swap") print "/dev/"$1" "$3" "fstype" "mp
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