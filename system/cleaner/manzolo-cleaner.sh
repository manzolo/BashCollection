#!/bin/bash
# PKG_NAME: manzolo-cleaner
# PKG_VERSION: 2.6.2
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), dialog, bc, sudo
# PKG_RECOMMENDS: apt, dpkg
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced system cleaning and maintenance tool
# PKG_LONG_DESCRIPTION: Dialog-based tool for cleaning and maintaining Debian/Ubuntu systems.
#  .
#  Features:
#  - Clean package cache and unused packages
#  - Remove old kernel versions safely
#  - Clear system logs and temporary files
#  - Free disk space analysis
#  - Configurable cleaning options
#  - Interactive TUI with progress tracking
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# ManzoloCleaner - Advanced System Cleaning Tool
# Improved version v2.5 with fixed kernel removal, better command execution, and optimizations

# Configuration
SCRIPT_NAME="ManzoloCleaner"
# shellcheck disable=SC2034  # consumed by sourced modules
LOG_FILE="/tmp/manzolo-cleaner.log"
# shellcheck disable=SC2034  # reserved for future per-user config support
CONFIG_FILE="$HOME/.manzolo-cleaner.conf"
# shellcheck disable=SC2034  # consumed by sourced modules
TEMP_OUTPUT="/tmp/manzolo-cleaner-output.txt"
# shellcheck disable=SC2034  # consumed by sourced modules
TEMP_COMMAND="/tmp/manzolo_temp_command.sh"  # New: Temp file for complex commands

# Colors for output
# shellcheck disable=SC2034  # consumed by sourced modules
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
# =================== MODULE LOADER ===================
# Implementation lives in manzolo-cleaner/*.sh. Resolve symlinks so the loader
# works from /usr/local/bin wrappers and direct invocation alike.
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

for _module in "$SCRIPT_DIR/manzolo-cleaner/"*.sh; do
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
$SCRIPT_NAME - Advanced system cleaning and maintenance tool

Usage: $(basename "$0") [-h|--help]

Interactive dialog-based tool for cleaning and maintaining
Debian/Ubuntu systems. Provides safe kernel removal, package
cache cleanup, log rotation, and disk-usage analysis.

Run without arguments to open the interactive menu (requires
sudo and dialog).
EOF
            exit 0
            ;;
    esac
    # Welcome banner
    clear
    echo -e "${BLUE}"
    echo "███╗   ███╗ █████╗ ███╗   ██╗███████╗ ██████╗ ██╗     ██████╗ "
    echo "████╗ ████║██╔══██╗████╗  ██║╚══███╔╝██╔═══██╗██║     ██╔═══██╗"
    echo "██╔████╔██║███████║██╔██╗ ██║  ███╔╝ ██║   ██║██║     ██║   ██║"
    echo "██║╚██╔╝██║██╔══██║██║╚██╗██║ ███╔╝  ██║   ██║██║     ██║   ██║"
    echo "██║ ╚═╝ ██║██║  ██║██║ ╚████║███████╗╚██████╔╝███████╗╚██████╔╝"
    echo "╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝ ╚═════╝ ╚══════╝ ╚═════╝ "
    echo -e "${NC}"
    echo -e "${YELLOW}               CLEANER v2.5${NC}"
    echo ""
    echo -e "${GREEN}Initializing...${NC}"
    
    # Initialize the script
    init_script
    
    sleep 2
    
    # Start the main menu
    main_menu
}

# Run the script
main "$@"
