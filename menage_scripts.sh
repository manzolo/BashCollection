#!/bin/bash

# Destination directory for symlinks
INSTALL_DIR="/usr/local/bin"

# Check if the script is run with root permissions
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use 'sudo'."
    exit 1
fi

# List of directories to scan for scripts
SCRIPT_DIRS=("backup" "cleaner" "docker" "nvidia" "utils")

# Function to install the scripts
install_scripts() {
    echo "Installing scripts into: $INSTALL_DIR"
    for dir in "${SCRIPT_DIRS[@]}"; do
        echo "Scanning directory: $dir"
        for script in "$dir"/*.sh; do
            if [ -f "$script" ]; then
                script_name=$(basename "$script" .sh)
                ln -sf "$(pwd)/$script" "$INSTALL_DIR/$script_name"
                echo "  - Symlink created: $INSTALL_DIR/$script_name -> $script"
            fi
        done
    done
    echo "Installation complete! The scripts are now available in your PATH."
    echo "You may need to restart your shell for changes to take effect."
}

# Function to uninstall the scripts
uninstall_scripts() {
    echo "Uninstalling scripts from: $INSTALL_DIR"
    for dir in "${SCRIPT_DIRS[@]}"; do
        echo "Scanning directory: $dir"
        for script in "$dir"/*.sh; do
            if [ -f "$script" ]; then
                script_name=$(basename "$script" .sh)
                if [ -L "$INSTALL_DIR/$script_name" ]; then
                    rm "$INSTALL_DIR/$script_name"
                    echo "  - Symlink removed: $INSTALL_DIR/$script_name"
                else
                    echo "  - Symlink not found: $INSTALL_DIR/$script_name. Skipping."
                fi
            fi
        done
    done
    echo "Uninstallation complete!"
}

# Main script logic
case "$1" in
    install)
        install_scripts
        ;;
    uninstall)
        uninstall_scripts
        ;;
    *)
        echo "Usage: sudo $0 {install|uninstall}"
        exit 1
        ;;
esac
