select_physical_device() {
    local label="${1:-}"
    local exclude_device="${2:-}"

    log "Scanning physical devices..."

    local devices=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            local name
            name=$(echo "$line" | awk '{print $1}')
            local size
            size=$(echo "$line" | awk '{print $2}')
            local model
            model=$(echo "$line" | cut -d' ' -f3-)

            # Skip excluded device
            if [ -n "$exclude_device" ] && [ "/dev/$name" = "$exclude_device" ]; then
                continue
            fi

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
            model_short=$(echo "$model" | cut -c1-32)
            local item
            item=$(printf "%-7s  %-32s  %-9s  %-20s  %s" \
                "$size" "$model_short" "${disk_type}/${tran_upper}" "S/N:${serial}" "$status_info")
            devices+=("/dev/$name" "$item")
        fi
    done < <(lsblk -dn -o NAME,SIZE,MODEL | grep -E '^sd|^nvme|^vd')

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

    local header
    header=$(printf "%-7s  %-32s  %-9s  %-20s  %s" "SIZE" "MODEL" "TYPE" "SERIAL" "PARTITIONS")

    local selected
    selected=$(dialog --clear --title "$title" \
        --menu "$prompt\n$header" 22 115 12 \
        "${devices[@]}" \
        3>&1 1>&2 2>&3)

    if [ $? -eq 0 ] && [ -n "$selected" ]; then
        echo "$selected"
        return 0
    fi
    return 1
}
