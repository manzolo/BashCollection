#!/bin/bash

# Codici ANSI per i colori
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Destination directories
INSTALL_DIR="/usr/local/bin"          # For main script symlinks
SCRIPT_BASE_DIR="/usr/local/share/scripts"  # For script directories and subdirectories

# Check if the script is run with root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}This script must be run as root. Please use 'sudo'.${NC}"
    exit 1
fi

# List of directories to scan for scripts
SCRIPT_DIRS=("backup" "cleaner" "docker" "nvidia" "utils" "vm")

install_scripts() {
    echo -e "${BLUE}>>> Installing scripts into: $SCRIPT_BASE_DIR and $INSTALL_DIR${NC}"

    # Create the base directory for scripts
    mkdir -p "$SCRIPT_BASE_DIR"

    for dir in "${SCRIPT_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "${YELLOW}>> Processing directory: $dir${NC}"
            
            # Copy the entire directory (including subdirectories) to SCRIPT_BASE_DIR
            cp -r "$dir" "$SCRIPT_BASE_DIR/"
            chmod -R 755 "$SCRIPT_BASE_DIR/$dir"
            
            # Create symlink for each .sh file in the top-level directory
            for script in "$dir"/*.sh; do
                if [ -f "$script" ]; then
                    script_name=$(basename "$script" .sh)
                    ln -sf "$SCRIPT_BASE_DIR/$dir/$script_name.sh" "$INSTALL_DIR/$script_name"
                    echo -e "  ${GREEN}✔ Symlink created:${NC} ${YELLOW}$INSTALL_DIR/$script_name${NC} -> ${BLUE}$SCRIPT_BASE_DIR/$dir/$script_name.sh${NC}"
                fi
            done
        else
            echo -e "  ${YELLOW}Directory $dir not found, skipping.${NC}"
        fi
    done
    echo -e "\n${GREEN}Installation complete!${NC} The scripts are now available in your PATH."
    echo -e "You may need to restart your shell for changes to take effect."
}

uninstall_scripts() {
    echo -e "${BLUE}>>> Uninstalling scripts from: $INSTALL_DIR and $SCRIPT_BASE_DIR${NC}"

    for dir in "${SCRIPT_DIRS[@]}"; do
        echo -e "${YELLOW}>> Processing directory: $dir${NC}"
        
        # Remove symlinks for scripts in the top-level directory
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
        
        # Remove the directory from SCRIPT_BASE_DIR
        if [ -d "$SCRIPT_BASE_DIR/$dir" ]; then
            rm -rf "$SCRIPT_BASE_DIR/$dir"
            echo -e "  ${RED}✖ Directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR/$dir${NC}"
        fi
    done
    # Remove SCRIPT_BASE_DIR if empty
    rmdir "$SCRIPT_BASE_DIR" 2>/dev/null && echo -e "  ${RED}✖ Base directory removed:${NC} ${YELLOW}$SCRIPT_BASE_DIR${NC}"
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