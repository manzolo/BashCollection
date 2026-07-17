#!/bin/bash
# PKG_NAME: nvidia-manager
# PKG_VERSION: 1.2.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), whiptail
# PKG_RECOMMENDS:
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive NVIDIA driver and GPU management tool
# PKG_LONG_DESCRIPTION: TUI-based tool for managing NVIDIA drivers and GPU settings.
#  .
#  Features:
#  - Check NVIDIA driver status with nvidia-smi
#  - Install and update NVIDIA drivers
#  - Configure GPU settings
#  - Monitor GPU usage and temperature
#  - Interactive whiptail-based interface
#  - Graceful Ctrl+C handling in status and troubleshoot screens
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Colori per output
# shellcheck disable=SC2034  # consumed by sourced modules
RED='\033[0;31m'
# shellcheck disable=SC2034  # consumed by sourced modules
GREEN='\033[0;32m'
# shellcheck disable=SC2034  # consumed by sourced modules
YELLOW='\033[1;33m'
# shellcheck disable=SC2034  # consumed by sourced modules
BLUE='\033[0;34m'
# shellcheck disable=SC2034  # consumed by sourced modules
GRAY='\033[0;90m'
# shellcheck disable=SC2034  # consumed by sourced modules
CYAN='\033[0;36m'
# shellcheck disable=SC2034  # consumed by sourced modules
NC='\033[0m'

SCRIPT_NAME="$(basename "$0")"

# =================== MODULE LOADER ===================
# Implementation lives in nvidia-manager/*.sh. Loaded before the argument
# handling below because it calls show_help. Resolve symlinks so the
# loader works from /usr/local/bin wrappers and direct invocation alike.
MODULE_DIR="$(dirname "$(readlink -f "$0")")/nvidia-manager"
readonly MODULE_DIR

for _module in "$MODULE_DIR/"*.sh; do
    if [ -f "$_module" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$_module"
    else
        echo "Error: module $_module not found." >&2
        exit 1
    fi
done
unset _module

# Selected GPU index shared between performance functions (was defined
# mid-file in the monolithic layout).
# shellcheck disable=SC2034  # consumed by sourced modules
SELECTED_GPU_INDEX=""
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Try '$SCRIPT_NAME --help'." >&2
        exit 2
        ;;
esac

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check if whiptail is installed
if ! command -v whiptail &> /dev/null; then
    echo "whiptail is not installed. Installing..."
    if ! apt-get update || ! apt-get install -y whiptail; then
        echo "Error: Could not install whiptail. Check your connection and repositories."
        exit 1
    fi
fi
while true; do
    CHOICE=$(whiptail --title "NVIDIA Driver Manager" --menu "Choose an option" 22 70 10 \
        "1" "Search and Install Drivers" \
        "2" "Manage Container Toolkit" \
        "3" "Check Driver Status" \
        "4" "Live GPU Dashboard" \
        "5" "Performance Controls" \
        "6" "GPU Process Viewer" \
        "7" "Clean Drivers" \
        "8" "Troubleshoot" \
        "9" "Exit" 3>&1 1>&2 2>&3)

    case $CHOICE in
        1)
            search_drivers
            ;;
        2)
            check_and_install_toolkit
            ;;
        3)
            check_driver_status
            ;;
        4)
            show_live_dashboard
            ;;
        5)
            performance_controls
            ;;
        6)
            show_gpu_processes
            ;;
        7)
            clean_drivers
            ;;
        8)
            troubleshoot_nvidia
            ;;
        9)
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
done
