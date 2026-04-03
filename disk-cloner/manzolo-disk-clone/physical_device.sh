select_physical_device() {
    local label="${1:-}"
    local exclude_device="${2:-}"

    log "Scanning physical devices..."

    local -a devices=()
    local -a device_paths=()
    local idx=0

    while IFS= read -r name; do
        [ -z "$name" ] && continue

        # Skip excluded device
        if [ -n "$exclude_device" ] && [ "/dev/$name" = "$exclude_device" ]; then
            continue
        fi

        # Get each field via dedicated lsblk call to avoid column-parsing issues
        local size
        size=$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null | tr -d ' ')
        local model
        model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Disk type: SSD or HDD
        local rota
        rota=$(lsblk -dn -o ROTA "/dev/$name" 2>/dev/null | tr -d ' ')
        local disk_type="HDD"
        [ "$rota" = "0" ] && disk_type="SSD"

        # Transport: sata, nvme, usb, ...
        local tran
        tran=$(lsblk -dn -o TRAN "/dev/$name" 2>/dev/null | tr -d ' ')
        [ -z "$tran" ] && tran="?"
        local tran_upper
        tran_upper=$(echo "$tran" | tr '[:lower:]' '[:upper:]')

        # Serial number: try lsblk first, then udevadm
        local serial
        serial=$(lsblk -dn -o SERIAL "/dev/$name" 2>/dev/null | tr -d ' ')
        if [ -z "$serial" ]; then
            serial=$(udevadm info -q property -n "/dev/$name" 2>/dev/null \
                     | grep -E "^ID_SERIAL_SHORT=" | cut -d= -f2)
        fi
        [ -z "$serial" ] && serial="N/A"

        # Partition count and filesystem types
        local part_count
        part_count=$(lsblk -lno NAME "/dev/$name" 2>/dev/null | tail -n +2 | wc -l)
        local fs_list
        fs_list=$(lsblk -lno FSTYPE "/dev/$name" 2>/dev/null \
                  | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')

        local status_info
        if [ "$part_count" -eq 0 ] || [ -z "$fs_list" ]; then
            status_info="EMPTY"
        else
            status_info="${part_count}p: ${fs_list}"
        fi

        local model_short
        model_short=$(printf "%.30s" "$model")
        local serial_short
        serial_short=$(printf "%.18s" "$serial")

        # Device name is included in the item text (fixed width) so that the
        # header format string can be identical, guaranteeing column alignment.
        local item
        item=$(printf "%-12s │ %-7s │ %-30s │ %-9s │ %-18s │ %s" \
            "/dev/$name" "$size" "$model_short" "${disk_type}/${tran_upper}" "$serial_short" "$status_info")

        devices+=("$idx" "$item")
        device_paths+=("/dev/$name")
        idx=$((idx + 1))
    done < <(lsblk -dn -o NAME 2>/dev/null | grep -E '^(sd|nvme|vd)')

    if [ ${#devices[@]} -eq 0 ]; then
        dialog --title "Error" --msgbox "No physical devices found!" 8 50
        return 1
    fi

    # Build dialog title and prompt
    local title="Select Physical Device"
    local prompt="Select the device:"
    if [ -n "$label" ]; then
        title="Select ${label} device"
        prompt="Select the ${label} device:"
        if [ -n "$exclude_device" ]; then
            prompt="Select the ${label} device  (${exclude_device} already used as source):"
        fi
    fi

    # Header format is identical to item format; only prefix differs.
    # dialog renders menu items as "  N  [item]" (2 + 1-digit tag + 2 spaces = 5 chars).
    # The prompt text area has 1 char of left margin, so net offset = 5 - 1 = 4 spaces.
    local header
    header=$(printf "%3s%-12s │ %-7s │ %-30s │ %-9s │ %-18s │ %s" \
        "" "DEVICE" "SIZE" "MODEL" "TYPE" "SERIAL" "PARTITIONS")

    local selected_idx
    selected_idx=$(dialog --clear --title "$title" \
        --menu "$prompt\n$header" 22 120 12 \
        "${devices[@]}" \
        3>&1 1>&2 2>&3)

    if [ $? -eq 0 ] && [ -n "$selected_idx" ]; then
        echo "${device_paths[$selected_idx]}"
        return 0
    fi
    return 1
}
