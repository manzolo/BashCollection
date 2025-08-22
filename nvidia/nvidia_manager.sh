#!/bin/bash

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

# Function to check NVIDIA driver status
check_driver_status() {
    clear
    echo "Checking NVIDIA driver status..."
    if command -v nvidia-smi &> /dev/null; then
        whiptail --title "NVIDIA Driver Status" --msgbox "$(nvidia-smi)" 25 100
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

    local DRIVERS_MENU
    readarray -t DRIVERS_MENU <<< "$DRIVER_LIST"

    # Add empty strings for whiptail menu format
    for i in "${!DRIVERS_MENU[@]}"; do
        DRIVERS_MENU[$i]+=" "
    done
    
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
    if ! command -v docker &> /dev/null; then
        whiptail --title "Container Toolkit" --msgbox "Docker is not installed. The NVIDIA Container Toolkit requires Docker." 10 70
        return
    fi
    
    if command -v docker run --gpus all nvidia/cuda:11.0.3-base-ubuntu20.04 nvidia-smi &> /dev/null; then
        whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit is already installed and working." 10 70
        return
    fi

    if whiptail --title "Install Container Toolkit" --yesno "The NVIDIA Container Toolkit is not installed. Do you want to install it now?" 10 70; then
        echo "Installing the NVIDIA Container Toolkit repository..."
        # Add the GPG key
        if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
            whiptail --title "Error" --msgbox "Could not add the NVIDIA repository GPG key. Check your connection." 10 60
            return
        fi
        
        # Add the repository
        if ! curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list; then
            whiptail --title "Error" --msgbox "Could not add the NVIDIA repository. Check your connection." 10 60
            return
        fi

        # Install the toolkit
        echo "Installing packages..."
        if apt-get update && apt-get install -y nvidia-container-toolkit; then
            # Restart Docker
            echo "Restarting Docker to apply changes..."
            if systemctl restart docker; then
                whiptail --title "Container Toolkit" --msgbox "NVIDIA Container Toolkit installed and configured successfully. You may need to reboot your system to complete the installation." 15 70
            else
                whiptail --title "Warning" --msgbox "NVIDIA Container Toolkit installed, but Docker restart failed. Please reboot your system manually." 15 70
            fi
        else
            whiptail --title "Error" --msgbox "Error installing the NVIDIA Container Toolkit." 10 60
        fi
    else
        whiptail --title "Container Toolkit" --msgbox "Container Toolkit installation canceled." 10 60
    fi
}

# Main menu
while true; do
    CHOICE=$(whiptail --title "NVIDIA Driver Manager" --menu "Choose an option" 17 60 5 \
        "1" "Check Driver Status" \
        "2" "Clean Drivers" \
        "3" "Search and Install Drivers" \
        "4" "Manage Container Toolkit" \
        "5" "Exit" 3>&1 1>&2 2>&3)

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
            exit 0
            ;;
        *)
            exit 0
            ;;
    esac
done
