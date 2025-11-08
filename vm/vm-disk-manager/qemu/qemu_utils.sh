# Detect file format automatically
detect_file_format() {
    local file=$1
    # Chiama la nuova funzione unificata
    detect_format "$file"
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
    local searched_paths=()

    # Common OVMF paths across different distributions
    local ovmf_locations=(
        # Debian/Ubuntu
        "/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd"
        "/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd"
        # Debian/Ubuntu legacy
        "/usr/share/ovmf/OVMF.fd|"
        # Arch Linux
        "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd|/usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
        "/usr/share/edk2-ovmf/OVMF_CODE.fd|/usr/share/edk2-ovmf/OVMF_VARS.fd"
        # Fedora/RHEL
        "/usr/share/edk2/ovmf/OVMF_CODE.fd|/usr/share/edk2/ovmf/OVMF_VARS.fd"
        "/usr/share/OVMF/OVMF_CODE.secboot.fd|/usr/share/OVMF/OVMF_VARS.fd"
        # openSUSE
        "/usr/share/qemu/ovmf-x86_64-code.bin|/usr/share/qemu/ovmf-x86_64-vars.bin"
        # NixOS
        "/run/libvirt/nix-ovmf/OVMF_CODE.fd|/run/libvirt/nix-ovmf/OVMF_VARS.fd"
        # Gentoo
        "/usr/share/edk2-ovmf/OVMF.fd|"
    )

    for location in "${ovmf_locations[@]}"; do
        local code_path="${location%|*}"
        local vars_path="${location#*|}"

        searched_paths+=("$code_path")

        if [ -f "$code_path" ]; then
            ovmf_code="$code_path"
            if [ -n "$vars_path" ] && [ -f "$vars_path" ]; then
                ovmf_vars="$vars_path"
            fi
            log "Found OVMF firmware: CODE=$ovmf_code, VARS=${ovmf_vars:-none}" >> "$LOG_FILE"
            break
        fi
    done

    if [ -z "$ovmf_code" ]; then
        log "OVMF firmware not found. Searched paths: ${searched_paths[*]}" >> "$LOG_FILE"
        return 1
    fi

    echo "$ovmf_code|$ovmf_vars"
    return 0
}

# Get or create persistent NVRAM file for a VM disk
# This allows UEFI settings (boot order, etc.) to persist across VM reboots
get_persistent_nvram() {
    local vm_disk="$1"
    local ovmf_vars_template="$2"

    # Create NVRAM storage directory
    local nvram_dir="$HOME/.local/share/vm-disk-manager/nvram"
    if [ ! -d "$nvram_dir" ]; then
        mkdir -p "$nvram_dir" 2>/dev/null || nvram_dir="/tmp/vm-disk-manager-nvram"
        mkdir -p "$nvram_dir"
        log "Created NVRAM storage directory: $nvram_dir" >> "$LOG_FILE"
    fi

    # Generate NVRAM filename based on VM disk path (sanitize the name)
    local vm_basename=$(basename "$vm_disk")
    local nvram_file="$nvram_dir/${vm_basename}.nvram.fd"

    # If NVRAM file doesn't exist and we have a template, create it
    if [ ! -f "$nvram_file" ] && [ -n "$ovmf_vars_template" ] && [ -f "$ovmf_vars_template" ]; then
        cp "$ovmf_vars_template" "$nvram_file"
        chmod 644 "$nvram_file"
        log "Created new persistent NVRAM file: $nvram_file (from template: $ovmf_vars_template)" >> "$LOG_FILE"
    elif [ -f "$nvram_file" ]; then
        log "Using existing persistent NVRAM file: $nvram_file" >> "$LOG_FILE"
    else
        log "Warning: Could not create NVRAM file (no template available)" >> "$LOG_FILE"
        return 1
    fi

    echo "$nvram_file"
    return 0
}

# Reset NVRAM for a specific VM (delete the persistent NVRAM file)
reset_nvram() {
    local vm_disk="$1"
    local nvram_dir="$HOME/.local/share/vm-disk-manager/nvram"
    local vm_basename=$(basename "$vm_disk")
    local nvram_file="$nvram_dir/${vm_basename}.nvram.fd"

    if [ -f "$nvram_file" ]; then
        rm -f "$nvram_file"
        log "Removed NVRAM file: $nvram_file" >> "$LOG_FILE"
        return 0
    else
        log "No NVRAM file found for: $vm_disk" >> "$LOG_FILE"
        return 1
    fi
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
        local install_cmd="sudo apt install ovmf"
        if command -v dnf &>/dev/null; then
            install_cmd="sudo dnf install edk2-ovmf"
        elif command -v pacman &>/dev/null; then
            install_cmd="sudo pacman -S edk2-ovmf"
        elif command -v zypper &>/dev/null; then
            install_cmd="sudo zypper install qemu-ovmf-x86_64"
        fi
        whiptail --msgbox "OVMF firmware not found.\n\nCommon installation commands:\nDebian/Ubuntu: sudo apt install ovmf\nFedora/RHEL: sudo dnf install edk2-ovmf\nArch Linux: sudo pacman -S edk2-ovmf\nopenSUSE: sudo zypper install qemu-ovmf-x86_64\n\nYour system: $install_cmd\n\nCheck log for searched paths: $LOG_FILE" 18 70
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
        # Use separate CODE and VARS (modern approach with persistent NVRAM)
        local persistent_nvram=$(get_persistent_nvram "$file" "$ovmf_vars")
        if [ $? -eq 0 ] && [ -f "$persistent_nvram" ]; then
            # Use persistent NVRAM for this VM
            qemu_args+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
                       -drive "if=pflash,format=raw,file=$persistent_nvram")
            log "Using persistent NVRAM: $persistent_nvram" >> "$LOG_FILE"
        else
            # Fallback to temporary NVRAM if persistent fails
            local temp_vars="/tmp/OVMF_VARS_$$.fd"
            cp "$ovmf_vars" "$temp_vars"
            qemu_args+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
                       -drive "if=pflash,format=raw,file=$temp_vars")
            log "Warning: Using temporary NVRAM (persistent NVRAM creation failed): $temp_vars" >> "$LOG_FILE"
        fi
    else
        # Use single OVMF file (legacy approach)
        qemu_args+=(-bios "$ovmf_code")
        log "Using legacy OVMF single-file approach (no persistent NVRAM)" >> "$LOG_FILE"
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

# Checks for the qemu-img dependency and installs it if not found.
check_qemu_img_dependency() {
    if ! command -v qemu-img &> /dev/null; then
        whiptail --title "$SCRIPT_NAME" --msgbox "The 'qemu-img' tool is required but not found. Please install it to continue." 10 60
        exit 1
    fi
}

# Function to compress a disk image using qemu-img.
# Usage: compress_image "input_image_path" "output_image_path"
compress_image() {
    local input_image="$1"
    local output_image="$2"

    if [ -z "$input_image" ] || [ -z "$output_image" ]; then
        whiptail --title "Compression Error" --msgbox "Error: Both input and output image paths are required." 8 60
        return 1
    fi

    # Verifica se il file di input esiste
    if [ ! -f "$input_image" ]; then
        whiptail --title "Compression Error" --msgbox "Error: Input image file not found at $input_image." 8 60
        return 1
    fi

    # Mostra un messaggio di avvio compressione
    whiptail --title "Compressing Image" --msgbox "Starting compression, be patient..." 8 60

    # Esegui la compressione con qemu-img
    if sudo qemu-img convert -c -O qcow2 -p "$input_image" "$output_image" 2>/dev/null; then
        #whiptail --title "Compression Complete" --msgbox "Compression successful. New image created at $output_image" 10 60
        return 0
    else
        whiptail --title "Compression Error" --msgbox "Error: Compression failed." 8 60
        return 1
    fi
}