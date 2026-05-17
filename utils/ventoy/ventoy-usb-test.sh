#!/bin/bash
# PKG_NAME: usb-boot-test
# PKG_VERSION: 2.1.5
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), qemu-system-x86, whiptail
# PKG_RECOMMENDS: ovmf
# PKG_PROVIDES: ventoy-usb-test
# PKG_REPLACES: ventoy-usb-test
# PKG_CONFLICTS: ventoy-usb-test
# PKG_ALIASES: ventoy-usb-test
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Test bootable USB drives and disk images in QEMU
# PKG_LONG_DESCRIPTION: Interactive tool for testing any bootable USB device
#  or disk image (ISO, qcow2, raw) in QEMU virtual machine without rebooting.
#  Works with Ventoy, Ubuntu, Windows, and any bootable media.
#  .
#  Features:
#  - Test physical USB devices and disk images
#  - UEFI and BIOS/Legacy boot mode testing
#  - Dual mode testing (UEFI+BIOS sequentially)
#  - Interactive whiptail-based TUI configuration
#  - Configurable RAM, CPU, VGA, and hardware settings
#  - Auto-detection of disk format and boot mode
#  - OVMF firmware management
#  - Configuration profiles (save/load)
#  - Network and sound device emulation
#  - Diagnostic tools and troubleshooting
#  - KVM acceleration support
#  .
#  Legacy name: ventoy-usb-test (still supported for backward compatibility)
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Interactive script for testing bootable USB drives and disk images in QEMU
# Supports any bootable media: Ventoy, Ubuntu ISOs, Windows installers, etc.
# Supports UEFI and MBR/BIOS Legacy boot modes with interactive TUI

set -euo pipefail

# Allow --help even without root so packaging / CI can smoke-test it.
case "${1:-}" in
    -h|--help) ;;  # handled later in main()
    *)
        if [ "$EUID" -ne 0 ]; then
            echo "Please run as root"
            exit 1
        fi
        ;;
esac

# Configuration and global state. Several variables below are consumed
# by the modules under ventoy-usb-test/*.sh that we source dynamically;
# they appear unused when this file is linted in isolation, so each
# such var gets an explicit `disable=SC2034` annotation.
readonly SCRIPT_NAME="USB Boot Tester"
readonly VERSION="2.1.5"
# shellcheck disable=SC2034
readonly LOG_DIR="/tmp/ventoy_test_logs"
# shellcheck disable=SC2034
readonly CONFIG_FILE="$HOME/.ventoy_test_config"
# Determine the directory where the script is located (resolving symlinks)
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

# Global variables with default values (consumed by sourced modules)
MEMORY="2048"
CORES="4"
# shellcheck disable=SC2034
THREADS="1"
# shellcheck disable=SC2034
SOCKETS="1"
# shellcheck disable=SC2034
MACHINE_TYPE="q35"
DEFAULT_BIOS="/usr/share/OVMF/OVMF.fd"
DISK=""
# shellcheck disable=SC2034
FORMAT="raw"
BIOS_MODE="uefi"
VGA_MODE="virtio"
# shellcheck disable=SC2034
NETWORK=false
# shellcheck disable=SC2034
SOUND=false
USB_VERSION="3.0"

# Colors for messages (consumed by sourced modules)
# shellcheck disable=SC2034
readonly RED='\033[0;31m'
# shellcheck disable=SC2034
readonly GREEN='\033[0;32m'
# shellcheck disable=SC2034
readonly YELLOW='\033[1;33m'
# shellcheck disable=SC2034
readonly BLUE='\033[0;34m'
# shellcheck disable=SC2034
readonly NC='\033[0m'

# Scan and "source" .sh file recursive.
for script in "$SCRIPT_DIR/ventoy-usb-test/"*.sh; do
    if [ -f "$script" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
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
                local size
                size=$(lsblk -d -o SIZE "$DISK" 2>/dev/null | tail -1 || echo "?")
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
    local help_text="USB BOOT TESTER GUIDE\n\n"
    help_text+="Test any bootable USB/disk in QEMU without rebooting!\n"
    help_text+="Works with: Ventoy, Ubuntu ISOs, Windows, rescue disks, etc.\n\n"
    help_text+="USAGE:\n"
    help_text+="1. Select a USB device or image file (ISO, qcow2, raw, etc.)\n"
    help_text+="2. Configure boot mode (UEFI/BIOS/Auto)\n"
    help_text+="3. Adjust system parameters if needed (RAM, CPU, VGA)\n"
    help_text+="4. Start the test (single mode or dual UEFI+BIOS)\n\n"
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
    case "${1:-}" in
        -h|--help)
            cat <<EOF
$SCRIPT_NAME v$VERSION - Test bootable USB devices and ISOs in QEMU

Usage: $(basename "$0") [-h|--help]

Interactive whiptail-based TUI to boot a USB device or ISO/qcow2/raw
image in QEMU (UEFI or BIOS) without restarting the host. Useful for
testing Ventoy, Ubuntu installers, Windows ISOs, rescue media, etc.

Run without arguments to open the interactive menu (requires
whiptail, qemu-system-x86_64, and root for raw USB devices).
EOF
            exit 0
            ;;
    esac
    initial_checks
    main_menu
}

# Execute only if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi