#!/usr/bin/env bash
# luks-manager.sh
# Professional LUKS Container Manager using whiptail
# Version 2.0 - Clean whiptail-based interface

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
CYAN_BOLD='\033[1;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Check if whiptail is available
if ! command -v whiptail >/dev/null 2>&1; then
    echo "Error: 'whiptail' is required but not installed."
    echo "Please install it with:"
    echo "  Ubuntu/Debian: sudo apt install whiptail"
    echo "  CentOS/RHEL:   sudo yum install newt"
    echo "  Arch Linux:    sudo pacman -S libnewt"
    exit 1
fi

# Get the real user info even when running with sudo
if [ -n "${SUDO_USER:-}" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(eval echo "~$SUDO_USER")
    REAL_UID=$(id -u "$SUDO_USER")
    REAL_GID=$(id -g "$SUDO_USER")
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
    REAL_UID=$(id -u)
    REAL_GID=$(id -g)
fi

# Use the real user's directories
STATE_DIR="${REAL_HOME}/.luksman"
STATE_FILE="${STATE_DIR}/containers.db"
MOUNT_BASE="${REAL_HOME}/luks_mounts"

# Whiptail configuration
WT_HEIGHT=20
WT_WIDTH=78
WT_MENU_HEIGHT=12
WT_TITLE="LUKS Container Manager"

# Ensure directories exist with proper ownership
setup_directories() {
    if [ "$EUID" -eq 0 ]; then
        mkdir -p "$STATE_DIR" "$MOUNT_BASE"
        chown "$REAL_UID:$REAL_GID" "$STATE_DIR" "$MOUNT_BASE"
        if [ ! -f "$STATE_FILE" ]; then
            touch "$STATE_FILE"
            chown "$REAL_UID:$REAL_GID" "$STATE_FILE"
            chmod 600 "$STATE_FILE"
        fi
    else
        mkdir -p "$STATE_DIR" "$MOUNT_BASE"
        if [ ! -f "$STATE_FILE" ]; then
            touch "$STATE_FILE"
            chmod 600 "$STATE_FILE"
        fi
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        whiptail --title "Permission Required" \
                 --msgbox "This script needs root privileges to manage encrypted containers.\n\nPlease run with: sudo $0" \
                 10 60
        exit 1
    fi
}

# Helper functions
show_message() {
    local title="$1"
    local message="$2"
    local height="${3:-12}"
    whiptail --title "$title" --msgbox "$message" "$height" "$WT_WIDTH"
}

show_error() {
    local message="$1"
    whiptail --title "Error" --msgbox "$message" 12 "$WT_WIDTH"
}

show_success() {
    local message="$1"
    whiptail --title "Success" --msgbox "$message" 12 "$WT_WIDTH"
}

confirm_action() {
    local title="$1"
    local message="$2"
    whiptail --title "$title" --yesno "$message" 15 "$WT_WIDTH"
}

get_input() {
    local title="$1"
    local prompt="$2"
    local default="${3:-}"
    local result
    
    if result=$(whiptail --title "$title" --inputbox "$prompt" 10 "$WT_WIDTH" "$default" 3>&1 1>&2 2>&3); then
        echo "$result"
        return 0
    else
        return 1
    fi
}

get_password() {
    local title="$1"
    local prompt="$2"
    local result
    
    if result=$(whiptail --title "$title" --passwordbox "$prompt" 10 "$WT_WIDTH" 3>&1 1>&2 2>&3); then
        echo "$result"
        return 0
    else
        return 1
    fi
}

show_progress() {
    local message="$1"
    local percent="$2"
    echo "$percent" | whiptail --title "Working..." --gauge "$message" 8 "$WT_WIDTH" 0
}

get_free_mapper_name() {
    local base="$1"
    local i=1
    while cryptsetup status "${base}_${i}" >/dev/null 2>&1; do
        i=$((i+1))
    done
    echo "${base}_${i}"
}

suggest_mapper_name() {
    local filepath="$1"
    local basename
    basename=$(basename "$filepath" .luks)
    # Clean basename for use as mapper name
    basename=$(echo "$basename" | sed 's/[^a-zA-Z0-9_]/_/g')
    echo "luks_${basename}"
}

record_container() {
    echo "$1|$2|$3|$4" >> "$STATE_FILE"
    if [ "$EUID" -eq 0 ]; then
        chown "$REAL_UID:$REAL_GID" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    fi
}

list_containers() {
    if [ ! -s "$STATE_FILE" ]; then
        show_message "Container List" "No containers registered yet."
        return 1
    fi
    
    local menu_items=()
    local i=1
    
    while IFS='|' read -r filepath loopdev mapper mountpoint; do
        local basename status_icon
        basename=$(basename "$filepath")
        
        if mountpoint -q "$mountpoint" 2>/dev/null; then
            status_icon="[●]"
        else
            status_icon="[○]"
        fi
        
        menu_items+=("$i" "$status_icon $basename")
        i=$((i+1))
    done < "$STATE_FILE"
    
    if [ ${#menu_items[@]} -eq 0 ]; then
        return 1
    fi
    
    local choice
    if choice=$(whiptail --title "LUKS Containers" \
                        --menu "Select a container (● = mounted, ○ = unmounted):" \
                        "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" \
                        "${menu_items[@]}" 3>&1 1>&2 2>&3); then
        echo "$choice"
        return 0
    else
        return 1
    fi
}

show_container_details() {
    local sel="$1"
    local rec filepath loopdev mapper mountpoint
    rec=$(sed -n "${sel}p" "$STATE_FILE")
    IFS='|' read -r filepath loopdev mapper mountpoint <<< "$rec"
    
    local status_text
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        status_text="MOUNTED and accessible"
    else
        status_text="Not mounted"
    fi
    
    local details="Container: $(basename "$filepath")

File Path: $filepath
Mount Point: $mountpoint
Loop Device: $loopdev
Mapper: /dev/mapper/$mapper
Status: $status_text"
    
    show_message "Container Details" "$details"
}

create_container() {
    local current_dir
    if [ -n "${SUDO_USER:-}" ]; then
        current_dir="${PWD}"
    else
        current_dir="$(pwd)"
    fi
    
    local default_path="${current_dir}/secure_container.luks"
    
    # Get file path
    local path
    if ! path=$(get_input "Create Container" "Enter container file path:" "$default_path"); then
        return
    fi
    
    # Handle empty input
    if [ -z "$path" ]; then
        path="$default_path"
    fi
    
    # Handle relative paths
    case "$path" in
        /*) ;;
        *) path="${current_dir}/${path}" ;;
    esac
    
    # Check if file exists
    if [ -e "$path" ]; then
        if ! confirm_action "File Exists" "File '$path' already exists.\n\nThis will OVERWRITE the existing file and DESTROY any data.\n\nContinue?"; then
            return
        fi
    fi
    
    # Get container size
    local size
    if ! size=$(get_input "Container Size" "Enter container size (e.g., 100M, 1G, 2G):" "500M"); then
        return
    fi
    
    # Handle empty size
    if [ -z "$size" ]; then
        size="500M"
    fi
    
    # Get mapper name
    local suggested_mapper default_mapper
    suggested_mapper=$(suggest_mapper_name "$path")
    default_mapper=$(get_free_mapper_name "$suggested_mapper")
    
    local mapper_name
    if ! mapper_name=$(get_input "Mapper Name" "Enter device mapper name:\n\nThis will create /dev/mapper/$default_mapper" "$default_mapper"); then
        return
    fi
    
    # Handle empty mapper name
    if [ -z "$mapper_name" ]; then
        mapper_name="$default_mapper"
    fi
    
    # Check if mapper name is available
    if cryptsetup status "$mapper_name" >/dev/null 2>&1; then
        show_error "Mapper name '$mapper_name' is already in use.\n\nPlease choose a different name."
        return
    fi
    
    # Get passwords
    local pass1 pass2
    if ! pass1=$(get_password "Security Setup" "Enter passphrase for the container:"); then
        return
    fi
    
    if ! pass2=$(get_password "Security Setup" "Confirm passphrase:"); then
        return
    fi
    
    if [ "$pass1" != "$pass2" ]; then
        show_error "Passphrases do not match. Please try again."
        return
    fi
    
    # Create container with progress display
    (
        echo 10; sleep 1
        # Create container file
        if ! truncate -s "$size" "$path"; then
            echo "ERROR: Failed to create container file"
            exit 1
        fi
        
        if [ "$EUID" -eq 0 ]; then
            chown "$REAL_UID:$REAL_GID" "$path"
        fi
        
        echo 20; sleep 1
        # Setup loop device
        local loopdev
        if ! loopdev=$(losetup --find --show "$path"); then
            echo "ERROR: Failed to setup loop device"
            rm -f "$path"
            exit 1
        fi
        
        echo 40; sleep 1
        # Format with LUKS
        if ! echo "$pass1" | cryptsetup luksFormat "$loopdev" --batch-mode --key-file=- 2>/dev/null; then
            echo "ERROR: Failed to format with LUKS"
            losetup -d "$loopdev"
            rm -f "$path"
            exit 1
        fi
        
        echo 60; sleep 1
        # Open LUKS
        if ! echo "$pass1" | cryptsetup open "$loopdev" "$mapper_name" --key-file=- 2>/dev/null; then
            echo "ERROR: Failed to open LUKS container"
            losetup -d "$loopdev"
            rm -f "$path"
            exit 1
        fi
        
        echo 80; sleep 1
        # Create filesystem
        if ! mkfs.ext4 -F "/dev/mapper/$mapper_name" >/dev/null 2>&1; then
            echo "ERROR: Failed to create filesystem"
            cryptsetup close "$mapper_name"
            losetup -d "$loopdev"
            rm -f "$path"
            exit 1
        fi
        
        echo 90; sleep 1
        # Mount
        local mountpoint="${MOUNT_BASE}/$(basename "$path" .luks)"
        mkdir -p "$mountpoint"
        
        if ! mount "/dev/mapper/$mapper_name" "$mountpoint"; then
            echo "ERROR: Failed to mount container"
            cryptsetup close "$mapper_name"
            losetup -d "$loopdev"
            rm -f "$path"
            exit 1
        fi
        
        chown "$REAL_UID:$REAL_GID" "$mountpoint"
        
        echo 100; sleep 1
        # Record container
        record_container "$path" "$loopdev" "$mapper_name" "$mountpoint"
        
    ) | whiptail --title "Creating Container" --gauge "Creating container file..." 8 "$WT_WIDTH" 0
    
    # Check if creation was successful
    local mountpoint="${MOUNT_BASE}/$(basename "$path" .luks)"
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        show_success "Container created successfully!\n\nLocation: $mountpoint\nMapper: /dev/mapper/$mapper_name\nUser: $REAL_USER\n\nThe encrypted container is ready for use."
    else
        show_error "Container creation failed. Please check the system logs for details."
    fi
}

mount_container() {
    local sel
    if ! sel=$(list_containers); then
        return
    fi
    
    local rec filepath loopdev mapper mountpoint
    rec=$(sed -n "${sel}p" "$STATE_FILE")
    IFS='|' read -r filepath loopdev mapper mountpoint <<< "$rec"
    
    # Check if already mounted
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        show_message "Already Mounted" "Container is already mounted at:\n$mountpoint"
        return
    fi
    
    # Check if file exists
    if [ ! -f "$filepath" ]; then
        show_error "Container file not found:\n$filepath"
        return
    fi
    
    # Setup loop device if needed
    if [ ! -b "$loopdev" ] || ! losetup -a 2>/dev/null | grep -q "^${loopdev}:"; then
        if ! loopdev=$(losetup --find --show "$filepath"); then
            show_error "Failed to setup loop device."
            return
        fi
        
        # Update record
        local tmp_file
        tmp_file=$(mktemp)
        awk -F'|' -v OFS='|' -v line="$sel" -v new_loop="$loopdev" \
            'NR==line {$2=new_loop} 1' "$STATE_FILE" > "$tmp_file"
        mv "$tmp_file" "$STATE_FILE"
        if [ "$EUID" -eq 0 ]; then
            chown "$REAL_UID:$REAL_GID" "$STATE_FILE"
            chmod 600 "$STATE_FILE"
        fi
    fi
    
    # Get password
    local pass
    if ! pass=$(get_password "Mount Container" "Enter passphrase for '$(basename "$filepath")':"); then
        return
    fi
    
    # Mount with progress display
    (
        echo 25; sleep 1
        # Open LUKS
        if ! echo "$pass" | cryptsetup open "$loopdev" "$mapper" --key-file=- 2>/dev/null; then
            echo "ERROR: Wrong passphrase"
            exit 1
        fi
        
        echo 75; sleep 1
        # Mount filesystem
        mkdir -p "$mountpoint"
        if ! mount "/dev/mapper/$mapper" "$mountpoint"; then
            echo "ERROR: Failed to mount"
            cryptsetup close "$mapper"
            exit 1
        fi
        
        if [ "$EUID" -eq 0 ]; then
            chown "$REAL_UID:$REAL_GID" "$mountpoint"
        fi
        
        echo 100; sleep 1
        
    ) | whiptail --title "Mounting Container" --gauge "Opening LUKS container..." 8 "$WT_WIDTH" 0
    
    # Check if mount was successful
    if mountpoint -q "$mountpoint" 2>/dev/null; then
        show_success "Container mounted successfully!\n\nLocation: $mountpoint\nMapper: /dev/mapper/$mapper\nUser: $REAL_USER\n\nFiles are now accessible."
    else
        show_error "Failed to mount container.\n\nPlease check your passphrase and try again."
    fi
}

unmount_container() {
    local sel
    if ! sel=$(list_containers); then
        return
    fi
    
    local rec filepath loopdev mapper mountpoint
    rec=$(sed -n "${sel}p" "$STATE_FILE")
    IFS='|' read -r filepath loopdev mapper mountpoint <<< "$rec"
    
    # Unmount with progress display
    (
        echo 25; sleep 1
        # Unmount filesystem
        if mountpoint -q "$mountpoint" 2>/dev/null; then
            if ! umount "$mountpoint" 2>/dev/null; then
                echo "ERROR: Failed to unmount - files may be in use"
                exit 1
            fi
        fi
        
        echo 50; sleep 1
        # Close LUKS
        if cryptsetup status "$mapper" >/dev/null 2>&1; then
            cryptsetup close "$mapper"
        fi
        
        echo 75; sleep 1
        # Detach loop device
        if losetup -a 2>/dev/null | grep -q "^${loopdev}:"; then
            losetup -d "$loopdev"
        fi
        
        echo 100; sleep 1
        
    ) | whiptail --title "Unmounting Container" --gauge "Unmounting filesystem..." 8 "$WT_WIDTH" 0
    
    # Verify unmount
    if ! mountpoint -q "$mountpoint" 2>/dev/null; then
        show_success "Container '$(basename "$filepath")' unmounted safely.\n\nThe encrypted data is now secure and inaccessible."
    else
        show_error "Failed to unmount container.\n\nFiles may be in use. Please close all applications accessing the container and try again."
    fi
}

delete_container() {
    local sel
    if ! sel=$(list_containers); then
        return
    fi
    
    local rec filepath loopdev mapper mountpoint
    rec=$(sed -n "${sel}p" "$STATE_FILE")
    IFS='|' read -r filepath loopdev mapper mountpoint <<< "$rec"
    
    if ! confirm_action "PERMANENT DELETION" "This will PERMANENTLY DELETE the container:\n\n$filepath\n\nALL DATA WILL BE LOST FOREVER!\nThis action CANNOT be undone.\n\nAre you absolutely sure?"; then
        return
    fi
    
    # Double confirmation for safety
    if ! confirm_action "FINAL CONFIRMATION" "Last chance to cancel!\n\nDelete '$filepath' permanently?\n\nThis will destroy all encrypted data forever."; then
        return
    fi
    
    # Delete with progress display
    (
        echo 20; sleep 1
        # Cleanup resources
        if mountpoint -q "$mountpoint" 2>/dev/null; then
            umount "$mountpoint" 2>/dev/null || true
        fi
        if cryptsetup status "$mapper" >/dev/null 2>&1; then
            cryptsetup close "$mapper" || true
        fi
        if losetup -a 2>/dev/null | grep -q "^${loopdev}:"; then
            losetup -d "$loopdev" || true
        fi
        
        echo 60; sleep 1
        # Delete file
        rm -f "$filepath"
        
        echo 90; sleep 1
        # Update registry
        local tmp_file
        tmp_file=$(mktemp)
        sed "${sel}d" "$STATE_FILE" > "$tmp_file"
        mv "$tmp_file" "$STATE_FILE"
        if [ "$EUID" -eq 0 ]; then
            chown "$REAL_UID:$REAL_GID" "$STATE_FILE"
            chmod 600 "$STATE_FILE"
        fi
        
        echo 100; sleep 1
        
    ) | whiptail --title "Deleting Container" --gauge "Cleaning up resources..." 8 "$WT_WIDTH" 0
    
    show_success "Container deleted permanently.\n\nAll data has been irreversibly destroyed."
}

show_status() {
    if [ ! -s "$STATE_FILE" ]; then
        show_message "Container Status" "No containers registered."
        return
    fi
    
    local details=""
    local i=1
    
    while IFS='|' read -r filepath loopdev mapper mountpoint; do
        local basename status_text status_icon
        basename=$(basename "$filepath")
        
        if mountpoint -q "$mountpoint" 2>/dev/null; then
            status_text="MOUNTED and accessible"
            status_icon="●"
        elif cryptsetup status "$mapper" >/dev/null 2>&1; then
            status_text="LUKS open but not mounted"
            status_icon="◐"
        else
            status_text="Closed and secure"
            status_icon="○"
        fi
        
        details+="[$i] $status_icon $basename
    File:     $filepath
    Mount:    $mountpoint
    Mapper:   /dev/mapper/$mapper
    Status:   $status_text

"
        i=$((i+1))
    done < "$STATE_FILE"
    
    whiptail --title "Container Status Overview" \
             --msgbox "$details" \
             24 "$WT_WIDTH" \
             --scrolltext
}

show_manual_commands() {
    clear
    echo
    echo -e "${CYAN_BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN_BOLD}║${NC}                    ${WHITE}Manual LUKS Commands Reference ${NC}                   ${CYAN_BOLD}║${NC}"
    echo -e "${CYAN_BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${YELLOW}CREATE CONTAINER:${NC}"
    echo -e "${GREEN}# Create 500MB file${NC}"
    echo -e "${WHITE}truncate -s 500M container.luks${NC}"
    echo -e "${GREEN}# Setup loop device${NC}"
    echo -e "${WHITE}sudo losetup --find --show container.luks${NC}"
    echo -e "${GREEN}# Format with LUKS (replace /dev/loopX with actual device)${NC}"
    echo -e "${WHITE}sudo cryptsetup luksFormat /dev/loopX${NC}"
    echo -e "${GREEN}# Open container${NC}"
    echo -e "${WHITE}sudo cryptsetup open /dev/loopX my_container${NC}"
    echo -e "${GREEN}# Create filesystem${NC}"
    echo -e "${WHITE}sudo mkfs.ext4 /dev/mapper/my_container${NC}"
    echo
    
    echo -e "${YELLOW}MOUNT EXISTING:${NC}"
    echo -e "${GREEN}# Setup loop device${NC}"
    echo -e "${WHITE}sudo losetup --find --show container.luks${NC}"
    echo -e "${GREEN}# Open LUKS (replace /dev/loopX)${NC}"
    echo -e "${WHITE}sudo cryptsetup open /dev/loopX my_container${NC}"
    echo -e "${GREEN}# Create mount point and mount${NC}"
    echo -e "${WHITE}mkdir -p ~/mnt/secure${NC}"
    echo -e "${WHITE}sudo mount /dev/mapper/my_container ~/mnt/secure${NC}"
    echo -e "${GREEN}# Fix permissions${NC}"
    echo -e "${WHITE}sudo chown $REAL_USER:$REAL_USER ~/mnt/secure${NC}"
    echo
    
    echo -e "${YELLOW}UNMOUNT:${NC}"
    echo -e "${GREEN}# Unmount filesystem${NC}"
    echo -e "${WHITE}sudo umount ~/mnt/secure${NC}"
    echo -e "${GREEN}# Close LUKS${NC}"
    echo -e "${WHITE}sudo cryptsetup close my_container${NC}"
    echo -e "${GREEN}# Detach loop device (find with: losetup -a)${NC}"
    echo -e "${WHITE}sudo losetup -d /dev/loopX${NC}"
    echo
    
    echo -e "${YELLOW}USEFUL COMMANDS:${NC}"
    echo -e "${GREEN}# List active loop devices${NC}"
    echo -e "${WHITE}losetup -a${NC}"
    echo -e "${GREEN}# List active LUKS mappings${NC}"
    echo -e "${WHITE}ls -la /dev/mapper/${NC}"
    echo -e "${GREEN}# Check LUKS status${NC}"
    echo -e "${WHITE}sudo cryptsetup status my_container${NC}"
    echo -e "${GREEN}# Check mount points${NC}"
    echo -e "${WHITE}mount | grep mapper${NC}"
    echo -e "${GREEN}# Force cleanup (if something is stuck)${NC}"
    echo -e "${WHITE}sudo cryptsetup close my_container${NC}"
    echo -e "${WHITE}sudo losetup -D  ${GREEN}# Detach all unused loop devices${NC}"
    echo
    
    echo -e "${CYAN}Press Enter to continue...${NC}"
    read
}

show_menu() {
    local container_count=0
    if [ -s "$STATE_FILE" ]; then
        container_count=$(wc -l < "$STATE_FILE")
    fi
    
    while true; do
        local choice
        choice=$(whiptail --title "$WT_TITLE v2.0" \
                         --menu "Professional Encrypted Storage Management\nRunning as: $REAL_USER (via $(whoami))\nContainers: $container_count" \
                         20 78 8 \
                         "1" "Create new encrypted container" \
                         "2" "Mount existing container" \
                         "3" "Unmount container" \
                         "4" "Delete container (⚠ destroys data)" \
                         "5" "Show container status" \
                         "6" "Show manual commands" \
                         "7" "Exit" 3>&1 1>&2 2>&3) || break
        
        case "$choice" in
            1) create_container ;;
            2) mount_container ;;
            3) unmount_container ;;
            4) delete_container ;;
            5) show_status ;;
            6) show_manual_commands ;;
            7) break ;;
        esac
        
        # Update container count
        if [ -s "$STATE_FILE" ]; then
            container_count=$(wc -l < "$STATE_FILE")
        else
            container_count=0
        fi
    done
}

main() {
    check_root
    setup_directories
    
    # Welcome message
    whiptail --title "Welcome" \
             --msgbox "LUKS Container Manager v2.0\n\nProfessional encrypted storage management for Linux systems.\n\nPress OK to continue." \
             12 60
    
    show_menu
    
    # Goodbye message
    whiptail --title "Goodbye" \
             --msgbox "Thank you for using LUKS Container Manager!\n\nYour encrypted data remains secure." \
             10 60
    
    clear
    echo "LUKS Container Manager - Session ended"
}

main "$@"