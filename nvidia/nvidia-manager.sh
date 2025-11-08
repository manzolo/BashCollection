#!/bin/bash
# PKG_NAME: nvidia-manager
# PKG_VERSION: 1.0.1
# PKG_SECTION: admin
# PKG_PRIORITY: optional
# PKG_ARCHITECTURE: all
# PKG_DEPENDS: bash (>= 4.0), whiptail
# PKG_RECOMMENDS: 
# PKG_MAINTAINER: Manzolo <manzolo@libero.it>
# PKG_DESCRIPTION: Interactive NVIDIA driver and GPU management tool
# PKG_LONG_DESCRIPTION: TUI-based tool for managing NVIDIA drivers and GPU settings.
#  .
#  Features:
#  - Check NVIDIA driver status with nvidia-smi
#  - Install and update NVIDIA drivers
#  - Configure GPU settings
#  - Monitor GPU usage and temperature
#  - Interactive whiptail-based interface
# PKG_HOMEPAGE: https://github.com/manzolo/BashCollection

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Check if whiptail is installed
if ! command -v whiptail &> /dev/null; then
    echo "whiptail is not installed. Installing..."
    if ! apt-get update || ! apt-get install -y whiptail; then
        echo "Error: Could not install whiptail. Check your connection and repositories."
        exit 1
    fi
fi

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Function to check NVIDIA driver status
check_driver_status() {
    clear
    echo "Checking NVIDIA driver status..."
    if command -v nvidia-smi &> /dev/null; then
        nvidia-smi
        read -p ""
    else
        whiptail --title "NVIDIA Driver Status" --msgbox "NVIDIA driver not detected or not working correctly." 10 60
    fi
}

# Function to clean NVIDIA drivers
clean_drivers() {
    if whiptail --title "Clean NVIDIA Drivers" --yesno "This operation will remove all NVIDIA drivers. Continue?" 10 60; then
        echo "Removing NVIDIA drivers..."
        if apt-get remove --purge -y 'nvidia-*' 'libnvidia-*' && apt-get autoremove -y && apt-get autoclean; then
            whiptail --title "Clean NVIDIA Drivers" --msgbox "NVIDIA drivers removed successfully." 10 60
        else
            whiptail --title "Clean NVIDIA Drivers" --msgbox "An error occurred while removing the drivers." 10 60
        fi
    else
        whiptail --title "Clean NVIDIA Drivers" --msgbox "Operation canceled." 10 60
    fi
}

# Function to search for available NVIDIA drivers
search_drivers() {
    clear
    echo "Searching for available NVIDIA drivers..."
    if ! apt-get update; then
        whiptail --title "Driver Search" --msgbox "Could not update repositories. Check your connection." 10 60
        return
    fi
    
    local DRIVER_LIST
    DRIVER_LIST=$(apt-cache search --names-only '^nvidia-driver-[0-9]+' | awk '{print $1}')
    
    if [ -z "$DRIVER_LIST" ]; then
        whiptail --title "Driver Search" --msgbox "No NVIDIA drivers found." 10 60
        return
    fi

    # Create proper whiptail menu format (tag description pairs)
    local DRIVERS_MENU=()
    while IFS= read -r driver; do
        DRIVERS_MENU+=("$driver" "NVIDIA Driver $driver")
    done <<< "$DRIVER_LIST"
    
    CHOICE=$(whiptail --title "Available NVIDIA Drivers" --menu "Select a driver to install" 25 78 15 "${DRIVERS_MENU[@]}" 3>&1 1>&2 2>&3)
    
    if [ -n "$CHOICE" ]; then
        if whiptail --title "Driver Installation" --yesno "Install $CHOICE?" 10 60; then
            install_driver "$CHOICE"
        fi
    else
        whiptail --title "Driver Installation" --msgbox "No driver selected." 10 60
    fi
}

# Function to install a specific NVIDIA driver
install_driver() {
    local driver_name=$1
    echo "Installing $driver_name..."
    if apt-get update && apt-get install -y "$driver_name"; then
        whiptail --title "Driver Installation" --msgbox "$driver_name installed successfully." 10 60
    else
        whiptail --title "Driver Installation" --msgbox "Error installing $driver_name." 10 60
    fi
}

# Function to check and install the NVIDIA Container Toolkit
check_and_install_toolkit() {
    # Check for container runtime (Docker or containerd)
    local runtime=""
    if command -v docker &> /dev/null; then
        runtime="docker"
    elif command -v containerd &> /dev/null; then
        runtime="containerd"
    else
        whiptail --title "Container Toolkit" --msgbox "No supported container runtime (Docker or containerd) found." 10 70
        return
    fi

    # Check if NVIDIA Container Toolkit is functional
    local toolkit_installed=false
    local test_image="nvidia/cuda:12.2.0-base-ubuntu22.04" # Specific version for broader compatibility
    if [ "$runtime" = "docker" ]; then
        # Attempt to pull the image first to avoid transient failures
        if docker pull "$test_image" &> /dev/null; then
            if docker run --rm --gpus all "$test_image" nvidia-smi &> /dev/null; then
                toolkit_installed=true
            fi
        fi
    elif [ "$runtime" = "containerd" ]; then
        if ctr images pull docker.io/"$test_image" && \
           ctr run --rm --gpus 0 docker.io/"$test_image" test nvidia-smi &> /dev/null; then
            toolkit_installed=true
        fi
    fi

    if $toolkit_installed; then
        local version=$(nvidia-container-toolkit --version 2>/dev/null || echo "Unknown")
        whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit is installed (Version: $version) and working." 10 70
        return
    fi

    # Prompt to install or update toolkit
    if whiptail --title "Install Container Toolkit" --yesno "NVIDIA Container Toolkit is not installed or not working. Install/update it?" 10 70; then
        echo "Setting up NVIDIA Container Toolkit repository..."

        # Add NVIDIA Container Toolkit repository
        local distro=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
        local release=$(lsb_release -rs)
        local repo_url="https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list"
        local gpg_key="https://nvidia.github.io/libnvidia-container/gpgkey"
        local keyring="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"

        # Check if GPG key exists to avoid overwrite prompt
        if [ -f "$keyring" ]; then
            echo "GPG key already exists at $keyring. Skipping key download."
        else
            if ! curl -fsSL "$gpg_key" | sudo gpg --dearmor -o "$keyring"; then
                whiptail --title "Error" --msgbox "Could not add NVIDIA GPG key. Check your connection." 10 60
                return
            fi
        fi

        # Add repository with proper signed-by syntax
        if ! curl -fsSL "$repo_url" | \
            sed 's|deb |deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] |' | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
            whiptail --title "Error" --msgbox "Could not add NVIDIA repository. Check your connection." 10 60
            return
        fi

        # Install or update the toolkit
        echo "Installing NVIDIA Container Toolkit..."
        if apt-get update && apt-get install -y nvidia-container-toolkit; then
            # Configure runtime based on detected runtime
            if [ "$runtime" = "docker" ]; then
                if nvidia-ctk runtime configure --runtime=docker && systemctl restart docker; then
                    whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured for Docker." 10 70
                else
                    whiptail --title "Warning" --msgbox "Toolkit installed, but Docker configuration failed. Please check manually." 15 70
                fi
            elif [ "$runtime" = "containerd" ]; then
                if nvidia-ctk runtime configure --runtime=containerd && systemctl restart containerd; then
                    whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured for containerd." 10 70
                else
                    whiptail --title "Warning" --msgbox "Toolkit installed, but containerd configuration failed. Please check manually." 15 70
                fi
            fi

            # Suggest reboot if needed
            if [ -f "/var/run/reboot-required" ]; then
                if whiptail --title "Reboot Required" --yesno "A system reboot is required to complete the installation. Reboot now?" 10 60; then
                    reboot
                else
                    whiptail --title "Reboot Required" --msgbox "Please reboot your system manually to complete the installation." 10 60
                fi
            fi
        else
            whiptail --title "Error" --msgbox "Error installing NVIDIA Container Toolkit." 10 60
        fi
    else
        whiptail --title "Container Toolkit" --msgbox "Installation canceled." 10 60
    fi
}

# Troubleshooting NVIDIA
troubleshoot_nvidia() {
    log "Running NVIDIA troubleshooting..."
    
    echo "=== NVIDIA Troubleshooting Report ==="
    echo "Generated: $(date)"
    echo
    
    # 1. Verifica presenza driver host
    local host_version
    host_version=$(detect_host_nvidia)
    
    # 2. Verifica container
    detect_container_nvidia
    
    # 3. Test OpenGL
    echo "=== OpenGL Test ==="
    if command -v glxinfo >/dev/null 2>&1; then
        local gl_renderer
        gl_renderer=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -n1)
        if [[ "$gl_renderer" =~ NVIDIA ]]; then
            success "$gl_renderer"
        else
            warning "OpenGL renderer: $gl_renderer"
        fi
    else
        warning "glxinfo not available (install mesa-utils)"
    fi
    echo
    
    # 4. Test CUDA (se disponibile)
    echo "=== CUDA Test ==="
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            success "nvidia-smi working"
            nvidia-smi -L 2>/dev/null || warning "Could not list GPU devices"
        else
            error "nvidia-smi failed"
        fi
    else
        warning "nvidia-smi not available"
    fi
    echo
    
    # 5. Verifica device nodes
    echo "=== Device Nodes ==="
    local nvidia_devices=(
        "/dev/nvidia0"
        "/dev/nvidiactl"
        "/dev/nvidia-modeset"
        "/dev/nvidia-uvm"
    )
    
    for device in "${nvidia_devices[@]}"; do
        if [ -e "$device" ]; then
            success "Found: $device"
        else
            warning "Missing: $device"
        fi
    done
    echo
    
    echo
    log "Troubleshooting completed"
    read -p ""
}

# Rileva driver NVIDIA host
detect_host_nvidia() {
    log "Detecting host NVIDIA driver..."
    
    local host_version=""
    local detection_method=""
    
    # Metodo 1: /proc/driver/nvidia/version
    if [ -f "/proc/driver/nvidia/version" ]; then
        host_version=$(sed -nE 's/.*Module[ \t]+([0-9]+\.[0-9]+).*/\1/p' /proc/driver/nvidia/version | head -n1)
        if [ -n "$host_version" ]; then
            detection_method="/proc/driver/nvidia/version"
        fi
    fi
    
    # Metodo 2: nvidia-smi
    if [ -z "$host_version" ] && command -v nvidia-smi >/dev/null 2>&1; then
        host_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ')
        if [ -n "$host_version" ]; then
            detection_method="nvidia-smi"
        fi
    fi
    
    # Metodo 3: modinfo
    if [ -z "$host_version" ] && command -v modinfo >/dev/null 2>&1; then
        host_version=$(modinfo nvidia 2>/dev/null | grep '^version:' | awk '{print $2}')
        if [ -n "$host_version" ]; then
            detection_method="modinfo"
        fi
    fi
    
    echo "=== Host NVIDIA Driver ==="
    if [ -n "$host_version" ]; then
        success "Version: $host_version"
        echo "Detection method: $detection_method"
        echo "Major version: $(echo "$host_version" | cut -d. -f1)"
    else
        warning "No NVIDIA driver detected on host"
    fi
    echo
    
    echo "$host_version"
}

# Rileva driver container
detect_container_nvidia() {
    log "Detecting container NVIDIA packages..."
    
    echo "=== Container NVIDIA Packages ==="
    
    local nvidia_packages
    nvidia_packages=$(dpkg -l 2>/dev/null | awk '$1 == "ii" && $2 ~ /nvidia/ {printf "%-30s %s\n", $2, $3}')
    
    if [ -n "$nvidia_packages" ]; then
        echo "$nvidia_packages"
        
        # Estrai versione principale
        local main_version
        main_version=$(dpkg -l 2>/dev/null | \
            awk '$1 == "ii" && $2 ~ /^libnvidia-gl-/ {print $3}' | \
            sed -nE 's/^([0-9]+(\.[0-9]+)?).*/\1/p' | \
            head -n1)
        
        if [ -n "$main_version" ]; then
            success "Primary driver version: $main_version"
        fi
    else
        warning "No NVIDIA packages found in container"
    fi
    echo
}

# Main menu
while true; do
    CHOICE=$(whiptail --title "NVIDIA Driver Manager" --menu "Choose an option" 17 60 5 \
        "1" "Check Driver Status" \
        "2" "Clean Drivers" \
        "3" "Search and Install Drivers" \
        "4" "Manage Container Toolkit" \
        "5" "Troubleshoot" \
        "6" "Exit" 3>&1 1>&2 2>&3)

    case $CHOICE in
        1)
            check_driver_status
            ;;
        2)
            clean_drivers
            ;;
        3)
            search_drivers
            ;;
        4)
            check_and_install_toolkit
            ;;
		5)	
            troubleshoot_nvidia
            ;;            
        6)
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
done
