# shellcheck shell=bash
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

# --- Media type (USB disk vs. USB CD-ROM) ----------------------------------
# A plain ISO 9660 image has no partition table, so attached as a USB *disk*
# neither SeaBIOS nor OVMF find anything to boot. Such images are attached as
# a USB CD-ROM instead (El Torito boot). Hybrid ISOs (isohybrid, xorriso
# -isohybrid-mbr: ISO 9660 *plus* an MBR/GPT) keep being tested as a disk,
# which is what happens when they are dd'd onto a USB stick.

# Read LEN bytes at OFFSET of FILE as a lowercase hex string (no separators).
_read_hex() {
    od -An -tx1 -v -j "$2" -N "$3" "$1" 2>/dev/null | tr -d ' \n'
}

# True when the file carries an ISO 9660 primary volume descriptor.
is_iso9660() {
    [[ "$(_read_hex "$1" 32769 5)" == "4344303031" ]]   # "CD001" at sector 16
}

# True when sector 0 ends with the 0x55AA MBR boot signature (MBR or
# protective-MBR GPT layouts; also what makes an ISO "hybrid").
has_mbr_signature() {
    [[ "$(_read_hex "$1" 510 2)" == "55aa" ]]
}

# El Torito platform id -> name (other ids, e.g. 01 PowerPC, 02 Mac, are ignored).
_eltorito_platform_name() {
    case "$1" in
        00) echo "bios" ;;
        ef) echo "uefi" ;;
    esac
}

# Print the firmware platforms listed in the El Torito boot catalog of an
# ISO 9660 image, one per line ("bios", "uefi"). Prints nothing when the
# image has no boot catalog.
iso_boot_platforms() {
    local iso="$1"
    # Boot Record Volume Descriptor (sector 17): type 0, "CD001", then
    # "EL TORITO SPECIFICATION" at byte 7 and the catalog LBA (LE32) at 0x47.
    local brvd
    brvd=$(_read_hex "$iso" $((17 * 2048)) 6)
    [[ "$brvd" == "004344303031" ]] || return 0
    local sysid
    sysid=$(_read_hex "$iso" $((17 * 2048 + 7)) 23)
    [[ "$sysid" == "454c20544f5249544f2053504543494649434154494f4e" ]] || return 0   # "EL TORITO SPECIFICATION"
    local lba_hex lba
    lba_hex=$(_read_hex "$iso" $((17 * 2048 + 0x47)) 4)
    [[ ${#lba_hex} -eq 8 ]] || return 0
    lba=$(( 0x${lba_hex:6:2}${lba_hex:4:2}${lba_hex:2:2}${lba_hex:0:2} ))
    (( lba > 0 )) || return 0

    local catalog
    catalog=$(_read_hex "$iso" $((lba * 2048)) 2048)
    # Validation entry: header id 01, platform id, ..., key bytes 55 AA.
    [[ "${catalog:0:2}" == "01" && "${catalog:60:4}" == "55aa" ]] || return 0

    _eltorito_platform_name "${catalog:2:2}"
    # Section headers (0x90 more follow, 0x91 final) carry their own platform.
    local i id
    for (( i = 64; i < ${#catalog}; i += 64 )); do
        id="${catalog:$i:2}"
        [[ "$id" == "90" || "$id" == "91" ]] || continue
        _eltorito_platform_name "${catalog:$((i + 2)):2}"
    done
}

# Print "disk" or "cdrom" for the target: a regular file that is ISO 9660
# without any partition table is a CD-ROM, everything else is a disk.
detect_media_type() {
    local target="$1"
    if [[ -f "$target" ]] && is_iso9660 "$target" && ! has_mbr_signature "$target"; then
        echo "cdrom"
    else
        echo "disk"
    fi
}

# Recompute the effective MEDIA from MEDIA_MODE (auto|disk|cdrom) and the
# current DISK/FORMAT. Only raw images can be ISO 9660.
# shellcheck disable=SC2034  # MEDIA is consumed by build_qemu_command in qemu.sh
refresh_media_type() {
    case "$MEDIA_MODE" in
        disk|cdrom) MEDIA="$MEDIA_MODE" ;;
        *)
            if [[ -n "$DISK" && "$FORMAT" == "raw" ]]; then
                MEDIA=$(detect_media_type "$DISK")
            else
                MEDIA="disk"
            fi
            ;;
    esac
}

# Guess the boot mode a target supports and say why. Prints "MODE REASON":
# MODE is "uefi" or "bios", REASON a short human-readable explanation.
# Returns 1 (with MODE=uefi) when nothing could be determined.
#
# Partitioned media: look for an EFI System Partition, not merely at the
# partition table type — Ventoy (and many hybrid installers) use an MBR table
# *with* an ESP and boot fine in UEFI. Plain ISO 9660 images: read the
# El Torito boot catalog. Works on block devices and on image files.
detect_boot_mode() {
    local target="$1"
    local table

    if [[ -f "$target" ]] && is_iso9660 "$target" && ! has_mbr_signature "$target"; then
        local platforms
        platforms=$(iso_boot_platforms "$target")
        if [[ "$platforms" == *uefi* && "$platforms" == *bios* ]]; then
            echo "uefi ISO 9660, El Torito UEFI+BIOS boot entries"
            return 0
        elif [[ "$platforms" == *uefi* ]]; then
            echo "uefi ISO 9660, El Torito UEFI boot entry only"
            return 0
        elif [[ "$platforms" == *bios* ]]; then
            echo "bios ISO 9660, El Torito BIOS boot entry only"
            return 0
        fi
        echo "uefi ISO 9660 without El Torito boot catalog, defaulting to uefi"
        return 1
    fi

    command -v fdisk >/dev/null 2>&1 || { echo "uefi fdisk not available, defaulting to uefi"; return 1; }
    table=$(fdisk -l "$target" 2>/dev/null) || table=""
    [[ -n "$table" ]] || { echo "uefi no partition table, defaulting to uefi"; return 1; }

    # fdisk labels the ESP "EFI System" on GPT and "EFI (FAT-12/16/32)" on MBR.
    if grep -qiE 'EFI (System|\(FAT)' <<< "$table"; then
        echo "uefi EFI System Partition found"
        return 0
    fi
    if grep -q 'Disklabel type: gpt' <<< "$table"; then
        # GPT without an ESP: firmware may still boot it via a fallback path,
        # but there is nothing for legacy BIOS to chain-load either.
        echo "uefi GPT table without EFI System Partition"
        return 0
    fi
    if grep -q 'Disklabel type: dos' <<< "$table"; then
        echo "bios MBR table, no EFI System Partition"
        return 0
    fi
    # No partition table at all (unpartitioned image).
    echo "uefi no partition table, defaulting to uefi"
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
