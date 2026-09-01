# Device, boot-mode and hardware detection.

# Detect removable / USB block devices and emit a whiptail menu item list
# (tag, description pairs), followed by the BROWSE and CUSTOM entries.
detect_usb_devices() {
    local devices=()
    local all_disks_info

    # Use lsblk with JSON output for better processing
    all_disks_info=$(lsblk -d -J -o NAME,SIZE,HOTPLUG,RM,TYPE,LABEL,TRAN 2>/dev/null | jq -c '.blockdevices[]' 2>/dev/null)

    # Handle case where lsblk or jq fails or no devices are found
    if [[ -z "$all_disks_info" ]]; then
        whiptail --title "Error" --msgbox "Unable to retrieve device list" 10 50 || true
        echo "BROWSE 'Browse image file (ISO/IMG)...'"
        echo "CUSTOM 'Custom path...'"
        return
    fi

    # Process each device
    while IFS= read -r disk; do
        local name size rm type label tran
        name=$(jq -r '.name' <<< "$disk" 2>/dev/null)
        size=$(jq -r '.size' <<< "$disk" 2>/dev/null)
        rm=$(jq -r '.rm' <<< "$disk" 2>/dev/null)
        type=$(jq -r '.type' <<< "$disk" 2>/dev/null)
        label=$(jq -r '.label' <<< "$disk" 2>/dev/null)
        tran=$(jq -r '.tran' <<< "$disk" 2>/dev/null)

        [[ -z "$name" ]] && continue

        local full_device="/dev/$name"
        local desc="$full_device ($size)"

        # Add device to list only if it is a removable USB disk
        if [[ "$type" == "disk" && ( "$rm" == "1" || "$rm" == "true" || "$tran" == "usb" ) ]]; then
            [[ -n "$label" && "$label" != "null" ]] && desc="$desc - $label"
            devices+=("$full_device" "$desc")
        fi
    done <<< "$all_disks_info"

    # Add standard options
    devices+=("BROWSE" "Browse image file (ISO/IMG)...")
    devices+=("CUSTOM" "Custom path...")

    # Handle case where no USB devices are detected
    if [[ ${#devices[@]} -eq 2 ]]; then  # Only BROWSE and CUSTOM
        whiptail --title "No USB Devices" --msgbox \
            "No USB devices detected. You can select an image file." 10 50 || true
    fi

    # Return array for whiptail
    printf '%s\n' "${devices[@]}"
}

# Guess the boot mode a target supports by looking for an EFI System
# Partition, not merely at the partition table type: Ventoy (and many
# hybrid installers) use an MBR table *with* an ESP and boot fine in UEFI.
# Works on block devices and on image files. Prints "uefi" or "bios";
# prints "uefi" and returns 1 when nothing could be determined.
detect_boot_mode() {
    local target="$1"
    local table

    command -v fdisk >/dev/null 2>&1 || { echo "uefi"; return 1; }
    table=$(fdisk -l "$target" 2>/dev/null) || table=""
    [[ -n "$table" ]] || { echo "uefi"; return 1; }

    # fdisk labels the ESP "EFI System" on GPT and "EFI (FAT-12/16/32)" on MBR.
    if grep -qiE 'EFI (System|\(FAT)' <<< "$table"; then
        echo "uefi"
        return 0
    fi
    if grep -q 'Disklabel type: gpt' <<< "$table"; then
        # GPT without an ESP: firmware may still boot it via a fallback path,
        # but there is nothing for legacy BIOS to chain-load either.
        echo "uefi"
        return 0
    fi
    if grep -q 'Disklabel type: dos' <<< "$table"; then
        echo "bios"
        return 0
    fi
    # No partition table at all (plain ISO, unpartitioned image).
    echo "uefi"
    return 1
}

# Show detailed hardware information
show_hardware_info() {
    local info=""

    # CPU Info
    local cpu_info cpu_cores cpu_freq
    cpu_info=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
    cpu_cores=$(nproc)
    cpu_freq=$(lscpu | grep "CPU max MHz" | cut -d: -f2 | xargs || echo "N/A")

    # Memory Info
    local mem_total mem_avail
    mem_total=$(free -h | awk '/^Mem:/{print $2}')
    mem_avail=$(free -h | awk '/^Mem:/{print $7}')

    # Storage Info
    local disk_info=""
    if [[ -n "$DISK" && -b "$DISK" ]]; then
        disk_info=$(lsblk -d -o MODEL,SIZE "$DISK" 2>/dev/null | tail -1 || echo "N/A")
    fi

    # Virtualization
    local virt_support="No"
    if grep -q "vmx\|svm" /proc/cpuinfo; then
        virt_support="Yes ($(grep -o "vmx\|svm" /proc/cpuinfo | head -1 | tr 'a-z' 'A-Z'))"
    fi

    info="SYSTEM HARDWARE INFORMATION\n\n"
    info+="CPU:\n  ${cpu_info}\n  Cores: ${cpu_cores}\n  Max Freq: ${cpu_freq} MHz\n\n"
    info+="MEMORY:\n  Total: ${mem_total}\n  Available: ${mem_avail}\n\n"
    info+="VIRTUALIZATION:\n  Support: ${virt_support}\n  KVM: $([[ -c /dev/kvm ]] && echo "Available" || echo "Not available")\n\n"

    if [[ -n "$disk_info" ]]; then
        info+="SELECTED DISK:\n  ${disk_info}\n\n"
    fi

    info+="QEMU:\n  Version: $(qemu-system-x86_64 --version | head -1 || echo "N/A")"

    whiptail --title "Hardware Information" --scrolltext \
        --msgbox "$info" 20 70 || true
}
