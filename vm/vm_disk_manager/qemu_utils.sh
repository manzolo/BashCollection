# Detect file format automatically
detect_file_format() {
    local file=$1
    local file_format="raw"
    
    if command -v file &> /dev/null; then
        local file_info=$(file "$file" 2>/dev/null)
        if [[ "$file_info" == *"QEMU QCOW"* ]]; then
            file_format="qcow2"
        elif [[ "$file_info" == *"DOS/MBR boot sector"* ]]; then
            file_format="raw"
        fi
    fi
    
    # Alternative detection by extension (more reliable)
    case "${file,,}" in
        *.qcow2|*.qcow)
            file_format="qcow2"
            ;;
        *.img|*.raw)
            file_format="raw"
            ;;
        *.vdi)
            file_format="vdi"
            ;;
        *.vmdk)
            file_format="vmdk"
            ;;
    esac
    
    echo "$file_format"
}

# Check KVM availability
check_kvm_support() {
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo "-enable-kvm"
        log "KVM acceleration available and enabled" >> "$LOG_FILE"
        return 0
    else
        log "KVM acceleration not available, using software emulation" >> "$LOG_FILE"
        whiptail --msgbox "Warning: KVM acceleration not available.\nVM will be slower." 8 50
        echo ""
        return 1
    fi
}

# Find OVMF firmware files
find_ovmf_firmware() {
    local ovmf_code=""
    local ovmf_vars=""
    
    if [ -f "/usr/share/OVMF/OVMF_CODE.fd" ]; then
        ovmf_code="/usr/share/OVMF/OVMF_CODE.fd"
        ovmf_vars="/usr/share/OVMF/OVMF_VARS.fd"
    elif [ -f "/usr/share/ovmf/OVMF.fd" ]; then
        ovmf_code="/usr/share/ovmf/OVMF.fd"
    elif [ -f "/usr/share/edk2-ovmf/OVMF_CODE.fd" ]; then
        ovmf_code="/usr/share/edk2-ovmf/OVMF_CODE.fd"
        ovmf_vars="/usr/share/edk2-ovmf/OVMF_VARS.fd"
    fi
    
    if [ -z "$ovmf_code" ]; then
        return 1
    fi
    
    echo "$ovmf_code|$ovmf_vars"
    return 0
}

# Setup network configuration
setup_network_args() {
    local network_mode=$1
    local net_args=()
    
    case "$network_mode" in
        "user")
            # User mode networking (NAT) with virtio-net and e1000 fallback
            net_args=(-netdev "user,id=net0,hostfwd=tcp::2222-:22" -device "virtio-net,netdev=net0,mac=52:54:00:12:34:56")
            net_args+=(-netdev "user,id=net1,hostfwd=tcp::2223-:22" -device "e1000,netdev=net1,mac=52:54:00:12:34:57")
            log "Configured user-mode networking: virtio-net (net0) and e1000 (net1)" >> "$LOG_FILE"
            ;;
        "bridge")
            # Bridge networking (requires setup)
            if command -v brctl &> /dev/null && brctl show | grep -q br0; then
                net_args=(-netdev "bridge,id=net0,br=br0" -device "virtio-net,netdev=net0,mac=52:54:00:12:34:56")
                net_args+=(-netdev "bridge,id=net1,br=br0" -device "e1000,netdev=net1,mac=52:54:00:12:34:57")
                log "Configured bridge networking: virtio-net (net0) and e1000 (net1)" >> "$LOG_FILE"
            else
                log "Bridge br0 not found, falling back to user networking" >> "$LOG_FILE"
                net_args=(-netdev "user,id=net0,hostfwd=tcp::2222-:22" -device "virtio-net,netdev=net0,mac=52:54:00:12:34:56")
                net_args+=(-netdev "user,id=net1,hostfwd=tcp::2223-:22" -device "e1000,netdev=net1,mac=52:54:00:12:34:57")
                log "Falling back to user-mode networking: virtio-net (net0) and e1000 (net1)" >> "$LOG_FILE"
            fi
            ;;
        "tap")
            # TAP networking (advanced)
            if ip link show tap0 &>/dev/null; then
                net_args=(-netdev "tap,id=net0,ifname=tap0,script=no,downscript=no" -device "virtio-net,netdev=net0,mac=52:54:00:12:34:56")
                net_args+=(-netdev "tap,id=net1,ifname=tap0,script=no,downscript=no" -device "e1000,netdev=net1,mac=52:54:00:12:34:57")
                log "Configured TAP networking: virtio-net (net0) and e1000 (net1)" >> "$LOG_FILE"
            else
                log "TAP interface tap0 not found, falling back to user networking" >> "$LOG_FILE"
                net_args=(-netdev "user,id=net0,hostfwd=tcp::2222-:22" -device "virtio-net,netdev=net0,mac=52:54:00:12:34:56")
                net_args+=(-netdev "user,id=net1,hostfwd=tcp::2223-:22" -device "e1000,netdev=net1,mac=52:54:00:12:34:57")
                log "Falling back to user-mode networking: virtio-net (net0) and e1000 (net1)" >> "$LOG_FILE"
            fi
            ;;
        "none")
            # No networking
            net_args=()
            log "No networking configured" >> "$LOG_FILE"
            ;;
        *)
            # Default to user networking
            net_args=(-netdev "user,id=net0,hostfwd=tcp::2222-:22" -device "virtio-net,netdev=net0,mac=52:54:00:12:34:56")
            net_args+=(-netdev "user,id=net1,hostfwd=tcp::2223-:22" -device "e1000,netdev=net1,mac=52:54:00:12:34:57")
            log "Defaulted to user-mode networking: virtio-net (net0) and e1000 (net1)" >> "$LOG_FILE"
            ;;
    esac
    
    echo "${net_args[@]}"
}

# Configure MBR/Legacy boot
configure_mbr_boot() {
    local file=$1
    local file_format=$2
    local kvm_option=$3
    local memory=${4:-2048}
    local network_mode=${5:-user}
    local audio_enabled=${6:-yes}
    
    local qemu_args=()
    local net_args=($(setup_network_args "$network_mode"))
    
    qemu_args=(-drive "file=$file,format=$file_format,if=virtio,cache=writeback"
               -m "$memory"
               $kvm_option
               -machine "pc-i440fx-4.2"
               -cpu "host"
               -smp "2,cores=2,threads=1"
               -vga "virtio"
               -display "gtk,show-cursor=on"
               -boot "order=c,menu=on"
               -monitor "vc"
               -serial "file:/tmp/qemu-serial-$$.log"
               -usb -device "usb-tablet"
               "${net_args[@]}")
    
    if [ "$audio_enabled" = "yes" ]; then
        qemu_args+=(-device "intel-hda" -device "hda-duplex")
        log "Audio enabled: intel-hda with hda-duplex" >> "$LOG_FILE"
    else
        log "Audio disabled" >> "$LOG_FILE"
    fi
    
    log "MBR boot configuration: file=$file, format=$file_format, memory=$memory, network=$network_mode, audio=$audio_enabled" >> "$LOG_FILE"
    echo "${qemu_args[@]}"
}

# Configure UEFI/EFI boot
configure_uefi_boot() {
    local file=$1
    local file_format=$2
    local kvm_option=$3
    local memory=${4:-2048}
    local network_mode=${5:-user}
    local audio_enabled=${6:-yes}
    
    local ovmf_info=$(find_ovmf_firmware)
    if [ $? -ne 0 ]; then
        whiptail --msgbox "OVMF firmware not found.\nPlease install the 'ovmf' package with:\nsudo apt install ovmf" 12 70
        return 1
    fi
    
    local ovmf_code="${ovmf_info%|*}"
    local ovmf_vars="${ovmf_info#*|}"
    local qemu_args=()
    local net_args=($(setup_network_args "$network_mode"))
    
    qemu_args=(-drive "file=$file,format=$file_format,if=virtio,cache=writeback"
               -m "$memory"
               $kvm_option
               -machine "q35"
               -cpu "host"
               -smp "$([ "$memory" -gt 2048 ] && echo 4 || echo 2)"
               -vga "virtio"
               -display "gtk,show-cursor=on"
               -boot "order=c,menu=on"
               -monitor "vc"
               -serial "file:/tmp/qemu-serial-$$.log"
               -usb -device "usb-tablet"
               "${net_args[@]}")
    
    if [ -n "$ovmf_vars" ] && [ "$ovmf_vars" != "$ovmf_code" ]; then
        # Use separate CODE and VARS (more modern approach)
        local temp_vars="/tmp/OVMF_VARS_$$.fd"
        cp "$ovmf_vars" "$temp_vars"
        qemu_args+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
                   -drive "if=pflash,format=raw,file=$temp_vars")
    else
        # Use single OVMF file (legacy approach)
        qemu_args+=(-bios "$ovmf_code")
    fi
    
    if [ "$audio_enabled" = "yes" ]; then
        qemu_args+=(-device "intel-hda" -device "hda-duplex")
        log "Audio enabled: intel-hda with hda-duplex" >> "$LOG_FILE"
    else
        log "Audio disabled" >> "$LOG_FILE"
    fi
    
    log "UEFI boot configuration: file=$file, format=$file_format, memory=$memory, network=$network_mode, audio=$audio_enabled" >> "$LOG_FILE"
    echo "${qemu_args[@]}"
    return 0
}

# Configure headless boot
configure_headless_boot() {
    local file=$1
    local file_format=$2
    local kvm_option=$3
    local memory=${4:-1024}
    local network_mode=${5:-user}
    
    local net_args=($(setup_network_args "$network_mode"))
    local qemu_args=()
    
    qemu_args=(-drive "file=$file,format=$file_format,if=virtio,cache=writeback"
               -m "$memory"
               $kvm_option
               -machine "pc-i440fx-4.2"
               -cpu "host"
               -smp "2"
               -nographic
               -serial "stdio"
               -monitor "telnet:127.0.0.1:4444,server,nowait"
               "${net_args[@]}")
    
    log "Headless boot configuration: file=$file, format=$file_format, memory=$memory, network=$network_mode, audio=disabled" >> "$LOG_FILE"
    echo "${qemu_args[@]}"
}

# Configure debug boot
configure_debug_boot() {
    local file=$1
    local file_format=$2
    local kvm_option=$3
    local memory=${4:-2048}
    local network_mode=${5:-user}
    local audio_enabled=${6:-yes}
    
    local net_args=($(setup_network_args "$network_mode"))
    local qemu_args=()
    
    qemu_args=(-drive "file=$file,format=$file_format,if=virtio,cache=writeback"
               -m "$memory"
               $kvm_option
               -machine "q35"
               -cpu "host"
               -smp "2"
               -vga "virtio"
               -display "gtk,show-cursor=on"
               -monitor "vc"
               -serial "file:/tmp/qemu-debug-$$.log"
               -d "guest_errors,unimp,trace:virtio*"
               -D "/tmp/qemu-trace-$$.log"
               -no-reboot
               "${net_args[@]}")
    
    if [ "$audio_enabled" = "yes" ]; then
        qemu_args+=(-device "intel-hda" -device "hda-duplex")
        log "Audio enabled: intel-hda with hda-duplex" >> "$LOG_FILE"
    else
        log "Audio disabled" >> "$LOG_FILE"
    fi
    
    log "Debug boot configuration: file=$file, format=$file_format, memory=$memory, network=$network_mode, audio=$audio_enabled" >> "$LOG_FILE"
    echo "${qemu_args[@]}"
}

# Get user preferences for advanced options
get_user_preferences() {
    local default_memory=$1
    local default_network="user"
    local default_audio="yes"
    
    # Memory selection
    local memory_options=(
        "1024" "1 GB RAM"
        "2048" "2 GB RAM"
        "4096" "4 GB RAM"
        "8192" "8 GB RAM"
    )
    
    local memory=$(whiptail --title "Memory Configuration" --menu "Select RAM amount:" 12 50 4 "${memory_options[@]}" --default-item "$default_memory" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        return 1  # User cancelled, exit function with error
    fi
    
    # Network selection
    local network_options=(
        "user" "User Mode (NAT) - Default"
        "bridge" "Bridge Mode (if configured)"
        "tap" "TAP Mode (advanced)"
        "none" "No Network"
    )
    
    local network=$(whiptail --title "Network Configuration" --menu "Select networking:" 12 60 4 "${network_options[@]}" --default-item "$default_network" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        return 1  # User cancelled, exit function with error
    fi
    
    # Audio selection
    local audio_options=(
        "yes" "Enable Audio (Intel HDA)"
        "no" "Disable Audio"
    )
    
    local audio=$(whiptail --title "Audio Configuration" --menu "Select audio option:" 10 50 2 "${audio_options[@]}" --default-item "$default_audio" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        return 1  # User cancelled, exit function with error
    fi
    
    echo "$memory|$network|$audio"
    return 0
}