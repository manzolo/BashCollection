#!/bin/bash
# PKG_NAME: mfirewall
# PKG_VERSION: 1.3.0
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), ufw, whiptail
# PKG_ALIASES: manzolo-firewall
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Advanced interactive UFW firewall manager
# PKG_LONG_DESCRIPTION: TUI-based tool for managing UFW firewall with advanced features.
#  .
#  Features:
#  - Interactive whiptail-based interface
#  - Enable/disable firewall
#  - Add/remove firewall rules
#  - Port management (allow/deny)
#  - Application profiles
#  - Rule backup and restore
#  - Status monitoring and logging
#  - Default policy configuration
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# UFW Manager - Advanced Interactive Firewall Management (Whiptail Version)
# Author: Manzolo
# Version: 1.3 - Modular layout (mfirewall/*.sh)
# License: MIT
# Compatible: Ubuntu 18.04+, Debian 10+

set -euo pipefail
LANG=C
LC_ALL=C

# =================== CONFIGURATION ===================
readonly SCRIPT_VERSION="1.3.0"
# shellcheck disable=SC2034
readonly SCRIPT_NAME="Manzolo UFW Manager"
# shellcheck disable=SC2034  # consumed by sourced modules
readonly LOG_FILE="/var/log/ufw-manager.log"
# shellcheck disable=SC2034
readonly CONFIG_FILE="/etc/ufw-manager/config.conf"
# shellcheck disable=SC2034
readonly BACKUP_DIR="/etc/ufw-manager/backups"

# Whiptail configuration
# shellcheck disable=SC2034
readonly WT_HEIGHT=20
# shellcheck disable=SC2034
readonly WT_WIDTH=78
# shellcheck disable=SC2034
readonly WT_MENU_HEIGHT=12

# =================== MODULE LOADER ===================
# Implementation lives in mfirewall/*.sh (menu, rules, policies,
# monitoring, audit, backup, utils). Resolve symlinks so the loader
# works from /usr/local/bin wrappers and direct invocation alike.
SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_PATH
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_DIR

for _module in "$SCRIPT_DIR/mfirewall/"*.sh; do
    if [ -f "$_module" ]; then
        # shellcheck disable=SC1090  # dynamic module loader
        source "$_module"
    else
        echo "Error: module $_module not found." >&2
        exit 1
    fi
done
unset _module

# =================== INITIALIZATION ===================

initialize_script() {
    setup_directories
    log_action "START" "UFW Manager Professional v$SCRIPT_VERSION started"
    check_system_requirements
}

# =================== MAIN EXECUTION ===================

main() {
    case "${1:-}" in
        -h|--help)
            cat <<EOF
manzolo-firewall - Professional UFW management TUI

Usage: $(basename "$0") [-h|--help]

Interactive whiptail-based front-end for managing UFW
(Uncomplicated Firewall): rules, policies, profiles, backups,
and logs. Requires sudo and ufw.

Run without arguments to open the interactive menu.
EOF
            exit 0
            ;;
    esac
    initialize_script
    main_menu
}

# Execute main function
main "$@"
