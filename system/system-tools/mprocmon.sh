#!/bin/bash
# PKG_NAME: mprocmon
# PKG_VERSION: 2.1.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), inotify-tools, net-tools, lsof
# PKG_RECOMMENDS: iftop, nethogs, iotop
# PKG_ALIASES: manzolo-process-monitor
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced network and file system monitor
# PKG_LONG_DESCRIPTION: Interactive tool for monitoring network connections
#  and file system changes in real-time.
#  .
#  Features:
#  - Real-time network connection monitoring
#  - File system change detection with inotify
#  - Process monitoring and tracking
#  - Bandwidth usage statistics
#  - Connection filtering and analysis
#  - Logging and reporting
#  - Interactive TUI interface
#  - Configuration file support
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Network and File Monitor Script
# Author: System Administrator
# Version: 2.0
# Description: Advanced interactive tool for network and file system monitoring
# Last Updated: $(date +%Y-%m-%d)

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Global configuration
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="2.1.0"
readonly LOG_DIR="/tmp/${SCRIPT_NAME%.*}_logs"
LOG_FILE="${LOG_DIR}/monitor_$(date +%Y%m%d_%H%M%S).log"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly LOG_FILE
# shellcheck disable=SC2034  # consumed by sourced modules
readonly CONFIG_FILE="$HOME/.netmonitor.conf"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly TEMP_DIR="/tmp/${SCRIPT_NAME%.*}_$$"

# Color codes for output (some unused — palette kept for future use)
# shellcheck disable=SC2034  # consumed by sourced modules
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
# shellcheck disable=SC2034  # consumed by sourced modules
readonly YELLOW='\033[1;33m'
# shellcheck disable=SC2034  # consumed by sourced modules
readonly BLUE='\033[0;34m'
# shellcheck disable=SC2034
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
# shellcheck disable=SC2034
readonly WHITE='\033[1;37m'
# shellcheck disable=SC2034  # consumed by sourced modules
readonly NC='\033[0m' # No Color

# Initialize environment
# =================== MODULE LOADER ===================
# Implementation lives in mprocmon/*.sh. Resolve symlinks so the loader
# works from /usr/local/bin wrappers and direct invocation alike.
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

for _module in "$SCRIPT_DIR/mprocmon/"*.sh; do
    if [ -f "$_module" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$_module"
    else
        echo "Error: module $_module not found." >&2
        exit 1
    fi
done
unset _module

main() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
manzolo-process-monitor v$SCRIPT_VERSION - Network & file usage monitor

Usage: $(basename "$0") [-h|--help]

Interactive whiptail-based TUI for inspecting open ports,
network sockets, processes, and file locks via lsof and ss.

Run without arguments to open the interactive menu (requires
whiptail; sudo recommended for full visibility).
EOF
            exit 0
            ;;
    esac
    # Initialize environment
    init_environment
    
    # Check dependencies
    check_dependencies
    
    # Show startup message
    print_color "$GREEN" "Manzolo Network & File Monitor v$SCRIPT_VERSION"
    print_color "$CYAN" "Initializing system monitoring capabilities..."
    
    # Brief pause for visual effect
    sleep 2
    
    # Clear screen and start main menu
    clear
    show_main_menu
}

# Run main function
main "$@"
