#!/bin/bash

# Interactive script for testing Ventoy USB boot with a whiptail-based TUI
# Supports UEFI and MBR/BIOS Legacy with a graphical interface

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Configuration
readonly SCRIPT_NAME="Ventoy USB Boot Tester"
readonly VERSION="2.0"
readonly LOG_DIR="/tmp/ventoy_test_logs"
readonly CONFIG_FILE="$HOME/.ventoy_test_config"
# Determine the directory where the script is located (resolving symlinks)
readonly SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Global variables with default values
MEMORY="2048"
CORES="4"
THREADS="1"
SOCKETS="1"
MACHINE_TYPE="q35"
DEFAULT_BIOS="/usr/share/OVMF/OVMF.fd"
DISK=""
FORMAT="raw"
BIOS_MODE="uefi"
VGA_MODE="virtio"
NETWORK=false
SOUND=false
USB_VERSION="3.0"

# Colors for messages
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/ventoy_usb_test/"*.sh; do
    if [ -f "$script" ]; then
        source "$script"
    else
        echo "Error: file script $script not found."
        exit 1
    fi
done

shopt -u globstar

# Main menu with Unicode icons
main_menu() {
    while true; do
        local disk_info=""
        if [[ -n "$DISK" ]]; then
            if [[ -b "$DISK" ]]; then
                local size=$(lsblk -d -o SIZE "$DISK" 2>/dev/null | tail -1 || echo "?")
                disk_info="$(basename "$DISK") (${size})"
            else
                disk_info="$(basename "$DISK")"
            fi
        else
            disk_info="Not selected"
        fi
        
        local choice
        choice=$(whiptail --title "$SCRIPT_NAME v$VERSION" \
            --menu "Main Menu:" \
            20 75 10 \
            "1" "💾 Disk/USB: $disk_info" \
            "2" "⚙️  Boot: $BIOS_MODE $([[ $BIOS_MODE == "uefi" && -f "$DEFAULT_BIOS" ]] && echo "✅" || [[ $BIOS_MODE == "bios" ]] && echo "✅" || echo "⚠️")" \
            "3" "💻 System: ${MEMORY}MB RAM, ${CORES}c CPU" \
            "4" "🔧 Advanced: VGA=$VGA_MODE, USB=$USB_VERSION" \
            "5" "🔍 Diagnostics & System Info" \
            "6" "📝 Configuration" \
            "7" "🚀 START SINGLE TEST!" \
            "8" "🧪 DUAL TEST (UEFI+BIOS)" \
            "9" "❓ Help" \
            "0" "🚪 Exit" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) select_disk_menu ;;
            2) bios_menu ;;
            3) system_config_menu ;;
            4) advanced_menu ;;
            5) diagnostic_menu ;;
            6) config_management_menu ;;
            7) 
                if [[ -z "$DISK" ]]; then
                    whiptail --title "Error" --msgbox "Select a disk first!" 8 40
                else
                    confirm_and_run
                fi
                ;;
            8) test_both_modes ;;
            9) show_help ;;
            0|"") 
                clear
                log_info "Thank you for using $SCRIPT_NAME!"
                exit 0
                ;;
        esac
    done
}

# Help system
show_help() {
    local help_text="VENTOY BOOT TESTER GUIDE\n\n"
    help_text+="USAGE:\n"
    help_text+="1. Select a USB device or image file\n"
    help_text+="2. Configure boot mode (UEFI/BIOS)\n"
    help_text+="3. Adjust system parameters if needed\n"
    help_text+="4. Start the test\n\n"
    help_text+="BOOT MODES:\n"
    help_text+="• UEFI: Modern, requires OVMF\n"
    help_text+="• BIOS: Legacy, for older systems\n"
    help_text+="• Auto: Detects automatically from partitions\n\n"
    help_text+="QEMU CONTROLS:\n"
    help_text+="• Ctrl+Alt+G: Release mouse\n"
    help_text+="• Ctrl+Alt+F: Fullscreen\n"
    help_text+="• Ctrl+C: Terminate emulation\n"
    help_text+="• Monitor: telnet localhost 4444\n\n"
    help_text+="TROUBLESHOOTING:\n"
    help_text+="• No KVM: Check module and permissions\n"
    help_text+="• OVMF missing: Compile or download\n"
    help_text+="• Boot fails: Verify partition table\n\n"
    help_text+="For support: Diagnostics → Verify dependencies"
    
    whiptail --title "User Guide" --scrolltext \
        --msgbox "$help_text" 22 70
}

# Main function
main() {
    initial_checks
    main_menu
}

# Execute only if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi