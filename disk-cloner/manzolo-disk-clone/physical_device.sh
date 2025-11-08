select_physical_device() {
    log "Scanning physical devices..."
    
    local devices=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local name=$(echo "$line" | awk '{print $1}')
            local size=$(echo "$line" | awk '{print $2}')
            local model=$(echo "$line" | cut -d' ' -f3-)
            devices+=("/dev/$name" "$size - $model")
        fi
    done < <(lsblk -dn -o NAME,SIZE,MODEL | grep -E '^sd|^nvme|^vd')
    
    if [ ${#devices[@]} -eq 0 ]; then
        dialog --title "Error" --msgbox "No physical devices found!" 8 50
        return 1
    fi
    
    local selected
    selected=$(dialog --clear --title "Select Physical Device" \
        --menu "Select the device:" 20 70 10 \
        "${devices[@]}" \
        3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        echo "$selected"
        return 0
    fi
    return 1
}