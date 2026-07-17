#!/bin/bash
# PKG_NAME: pi-emulate
# PKG_VERSION: 4.3.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), whiptail, qemu-system-arm, qemu-utils, wget, unzip
# PKG_RECOMMENDS: qemu-system-gui, pulseaudio
# PKG_SUGGESTS: curl
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Complete Raspberry Pi emulation manager for QEMU
# PKG_LONG_DESCRIPTION: Advanced TUI tool for managing Raspberry Pi OS emulation in QEMU.
#  .
#  Features:
#  - Download and manage Raspberry Pi OS images
#  - Auto-download compatible QEMU kernels and DTBs
#  - Create and manage VM instances with snapshots
#  - Configure memory, SSH, VNC, and audio settings
#  - Support for multiple Raspbian versions (Jessie to Bullseye)
#  - Instance cloning and snapshot management
#  - Interactive whiptail-based interface
#  - Comprehensive logging and error handling
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

set -e

# ==============================================================================
# GLOBAL CONFIGURATION - v4.3 Enhanced Edition
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly VERSION="4.3"
readonly WORK_DIR="${HOME}/.qemu-rpi-manager"
readonly IMAGES_DIR="${WORK_DIR}/images"
readonly KERNELS_DIR="${WORK_DIR}/kernels"
readonly DTBS_DIR="${WORK_DIR}/dtbs"
readonly SNAPSHOTS_DIR="${WORK_DIR}/snapshots"
readonly CONFIGS_DIR="${WORK_DIR}/configs"
readonly LOGS_DIR="${WORK_DIR}/logs"
readonly TEMP_DIR="${WORK_DIR}/temp"
readonly CACHE_DIR="${WORK_DIR}/cache"
readonly MOUNT_DIR="${WORK_DIR}/mount"

# Configuration files
readonly CONFIG_FILE="${CONFIGS_DIR}/qemu-rpi.conf"
readonly INSTANCES_DB="${CONFIGS_DIR}/instances.db"

# Logging
readonly LOG_FILE="${LOGS_DIR}/qemu-rpi-$(date +%Y%m%d-%H%M%S).log"

# QEMU defaults
readonly DEFAULT_MEMORY="256"  # Fixed for VersatilePB limit
readonly DEFAULT_SSH_PORT="5022"
readonly DEFAULT_VNC_PORT="5900"
readonly DEFAULT_AUDIO="no"
readonly DEFAULT_AUDIO_BACKEND="pa"  # PulseAudio by default
readonly FALLBACK_KERNEL="kernel-qemu-4.4.34-jessie"

# Enhanced Kernel Database
declare -A KERNEL_DB=(
    ["5.10.63"]="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-5.10.63-bullseye|bullseye|modern"
    ["5.4.51"]="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-5.4.51-buster|buster|modern"
    ["4.19.50"]="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.19.50-buster|buster|stable"
    ["4.14.79"]="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.14.79-stretch|stretch|stable"
    ["4.4.34"]="https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-4.4.34-jessie|jessie|legacy"
)

# OS Catalog
declare -A OS_CATALOG=(
    ["jessie_2017_full"]="jessie|2017-04-10|4.4.34|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2017-04-10/2017-04-10-raspbian-jessie.zip"
    ["jessie_2017_lite"]="jessie|2017-04-10|4.4.34|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2017-04-10/2017-04-10-raspbian-jessie-lite.zip"
    ["stretch_2018_full"]="stretch|2018-11-13|4.14.79|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2018-11-15/2018-11-13-raspbian-stretch.zip"
    ["stretch_2018_lite"]="stretch|2018-11-13|4.14.79|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2018-11-15/2018-11-13-raspbian-stretch-lite.zip"
    ["buster_2020_full"]="buster|2020-02-13|5.4.51|full|http://downloads.raspberrypi.org/raspbian/images/raspbian-2020-02-14/2020-02-13-raspbian-buster.zip"
    ["buster_2020_lite"]="buster|2020-02-13|5.4.51|lite|http://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2020-02-14/2020-02-13-raspbian-buster-lite.zip"
    ["bullseye_2022_full"]="bullseye|2022-04-04|5.10.63|full|https://downloads.raspberrypi.org/raspios_armhf/images/raspios_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf.img.xz"
    ["bullseye_2022_lite"]="bullseye|2022-04-04|5.10.63|lite|https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2022-04-07/2022-04-04-raspios-bullseye-armhf-lite.img.xz"
    ["bookworm_2025_full"]="bookworm|2025-05-13|4.4.34|full|https://downloads.raspberrypi.org/raspios_full_armhf/images/raspios_full_armhf-2025-05-13/2025-05-13-raspios-bookworm-armhf-full.img.xz"
    ["bookworm_2025_lite"]="bookworm|2025-05-13|4.4.34|lite|https://downloads.raspberrypi.org/raspios_lite_armhf/images/raspios_lite_armhf-2025-05-13/2025-05-13-raspios-bookworm-armhf-lite.img.xz"
)

# Audio backend options
declare -A AUDIO_BACKENDS=(
    ["none"]="No audio"
    ["pa"]="PulseAudio"
    ["alsa"]="ALSA"
    ["sdl"]="SDL"
    ["oss"]="OSS"
)

# ───────────────────────────────
# Load helper scripts
# ───────────────────────────────
load_modules() {
    for script in "$SCRIPT_DIR/pi-emulate/"*.sh; do
        if [ -f "$script" ]; then
            source "$script"
        else
            echo "Error: missing module $script"
            exit 1
        fi
    done
}

load_modules

trap 'handle_error $LINENO' ERR
trap 'cleanup_and_exit' EXIT INT TERM

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    if ! init_workspace; then
        echo "Failed to initialize workspace"
        exit 1
    fi
    
    log_init
    
    if ! check_dialog; then
        echo "Dialog is required but not available"
        exit 1
    fi
    
    if ! check_requirements; then
        echo "Failed to check/install requirements"
        exit 1
    fi
    
    while true; do
        choice=$(show_main_menu)
        
        case $choice in
            1) quick_start ;;
            2) create_instance ;;
            3) list_instances ;;
            4) download_os_image ;;
            5) manage_kernels ;;
            6) configure_audio ;;
            7) system_diagnostics ;;
            8) performance_monitor ;;
            9) view_logs ;;
            10) show_performance_tips ;;
            11) clean_workspace ;;
            0|"") break ;;
            *) dialog --msgbox "Invalid option!" 8 30 ;;
        esac
    done
    
    cleanup_and_exit
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

SUDO_CMD=""
if [ "$EUID" -ne 0 ]; then
    SUDO_CMD="sudo"
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "QEMU Raspberry Pi Manager v${VERSION}"
            echo "Enhanced Edition with Audio & Modern Kernels"
            echo ""
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -h, --help      Show this help"
            echo "  -v, --verbose   Enable verbose output"
            echo "  -d, --debug     Enable debug mode"
            echo "  --install-audio Install audio dependencies"
            echo ""
            echo "Features:"
            echo "  ✓ Modern kernel support (5.x series)"
            echo "  ✓ Audio emulation (PulseAudio/ALSA)"
            echo "  ✓ Performance monitoring"
            echo "  ✓ VNC support"
            echo "  ✓ Snapshot management"
            echo "  ✓ Auto-configuration"
            echo ""
            echo "Supported OS versions:"
            echo "  • Raspbian Jessie (2017)"
            echo "  • Raspbian Stretch (2018)"
            echo "  • Raspbian Buster (2020)"
            echo "  • Raspberry Pi OS Bullseye (2022)"
            exit 0
            ;;
        -v|--verbose)
            export VERBOSE=1
            shift
            ;;
        -d|--debug)
            export DEBUG=1
            export VERBOSE=1
            shift
            ;;
        --install-audio)
            install_audio_dependencies
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "=================================================="
        echo " QEMU Raspberry Pi Manager v${VERSION}"
        echo " Enhanced Edition"
        echo "=================================================="
        echo ""
        echo "New in this version:"
        echo "  • Modern kernel support (5.x)"
        echo "  • Improved audio handling"
        echo "  • Performance monitoring"
        echo "  • Enhanced networking"
        echo "  • Kernel fallback on boot failure"
        echo "  • Log viewer"
        echo ""
        echo "Sudo privileges are required for:"
        echo "  • Package installation"
        echo "  • Audio configuration"
        echo ""
        echo "Press ENTER to continue or Ctrl+C to exit..."
        read -r
    fi
fi

main "$@"
