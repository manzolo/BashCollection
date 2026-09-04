# shellcheck shell=bash
# Interactive whiptail menus.

# --- Input helpers ---------------------------------------------------------
# whiptail prints an empty string on ESC/Cancel. Assigning that straight into a
# config variable used to blank it (e.g. MEMORY="" → `qemu -m ""`). These
# helpers only commit a value when the user actually entered a valid one.

# prompt_number VARNAME TITLE PROMPT MIN MAX
prompt_number() {
    local varname="$1" title="$2" prompt="$3" min="$4" max="$5"
    local current="${!varname}" value
    value=$(whiptail --title "$title" --inputbox "$prompt" 10 50 "$current" 3>&1 1>&2 2>&3) || return 0
    [[ -n "$value" ]] || return 0
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
        printf -v "$varname" '%s' "$value"
    else
        whiptail --title "Invalid value" --msgbox \
            "\"$value\" is not valid.\nEnter a whole number between $min and $max." 9 50 || true
    fi
}

# prompt_choice VARNAME TITLE PROMPT HEIGHT WIDTH LISTHEIGHT tag desc [tag desc ...]
prompt_choice() {
    local varname="$1" title="$2" prompt="$3" h="$4" w="$5" lh="$6"
    shift 6
    local value
    value=$(whiptail --title "$title" --default-item "${!varname}" \
        --menu "$prompt" "$h" "$w" "$lh" "$@" 3>&1 1>&2 2>&3) || return 0
    [[ -n "$value" ]] && printf -v "$varname" '%s' "$value"
    return 0
}

# --- Disk selection --------------------------------------------------------
select_disk_menu() {
    local devices_array=()

    readarray -t devices_array < <(detect_usb_devices)

    if [[ ${#devices_array[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox \
            "Unable to detect devices.\n\nUse manual selection options." \
            10 60 || true
        devices_array=("BROWSE" "Browse image file..." "CUSTOM" "Custom path...")
    fi

    local selected
    selected=$(whiptail --title "Disk/Image Selection" \
        --menu "Select a USB device or image file to test:" \
        22 90 14 "${devices_array[@]}" 3>&1 1>&2 2>&3) || true

    local new_disk=""
    case "$selected" in
        "BROWSE")
            new_disk=$(browse_image_files) || return 1
            ;;
        "CUSTOM")
            new_disk=$(whiptail --title "Custom Path" \
                --inputbox "Enter the full path of a device or image file:" \
                10 75 "$DISK" 3>&1 1>&2 2>&3) || return 1
            ;;
        "")
            return 1
            ;;
        *)
            new_disk="$selected"
            ;;
    esac

    [[ -n "$new_disk" ]] || return 1

    DISK="$new_disk"
    FORMAT=$(detect_image_format "$DISK")
    [[ "$FORMAT" == "unknown" ]] && FORMAT="raw"
    refresh_media_type

    if [[ -f "$DISK" ]]; then
        show_image_details_dialog "$DISK"
    fi

    validate_selected_disk "$DISK"
}

# --- System configuration --------------------------------------------------
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
            3>&1 1>&2 2>&3) || true

        case $choice in
            1) prompt_number MEMORY "RAM Configuration" "RAM in MB (recommended: 1024-4096):" 128 262144 ;;
            2) prompt_number CORES "CPU Cores" "Number of CPU cores (1-$(nproc)):" 1 "$(nproc)" ;;
            3) prompt_number THREADS "CPU Threads" "Threads per core (1-2):" 1 2 ;;
            4) prompt_number SOCKETS "CPU Sockets" "Number of CPU sockets (usually 1):" 1 4 ;;
            5)
                prompt_choice MACHINE_TYPE "Machine Type" "Select machine type:" 12 50 3 \
                    "q35" "Modern (recommended)" \
                    "pc" "Legacy compatibility" \
                    "microvm" "Minimal (advanced)"
                ;;
            6)
                prompt_choice FORMAT "Disk Format" "Select disk format:" 13 50 5 \
                    "raw" "Raw (physical devices, ISO, IMG)" \
                    "qcow2" "QEMU Copy-On-Write" \
                    "vpc" "VHD / Ventoy .vtoy" \
                    "vdi" "VirtualBox Disk" \
                    "vmdk" "VMware Disk"
                ;;
            7)
                prompt_choice USB_VERSION "USB Version" "Select USB controller version:" 12 50 3 \
                    "1.1" "USB 1.1 (UHCI)" \
                    "2.0" "USB 2.0 (EHCI)" \
                    "3.0" "USB 3.0 (xHCI)"
                ;;
            8|"") break ;;
        esac
    done
}

# --- Boot mode -------------------------------------------------------------
bios_menu() {
    local choice
    choice=$(whiptail --title "Boot Mode" --default-item "$BIOS_MODE" \
        --menu "Select boot mode:" \
        15 60 4 \
        "uefi" "UEFI (modern, recommended)" \
        "bios" "BIOS Legacy/MBR" \
        "auto" "Detect from the selected disk" \
        3>&1 1>&2 2>&3) || return 0

    case "$choice" in
        "uefi")
            BIOS_MODE="uefi"
            if [[ ! -f "$DEFAULT_BIOS" ]]; then
                if whiptail --title "OVMF Not Found" --yesno \
                    "No OVMF firmware was found.\nWould you like to install it now?" \
                    10 50; then
                    ovmf_management_menu
                fi
            fi
            ;;
        "bios")
            BIOS_MODE="bios"
            ;;
        "auto")
            if [[ -z "$DISK" ]]; then
                whiptail --title "Automatic Detection" --msgbox \
                    "Select a disk first, then run detection again." 8 55 || true
                return 0
            fi
            local detected reason
            if detected=$(detect_boot_mode "$DISK"); then
                read -r BIOS_MODE reason <<< "$detected"
                whiptail --title "Automatic Detection" --msgbox \
                    "$(basename "$DISK"): $reason\n\nSelected mode: $BIOS_MODE" \
                    10 60 || true
            else
                read -r BIOS_MODE reason <<< "$detected"
                whiptail --title "Automatic Detection" --msgbox \
                    "$(basename "$DISK"): $reason.\n\nDefaulting to: $BIOS_MODE" \
                    10 60 || true
            fi
            ;;
    esac
}

# --- Advanced options ------------------------------------------------------
advanced_menu() {
    while true; do
        local network_status sound_status snapshot_status media_status
        [[ "$NETWORK" == true ]] && network_status="Enabled ✓" || network_status="Disabled ✗"
        [[ "$SOUND" == true ]] && sound_status="Enabled ✓" || sound_status="Disabled ✗"
        [[ "$SNAPSHOT" == true ]] && snapshot_status="ON (target never modified)" || snapshot_status="OFF (guest may write to target)"
        media_status="$MEDIA"
        [[ "$MEDIA_MODE" == "auto" ]] && media_status="$MEDIA (auto)"

        local choice
        choice=$(whiptail --title "Advanced Options" \
            --menu "Additional configurations:" \
            18 70 8 \
            "1" "VGA: $VGA_MODE" \
            "2" "Network: $network_status" \
            "3" "Audio: $sound_status" \
            "4" "Snapshot: $snapshot_status" \
            "5" "Media: $media_status" \
            "6" "QEMU Monitor info" \
            "7" "OVMF Management" \
            "8" "Back to main menu" \
            3>&1 1>&2 2>&3) || true

        case $choice in
            1)
                prompt_choice VGA_MODE "Video Mode" "Select video mode:" 14 50 5 \
                    "virtio" "VirtIO (recommended)" \
                    "std" "Standard VGA" \
                    "cirrus" "Cirrus Logic" \
                    "qxl" "QXL (SPICE)" \
                    "none" "Headless (serial console only)"
                ;;
            2) [[ "$NETWORK" == true ]] && NETWORK=false || NETWORK=true ;;
            3) [[ "$SOUND" == true ]] && SOUND=false || SOUND=true ;;
            4)
                if [[ "$SNAPSHOT" == true ]]; then
                    if whiptail --title "Disable snapshot?" --yesno \
                        "With snapshot OFF the guest can write to the real device/image\n(installers, Ventoy persistence, saved settings...).\n\nDisable snapshot mode?" \
                        11 64; then
                        SNAPSHOT=false
                    fi
                else
                    SNAPSHOT=true
                fi
                ;;
            5)
                prompt_choice MEDIA_MODE "Media Type" \
                    "How the target is presented to the guest:\n\nauto: plain ISO 9660 images (no partition table) become a\nUSB CD-ROM, everything else a USB disk." 16 70 3 \
                    "auto"  "Detect from the image (recommended)" \
                    "disk"  "USB disk (partitioned media, hybrid ISOs)" \
                    "cdrom" "USB CD-ROM (El Torito boot, read-only)"
                refresh_media_type
                ;;
            6)
                whiptail --title "QEMU Monitor" --msgbox \
                    "While a test runs, the QEMU monitor listens on:\n\n$MONITOR_SOCK\n\nConnect with:\n  socat - UNIX-CONNECT:$MONITOR_SOCK\n\nUseful commands: info status, system_reset, quit" \
                    14 72 || true
                ;;
            7) ovmf_management_menu ;;
            8|"") break ;;
        esac
    done
}

# --- OVMF management -------------------------------------------------------
ovmf_management_menu() {
    local ovmf_status
    if [[ -f "$DEFAULT_BIOS" ]]; then
        ovmf_status="Present ✓ ($DEFAULT_BIOS)"
    else
        ovmf_status="Missing ✗"
    fi

    local choice
    choice=$(whiptail --title "OVMF Management" \
        --menu "OVMF Status: $ovmf_status\n\nAvailable options:" \
        16 70 4 \
        "1" "Install prebuilt OVMF (package manager)" \
        "2" "Compile OVMF from source" \
        "3" "Custom OVMF path" \
        "4" "Back" \
        3>&1 1>&2 2>&3) || true

    case $choice in
        1) download_ovmf_prebuilt ;;
        2) prepare_ovmf_interactive ;;
        3)
            local path
            path=$(whiptail --title "OVMF Path" \
                --inputbox "Enter OVMF firmware file path (OVMF.fd or OVMF_CODE*.fd):" \
                10 70 "$DEFAULT_BIOS" 3>&1 1>&2 2>&3) || return 0
            [[ -n "$path" ]] || return 0
            if [[ -f "$path" ]]; then
                DEFAULT_BIOS="$path"
            else
                whiptail --title "Not found" --msgbox "File not found:\n$path" 9 60 || true
            fi
            ;;
    esac
}

# --- Configuration management ----------------------------------------------
config_management_menu() {
    local choice
    choice=$(whiptail --title "Configuration Management" \
        --menu "Configuration file: $CONFIG_FILE" \
        12 70 4 \
        "1" "Save current configuration" \
        "2" "Load saved configuration" \
        "3" "Reset to default configuration" \
        "4" "Back" \
        3>&1 1>&2 2>&3) || true

    case $choice in
        1)
            save_config
            whiptail --title "Saved" --msgbox "Configuration saved to:\n$CONFIG_FILE" 9 60 || true
            ;;
        2)
            if [[ -f "$CONFIG_FILE" ]]; then
                load_config
                whiptail --title "Loaded" --msgbox "Configuration loaded successfully!" 8 40 || true
            else
                whiptail --title "Error" --msgbox "No saved configuration found." 8 40 || true
            fi
            ;;
        3)
            if whiptail --title "Reset Configuration" --yesno \
                "Reset to default values?\nThe current configuration will be lost." \
                10 50; then
                reset_to_defaults
                whiptail --title "Reset" --msgbox "Configuration reset to defaults." 8 50 || true
            fi
            ;;
    esac
}

# --- Diagnostics -----------------------------------------------------------
diagnostic_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "System Diagnostics" \
            --menu "Diagnostic tools:" \
            13 60 4 \
            "1" "Hardware Info" \
            "2" "KVM Test" \
            "3" "Verify Dependencies" \
            "4" "Back" \
            3>&1 1>&2 2>&3) || true

        case $choice in
            1) show_hardware_info ;;
            2) test_kvm_functionality ;;
            3) verify_all_dependencies ;;
            4|"") break ;;
        esac
    done
}
