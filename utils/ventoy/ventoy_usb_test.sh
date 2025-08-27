#!/bin/bash

# Interactive script for testing Ventoy USB boot with a whiptail-based TUI
# Supports UEFI and MBR/BIOS Legacy with a graphical interface

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Configuration
readonly SCRIPT_NAME="Ventoy USB Boot Tester"
readonly VERSION="2.0"
readonly LOG_DIR="/tmp/ventoy_test_logs"
readonly CONFIG_FILE="$HOME/.ventoy_test_config"

# Global variables with default values
MEMORY="2048"
CORES="4"
THREADS="1"
SOCKETS="1"
MACHINE_TYPE="q35"
DEFAULT_BIOS="/usr/share/OVMF/OVMF.fd"
DISK=""
FORMAT="raw"
BIOS_MODE="uefi"
VGA_MODE="virtio"
NETWORK=false
SOUND=false
USB_VERSION="3.0"

# Colors for messages
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Utility functions
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check dependencies
check_dependencies() {
    local missing=()
    
    command -v qemu-system-x86_64 >/dev/null || missing+=("qemu-system-x86")
    command -v lsblk >/dev/null || missing+=("util-linux")
    command -v git >/dev/null || missing+=("git")
    command -v whiptail >/dev/null || missing+=("whiptail")
    command -v dialog >/dev/null || missing+=("dialog")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        if whiptail --title "Missing Dependencies" --yesno \
            "The following dependencies are missing:\n\n${missing[*]}\n\nWould you like to install them now?" \
            15 70; then
            
            local pkgs_to_install="${missing[*]}"
            
            # Install dependencies in the background with progress
            {
                echo "10" ; echo "Updating package indices..."
                sudo apt update >/dev/null 2>&1 || true
                
                echo "50" ; echo "Installing packages: ${pkgs_to_install}..."
                sudo apt install -y $pkgs_to_install >/dev/null 2>&1
                
                echo "100" ; echo "Completed."
            } | whiptail --gauge "Installing dependencies..." 8 70 0

            # Re-check dependencies after installation
            local missing_after_install=()
            command -v qemu-system-x86_64 >/dev/null || missing_after_install+=("qemu-system-x86")
            command -v lsblk >/dev/null || missing_after_install+=("util-linux")
            command -v git >/dev/null || missing_after_install+=("git")
            command -v whiptail >/dev/null || missing_after_install+=("whiptail")
            command -v dialog >/dev/null || missing_after_install+=("dialog")
            
            if [[ ${#missing_after_install[@]} -eq 0 ]]; then
                whiptail --title "Installation Successful" --msgbox \
                    "All dependencies have been successfully installed!" 8 50
                return 0
            else
                whiptail --title "Installation Failed" --msgbox \
                    "Failed to install dependencies. Still missing:\n\n${missing_after_install[*]}" 10 70
                return 1
            fi
        else
            return 1 # User canceled
        fi
    fi
    return 0 # No missing dependencies
}

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
MEMORY="$MEMORY"
CORES="$CORES"
THREADS="$THREADS"
SOCKETS="$SOCKETS"
DISK="$DISK"
FORMAT="$FORMAT"
BIOS_MODE="$BIOS_MODE"
VGA_MODE="$VGA_MODE"
NETWORK=$NETWORK
SOUND=$SOUND
USB_VERSION="$USB_VERSION"
EOF
    log_info "Configuration saved to $CONFIG_FILE"
}

# Load saved configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    fi
}

# Detect system capabilities
detect_system() {
    local sys_cores sys_memory_gb kvm_status
    
    sys_cores=$(nproc)
    sys_memory_gb=$(( $(free -m | awk '/^Mem:/{print $2}') / 1024 ))
    
    if [[ -c /dev/kvm && -r /dev/kvm ]]; then
        kvm_status="Available ✓"
    else
        kvm_status="Not available ✗"
    fi
    
    whiptail --title "System Information" --msgbox \
        "Detected System:\n\n• CPU Cores: $sys_cores\n• RAM: ${sys_memory_gb}GB\n• KVM: $kvm_status\n\nRecommendations:\n• CPU Cores: max $sys_cores\n• RAM: max $(( sys_memory_gb * 1024 / 2 ))MB" \
        15 50
    
    # Adjust values if necessary
    if [[ $CORES -gt $sys_cores ]]; then
        CORES="$sys_cores"
    fi
}

# Detect USB devices
detect_usb_devices() {
    local devices=()
    local all_disks_info
    
    # Use lsblk with JSON output for better processing
    all_disks_info=$(lsblk -d -J -o NAME,SIZE,HOTPLUG,RM,TYPE,LABEL,TRAN 2>/dev/null | jq -c '.blockdevices[]' 2>/dev/null)
    
    # Handle case where lsblk or jq fails or no devices are found
    if [[ -z "$all_disks_info" ]]; then
        whiptail --title "Error" --msgbox "Unable to retrieve device list" 10 50
        echo "BROWSE 'Browse image file (ISO/IMG)...'"
        echo "CUSTOM 'Custom path...'"
        return
    fi

    # Process each device
    while IFS= read -r disk; do
        local name=$(jq -r '.name' <<< "$disk" 2>/dev/null)
        local size=$(jq -r '.size' <<< "$disk" 2>/dev/null)
        local rm=$(jq -r '.rm' <<< "$disk" 2>/dev/null)
        local type=$(jq -r '.type' <<< "$disk" 2>/dev/null)
        local label=$(jq -r '.label' <<< "$disk" 2>/dev/null)
        local tran=$(jq -r '.tran' <<< "$disk" 2>/dev/null)
        
        [[ -z "$name" ]] && continue

        local full_device="/dev/$name"
        local desc="$full_device ($size)"
        
        # Add device to list only if it is a removable USB disk
        if [[ "$type" == "disk" && ( "$rm" == "1" || "$tran" == "usb" ) ]]; then
            [[ -n "$label" && "$label" != "null" ]] && desc="$desc - $label"
            devices+=("$full_device" "$desc")
        fi
    done <<< "$all_disks_info"

    # Add standard options
    devices+=("BROWSE" "Browse image file (ISO/IMG)...")
    devices+=("CUSTOM" "Custom path...")
    
    # Handle case where no USB devices are detected
    if [[ ${#devices[@]} -eq 2 ]]; then  # Only BROWSE and CUSTOM
        whiptail --title "No USB Devices" --msgbox \
            "No USB devices detected. You can select an image file." 10 50
    fi
    
    # Return array for whiptail
    printf '%s\n' "${devices[@]}"
}

# Function to browse image files (ISO, IMG, QCOW2, etc.) using dialog
browse_image_files() {
    local start_dir="$PWD"
    local selected_file=""
    local current_dir="$start_dir"
    
    # Check if 'dialog' command is available
    if ! command -v dialog &>/dev/null; then
        whiptail --title "Error" --msgbox "The 'dialog' command is not installed. Install it to use this feature." 10 60
        return 1
    fi
    
    # Navigation loop
    while true; do
        # Get files and directories in the current folder
        local items=()
        
        # Add '..' to go back
        if [[ "$current_dir" != "/" ]]; then
            items+=(".." "Parent directory")
        fi
        
        # Find directories
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                local dir_name="$(basename "$dir")"
                items+=("$dir_name" "Directory")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type d ! -path "$current_dir" -print 2>/dev/null | sort)
        
        # Find image files
        while IFS= read -r file; do
            if [[ -n "$file" ]]; then
                items+=("$(basename "$file")" "Image file")
            fi
        done < <(find "$current_dir" -maxdepth 1 -type f \( -iname "*.iso" -o -iname "*.img" -o -iname "*.qcow2" -o -iname "*.vdi" -o -iname "*.vmdk" -o -iname "*.raw" \) -print 2>/dev/null | sort)
        
        # Show menu with options
        selected_file=$(dialog --title "Browse Image Files ($current_dir)" \
            --menu "Select a file or navigate to a folder:" \
            25 78 15 "${items[@]}" 3>&1 1>&2 2>&3)
        
        # Check dialog exit code
        if [ $? -ne 0 ]; then
            # User pressed Cancel or Exit
            echo ""
            return 1
        fi
        
        # Handle selection
        if [[ "$selected_file" == ".." ]]; then
            # Go to parent directory
            current_dir=$(dirname "$current_dir")
        elif [[ -d "$current_dir/$selected_file" ]]; then
            # Enter selected directory
            current_dir="$current_dir/$selected_file"
        elif [[ -f "$current_dir/$selected_file" ]]; then
            # File selected - build full path
            selected_file="$current_dir/$selected_file"
            break # Exit loop
        else
            # Item not found - retry
            continue
        fi
    done
    
    # Normalize path if a file was selected
    if [[ -n "$selected_file" ]]; then
        selected_file=$(realpath "$selected_file" 2>/dev/null || echo "$selected_file")
    fi
    
    # Check if file exists and is readable
    if [[ -f "$selected_file" && -r "$selected_file" ]]; then
        echo "$selected_file"
        return 0
    else
        whiptail --title "File Not Found" --msgbox \
            "The selected file does not exist or is not readable:\n$selected_file" \
            10 70
        echo ""
        return 1
    fi
}

# Disk selection menu
select_disk_menu() {
    local devices_array=()
    
    readarray -t devices_array < <(detect_usb_devices)
    
    if [[ ${#devices_array[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox \
            "Unable to detect devices.\n\nUse manual selection options." \
            10 60
        devices_array=("BROWSE" "Browse image file (ISO/IMG)..." "CUSTOM" "Custom path..." "" "No selection")
    fi
    
    local selected
    selected=$(whiptail --title "Disk/Image Selection" \
        --menu "Select a USB device or image file to test:" \
        22 90 14 "${devices_array[@]}" 3>&1 1>&2 2>&3)
    
    # Handle selection
    case "$selected" in
        "BROWSE")
            local browsed_file
            browsed_file=$(browse_image_files)
            if [[ -n "$browsed_file" ]]; then
                DISK="$browsed_file"
                # Automatically set format based on extension
                case "${DISK##*.}" in
                    qcow2) FORMAT="qcow2" ;;
                    vdi) FORMAT="vdi" ;;
                    vmdk) FORMAT="vmdk" ;;
                    *) FORMAT="raw" ;;
                esac
            else
                return 1  # Browser canceled
            fi
            ;;
        "CUSTOM")
            local custom_path
            custom_path=$(whiptail --title "Custom Path" \
                --inputbox "Enter the full path:\n\nUSB Devices:\n• /dev/sdc, /dev/sdd, etc.\n\nImage Files:\n• /path/to/image.iso\n• /path/to/ventoy.img\n• /path/to/disk.qcow2" \
                18 75 "$DISK" 3>&1 1>&2 2>&3)
            
            if [[ -n "$custom_path" ]]; then
                DISK="$custom_path"
                # Auto-detect format for files
                if [[ -f "$DISK" ]]; then
                    case "${DISK##*.}" in
                        qcow2) FORMAT="qcow2" ;;
                        vdi) FORMAT="vdi" ;;
                        vmdk) FORMAT="vmdk" ;;
                        *) FORMAT="raw" ;;
                    esac
                fi
            else
                return 1  # Canceled
            fi
            ;;
        "")
            return 1  # No selection or canceled
            ;;
        *)
            if [[ -n "$selected" ]]; then
                DISK="$selected"
                FORMAT="raw"  # USB devices always raw
            else
                return 1
            fi
            ;;
    esac
    
    # Validate selection
    if [[ -n "$DISK" ]]; then
        if [[ -b "$DISK" ]]; then
            # Block device - show detailed info
            local info
            info=$(lsblk "$DISK" -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null || echo "Information not available")
            
            # Final safety check
            local mounted_critical=false
            while read -r mount; do
                [[ -z "$mount" ]] && continue
                if [[ "$mount" =~ ^(/|/boot|/home|/usr|/var|/opt|/root)$ ]]; then
                    mounted_critical=true
                    break
                fi
            done < <(lsblk -no MOUNTPOINT "$DISK" 2>/dev/null | grep -v "^$")
            
            if [[ "$mounted_critical" == true ]]; then
                whiptail --title "SAFETY WARNING" --msgbox \
                    "CRITICAL DEVICE DETECTED!\n\nThe device $DISK contains mounted system filesystems.\n\nFor safety, its use is blocked.\n\nSelect an external USB device." \
                    15 70
                DISK=""
                return 1
            fi
            
            whiptail --title "Selected Device" --msgbox \
                "Device: $DISK\n\nInformation:\n$info\n\nSafety checks: OK" \
                18 80
                
        elif [[ -f "$DISK" ]]; then
            # Image file - show info
            local size file_type
            size=$(du -h "$DISK" 2>/dev/null | cut -f1 || echo "Unknown")
            file_type=$(file "$DISK" 2>/dev/null | cut -d: -f2 || echo "Unknown type")
            
            whiptail --title "Selected File" --msgbox \
                "File: $DISK\nSize: $size\nType: $file_type" \
                12 70
                
        elif [[ -e "$DISK" ]]; then
            # Exists but is neither a device nor a regular file
            whiptail --title "Invalid File Type" --msgbox \
                "The specified path exists but is not usable:\n$DISK\n\nIt must be a block device (/dev/sdX) or an image file." \
                12 70
            DISK=""
            return 1
        else
            # Does not exist
            whiptail --title "Path Error" --msgbox \
                "The specified path does not exist or is not accessible:\n\n$DISK\n\nVerify:\n• Correct path\n• Access permissions\n• Device connected" \
                12 70
            DISK=""
            return 1
        fi
        
        return 0
    else
        return 1
    fi
}

# System configuration menu
system_config_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "System Configuration" \
            --menu "Virtual hardware configuration:" \
            18 70 8 \
            "1" "RAM: ${MEMORY}MB" \
            "2" "CPU Cores: $CORES" \
            "3" "CPU Threads/core: $THREADS" \
            "4" "CPU Sockets: $SOCKETS" \
            "5" "Machine Type: $MACHINE_TYPE" \
            "6" "Disk Format: $FORMAT" \
            "7" "USB Version: $USB_VERSION" \
            "8" "Back to main menu" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) 
                MEMORY=$(whiptail --title "RAM Configuration" \
                    --inputbox "RAM in MB (recommended: 1024-4096):" \
                    10 40 "$MEMORY" 3>&1 1>&2 2>&3) || true
                ;;
            2)
                CORES=$(whiptail --title "CPU Cores" \
                    --inputbox "Number of CPU cores (1-$(nproc)):" \
                    10 40 "$CORES" 3>&1 1>&2 2>&3) || true
                ;;
            3)
                THREADS=$(whiptail --title "CPU Threads" \
                    --inputbox "Threads per core (1-2):" \
                    10 40 "$THREADS" 3>&1 1>&2 2>&3) || true
                ;;
            4)
                SOCKETS=$(whiptail --title "CPU Sockets" \
                    --inputbox "Number of CPU sockets (usually 1):" \
                    10 40 "$SOCKETS" 3>&1 1>&2 2>&3) || true
                ;;
            5)
                MACHINE_TYPE=$(whiptail --title "Machine Type" \
                    --menu "Select machine type:" \
                    12 50 3 \
                    "q35" "Modern (recommended)" \
                    "pc" "Legacy compatibility" \
                    "microvm" "Minimal (advanced)" \
                    3>&1 1>&2 2>&3) || true
                ;;
            6)
                FORMAT=$(whiptail --title "Disk Format" \
                    --menu "Select disk format:" \
                    12 50 4 \
                    "raw" "Raw (physical devices)" \
                    "qcow2" "QEMU Copy-On-Write" \
                    "vdi" "VirtualBox Disk" \
                    "vmdk" "VMware Disk" \
                    3>&1 1>&2 2>&3) || true
                ;;
            7)
                USB_VERSION=$(whiptail --title "USB Version" \
                    --menu "Select USB controller version:" \
                    12 50 3 \
                    "1.1" "USB 1.1 (UHCI)" \
                    "2.0" "USB 2.0 (EHCI)" \
                    "3.0" "USB 3.0 (xHCI)" \
                    3>&1 1>&2 2>&3) || true
                ;;
            8|"") break ;;
        esac
    done
}

# BIOS/UEFI menu
bios_menu() {
    BIOS_MODE=$(whiptail --title "Boot Mode" \
        --menu "Select boot mode:" \
        15 60 4 \
        "uefi" "UEFI (modern, recommended)" \
        "bios" "BIOS Legacy/MBR" \
        "auto" "Automatic detection" \
        3>&1 1>&2 2>&3) || return
    
    case $BIOS_MODE in
        "uefi")
            if [[ ! -f "$DEFAULT_BIOS" ]]; then
                if whiptail --title "OVMF Not Found" --yesno \
                    "The OVMF.fd file is missing.\nWould you like to compile it now? (This may take time)" \
                    10 50; then
                    prepare_ovmf_interactive
                fi
            fi
            ;;
        "auto")
            # Automatically detect based on disk
            if [[ -b "$DISK" ]] && command -v fdisk >/dev/null; then
                local partition_table
                partition_table=$(fdisk -l "$DISK" 2>/dev/null | grep "Disklabel type" | awk '{print $3}' || echo "unknown")
                case $partition_table in
                    "gpt") BIOS_MODE="uefi" ;;
                    "dos") BIOS_MODE="bios" ;;
                    *) BIOS_MODE="uefi" ;;  # Default to modern
                esac
                whiptail --title "Automatic Detection" --msgbox \
                    "Detected partition table: $partition_table\nSelected mode: $BIOS_MODE" \
                    10 50
            else
                BIOS_MODE="uefi"  # Default
            fi
            ;;
    esac
}

# Advanced options menu
advanced_menu() {
    while true; do
        local network_status sound_status
        [[ "$NETWORK" == true ]] && network_status="Enabled ✓" || network_status="Disabled ✗"
        [[ "$SOUND" == true ]] && sound_status="Enabled ✓" || sound_status="Disabled ✗"
        
        local choice
        choice=$(whiptail --title "Advanced Options" \
            --menu "Additional configurations:" \
            16 60 6 \
            "1" "VGA: $VGA_MODE" \
            "2" "Network: $network_status" \
            "3" "Audio: $sound_status" \
            "4" "QEMU Monitor: Always enabled" \
            "5" "OVMF Management" \
            "6" "Back to main menu" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1)
                VGA_MODE=$(whiptail --title "Video Mode" \
                    --menu "Select video mode:" \
                    14 50 5 \
                    "virtio" "VirtIO (recommended)" \
                    "std" "Standard VGA" \
                    "cirrus" "Cirrus Logic" \
                    "qxl" "QXL (SPICE)" \
                    "none" "Headless (no video)" \
                    3>&1 1>&2 2>&3) || true
                ;;
            2)
                if [[ "$NETWORK" == true ]]; then
                    NETWORK=false
                else
                    NETWORK=true
                fi
                ;;
            3)
                if [[ "$SOUND" == true ]]; then
                    SOUND=false
                else
                    SOUND=true
                fi
                ;;
            4)
                whiptail --title "QEMU Monitor" --msgbox \
                    "The QEMU monitor will be available at:\n\ntelnet localhost 4444\n\nUseful commands:\n- info status\n- system_reset\n- quit" \
                    12 50
                ;;
            5) ovmf_management_menu ;;
            6|"") break ;;
        esac
    done
}

# OVMF management menu
ovmf_management_menu() {
    local ovmf_status
    if [[ -f "$DEFAULT_BIOS" ]]; then
        ovmf_status="Present ✓"
    else
        ovmf_status="Missing ✗"
    fi
    
    local choice
    choice=$(whiptail --title "OVMF Management" \
        --menu "OVMF Status: $ovmf_status\n\nAvailable options:" \
        16 60 4 \
        "1" "Compile OVMF from source" \
        "2" "Download prebuilt OVMF" \
        "3" "Custom OVMF path" \
        "4" "Back" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) prepare_ovmf_interactive ;;
        2) download_ovmf_prebuilt ;;
        3) 
            DEFAULT_BIOS=$(whiptail --title "OVMF Path" \
                --inputbox "Enter OVMF file path:" \
                10 60 "$DEFAULT_BIOS" 3>&1 1>&2 2>&3) || true
            ;;
    esac
}

# Compile OVMF interactively
prepare_ovmf_interactive() {
    # Ask for confirmation before proceeding
    if ! whiptail --title "OVMF Compilation" --yesno \
        "Compiling OVMF may take 10-30 minutes and requires about 2GB of space.\n\nProceed?" \
        10 50; then
        return
    fi

    # Check and install dependencies
    if ! install_ovmf_deps; then
        whiptail --title "Installation Canceled" --msgbox \
            "Dependencies were not installed. Unable to proceed." \
            10 50
        return
    fi

    # Create temporary files for log and progress
    local temp_log=$(mktemp)
    local temp_progress=$(mktemp)
    local temp_dir=$(mktemp -d)
    local compilation_success=false

    # Create compilation script that reports progress
    local compilation_script=$(mktemp)
    cat > "$compilation_script" << EOF
#!/bin/bash
set -e
exec > >(tee -a "${temp_log}") 2>&1

WORK_DIR="${temp_dir}"
PROGRESS_FILE="${temp_progress}"

cd "\$WORK_DIR"

echo "=== OVMF Compilation Log ===" 
echo "Started at: \$(date)"
echo "Working directory: \$WORK_DIR"
echo

# Phase 1: Clone repository
echo "10" > "\$PROGRESS_FILE"
echo "Cloning EDK2 repository..." >> "\$PROGRESS_FILE"
echo "PHASE: Cloning EDK2 repository..."
if ! git clone --depth 1 https://github.com/tianocore/edk2.git; then
    echo "ERROR: Failed to clone EDK2 repository"
    exit 1
fi
echo "Repository cloned successfully"

# Phase 2: Submodules
echo "25" > "\$PROGRESS_FILE"
echo "Initializing Git submodules..." >> "\$PROGRESS_FILE"
cd edk2/
echo "PHASE: Initializing submodules..."
if ! git submodule update --init --recursive; then
    echo "ERROR: Failed to initialize submodules"
    exit 1
fi
echo "Submodules initialized successfully"

# Phase 3: Setup environment
echo "40" > "\$PROGRESS_FILE"
echo "Setting up build environment..." >> "\$PROGRESS_FILE"
echo "PHASE: Setting up build environment..."
if ! source ./edksetup.sh BaseTools; then
    echo "ERROR: Failed to setup build environment"
    exit 1
fi
echo "Build environment configured successfully"

# Phase 4: Build BaseTools
echo "55" > "\$PROGRESS_FILE"
echo "Building BaseTools..." >> "\$PROGRESS_FILE"
echo "PHASE: Building BaseTools..."
if ! make -C BaseTools/; then
    echo "ERROR: Failed to build BaseTools"
    exit 1
fi
echo "BaseTools built successfully"

# Phase 5: Build OVMF
echo "70" > "\$PROGRESS_FILE"
echo "Building OVMF (this phase takes longer)..." >> "\$PROGRESS_FILE"
echo "PHASE: Building OVMF firmware..."
if ! OvmfPkg/build.sh -a X64 -b RELEASE -t GCC5; then
    echo "ERROR: Failed to build OVMF"
    exit 1
fi
echo "OVMF built successfully"

# Phase 6: Installation
echo "90" > "\$PROGRESS_FILE"
echo "Installing OVMF to system..." >> "\$PROGRESS_FILE"
echo "PHASE: Installing OVMF..."

OVMF_FILE="Build/OvmfX64/RELEASE_GCC5/FV/OVMF.fd"
if [[ -f "\$OVMF_FILE" ]]; then
    echo "OVMF binary found: \$OVMF_FILE"
    echo "Size: \$(du -h "\$OVMF_FILE" | cut -f1)"
    
    if sudo mkdir -p /usr/share/OVMF && sudo cp "\$OVMF_FILE" /usr/share/OVMF/OVMF.fd; then
        sudo chown root:root /usr/share/OVMF/OVMF.fd
        sudo chmod 644 /usr/share/OVMF/OVMF.fd
        echo "OVMF installed successfully to /usr/share/OVMF/OVMF.fd"
        echo "SUCCESS" > "\$PROGRESS_FILE.result"
    else
        echo "ERROR: Failed to install OVMF to system directory"
        exit 1
    fi
else
    echo "ERROR: OVMF binary not found after compilation"
    echo "Expected location: \$OVMF_FILE"
    echo "Directory contents:"
    find Build/ -name "*.fd" -type f 2>/dev/null || echo "No .fd files found"
    exit 1
fi

echo "95" > "\$PROGRESS_FILE"
echo "Cleaning up temporary files..." >> "\$PROGRESS_FILE"

echo "100" > "\$PROGRESS_FILE"
echo "Compilation completed successfully!" >> "\$PROGRESS_FILE"

echo
echo "=== Compilation completed successfully ==="
echo "Finished at: \$(date)"
EOF

    chmod +x "$compilation_script"

    # Run compilation with improved progress bar
    {
        # Start compilation in the background
        "$compilation_script" &
        local compilation_pid=$!
        
        # Monitor progress
        while kill -0 $compilation_pid 2>/dev/null; do
            if [[ -f "$temp_progress" ]]; then
                local percent=$(head -n 1 "$temp_progress" 2>/dev/null || echo "0")
                local message=$(tail -n 1 "$temp_progress" 2>/dev/null || echo "Compilation in progress...")
                
                # Validate progress (must be a number)
                if [[ "$percent" =~ ^[0-9]+$ ]] && [[ $percent -ge 0 ]] && [[ $percent -le 100 ]]; then
                    echo "$percent"
                    echo "# $message"
                fi
            else
                echo "5"
                echo "# Initializing..."
            fi
            sleep 2
        done
        
        # Wait for the process to complete and get exit status
        wait $compilation_pid
        local exit_status=$?
        
        # Final progress update
        if [[ $exit_status -eq 0 ]] && [[ -f "$temp_progress.result" ]]; then
            echo "100"
            echo "# Compilation completed successfully!"
            compilation_success=true
        else
            echo "100"
            echo "# Compilation failed with errors"
            compilation_success=false
        fi
        
    } | whiptail --gauge "OVMF compilation in progress..." 10 70 0

    # Analyze results
    local final_ovmf_file="/usr/share/OVMF/OVMF.fd"
    if [[ -f "$final_ovmf_file" ]]; then
        local file_size=$(stat -c%s "$final_ovmf_file" 2>/dev/null || echo "0")
        if [[ $file_size -gt 1000000 ]]; then
            whiptail --title "Compilation Completed" --msgbox \
                "OVMF compiled and installed successfully!\n\nPath: $final_ovmf_file\nSize: $(du -h $final_ovmf_file | cut -f1)" \
                10 60
            DEFAULT_BIOS="$final_ovmf_file"
        else
            whiptail --title "Corrupted File" --msgbox \
                "OVMF was created but appears corrupted.\nSize: $(du -h $final_ovmf_file 2>/dev/null | cut -f1 || echo "0")" \
                10 50
        fi
    else
        # Compilation failed if file does not exist
        local error_summary=""
        if [[ -f "$temp_log" ]]; then
            error_summary=$(grep -i "error\|failed\|fatal" "$temp_log" | tail -5 | cut -c1-60)
            if [[ -z "$error_summary" ]]; then
                error_summary="Unknown error during compilation"
            fi
        else
            error_summary="Compilation log not available"
        fi
        
        if whiptail --title "Compilation Failed" --yesno \
            "Error during OVMF compilation.\n\nLast errors:\n$error_summary\n\nWould you like to view the full log?" \
            15 70; then
            show_compilation_log "$temp_log"
        fi
    fi

    # Manual cleanup
    log_info "Cleaning up temporary files..."
    [[ -f "$compilation_script" ]] && rm -f "$compilation_script"
    [[ -f "$temp_log" ]] && rm -f "$temp_log"
    [[ -f "$temp_progress" ]] && rm -f "$temp_progress"
    [[ -f "$temp_progress.result" ]] && rm -f "$temp_progress.result"
    [[ -d "$temp_dir" ]] && rm -rf "$temp_dir"
    log_info "Cleanup completed"
}

# Show compilation log
show_compilation_log() {
    local log_file="$1"
    
    if [[ -f "$log_file" ]]; then
        # Create a filtered version of the log
        local filtered_log=$(mktemp)
        
        # Extract key sections
        {
            echo "=== COMPILATION PHASES ==="
            grep "PHASE:" "$log_file" 2>/dev/null || echo "No phases identified"
            echo
            echo "=== ERRORS ==="
            grep -i "error\|failed\|fatal" "$log_file" 2>/dev/null || echo "No explicit errors found"
            echo
            echo "=== LAST 20 LINES ==="
            tail -20 "$log_file" 2>/dev/null || echo "Log not readable"
        } > "$filtered_log"
        
        local log_content=$(cat "$filtered_log")
        whiptail --title "OVMF Compilation Log" --scrolltext \
            --msgbox "$log_content" 20 80
            
        rm -f "$filtered_log"
    else
        whiptail --title "Error" --msgbox "Log file not found or already deleted." 8 40
    fi
}

# Improved function to download prebuilt OVMF
download_ovmf_prebuilt() {
    if whiptail --title "Download OVMF" --yesno \
        "Would you like to download a prebuilt OVMF?\n\nThis is faster than compiling from source." \
        10 50; then
        
        local temp_log=$(mktemp)
        local install_success=false
        local progress_file=$(mktemp)

        # Cleanup
        cleanup_download() {
            rm -f "$temp_log" "$progress_file" 2>/dev/null
        }
        trap cleanup_download EXIT

        # Improved installation script
        {
            echo "10" > "$progress_file"
            echo "# Detecting package manager..." >> "$progress_file"
            
            # Detect package manager and install
            if command -v apt >/dev/null; then
                echo "20" > "$progress_file"
                echo "# Updating apt package database..." >> "$progress_file"
                sudo apt update >"$temp_log" 2>&1
                
                echo "50" > "$progress_file"
                echo "# Installing OVMF with apt..." >> "$progress_file"
                if sudo apt install -y ovmf >>"$temp_log" 2>&1; then
                    install_success=true
                fi
                
            elif command -v dnf >/dev/null; then
                echo "30" > "$progress_file"
                echo "# Installing OVMF with dnf..." >> "$progress_file"
                if sudo dnf install -y edk2-ovmf >>"$temp_log" 2>&1; then
                    install_success=true
                fi
                
            elif command -v pacman >/dev/null; then
                echo "30" > "$progress_file"
                echo "# Installing OVMF with pacman..." >> "$progress_file"
                if sudo pacman -S edk2-ovmf --noconfirm >>"$temp_log" 2>&1; then
                    install_success=true
                fi
                
            elif command -v zypper >/dev/null; then
                echo "30" > "$progress_file"
                echo "# Installing OVMF with zypper..." >> "$progress_file"
                if sudo zypper install -y ovmf >>"$temp_log" 2>&1; then
                    install_success=true
                fi
            else
                echo "ERROR: No supported package manager found"
            fi

            echo "80" > "$progress_file"
            echo "# Searching for OVMF files..." >> "$progress_file"
            
            echo "100" > "$progress_file"
            echo "# Completed" >> "$progress_file"
            
            # Report result
            if [[ "$install_success" == true ]]; then
                echo "SUCCESS" > "$progress_file.result"
            else
                echo "FAILED" > "$progress_file.result"
            fi
            
        } &
        local install_pid=$!
        
        # Monitor progress
        {
            while kill -0 $install_pid 2>/dev/null; do
                if [[ -f "$progress_file" ]]; then
                    local percent=$(head -n 1 "$progress_file" 2>/dev/null || echo "0")
                    local message=$(tail -n 1 "$progress_file" 2>/dev/null || echo "Download in progress...")
                    
                    if [[ "$percent" =~ ^[0-9]+$ ]]; then
                        echo "$percent"
                        echo "# $message"
                    fi
                fi
                sleep 1
            done
            
            wait $install_pid
            echo "100"
            echo "# Download completed"
            
        } | whiptail --gauge "Downloading OVMF..." 8 60 0
        
        # Check result and locate OVMF
        local found_path=""
        local ovmf_paths=(
            "/usr/share/OVMF/OVMF_CODE.fd"
            "/usr/share/ovmf/OVMF.fd" 
            "/usr/share/edk2-ovmf/OVMF_CODE.fd"
            "/usr/share/edk2/ovmf/OVMF_CODE.fd"
            "/usr/share/qemu/OVMF.fd"
            "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
        )
        
        for path in "${ovmf_paths[@]}"; do
            if [[ -f "$path" ]]; then
                found_path="$path"
                break
            fi
        done

        if [[ -n "$found_path" ]]; then
            DEFAULT_BIOS="$found_path"
            local file_size=$(du -h "$found_path" | cut -f1)
            whiptail --title "OVMF Found" --msgbox \
                "OVMF is now available!\n\nPath: $found_path\nSize: $file_size" \
                10 70
        else
            if [[ -f "$progress_file.result" ]] && [[ "$(cat "$progress_file.result")" == "SUCCESS" ]]; then
                whiptail --title "OVMF Installed" --msgbox \
                    "Installation succeeded, but the OVMF file was not found in standard paths.\n\nTry searching manually in /usr/share/" \
                    12 70
            else
                local error_msg="Installation failed."
                if [[ -f "$temp_log" ]]; then
                    local last_error=$(tail -3 "$temp_log" | grep -v "^$" | tail -1)
                    if [[ -n "$last_error" ]]; then
                        error_msg="$error_msg\n\nLast error:\n${last_error:0:100}"
                    fi
                fi
                
                whiptail --title "Download Failed" --msgbox "$error_msg" 12 70
            fi
        fi
    fi
}

# Function to check and install OVMF dependencies
install_ovmf_deps() {
    local missing=()
    command -v gcc >/dev/null || missing+=("build-essential")
    command -v nasm >/dev/null || missing+=("nasm")
    command -v iasl >/dev/null || missing+=("acpica-tools")
    command -v uuid >/dev/null || missing+=("uuid-dev")
    command -v uuid >/dev/null || missing+=("uuid")
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        if whiptail --title "Missing Dependencies" --yesno \
            "The following dependencies are missing for OVMF compilation:\n\n${missing[*]}\n\nWould you like to install them now?" \
            15 70; then
            
            local pkgs_to_install="${missing[*]}"
            
            # Install dependencies in the background with progress
            {
                echo "10" ; echo "Updating package indices..."
                sudo apt update >/dev/null 2>&1 || true
                
                echo "50" ; echo "Installing packages: ${pkgs_to_install}..."
                sudo apt install -y $pkgs_to_install >/dev/null 2>&1
                
                echo "100" ; echo "Completed."
            } | whiptail --gauge "Installing dependencies..." 8 70 0

            # Re-check dependencies after installation
            local missing_after_install=()
            command -v gcc >/dev/null || missing_after_install+=("build-essential")
            command -v nasm >/dev/null || missing_after_install+=("nasm")
            command -v iasl >/dev/null || missing_after_install+=("acpica-tools")
            command -v uuid >/dev/null || missing_after_install+=("uuid-dev")
            command -v uuid >/dev/null || missing_after_install+=("uuid")
            
            if [[ ${#missing_after_install[@]} -eq 0 ]]; then
                whiptail --title "Installation Successful" --msgbox \
                    "All dependencies have been successfully installed!" 8 50
                return 0
            else
                whiptail --title "Installation Failed" --msgbox \
                    "Failed to install dependencies. Still missing:\n\n${missing_after_install[*]}" 10 70
                return 1
            fi
        else
            return 1 # User canceled
        fi
    fi
    return 0 # No missing dependencies
}

# Build QEMU command
build_qemu_command() {
    local qemu_cmd=(
        qemu-system-x86_64
        -name "Ventoy Boot Test"
        -m "$MEMORY"
        -smp cores="$CORES",threads="$THREADS",sockets="$SOCKETS"
        -machine "$MACHINE_TYPE"
    )
    
    # USB controller based on version
    case "$USB_VERSION" in
        "1.1") qemu_cmd+=(-usb -device usb-storage,drive=usb-drive) ;;
        "2.0") qemu_cmd+=(-device ich9-usb-ehci1,id=ehci -device usb-storage,bus=ehci.0,drive=usb-drive) ;;
        "3.0") qemu_cmd+=(-device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=usb-drive) ;;
    esac
    
    # USB drive
    qemu_cmd+=(-drive file="$DISK",format="$FORMAT",if=none,id=usb-drive)
    
    # KVM if available
    if [[ -c /dev/kvm && -r /dev/kvm ]]; then
        qemu_cmd+=(-enable-kvm -cpu host,kvm=on)
    else
        qemu_cmd+=(-cpu qemu64)
    fi
    
    # BIOS/UEFI
    if [[ "$BIOS_MODE" == "uefi" ]]; then
        qemu_cmd+=(-bios "$DEFAULT_BIOS")
    fi
    
    # Video
    if [[ "$VGA_MODE" != "none" ]]; then
        qemu_cmd+=(-vga "$VGA_MODE")
        qemu_cmd+=(-display gtk,show-cursor=on)
    else
        qemu_cmd+=(-nographic)
    fi
    
    # Network
    if [[ "$NETWORK" == true ]]; then
        qemu_cmd+=(-netdev user,id=net0 -device e1000,netdev=net0)
    else
        qemu_cmd+=(-nic none)
    fi
    
    # Audio
    if [[ "$SOUND" == true ]]; then
        qemu_cmd+=(-audiodev pa,id=audio0 -device intel-hda -device hda-duplex,audiodev=audio0)
    fi
    
    # Monitor and serial
    qemu_cmd+=(-monitor telnet:127.0.0.1:4444,server,nowait -serial stdio)
    
    printf '%s\n' "${qemu_cmd[@]}"
}

# Confirm and run
confirm_and_run() {
    local qemu_cmd_array=()
    readarray -t qemu_cmd_array < <(build_qemu_command)
    local qemu_cmd_string="${qemu_cmd_array[*]}"
    
    # Show configuration summary
    local summary="VENTOY BOOT TEST CONFIGURATION\n\n"
    summary+="• Disk: $DISK\n"
    summary+="• Mode: $BIOS_MODE\n"
    summary+="• RAM: ${MEMORY}MB\n"
    summary+="• CPU: ${CORES}c/${THREADS}t/${SOCKETS}s\n"
    summary+="• USB: $USB_VERSION\n"
    summary+="• VGA: $VGA_MODE\n"
    summary+="• Network: $([[ $NETWORK == true ]] && echo "Yes" || echo "No")\n"
    summary+="• Audio: $([[ $SOUND == true ]] && echo "Yes" || echo "No")\n\n"
    summary+="Monitor: telnet localhost 4444"
    
    if ! whiptail --title "Confirm Execution" --yesno \
        "$summary" \
        18 60; then
        return
    fi
    
    # Save configuration
    save_config
    
    # Final confirmation
    if whiptail --title "Start Test" --yesno \
        "Start the boot test?\n\nPress Ctrl+C to terminate QEMU." \
        10 50; then
        
        clear
        log_info "=== VENTOY BOOT TEST STARTED ==="
        log_info "Monitor: telnet localhost 4444"
        log_info "Full QEMU command:\n$qemu_cmd_string"
        log_info "Press Ctrl+C to terminate"
        echo
        
        # Run QEMU
        if "${qemu_cmd_array[@]}"; then
            log_info "Test completed successfully"
        else
            log_error "Test failed with error"
        fi
        
        echo
        read -p "Press Enter to return to the menu..." -r
    fi
}

# Main menu
main_menu() {
    while true; do
        local disk_status="Not selected"
        [[ -n "$DISK" ]] && disk_status="$DISK"
        
        local choice
        choice=$(whiptail --title "$SCRIPT_NAME v$VERSION" \
            --menu "Main Menu - Select an option:" \
            18 70 8 \
            "1" "Select Disk/USB: $([[ -n "$DISK" ]] && basename "$DISK" || echo "Not selected")" \
            "2" "Boot Mode: $BIOS_MODE" \
            "3" "System Configuration" \
            "4" "Advanced Options" \
            "5" "System Information" \
            "6" "Save/Load Configuration" \
            "7" "START TEST!" \
            "8" "Exit" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) select_disk_menu ;;
            2) bios_menu ;;
            3) system_config_menu ;;
            4) advanced_menu ;;
            5) detect_system ;;
            6) config_management_menu ;;
            7) 
                if [[ -z "$DISK" ]]; then
                    whiptail --title "Error" --msgbox \
                        "Select a disk or image file first!" \
                        8 50
                else
                    confirm_and_run
                fi
                ;;
            8|"") 
                if whiptail --title "Confirm Exit" --yesno \
                    "Would you like to save the configuration before exiting?" \
                    8 50; then
                    save_config
                fi
                exit 0
                ;;
        esac
    done
}

# Configuration management menu
config_management_menu() {
    local choice
    choice=$(whiptail --title "Configuration Management" \
        --menu "Configuration options:" \
        12 60 4 \
        "1" "Save current configuration" \
        "2" "Load saved configuration" \
        "3" "Reset to default configuration" \
        "4" "Back" \
        3>&1 1>&2 2>&3)
    
    case $choice in
        1) 
            save_config
            whiptail --title "Saved" --msgbox "Configuration saved successfully!" 8 40
            ;;
        2)
            if [[ -f "$CONFIG_FILE" ]]; then
                load_config
                whiptail --title "Loaded" --msgbox "Configuration loaded successfully!" 8 40
            else
                whiptail --title "Error" --msgbox "No saved configuration found." 8 40
            fi
            ;;
        3)
            if whiptail --title "Reset Configuration" --yesno \
                "Reset to default values?\nThe current configuration will be lost." \
                10 50; then
                reset_to_defaults
                whiptail --title "Reset" --msgbox "Configuration reset to defaults." 8 50
            fi
            ;;
    esac
}

# Reset configuration to defaults
reset_to_defaults() {
    MEMORY="2048"
    CORES="4"
    THREADS="1"
    SOCKETS="1"
    MACHINE_TYPE="q35"
    DISK=""
    FORMAT="raw"
    BIOS_MODE="uefi"
    VGA_MODE="virtio"
    NETWORK=false
    SOUND=false
    USB_VERSION="3.0"
}

# Test both modes (UEFI and BIOS)
test_both_modes() {
    if [[ -z "$DISK" ]]; then
        whiptail --title "Error" --msgbox "Select a disk first!" 8 40
        return
    fi
    
    if ! whiptail --title "Dual Test" --yesno \
        "Test both UEFI and BIOS modes?\n\nTwo consecutive tests will be run." \
        10 50; then
        return
    fi
    
    # Test UEFI
    BIOS_MODE="uefi"
    if [[ ! -f "$DEFAULT_BIOS" ]]; then
        whiptail --title "OVMF Required" --msgbox \
            "OVMF is required for UEFI testing.\nSkipping UEFI test." \
            8 50
    else
        whiptail --title "UEFI Test" --msgbox \
            "Starting UEFI mode test...\nPress OK to continue." \
            8 40
        
        clear
        log_info "=== UEFI TEST STARTED ==="
        local qemu_cmd_array=()
        readarray -t qemu_cmd_array < <(build_qemu_command)
        "${qemu_cmd_array[@]}" || log_error "UEFI test failed"
        
        echo
        read -p "UEFI test completed. Press Enter for BIOS test..." -r
    fi
    
    # Test BIOS
    BIOS_MODE="bios"
    whiptail --title "BIOS Test" --msgbox \
        "Starting BIOS Legacy mode test...\nPress OK to continue." \
        8 40
    
    clear
    log_info "=== BIOS LEGACY TEST STARTED ==="
    local qemu_cmd_array=()
    readarray -t qemu_cmd_array < <(build_qemu_command)
    "${qemu_cmd_array[@]}" || log_error "BIOS test failed"
    
    echo
    log_info "Dual test completed!"
    read -p "Press Enter to return to the menu..." -r
}

# Advanced diagnostic menu
diagnostic_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "System Diagnostics" \
            --menu "Diagnostic tools:" \
            16 60 7 \
            "1" "Hardware Info" \
            "2" "KVM Test" \
            "3" "Verify Dependencies" \
            "4" "System Logs" \
            "5" "Disk Speed Test" \
            "6" "CPU Benchmark" \
            "7" "Back" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) show_hardware_info ;;
            2) test_kvm_functionality ;;
            3) verify_all_dependencies ;;
            4) show_system_logs ;;
            5) test_disk_speed ;;
            6) benchmark_cpu ;;
            7|"") break ;;
        esac
    done
}

# Show detailed hardware information
show_hardware_info() {
    local info=""
    
    # CPU Info
    local cpu_info=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
    local cpu_cores=$(nproc)
    local cpu_freq=$(lscpu | grep "CPU max MHz" | cut -d: -f2 | xargs || echo "N/A")
    
    # Memory Info
    local mem_total=$(free -h | awk '/^Mem:/{print $2}')
    local mem_avail=$(free -h | awk '/^Mem:/{print $7}')
    
    # Storage Info
    local disk_info=""
    if [[ -n "$DISK" && -b "$DISK" ]]; then
        disk_info=$(lsblk -d -o MODEL,SIZE "$DISK" 2>/dev/null | tail -1 || echo "N/A")
    fi
    
    # Virtualization
    local virt_support="No"
    if grep -q "vmx\|svm" /proc/cpuinfo; then
        virt_support="Yes ($(grep -o "vmx\|svm" /proc/cpuinfo | head -1 | tr 'a-z' 'A-Z'))"
    fi
    
    info="SYSTEM HARDWARE INFORMATION\n\n"
    info+="CPU:\n  ${cpu_info}\n  Cores: ${cpu_cores}\n  Max Freq: ${cpu_freq} MHz\n\n"
    info+="MEMORY:\n  Total: ${mem_total}\n  Available: ${mem_avail}\n\n"
    info+="VIRTUALIZATION:\n  Support: ${virt_support}\n  KVM: $([[ -c /dev/kvm ]] && echo "Available" || echo "Not available")\n\n"
    
    if [[ -n "$disk_info" ]]; then
        info+="SELECTED DISK:\n  ${disk_info}\n\n"
    fi
    
    info+="QEMU:\n  Version: $(qemu-system-x86_64 --version | head -1 || echo "N/A")"
    
    whiptail --title "Hardware Information" --scrolltext \
        --msgbox "$info" 20 70
}

# Test KVM functionality
test_kvm_functionality() {
    local result=""
    
    if [[ ! -c /dev/kvm ]]; then
        result="KVM is not available\n\nThe KVM module is not loaded."
    elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        result="KVM present but not accessible\n\nSolution:\nsudo usermod -a -G kvm $USER\n\nThen restart your session."
    else
        # Quick KVM test
        local test_result
        if timeout 10 qemu-system-x86_64 -enable-kvm -m 64 -nographic -no-reboot \
            -kernel /dev/null 2>/dev/null; then
            test_result="Functional"
        else
            test_result="Issues detected"
        fi
        
        result="KVM fully functional\n\n"
        result+="KVM Group: $(groups | grep -o kvm || echo "Not in group")\n"
        result+="Permissions: $(ls -l /dev/kvm)\n"
        result+="Quick Test: $test_result"
    fi
    
    whiptail --title "KVM Test" --msgbox "$result" 15 60
}

# Verify all dependencies
verify_all_dependencies() {
    local deps_info="DEPENDENCY VERIFICATION\n\n"
    
    local deps=(
        "qemu-system-x86_64:QEMU x86_64"
        "whiptail:Dialog TUI"
        "lsblk:Block utilities"
        "git:Version Control"
        "make:Build tools"
        "fdisk:Disk utilities"
        "free:Memory info"
        "lscpu:CPU info"
    )
    
    for dep in "${deps[@]}"; do
        local cmd="${dep%:*}"
        local desc="${dep#*:}"
        
        if command -v "$cmd" >/dev/null 2>&1; then
            deps_info+="✓ $desc ($cmd)\n"
        else
            deps_info+="✗ $desc ($cmd) - MISSING\n"
        fi
    done
    
    # Additional checks
    deps_info+="\nADDITIONAL CHECKS:\n"
    
    # OVMF
    if [[ -f "$DEFAULT_BIOS" ]]; then
        deps_info+="✓ OVMF present\n"
    else
        deps_info+="⚠ OVMF missing (required for UEFI)\n"
    fi
    
    # KVM Group
    if groups | grep -q kvm; then
        deps_info+="✓ User in KVM group\n"
    else
        deps_info+="⚠ User not in KVM group\n"
    fi
    
    whiptail --title "Dependency Verification" --scrolltext \
        --msgbox "$deps_info" 20 70
}

# Show system logs (placeholder)
show_system_logs() {
    whiptail --title "System Logs" --msgbox \
        "System log function not implemented.\n\nFor now, use: journalctl -f" \
        10 50
}

# Disk speed test
test_disk_speed() {
    if [[ -z "$DISK" ]]; then
        whiptail --title "Error" --msgbox "Select a disk first!" 8 40
        return
    fi
    
    if [[ ! -b "$DISK" ]]; then
        whiptail --title "Info" --msgbox "Disk speed test is only available for block devices." 10 50
        return
    fi
    
    if ! whiptail --title "Disk Speed Test" --yesno \
        "Test read speed of $DISK?\n\nThe test is safe (read-only)." \
        10 50; then
        return
    fi
    
    local temp_result=$(mktemp)
    
    {
        echo "10"; echo "# Preparing test..."
        sleep 1
        echo "30"; echo "# Sequential read test..."
        sudo hdparm -t "$DISK" > "$temp_result" 2>&1 || echo "hdparm error" > "$temp_result"
        echo "70"; echo "# Cache read test..."
        sudo hdparm -T "$DISK" >> "$temp_result" 2>&1 || echo "Cache test error" >> "$temp_result"
        echo "100"; echo "# Completed"
    } | whiptail --gauge "Disk speed test in progress..." 8 50 0
    
    local result
    result=$(cat "$temp_result")
    rm -f "$temp_result"
    
    whiptail --title "Disk Speed Test Results" --scrolltext \
        --msgbox "Device: $DISK\n\n$result" 15 70
}

# Simple CPU benchmark
benchmark_cpu() {
    if ! command -v bc >/dev/null; then
        whiptail --title "Error" --msgbox \
            "bc (calculator) is not installed.\nInstall with: sudo apt install bc" \
            10 50
        return
    fi
    
    if ! whiptail --title "CPU Benchmark" --yesno \
        "Run a quick CPU benchmark?\n\nDuration: approximately 10 seconds." \
        10 50; then
        return
    fi
    
    local result=""
    
    {
        echo "20"; echo "# Calculating Pi..."
        local pi_time
        pi_time=$(time (echo "scale=1000; 4*a(1)" | bc -l) 2>&1 | grep real | awk '{print $2}')
        
        echo "60"; echo "# Arithmetic test..."
        local arith_start arith_end arith_time
        arith_start=$(date +%s%N)
        for i in {1..100000}; do
            echo "scale=2; sqrt($i)" | bc -l >/dev/null
        done
        arith_end=$(date +%s%N)
        arith_time=$(echo "scale=3; ($arith_end - $arith_start) / 1000000000" | bc)
        
        echo "100"; echo "# Completed"
        
        result="CPU BENCHMARK\n\n"
        result+="CPU: $(nproc) cores\n"
        result+="Model: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)\n\n"
        result+="Pi calculation (1000 decimals): ${pi_time}\n"
        result+="Arithmetic test (100k ops): ${arith_time}s\n\n"
        result+="Note: Results are indicative for relative comparison"
        
    } | whiptail --gauge "Benchmark in progress..." 8 50 0
    
    whiptail --title "Benchmark Results" --scrolltext \
        --msgbox "$result" 15 60
}

# Enhanced main menu with diagnostics
enhanced_main_menu() {
    while true; do
        local disk_info=""
        if [[ -n "$DISK" ]]; then
            if [[ -b "$DISK" ]]; then
                local size=$(lsblk -d -o SIZE "$DISK" 2>/dev/null | tail -1 || echo "?")
                disk_info="$(basename "$DISK") (${size})"
            else
                disk_info="$(basename "$DISK")"
            fi
        else
            disk_info="Not selected"
        fi
        
        local choice
        choice=$(whiptail --title "$SCRIPT_NAME v$VERSION" \
            --menu "Main Menu:" \
            20 75 10 \
            "1" "Disk/USB: $disk_info" \
            "2" "Boot: $BIOS_MODE $([[ $BIOS_MODE == "uefi" && -f "$DEFAULT_BIOS" ]] && echo "✓" || [[ $BIOS_MODE == "bios" ]] && echo "✓" || echo "⚠")" \
            "3" "System: ${MEMORY}MB RAM, ${CORES}c CPU" \
            "4" "Advanced: VGA=$VGA_MODE, USB=$USB_VERSION" \
            "5" "Diagnostics & System Info" \
            "6" "Configuration" \
            "7" "START SINGLE TEST!" \
            "8" "DUAL TEST (UEFI+BIOS)" \
            "9" "Help" \
            "0" "Exit" \
            3>&1 1>&2 2>&3)
        
        case $choice in
            1) select_disk_menu ;;
            2) bios_menu ;;
            3) system_config_menu ;;
            4) advanced_menu ;;
            5) diagnostic_menu ;;
            6) config_management_menu ;;
            7) 
                if [[ -z "$DISK" ]]; then
                    whiptail --title "Error" --msgbox "Select a disk first!" 8 40
                else
                    confirm_and_run
                fi
                ;;
            8) test_both_modes ;;
            9) show_help ;;
            0|"") 
                if whiptail --title "Exit" --yesno \
                    "Save configuration before exiting?" \
                    8 50; then
                    save_config
                fi
                clear
                log_info "Thank you for using $SCRIPT_NAME!"
                exit 0
                ;;
        esac
    done
}

# Help system
show_help() {
    local help_text="VENTOY BOOT TESTER GUIDE\n\n"
    help_text+="USAGE:\n"
    help_text+="1. Select a USB device or image file\n"
    help_text+="2. Configure boot mode (UEFI/BIOS)\n"
    help_text+="3. Adjust system parameters if needed\n"
    help_text+="4. Start the test\n\n"
    help_text+="BOOT MODES:\n"
    help_text+="• UEFI: Modern, requires OVMF\n"
    help_text+="• BIOS: Legacy, for older systems\n"
    help_text+="• Auto: Detects automatically from partitions\n\n"
    help_text+="QEMU CONTROLS:\n"
    help_text+="• Ctrl+Alt+G: Release mouse\n"
    help_text+="• Ctrl+Alt+F: Fullscreen\n"
    help_text+="• Ctrl+C: Terminate emulation\n"
    help_text+="• Monitor: telnet localhost 4444\n\n"
    help_text+="TROUBLESHOOTING:\n"
    help_text+="• No KVM: Check module and permissions\n"
    help_text+="• OVMF missing: Compile or download\n"
    help_text+="• Boot fails: Verify partition table\n\n"
    help_text+="For support: Diagnostics → Verify dependencies"
    
    whiptail --title "User Guide" --scrolltext \
        --msgbox "$help_text" 22 70
}

# Initial comprehensive checks
initial_checks() {
    # Fundamental checks
    check_dependencies
    
    # Welcome banner
    whiptail --title "Welcome" --msgbox \
        "$SCRIPT_NAME v$VERSION\n\nInteractive script for testing Ventoy USB boot\nwith UEFI and BIOS Legacy support.\n\nLoading..." \
        12 60
    
    # Load configuration if it exists
    load_config
    
    # Setup logging
    mkdir -p "$LOG_DIR"
    log_info "$SCRIPT_NAME v$VERSION started"
    log_info "Log directory: $LOG_DIR"
}

# Main function
main() {
    initial_checks
    enhanced_main_menu
}

# Execute only if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi