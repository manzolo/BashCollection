#!/bin/bash

# Codici ANSI per i colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Destination directory for symlinks
INSTALL_DIR="/usr/local/bin"

# Check if the script is run with root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use 'sudo'.${NC}"
    exit 1
fi

# List of directories to scan for scripts
SCRIPT_DIRS=("backup" "cleaner" "docker" "nvidia" "utils")

install_scripts() {
    echo -e "${BLUE}>>> Installing scripts into: $INSTALL_DIR${NC}"
    for dir in "${SCRIPT_DIRS[@]}"; do
        echo -e "${YELLOW}>> Scanning directory: $dir${NC}"
        for script in "$dir"/*.sh; do
            if [ -f "$script" ]; then
                script_name=$(basename "$script" .sh)
                ln -sf "$(pwd)/$script" "$INSTALL_DIR/$script_name"
                echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC} -> ${BLUE}$script${NC}"
            fi
        done
    done
    echo -e "\n${GREEN}Installation complete!${NC} The scripts are now available in your PATH."
    echo -e "You may need to restart your shell for changes to take effect."
}
uninstall_scripts() {
    echo -e "${BLUE}>>> Uninstalling scripts from: $INSTALL_DIR${NC}"
    for dir in "${SCRIPT_DIRS[@]}"; do
        echo -e "${YELLOW}>> Scanning directory: $dir${NC}"
        for script in "$dir"/*.sh; do
            if [ -f "$script" ]; then
                script_name=$(basename "$script" .sh)
                if [ -L "$INSTALL_DIR/$script_name" ]; then
                    rm "$INSTALL_DIR/$script_name"
                    echo -e "  ${RED}✖ Symlink removed:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC}"
                else
                    echo -e "  ${YELLOW}→ Symlink not found:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC}. Skipping."
                fi
            fi
        done
    done
    echo -e "\n${GREEN}Uninstallation complete!${NC}"
}

list_scripts() {
    echo -e "${BLUE}>>> Available commands:${NC}"
    local count=0
    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            for script in "$dir"/*.sh; do
                if [ -f "$script" ]; then
                    script_name=$(basename "$script" .sh)
                    echo -e "  ${GREEN}•${NC} ${YELLOW}$script_name${NC} ${BLUE}(from $dir)${NC}"
                    count=$((count + 1))
                fi
            done
        fi
    done
    if [ "$count" -eq 0 ]; then
        echo -e "  ${YELLOW}No scripts found.${NC}"
    else
        echo -e "\n${GREEN}Total:${NC} ${YELLOW}$count commands.${NC}"
    fi
}

# Main script logic
case "$1" in
    install)
        install_scripts
        ;;
    uninstall)
        uninstall_scripts
        ;;
    list)
        list_scripts
        ;;
    *)
        echo "Usage: sudo $0 {install|uninstall|list}"
        exit 1
        ;;
esac
