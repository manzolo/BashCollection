#!/bin/bash
# PKG_NAME: gnome-backup
# PKG_VERSION: 1.0.0
# PKG_SECTION: utils
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), dconf-cli
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: GNOME settings backup, restore and reset tool
# PKG_LONG_DESCRIPTION: Manages GNOME desktop configuration via dconf.
#  Supports full backup, restore from a specific snapshot, and factory reset
#  of desktop, shell, terminal, Nautilus and Gedit settings.
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# GNOME Settings Backup/Restore/Reset Script for Ubuntu
# Author: GNOME Configuration Management Script
# Version: 1.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default backup directory
DEFAULT_BACKUP_DIR="$HOME/.gnome-backup"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to show help
show_help() {
    cat << EOF
GNOME Settings Manager - Backup, Restore, and Reset of GNOME Settings

Usage: $0 [OPTION] [DIRECTORY]

OPTIONS:
    backup      Creates a backup of GNOME settings
    restore     Restores settings from a backup
    reset       Complete reset of GNOME settings
    list        Shows all available backups
    help        Shows this help message

DIRECTORY:
    Custom path for the backup (optional)
    Default: $DEFAULT_BACKUP_DIR

EXAMPLES:
    $0 backup                           # Backup to the default directory
    $0 backup /path/to/custom/backup    # Backup to a custom directory
    $0 restore                          # Restore from the latest backup
    $0 restore /path/to/backup          # Restore from a specific backup
    $0 reset                            # Complete reset of settings
    $0 list                             # List all backups

NOTE: This script requires 'dconf' to function correctly.
EOF
}

# Check if dconf is installed
check_dependencies() {
    if ! command -v dconf &> /dev/null; then
        print_message $RED "ERROR: dconf is not installed!"
        print_message $YELLOW "Install dconf with: sudo apt install dconf-cli"
        exit 1
    fi
}

# Function to create the backup
create_backup() {
    local backup_dir=${1:-$DEFAULT_BACKUP_DIR}
    local backup_path="$backup_dir/gnome-backup-$TIMESTAMP"
    
    print_message $BLUE "Creating backup of GNOME settings..."
    
    # Create the backup directory if it doesn't exist
    mkdir -p "$backup_path"
    
    # Backup dconf settings
    print_message $YELLOW "Backing up dconf settings..."
    dconf dump / > "$backup_path/dconf-settings.conf"
    
    # Backup specific configurations
    print_message $YELLOW "Backing up desktop configurations..."
    
    # Desktop settings
    if dconf dump /org/gnome/desktop/ > "$backup_path/desktop-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Desktop settings saved"
    fi
    
    # Shell settings
    if dconf dump /org/gnome/shell/ > "$backup_path/shell-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Shell settings saved"
    fi
    
    # Terminal settings
    if dconf dump /org/gnome/terminal/ > "$backup_path/terminal-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Terminal settings saved"
    fi
    
    # Nautilus settings
    if dconf dump /org/gnome/nautilus/ > "$backup_path/nautilus-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Nautilus settings saved"
    fi
    
    # Gedit settings
    if dconf dump /org/gnome/gedit/ > "$backup_path/gedit-settings.conf" 2>/dev/null; then
        print_message $GREEN "✓ Gedit settings saved"
    fi
    
    # Settings daemon
    if dconf dump /org/gnome/settings-daemon/ > "$backup_path/settings-daemon.conf" 2>/dev/null; then
        print_message $GREEN "✓ Settings daemon saved"
    fi
    
    # Save backup information
    cat > "$backup_path/backup-info.txt" << EOF
Backup created on: $(date)
System: $(lsb_release -d | cut -f2)
GNOME Version: $(gnome-shell --version 2>/dev/null || echo "Not available")
User: $USER
Hostname: $(hostname)
EOF
    
    # Create symbolic link to the latest backup
    ln -sfn "$backup_path" "$backup_dir/latest"
    
    print_message $GREEN "Backup completed successfully!"
    print_message $BLUE "Backup path: $backup_path"
}

# Function to restore the backup
restore_backup() {
    local backup_source=${1:-"$DEFAULT_BACKUP_DIR/latest"}
    
    # If it's a directory, use it directly, otherwise assume it's in the backup dir
    if [[ -d "$backup_source" ]]; then
        local backup_path="$backup_source"
    elif [[ -d "$DEFAULT_BACKUP_DIR/$backup_source" ]]; then
        local backup_path="$DEFAULT_BACKUP_DIR/$backup_source"
    else
        print_message $RED "ERROR: Backup not found: $backup_source"
        exit 1
    fi
    
    if [[ ! -f "$backup_path/dconf-settings.conf" ]]; then
        print_message $RED "ERROR: Invalid backup file!"
        exit 1
    fi
    
    print_message $YELLOW "WARNING: This will restore all GNOME settings!"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_message $BLUE "Operation cancelled."
        exit 0
    fi
    
    print_message $BLUE "Restoring backup from: $backup_path"
    
    # Restore complete settings
    print_message $YELLOW "Restoring dconf settings..."
    dconf load / < "$backup_path/dconf-settings.conf"
    
    # Restart GNOME Shell to apply changes
    print_message $YELLOW "Restarting GNOME Shell..."
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        print_message $YELLOW "Wayland session detected. You might need to restart your session."
    else
        # X11 session
        nohup gnome-shell --replace &>/dev/null & disown
    fi
    
    print_message $GREEN "Restore complete!"
    print_message $BLUE "Changes might require a session restart to be fully applied."
}

# Function to reset settings
reset_settings() {
    print_message $YELLOW "WARNING: This will reset ALL GNOME settings to default values!"
    print_message $YELLOW "This operation CANNOT be undone!"
    echo
    read -p "Are you sure you want to continue? (RESET/N): " -r
    echo
    if [[ ! $REPLY == "RESET" ]]; then
        print_message $BLUE "Operation cancelled."
        exit 0
    fi
    
    print_message $BLUE "Resetting GNOME settings..."
    
    # Resetting main GNOME configurations
    print_message $YELLOW "Resetting desktop settings..."
    dconf reset -f /org/gnome/desktop/
    
    print_message $YELLOW "Resetting shell settings..."
    dconf reset -f /org/gnome/shell/
    
    print_message $YELLOW "Resetting terminal settings..."
    dconf reset -f /org/gnome/terminal/
    
    print_message $YELLOW "Resetting Nautilus settings..."
    dconf reset -f /org/gnome/nautilus/
    
    print_message $YELLOW "Resetting Gedit settings..."
    dconf reset -f /org/gnome/gedit/
    
    print_message $YELLOW "Resetting daemon settings..."
    dconf reset -f /org/gnome/settings-daemon/
    
    # Restart GNOME Shell
    print_message $YELLOW "Restarting GNOME Shell..."
    if [[ "$XDG_SESSION_TYPE" == "wayland" ]]; then
        print_message $YELLOW "Wayland session detected. Restart your session to fully apply the changes."
    else
        nohup gnome-shell --replace &>/dev/null & disown
    fi
    
    print_message $GREEN "Reset complete!"
    print_message $BLUE "Restart your session to fully apply all changes."
}

# Function to list backups
list_backups() {
    local backup_dir=${1:-$DEFAULT_BACKUP_DIR}
    
    if [[ ! -d "$backup_dir" ]]; then
        print_message $YELLOW "No backup directory found: $backup_dir"
        return
    fi
    
    print_message $BLUE "Available backups in: $backup_dir"
    echo
    
    local found_backups=false
    for backup in "$backup_dir"/gnome-backup-*; do
        if [[ -d "$backup" ]]; then
            found_backups=true
            local backup_name=$(basename "$backup")
            local backup_date=""
            
            if [[ -f "$backup/backup-info.txt" ]]; then
                backup_date=$(head -n 1 "$backup/backup-info.txt" | cut -d: -f2- | xargs)
            fi
            
            print_message $GREEN "📁 $backup_name"
            if [[ -n "$backup_date" ]]; then
                print_message $YELLOW "   Date: $backup_date"
            fi
            echo
        fi
    done
    
    if [[ "$found_backups" == false ]]; then
        print_message $YELLOW "No backups found."
    fi
    
    # Show the latest backup link
    if [[ -L "$backup_dir/latest" ]]; then
        local latest_target=$(readlink "$backup_dir/latest")
        print_message $BLUE "Latest backup: $(basename "$latest_target")"
    fi
}

# Main function
main() {
    check_dependencies
    
    case "${1:-}" in
        "backup")
            create_backup "${2:-}"
            ;;
        "restore")
            restore_backup "${2:-}"
            ;;
        "reset")
            reset_settings
            ;;
        "list")
            list_backups "${2:-}"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        "")
            print_message $RED "ERROR: No option specified!"
            echo
            show_help
            exit 1
            ;;
        *)
            print_message $RED "ERROR: Unrecognized option: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Execute the main function with all arguments
main "$@"