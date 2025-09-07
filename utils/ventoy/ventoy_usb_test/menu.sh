# Disk selection menu
select_disk_menu() {
    local devices_array=()
    
    readarray -t devices_array < <(detect_usb_devices)
    
    if [[ ${#devices_array[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox \
            "Unable to detect devices.\n\nUse manual selection options." \
            10 60
        devices_array=("BROWSE" "Browse image file..." "CUSTOM" "Custom path..." "" "No selection")
    fi
    
    local selected
    selected=$(whiptail --title "Disk/Image Selection" \
        --menu "Select a USB device or image file to test:" \
        22 90 14 "${devices_array[@]}" 3>&1 1>&2 2>&3)
    
    # Handle selection
    case "$selected" in
        "BROWSE")
            local browsed_file
            browsed_file=$(browse_image_files_enhanced)
            if [[ -n "$browsed_file" ]]; then
                DISK="$browsed_file"
                if [[ "${DISK##*.}" =~ ^(vhd|VHD|vpc|VPC)$ ]]; then
                    if command -v qemu-img >/dev/null; then
                        local vpc_test
                        vpc_test=$(qemu-img info -f vpc "$DISK" 2>&1 || true)
                        if [[ -n "$vpc_test" ]] && ! echo "$vpc_test" | grep -qi "could not open\|invalid\|error\|failed"; then
                            FORMAT="vpc"
                        else
                            FORMAT="raw"
                        fi
                    else
                        FORMAT="vpc"
                    fi
                else
                    case "${DISK##*.}" in
                        qcow2) FORMAT="qcow2" ;;
                        vdi) FORMAT="vdi" ;;
                        vmdk) FORMAT="vmdk" ;;
                        *) FORMAT="raw" ;;
                    esac
                fi
                
                # Show detailed information and validation
                show_image_details_dialog "$DISK"
            else
                return 1
            fi
            ;;
        "CUSTOM")
            local custom_path
            custom_path=$(whiptail --title "Custom Path" \
                --inputbox "Enter the full path:" \
                15 75 "$DISK" 3>&1 1>&2 2>&3)
            
            if [[ -n "$custom_path" ]]; then
                DISK="$custom_path"
                # Enhanced format detection with VHD test
                if [[ "${DISK##*.}" =~ ^(vhd|VHD|vpc|VPC)$ ]]; then
                    # Test VHD with -f vpc first
                    if command -v qemu-img >/dev/null; then
                        local vpc_test
                        vpc_test=$(qemu-img info -f vpc "$DISK" 2>&1 || true)
                        if [[ -n "$vpc_test" ]] && ! echo "$vpc_test" | grep -qi "could not open\|invalid\|error\|failed"; then
                            FORMAT="vpc"
                        else
                            FORMAT="raw"  # fallback se test vpc fallisce
                        fi
                    else
                        FORMAT="vpc"  # fallback se qemu-img non disponibile
                    fi
                else
                    # Standard detection for other formats
                    case "${DISK##*.}" in
                        qcow2) FORMAT="qcow2" ;;
                        vdi) FORMAT="vdi" ;;
                        vmdk) FORMAT="vmdk" ;;
                        *) FORMAT="raw" ;;
                    esac
                fi
            else
                return 1
            fi
            ;;
        "")
            return 1
            ;;
        *)
            if [[ -n "$selected" ]]; then
                DISK="$selected"
                FORMAT="raw"  # USB devices always raw
            else
                return 1
            fi
            ;;
    esac
    
    # Final validation
    if [[ -n "$DISK" ]]; then
        validate_selected_disk_enhanced "$DISK"
        return $?
    else
        return 1
    fi
}

# System configuration menu
system_config_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "System Configuration" \
            --menu "Virtual hardware configuration:" \
            18 70 8 \
            "1" "RAM: ${MEMORY}MB" \
            "2" "CPU Cores: $CORES" \
            "3" "CPU Threads/core: $THREADS" \
            "4" "CPU Sockets: $SOCKETS" \
            "5" "Machine Type: $MACHINE_TYPE" \
            "6" "Disk Format: $FORMAT" \
            "7" "USB Version: $USB_VERSION" \
            "8" "Back to main menu" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) 
                MEMORY=$(whiptail --title "RAM Configuration" \
                    --inputbox "RAM in MB (recommended: 1024-4096):" \
                    10 40 "$MEMORY" 3>&1 1>&2 2>&3) || true
                ;;
            2)
                CORES=$(whiptail --title "CPU Cores" \
                    --inputbox "Number of CPU cores (1-$(nproc)):" \
                    10 40 "$CORES" 3>&1 1>&2 2>&3) || true
                ;;
            3)
                THREADS=$(whiptail --title "CPU Threads" \
                    --inputbox "Threads per core (1-2):" \
                    10 40 "$THREADS" 3>&1 1>&2 2>&3) || true
                ;;
            4)
                SOCKETS=$(whiptail --title "CPU Sockets" \
                    --inputbox "Number of CPU sockets (usually 1):" \
                    10 40 "$SOCKETS" 3>&1 1>&2 2>&3) || true
                ;;
            5)
                MACHINE_TYPE=$(whiptail --title "Machine Type" \
                    --menu "Select machine type:" \
                    12 50 3 \
                    "q35" "Modern (recommended)" \
                    "pc" "Legacy compatibility" \
                    "microvm" "Minimal (advanced)" \
                    3>&1 1>&2 2>&3) || true
                ;;
            6)
                FORMAT=$(whiptail --title "Disk Format" \
                    --menu "Select disk format:" \
                    12 50 4 \
                    "raw" "Raw (physical devices)" \
                    "qcow2" "QEMU Copy-On-Write" \
                    "vdi" "VirtualBox Disk" \
                    "vmdk" "VMware Disk" \
                    3>&1 1>&2 2>&3) || true
                ;;
            7)
                USB_VERSION=$(whiptail --title "USB Version" \
                    --menu "Select USB controller version:" \
                    12 50 3 \
                    "1.1" "USB 1.1 (UHCI)" \
                    "2.0" "USB 2.0 (EHCI)" \
                    "3.0" "USB 3.0 (xHCI)" \
                    3>&1 1>&2 2>&3) || true
                ;;
            8|"") break ;;
        esac
    done
}

# BIOS/UEFI menu
bios_menu() {
    BIOS_MODE=$(whiptail --title "Boot Mode" \
        --menu "Select boot mode:" \
        15 60 4 \
        "uefi" "UEFI (modern, recommended)" \
        "bios" "BIOS Legacy/MBR" \
        "auto" "Automatic detection" \
        3>&1 1>&2 2>&3) || return
    
    case $BIOS_MODE in
        "uefi")
            if [[ ! -f "$DEFAULT_BIOS" ]]; then
                if whiptail --title "OVMF Not Found" --yesno \
                    "The OVMF.fd file is missing.\nWould you like to compile it now? (This may take time)" \
                    10 50; then
                    prepare_ovmf_interactive
                fi
            fi
            ;;
        "auto")
            # Automatically detect based on disk
            if [[ -b "$DISK" ]] && command -v fdisk >/dev/null; then
                local partition_table
                partition_table=$(fdisk -l "$DISK" 2>/dev/null | grep "Disklabel type" | awk '{print $3}' || echo "unknown")
                case $partition_table in
                    "gpt") BIOS_MODE="uefi" ;;
                    "dos") BIOS_MODE="bios" ;;
                    *) BIOS_MODE="uefi" ;;  # Default to modern
                esac
                whiptail --title "Automatic Detection" --msgbox \
                    "Detected partition table: $partition_table\nSelected mode: $BIOS_MODE" \
                    10 50
            else
                BIOS_MODE="uefi"  # Default
            fi
            ;;
    esac
}

# Advanced options menu
advanced_menu() {
    while true; do
        local network_status sound_status
        [[ "$NETWORK" == true ]] && network_status="Enabled ✓" || network_status="Disabled ✗"
        [[ "$SOUND" == true ]] && sound_status="Enabled ✓" || sound_status="Disabled ✗"
        
        local choice
        choice=$(whiptail --title "Advanced Options" \
            --menu "Additional configurations:" \
            16 60 6 \
            "1" "VGA: $VGA_MODE" \
            "2" "Network: $network_status" \
            "3" "Audio: $sound_status" \
            "4" "QEMU Monitor: Always enabled" \
            "5" "OVMF Management" \
            "6" "Back to main menu" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                VGA_MODE=$(whiptail --title "Video Mode" \
                    --menu "Select video mode:" \
                    14 50 5 \
                    "virtio" "VirtIO (recommended)" \
                    "std" "Standard VGA" \
                    "cirrus" "Cirrus Logic" \
                    "qxl" "QXL (SPICE)" \
                    "none" "Headless (no video)" \
                    3>&1 1>&2 2>&3) || true
                ;;
            2)
                if [[ "$NETWORK" == true ]]; then
                    NETWORK=false
                else
                    NETWORK=true
                fi
                ;;
            3)
                if [[ "$SOUND" == true ]]; then
                    SOUND=false
                else
                    SOUND=true
                fi
                ;;
            4)
                whiptail --title "QEMU Monitor" --msgbox \
                    "The QEMU monitor will be available at:\n\ntelnet localhost 4444\n\nUseful commands:\n- info status\n- system_reset\n- quit" \
                    12 50
                ;;
            5) ovmf_management_menu ;;
            6|"") break ;;
        esac
    done
}

# OVMF management menu
ovmf_management_menu() {
    local ovmf_status
    if [[ -f "$DEFAULT_BIOS" ]]; then
        ovmf_status="Present ✓"
    else
        ovmf_status="Missing ✗"
    fi
    
    local choice
    choice=$(whiptail --title "OVMF Management" \
        --menu "OVMF Status: $ovmf_status\n\nAvailable options:" \
        16 60 4 \
        "1" "Compile OVMF from source" \
        "2" "Download prebuilt OVMF" \
        "3" "Custom OVMF path" \
        "4" "Back" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) prepare_ovmf_interactive ;;
        2) download_ovmf_prebuilt ;;
        3) 
            DEFAULT_BIOS=$(whiptail --title "OVMF Path" \
                --inputbox "Enter OVMF file path:" \
                10 60 "$DEFAULT_BIOS" 3>&1 1>&2 2>&3) || true
            ;;
    esac
}

# Configuration management menu
config_management_menu() {
    local choice
    choice=$(whiptail --title "Configuration Management" \
        --menu "Configuration options:" \
        12 60 4 \
        "1" "Save current configuration" \
        "2" "Load saved configuration" \
        "3" "Reset to default configuration" \
        "4" "Back" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) 
            save_config
            whiptail --title "Saved" --msgbox "Configuration saved successfully!" 8 40
            ;;
        2)
            if [[ -f "$CONFIG_FILE" ]]; then
                load_config
                whiptail --title "Loaded" --msgbox "Configuration loaded successfully!" 8 40
            else
                whiptail --title "Error" --msgbox "No saved configuration found." 8 40
            fi
            ;;
        3)
            if whiptail --title "Reset Configuration" --yesno \
                "Reset to default values?\nThe current configuration will be lost." \
                10 50; then
                reset_to_defaults
                whiptail --title "Reset" --msgbox "Configuration reset to defaults." 8 50
            fi
            ;;
    esac
}

# Advanced diagnostic menu
diagnostic_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "System Diagnostics" \
            --menu "Diagnostic tools:" \
            16 60 7 \
            "1" "Hardware Info" \
            "2" "KVM Test" \
            "3" "Verify Dependencies" \
            "4" "System Logs" \
            "5" "Disk Speed Test" \
            "6" "CPU Benchmark" \
            "7" "Back" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) show_hardware_info ;;
            2) test_kvm_functionality ;;
            3) verify_all_dependencies ;;
            4) show_system_logs ;;
            5) test_disk_speed ;;
            6) benchmark_cpu ;;
            7|"") break ;;
        esac
    done
}