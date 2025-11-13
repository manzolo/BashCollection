#!/bin/bash
# PKG_NAME: ssh-manager
# PKG_VERSION: 2.4.2
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), openssh-client
# PKG_RECOMMENDS: sshpass, autossh
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Enhanced SSH connection manager with profiles and automation
# PKG_LONG_DESCRIPTION: Comprehensive SSH management tool for managing
#  multiple SSH connections, profiles, and automation tasks.
#  .
#  Features:
#  - Save and manage SSH connection profiles
#  - Quick connect to saved hosts
#  - SSH key management and generation
#  - Advanced port forwarding (Local, Remote, Dynamic/SOCKS)
#  - Auto-reconnect tunnels with autossh
#  - Connection logging and history
#  - Batch operations across multiple hosts
#  - YAML-based configuration
#  - Modular architecture for easy extension
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Enhanced SSH Manager
# Version: 2.4.2 - Port Forwarding & Tunnel Management (grep compatibility fix)

# Get script directory for module loading
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
CONFIG_DIR="$HOME/.config/manzolo-ssh-manager"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
LOG_FILE="$CONFIG_DIR/ssh-manager.log"

# Source all modules
for module in "$SCRIPT_DIR/ssh-manager/"*.sh; do
    if [[ -f "$module" ]]; then
        source "$module"
    fi
done

# Main function
main() {
    # Check Bash version
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        print_message "$RED" "❌ Bash version 4 or higher required. Current version: $BASH_VERSION"
        exit 1
    fi
    
    # Check prerequisites
    if ! command -v dialog &> /dev/null; then
        print_message "$RED" "❌ Dialog is not installed. Run option 9 from the menu."
        echo "Do you want to install the prerequisites now? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_prerequisites || exit 1
        else
            exit 1
        fi
    fi
    
    if ! command -v yq &> /dev/null; then
        print_message "$RED" "❌ yq is not installed. Run option 9 from the menu."
        echo "Do you want to install the prerequisites now? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            install_prerequisites || exit 1
        else
            exit 1
        fi
    fi
    
    # Initialize configuration
    init_config
    
    # Log startup
    log_message "INFO" "SSH Manager started"
    
    # Start main menu
    main_menu
}

# Run if script is called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
